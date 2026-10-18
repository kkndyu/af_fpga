`include "moe_params.vh"

// -----------------------------------------------------------------------------
// result_readout
// -----------------------------------------------------------------------------
// Exposes the 256-lane accumulator vector through a narrow, one-byte-at-a-time
// interface, and holds nothing of its own.
//
// Why a narrow interface at all
// ----------------------------
// The GEMV produces OUT_VEC_W = 256 * 32 = 8192 flattened bits.  As a top-level
// port that would mean 8192 output pads; the AX7203B has 285.  So the result has
// to leave through a window, one byte at a time.
//
// Why there is no snapshot buffer any more
// ----------------------------------------
// Earlier versions copied all 256 accumulators into a local 256 x 32 register
// file (`res_buf`, 8192 flip-flops) and then indexed that copy.  That was pure
// overhead: the copy is indexed exactly like the original, so the selector cost
// is identical either way, while the accumulators already hold their value -
// they are only cleared when the next GEMV begins, and this board runs exactly
// one GEMV per reset.
//
// Removing it saves 8192 flip-flops (3 % of the device) and deletes 8192 bits of
// pointless fan-out.
//
// Why the selector is split into two levels
// -----------------------------------------
// Reading one lane out of 256 is a 256:1 mux on 32 bits.  Measured at a 200 MHz
// constraint it was the critical path of the ENTIRE design:
//
//   lane_idx_reg[*] -> lane_word_q_reg[*]
//   4.744 ns, 6 levels (LUT6 x2, MUXF7 x2, MUXF8 x2)
//
// which is absurd for a readout that is not even on the compute path.  But the
// structure is already partitioned: 4 regions of 64 lanes.  So select per region
// first (64:1, four of them in parallel), register, then pick one of four (4:1).
//
//   stage 1: acc_flat[g*2048 + lane_lo*32 +: 32]   for g = 0..3   (64:1 each)
//   register: cand_q[0..3], lane_hi_q
//   stage 2: cand_q[lane_hi_q]                                    (4:1)
//
// Each stage is now about 4 and 1 levels deep, and every 64:1 mux reads only
// from its own region, so the routing is local as well.
//
// Readout protocol
// ----------------
//   pulse rd_start
//   then one lane word per 6 cycles:
//     phase 0      : lane_lo settles through the 64:1 muxes
//     phases 1..4  : byte 0..3 of the lane word
//     phase 5      : spare, index advances
//   byte 0 = bits  7:0  (little endian)
//   byte 1 = bits 15:8
//   byte 2 = bits 23:16
//   byte 3 = bits 31:24
//
// rd_lane / rd_byte / rd_data are registered together, so a consumer sampling on
// one clock edge sees a consistent triple.
//
// rd_pause freezes the sequencer, letting a slow consumer (a UART, at 17360
// engine cycles per byte) throttle the stream without any FIFO.
// -----------------------------------------------------------------------------
module result_readout (
    input                          clk,
    input                          rst_n,

    // The live accumulator vector, lane j of region g at
    // [(g*REGION_LANES + j)*ACC_W +: ACC_W].  Read directly - no copy is kept.
    input      [`OUT_ACC_W-1:0]    acc_flat,

    // Narrow readout interface.
    input                          rd_start,     // pulse to begin streaming
    // V2: which lane to start from.  Before this, every readout began at lane 0
    // and streamed to the end, so a host could not ask for "lanes 64..127" - the
    // only way to reach a later range was to read everything from the start and
    // discard.  With a per-inference protocol that is a real limitation, and the
    // fix is one assignment below.
    input      [`E_ADDR_W-1:0]     rd_start_lane,
    input                          rd_pause,     // hold the stream (slow consumer)
    output reg                     rd_valid,
    output reg [`E_ADDR_W-1:0]     rd_lane,      // 0 .. OUT_LANES-1
    output reg [1:0]               rd_byte,      // 0 .. 3
    output reg [7:0]               rd_data,
    output reg                     rd_busy
);

    // Region size in bits, and the split of the lane index.
    localparam RW           = `REGION_ACC_W;                 // 64 * 32 = 2048
    localparam REGION_BITS  = 2;                             // log2(4 regions)
    localparam LANE_LO_W    = `E_ADDR_W - REGION_BITS;       // 6

    reg [`E_ADDR_W-1:0] lane_idx;

    // Phase within one lane.
    reg [2:0]  ph;
    reg        active;

    wire [REGION_BITS-1:0] lane_hi = lane_idx[`E_ADDR_W-1 : LANE_LO_W];
    wire [LANE_LO_W-1:0]   lane_lo = lane_idx[LANE_LO_W-1 : 0];

    wire [1:0] byte_idx  = ((ph >= 3'd1) && (ph <= 3'd4)) ? (ph[1:0] - 2'd1) : 2'd0;
    wire       valid_now = active && (ph >= 3'd1) && (ph <= 3'd4);

    // ------------------------------------------------------------------
    // Stage 1 - one 64:1 selector per region, reading only that region
    // ------------------------------------------------------------------
    wire [`ACC_W-1:0] cand0 = acc_flat[0*RW + lane_lo*`ACC_W +: `ACC_W];
    wire [`ACC_W-1:0] cand1 = acc_flat[1*RW + lane_lo*`ACC_W +: `ACC_W];
    wire [`ACC_W-1:0] cand2 = acc_flat[2*RW + lane_lo*`ACC_W +: `ACC_W];
    wire [`ACC_W-1:0] cand3 = acc_flat[3*RW + lane_lo*`ACC_W +: `ACC_W];

    reg [`ACC_W-1:0]  cand_q [0:3];
    reg [REGION_BITS-1:0] lane_hi_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cand_q[0]  <= {`ACC_W{1'b0}};
            cand_q[1]  <= {`ACC_W{1'b0}};
            cand_q[2]  <= {`ACC_W{1'b0}};
            cand_q[3]  <= {`ACC_W{1'b0}};
            lane_hi_q  <= {REGION_BITS{1'b0}};
        end else begin
            cand_q[0] <= cand0;
            cand_q[1] <= cand1;
            cand_q[2] <= cand2;
            cand_q[3] <= cand3;
            lane_hi_q <= lane_hi;
        end
    end

    // ------------------------------------------------------------------
    // Stage 2 - pick the region, then the byte
    // ------------------------------------------------------------------
    wire [`ACC_W-1:0] lane_word = cand_q[lane_hi_q];

    reg [7:0] selected_byte;

    always @* begin
        case (byte_idx)
            2'd0:    selected_byte = lane_word[7:0];
            2'd1:    selected_byte = lane_word[15:8];
            2'd2:    selected_byte = lane_word[23:16];
            default: selected_byte = lane_word[31:24];
        endcase
    end

    // ------------------------------------------------------------------
    // Readout sequencer
    // ------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active   <= 1'b0;
            lane_idx <= {`E_ADDR_W{1'b0}};
            ph       <= 3'd0;
            rd_valid <= 1'b0;
            rd_busy  <= 1'b0;
            rd_lane  <= {`E_ADDR_W{1'b0}};
            rd_byte  <= 2'd0;
            rd_data  <= 8'd0;
        end else begin
            // All three payload registers carry the previous cycle's tuple, so
            // a consumer sampling on one edge always sees a consistent
            // (lane, byte, data) triple.
            rd_lane  <= lane_idx;
            rd_byte  <= byte_idx;
            rd_data  <= selected_byte;
            rd_valid <= valid_now;
            rd_busy  <= active;

            if (!active) begin
                if (rd_start) begin
                    active   <= 1'b1;
                    lane_idx <= rd_start_lane;
                    ph       <= 3'd0;
                end
            end else if (!rd_pause) begin
                // Frozen while rd_pause is high, so the registered outputs hold
                // the byte that the slow consumer is still taking.
                if (ph == 3'd5) begin
                    ph <= 3'd0;
                    if (lane_idx == `OUT_LANES - 1) begin
                        active <= 1'b0;
                    end else begin
                        lane_idx <= lane_idx + {{(`E_ADDR_W-1){1'b0}}, 1'b1};
                    end
                end else begin
                    ph <= ph + 3'd1;
                end
            end
        end
    end

endmodule
