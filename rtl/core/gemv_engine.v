`include "moe_params.vh"

// -----------------------------------------------------------------------------
// gemv_engine
// -----------------------------------------------------------------------------
// Single GEMV stage prototype:
//
//   acc[j] = sum_k product16(x[k])[ W[k][j] ]
//
// Current first-version assumptions:
//   - OUT_LANES=256, split into 4 regions x 64 lanes.
//   - K_PAR=1.  One activation element is consumed per accumulation cycle.
//   - One output block only.  This directly covers gate/up output width E=256.
//   - Down stage can reuse this block repeatedly outside this module.
//
// The activation buffer can be loaded through act_wr_* ports before start.
// Region weight banks are initialized from four .mem files.
// -----------------------------------------------------------------------------
module gemv_engine #(
    parameter K_LEN      = `H_DIM,
    parameter K_ADDR_W   = `H_ADDR_W,
    parameter INIT_R0    = "mem_init/expert0/gate_r0.mem",
    parameter INIT_R1    = "mem_init/expert0/gate_r1.mem",
    parameter INIT_R2    = "mem_init/expert0/gate_r2.mem",
    parameter INIT_R3    = "mem_init/expert0/gate_r3.mem"
)(
    input                         clk,
    input                         rst_n,

    input                         start,
    output reg                    busy,
    output reg                    done,

    // Activation load port.
    input                         act_wr_en,
    input      [K_ADDR_W-1:0]     act_wr_addr,
    input      [`ACT_W-1:0]       act_wr_data,

    // Flattened accumulator output, lane j at [j*ACC_W +: ACC_W].
    output     [`OUT_ACC_W-1:0]   acc_flat
);

    localparam S_IDLE   = 2'd0;
    localparam S_CLEAR  = 2'd1;
    localparam S_RUN    = 2'd2;
    localparam S_DONE   = 2'd3;

    // ------------------------------------------------------------------
    // Pipeline depth
    // ------------------------------------------------------------------
    // How many cycles from "issue the read for tap k" to "tap k is being
    // accumulated":
    //
    //   1  read      : rd_en, address k; the region's activation BRAM registers
    //   2  act reg   : act_q -> act_q_q inside each mac_region
    //   3  product   : act_q_q -> candidates -> prod16_q, wcode_d -> lane wcode_q
    //   4  select    : prod16_q + wcode_q -> 16:1 mux -> sel_prod_q
    //   5  acc enable: acc_en -> acc_en_q inside each mac_region
    //   6  accumulate: sel_prod_q -> 32-bit adder -> acc_out
    //
    // This is the whole reason the FSM no longer walks one tap at a time.  The
    // previous structure spent 3 cycles per tap and only the last one did any
    // work, so 256 lanes produced 256 MACs per 3 cycles - 33 % utilisation.  In
    // a pipeline the accumulator runs EVERY cycle on a different tap, so
    // utilisation goes to 100 %.
    //
    // It also makes the extra register stages free: adding a stage costs one
    // cycle of latency once per GEMV, not one cycle per tap.
    //
    // DATA_LATENCY and EN_DELAY must be kept in step with the registers inside
    // mac_region / mac_lane.  Getting the relationship wrong does not break
    // anything loudly - it just drops the first taps and double-counts the last
    // one.  That is exactly what happened when the acc_en register was added and
    // the window was not shifted: the checksum read ffffc6dd instead of
    // ffffc6e2.  Whenever a stage is added, DATA_LATENCY goes up by one.
    localparam DATA_LATENCY = 4;   // read issue -> selected product at the adder
    localparam EN_DELAY     = 1;   // mac_region registers acc_en once

    // acc_en must lead the data window by EN_DELAY so that, after the region's
    // register, the accumulator is enabled on exactly the cycles where taps
    // 0 .. K_LEN-1 are sitting on its inputs.
    localparam ACC_FIRST = DATA_LATENCY - EN_DELAY;              // 2
    localparam ACC_LAST  = K_LEN + DATA_LATENCY - 1 - EN_DELAY;  // 1025
    localparam RUN_END   = K_LEN + DATA_LATENCY - 1;             // 1026

    reg [1:0]           state;
    reg [K_ADDR_W:0]    c;         // cycle counter inside S_RUN, 0 .. K_LEN+DEPTH

    reg rd_en;
    reg clear_acc;
    reg acc_en;

    // Read address: the counter's low bits.  It wraps past K_LEN, which is
    // harmless because rd_en is gated off at that point.
    wire [K_ADDR_W-1:0] k_idx = c[K_ADDR_W-1:0];

    // No act_q wire here any more: the activation buffer and its read data are
    // entirely inside mac_region.

    // ------------------------------------------------------------------
    // Product generation now lives inside each mac_region.
    // ------------------------------------------------------------------
    // The engine used to own one fp4_product_gen plus four registered copies of
    // its 384-bit output.  Measured behaviour of that shape:
    //
    //   * the four copies hold the same value, so the synthesiser merged them -
    //     declaring 1536 product bits grew the flip-flop count by only 307;
    //   * the resulting 100 MHz critical path started at
    //     prod16_region_flat_reg[*] and spent 82 % of its 9.064 ns in routing,
    //     i.e. the merged registers were NOT beside the regions they feed;
    //   * before the copies existed, the activation net measured 4.425 ns with
    //     fanout 1288, about four replicated product generators' worth of load.
    //
    // So the fanout was already being paid for, just in the wrong place.  Moving
    // the generator behind the region boundary makes four genuinely separate
    // pieces of logic, each driving only its own 64 lanes, and reduces what
    // crosses that boundary from FP4_CODES*PROD_W = 384 bits to ACT_W = 16.
    //
    // The pipeline does not change: S_REQ reads the memories, S_PROD gives the
    // per-region product register its cycle, S_ACC selects and accumulates.  A
    // tap is still 3 cycles.

    wire [`REGION_WCODE_W-1:0] wcode_r0;
    wire [`REGION_WCODE_W-1:0] wcode_r1;
    wire [`REGION_WCODE_W-1:0] wcode_r2;
    wire [`REGION_WCODE_W-1:0] wcode_r3;

    wire [`REGION_ACC_W-1:0] acc_r0;
    wire [`REGION_ACC_W-1:0] acc_r1;
    wire [`REGION_ACC_W-1:0] acc_r2;
    wire [`REGION_ACC_W-1:0] acc_r3;

    assign acc_flat[0*`REGION_ACC_W +: `REGION_ACC_W] = acc_r0;
    assign acc_flat[1*`REGION_ACC_W +: `REGION_ACC_W] = acc_r1;
    assign acc_flat[2*`REGION_ACC_W +: `REGION_ACC_W] = acc_r2;
    assign acc_flat[3*`REGION_ACC_W +: `REGION_ACC_W] = acc_r3;

    // The activation buffer now lives INSIDE each mac_region - see mac_region.v
    // for the measurement that forced it.  The engine only broadcasts the load
    // port and the read address; it no longer holds the vector itself.
    //
    // This is symmetric with the product generator (517) and the weight
    // distribution, both of which are already per-region: the diagram draws one
    // region, and there are four of everything.

    wbank_region #(
        .DEPTH(K_LEN),
        .ADDR_W(K_ADDR_W),
        .DATA_W(`REGION_WCODE_W),
        .INIT_FILE(INIT_R0)
    ) u_wbank_r0 (
        .clk(clk),
        .rd_en(rd_en),
        .rd_addr(k_idx),
        .rd_data(wcode_r0)
    );

    wbank_region #(
        .DEPTH(K_LEN),
        .ADDR_W(K_ADDR_W),
        .DATA_W(`REGION_WCODE_W),
        .INIT_FILE(INIT_R1)
    ) u_wbank_r1 (
        .clk(clk),
        .rd_en(rd_en),
        .rd_addr(k_idx),
        .rd_data(wcode_r1)
    );

    wbank_region #(
        .DEPTH(K_LEN),
        .ADDR_W(K_ADDR_W),
        .DATA_W(`REGION_WCODE_W),
        .INIT_FILE(INIT_R2)
    ) u_wbank_r2 (
        .clk(clk),
        .rd_en(rd_en),
        .rd_addr(k_idx),
        .rd_data(wcode_r2)
    );

    wbank_region #(
        .DEPTH(K_LEN),
        .ADDR_W(K_ADDR_W),
        .DATA_W(`REGION_WCODE_W),
        .INIT_FILE(INIT_R3)
    ) u_wbank_r3 (
        .clk(clk),
        .rd_en(rd_en),
        .rd_addr(k_idx),
        .rd_data(wcode_r3)
    );

    mac_region u_region0 (
        .clk(clk),
        .rst_n(rst_n),
        .clear_acc(clear_acc),
        .acc_en(acc_en),
        .act_wr_en(act_wr_en),
        .act_wr_addr(act_wr_addr),
        .act_wr_data(act_wr_data),
        .act_rd_en(rd_en),
        .act_rd_addr(k_idx),
        .wcode_row(wcode_r0),
        .acc_vec_flat(acc_r0)
    );

    mac_region u_region1 (
        .clk(clk),
        .rst_n(rst_n),
        .clear_acc(clear_acc),
        .acc_en(acc_en),
        .act_wr_en(act_wr_en),
        .act_wr_addr(act_wr_addr),
        .act_wr_data(act_wr_data),
        .act_rd_en(rd_en),
        .act_rd_addr(k_idx),
        .wcode_row(wcode_r1),
        .acc_vec_flat(acc_r1)
    );

    mac_region u_region2 (
        .clk(clk),
        .rst_n(rst_n),
        .clear_acc(clear_acc),
        .acc_en(acc_en),
        .act_wr_en(act_wr_en),
        .act_wr_addr(act_wr_addr),
        .act_wr_data(act_wr_data),
        .act_rd_en(rd_en),
        .act_rd_addr(k_idx),
        .wcode_row(wcode_r2),
        .acc_vec_flat(acc_r2)
    );

    mac_region u_region3 (
        .clk(clk),
        .rst_n(rst_n),
        .clear_acc(clear_acc),
        .acc_en(acc_en),
        .act_wr_en(act_wr_en),
        .act_wr_addr(act_wr_addr),
        .act_wr_data(act_wr_data),
        .act_rd_en(rd_en),
        .act_rd_addr(k_idx),
        .wcode_row(wcode_r3),
        .acc_vec_flat(acc_r3)
    );

    always @* begin
        rd_en     = 1'b0;
        clear_acc = 1'b0;
        acc_en    = 1'b0;

        case (state)
            S_CLEAR: begin
                clear_acc = 1'b1;
            end
            S_RUN: begin
                // Keep issuing reads for taps 0 .. K_LEN-1.
                rd_en  = (c < K_LEN);
                // Enable the accumulators so that, once the region's acc_en
                // register has delayed this by EN_DELAY, the add happens on
                // exactly the cycles where taps 0 .. K_LEN-1 are on the mux
                // inputs.
                acc_en = (c >= ACC_FIRST) && (c <= ACC_LAST);
            end
            default: begin
                rd_en     = 1'b0;
                clear_acc = 1'b0;
                acc_en    = 1'b0;
            end
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            busy  <= 1'b0;
            done  <= 1'b0;
            c     <= {(K_ADDR_W+1){1'b0}};
        end else begin
            done <= 1'b0;

            case (state)
                S_IDLE: begin
                    busy <= 1'b0;
                    c    <= {(K_ADDR_W+1){1'b0}};
                    if (start) begin
                        busy  <= 1'b1;
                        state <= S_CLEAR;
                    end
                end

                // One cycle to clear every accumulator before the first add.
                S_CLEAR: begin
                    c     <= {(K_ADDR_W+1){1'b0}};
                    state <= S_RUN;
                end

                // Free-running pipeline.  The counter advances every cycle;
                // rd_en and acc_en are derived from it above, so a new tap is
                // issued every cycle while a completed tap is accumulated every
                // cycle.
                S_RUN: begin
                    c <= c + 1'b1;
                    if (c == RUN_END) begin
                        state <= S_DONE;
                    end
                end

                S_DONE: begin
                    busy  <= 1'b0;
                    done  <= 1'b1;
                    state <= S_IDLE;
                end

                default: begin
                    state <= S_IDLE;
                end
            endcase
        end
    end

endmodule
