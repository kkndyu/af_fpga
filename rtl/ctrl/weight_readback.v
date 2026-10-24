`include "moe_params.vh"

// -----------------------------------------------------------------------------
// weight_readback - stream a weight row back out as bytes
// -----------------------------------------------------------------------------
// Until now the contents of the weight banks were unobservable.  A GEMV row
// feeds all 256 outputs, so a misplaced row shows up in the result, but "the
// answer is wrong" says nothing about *which* stage is wrong, and confirming a
// load meant running a whole computation.
//
// wbank_region already has an independent read port - one write port, one read
// port, separate addresses - and all four banks share rd_en and the address.  So
// when the engine is idle the read port is free: assert rd_en with a chosen
// address, wait one cycle for the bank's registered output, and the whole
// REGION_WCODE_W-bit row appears.  No extra memory, no extra port, no change to
// wbank_region at all.
//
// This module drives that port and serialises the row into bytes, most
// significant byte first, so the output is directly comparable with the .mem
// file the host loaded from (which is also MSB first).
//
//   start ─┐
//          v
//   RB_IDLE ──(nrows != 0)──> RB_WAIT ──(row valid)──> RB_STREAM
//                                 ^                        │
//                                 │                        │ 32 bytes
//                                 └──(rows remain)─────────┘
//                                                          │
//                                                          └─> done
//
// byte_ready is the consumer's backpressure.  A byte is presented on byte_out
// with byte_valid until byte_ready is high, and only then does the stream
// advance, so no byte can be lost or duplicated when the reply FIFO fills.
// -----------------------------------------------------------------------------
module weight_readback #(
    parameter ROW_W  = `REGION_WCODE_W,
    // Bytes per row = ROW_W / 8 = 32.  This was originally written as
    // REGION_LANES, which is the LANE count (64), not the byte count - each lane
    // is 4 bits, so the row is 64*4/8 = 32 bytes.  With 64 the stream ran twice
    // as long, and the second half indexed past the top of row_q
    // (row_q[255 - 32*8] = row_q[-1]), which reads as X.  The visible symptom was
    // "first row correct, everything after it wrong or X".
    parameter BYTES  = ROW_W / 8,
    parameter ADDR_W = `H_ADDR_W
)(
    input                     clk,
    input                     rst_n,

    // Request
    input                     start,
    input      [1:0]          region,
    input      [ADDR_W-1:0]   addr,
    input      [15:0]         nrows,           // 0 = read nothing

    // Weight bank read port (shared by all four banks)
    output reg                rb_en,
    output     [1:0]          rb_region,
    output reg [ADDR_W-1:0]   rb_addr,
    input      [ROW_W-1:0]    rb_data,         // registered bank output

    // Byte stream out.  byte_out is COMBINATIONAL from row_q and byte_idx, so
    // byte_idx always names the byte currently being presented.  When it was a
    // register the index had already advanced past the byte on offer, so the
    // last_byte test fired one byte early and every row lost its final byte.
    output [7:0]              byte_out,
    output reg                byte_valid,
    input                     byte_ready,

    output                    busy,            // continuous assignment, not a reg
    output reg                done
);

    localparam ST_IDLE   = 3'd0;
    localparam ST_WAIT   = 3'd1;
    localparam ST_WAIT2  = 3'd4;
    localparam ST_CAP    = 3'd2;
    localparam ST_STREAM = 3'd3;

    reg [2:0]          st;
    reg [ADDR_W-1:0]   cur_addr;
    reg [15:0]         rows_left;
    reg [5:0]          byte_idx;               // 0 .. BYTES-1 (BYTES <= 32)
    reg [1:0]          region_r;
    reg [ROW_W-1:0]    row_q;

    assign rb_region = region_r;
    assign busy      = (st != ST_IDLE) || done;
    assign byte_out  = row_q[ROW_W - 1 - byte_idx*8 -: 8];

    wire last_byte = (byte_idx == BYTES[5:0] - 6'd1);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st         <= ST_IDLE;
            rb_en      <= 1'b0;
            rb_addr    <= {ADDR_W{1'b0}};
            cur_addr   <= {ADDR_W{1'b0}};
            rows_left  <= 16'd0;
            byte_idx   <= 6'd0;
            region_r   <= 2'd0;
            row_q      <= {ROW_W{1'b0}};
            byte_valid <= 1'b0;
            done       <= 1'b0;
        end else begin
            done <= 1'b0;

            case (st)
                // ----------------------------------------------------------
                ST_IDLE: begin
                    byte_valid <= 1'b0;
                    if (start) begin
                        region_r  <= region;
                        cur_addr  <= addr;
                        rows_left <= nrows;
                        if (nrows == 16'd0) begin
                            done <= 1'b1;
                        end else begin
                            // Address the bank, then give its registered output
                            // one cycle before looking at it.
                            rb_en   <= 1'b1;
                            rb_addr <= addr;
                            st      <= ST_WAIT;
                        end
                    end
                end

                // ----------------------------------------------------------
                // Three cycles, not one.
                //
                // The address now reaches the bank through the engine's counter
                // rather than through a mux in front of the BRAM pins (that mux
                // was the design's worst setup path at -0.063 ns), so it takes
                // one extra cycle:
                //   cycle 1  rb_addr presented, engine counter loads it
                //   cycle 2  the counter drives the bank address; the bank samples
                //   cycle 3  rd_data is valid
                ST_WAIT: begin
                    st <= ST_WAIT2;
                end

                ST_WAIT2: begin
                    st <= ST_CAP;
                end

                ST_CAP: begin
                    row_q    <= rb_data;
                    byte_idx <= 6'd0;
                    st       <= ST_STREAM;
                end

                // ----------------------------------------------------------
                ST_STREAM: begin
                    if (!byte_valid) begin
                        // byte_out is already correct combinationally; one cycle
                        // is spent raising valid so the consumer never samples a
                        // half-settled index.
                        byte_valid <= 1'b1;
                    end else if (byte_ready) begin
                        if (last_byte) begin
                            byte_valid <= 1'b0;
                            byte_idx   <= 6'd0;
                            rows_left  <= rows_left - 16'd1;
                            if (rows_left == 16'd1) begin
                                rb_en <= 1'b0;
                                st    <= ST_IDLE;
                                done  <= 1'b1;
                            end else begin
                                rb_addr  <= cur_addr + {{(ADDR_W-1){1'b0}}, 1'b1};
                                cur_addr <= cur_addr + {{(ADDR_W-1){1'b0}}, 1'b1};
                                // Keep rb_en high so the next row is already in
                                // flight when ST_WAIT is entered.
                                st       <= ST_WAIT;
                            end
                        end else begin
                            byte_idx <= byte_idx + 6'd1;
                        end
                    end
                end

                default: st <= ST_IDLE;
            endcase
        end
    end

endmodule
