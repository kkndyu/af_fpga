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
// V2: both the activations and the weights are loaded at runtime.  Nothing is
// read from a .mem file at synthesis time any more - see wbank_region.v for why.
// -----------------------------------------------------------------------------
module gemv_engine #(
    parameter K_LEN      = `H_DIM,
    parameter K_ADDR_W   = `H_ADDR_W
)(
    input                         clk,
    input                         rst_n,

    input                         start,
    output reg                    busy,
    output reg                    done,

    // Weight load port (V2).
    //
    // One whole 256-bit row per cycle.  w_wr_region picks which of the four banks
    // receives it: the banks hold four different column slices of the weight
    // matrix, so they need different data and cannot share one write strobe.
    //
    // A 256-bit port at the board level would be 256 pins, which the board does
    // not have, so this port is driven internally (by the loader) and never
    // becomes a top-level pin.
    input                         w_wr_en,
    input      [1:0]              w_wr_region,
    input      [K_ADDR_W-1:0]     w_wr_addr,
    input      [`REGION_WCODE_W-1:0] w_wr_data,

    // Activation load port.  Broadcast to all four regions: every region needs
    // the same activation vector, so one write reaches four buffers.
    input                         act_wr_en,
    input      [K_ADDR_W-1:0]     act_wr_addr,
    input      [`ACT_W-1:0]       act_wr_data,

    // Weight readback.
    //
    // The serialiser lives INSIDE this module, next to the banks, on purpose.
    //
    // The first version put weight_readback in moe_loader and brought the whole
    // REGION_WCODE_W-bit row out through four module boundaries.  That turned
    // each bank's read data into a second, far-away load (1024 nets dragged across
    // the die) and forced the loader to sit in the middle of a four-way 256-bit
    // star while it also had to stay near the AXI bridge and the UART.  Resource
    // use was unchanged (-114 LUT, -141 FF) but route_design went from 499 s to
    // over 40 minutes, because the placement of the whole engine was compromised.
    //
    // Keeping the row selection local costs the same handful of LUTs and leaves
    // the external interface at 40 narrow bits instead of 256.
    input                         rb_start,
    input      [1:0]              rb_region,
    input      [K_ADDR_W-1:0]     rb_addr,
    input      [15:0]             rb_nrows,
    input                         rb_byte_ready,
    output     [7:0]              rb_byte_out,
    output                        rb_byte_valid,
    output                        rb_done,

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

    // Readback takes over the shared bank read port.  When rb_bank_en is low this
    // is the engine's own behaviour, unchanged.  The caller must not start a
    // readback during a GEMV.
    wire                   rb_bank_en;
    wire [1:0]             rb_bank_region;
    wire [K_ADDR_W-1:0]    rb_bank_addr;
    wire [`REGION_WCODE_W-1:0] rb_row;      // LOCAL: never leaves this module

    wire                   bank_rd_en   = rb_bank_en ? 1'b1 : rd_en;

    assign rb_row = (rb_bank_region == 2'd0) ? wcode_r0 :
                    (rb_bank_region == 2'd1) ? wcode_r1 :
                    (rb_bank_region == 2'd2) ? wcode_r2 : wcode_r3;

    weight_readback #(
        .ROW_W (`REGION_WCODE_W),
        .ADDR_W(K_ADDR_W)
    ) u_readback (
        .clk        (clk),
        .rst_n      (rst_n),
        .start      (rb_start),
        .region     (rb_region),
        .addr       (rb_addr),
        .nrows      (rb_nrows),
        .rb_en      (rb_bank_en),
        .rb_region  (rb_bank_region),
        .rb_addr    (rb_bank_addr),
        .rb_data    (rb_row),
        .byte_out   (rb_byte_out),
        .byte_valid (rb_byte_valid),
        .byte_ready (rb_byte_ready),
        .busy       (),
        .done       (rb_done)
    );

    // ------------------------------------------------------------------
    // Weight write port, REGISTERED at the destination
    // ------------------------------------------------------------------
    // The 256-bit write bus runs from the loader, across the die, to the data
    // pins of all four banks.  Unregistered it was the design's worst setup path
    // once the readback problems were fixed:
    //
    //   +0.071 ns, u_loader/w_wr_data -> u_wbank_r2/mem
    //
    // while the next worst path anywhere had +3.934 ns.  One long bus was setting
    // the timing of the whole design.
    //
    // Registering here costs about 270 flops (the device is 8 % used) and turns
    // the bank's data pins into a short register-to-BRAM hop.  The write lands one
    // cycle later, which nothing can notice: the loader commits one row per 32
    // bytes over a link that costs about a millisecond per byte.
    //
    // All four fields are registered together so enable/region/address/data keep
    // their exact relationship; the loader holds them stable for the single cycle
    // that w_wr_en is high.
    reg                       w_wr_en_q;
    reg [1:0]                 w_wr_region_q;
    reg [K_ADDR_W-1:0]        w_wr_addr_q;
    reg [`REGION_WCODE_W-1:0] w_wr_data_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            w_wr_en_q     <= 1'b0;
            w_wr_region_q <= 2'd0;
            w_wr_addr_q   <= {K_ADDR_W{1'b0}};
            w_wr_data_q   <= {`REGION_WCODE_W{1'b0}};
        end else begin
            w_wr_en_q     <= w_wr_en;
            w_wr_region_q <= w_wr_region;
            w_wr_addr_q   <= w_wr_addr;
            w_wr_data_q   <= w_wr_data;
        end
    end

    wbank_region #(
        .DEPTH(K_LEN),
        .ADDR_W(K_ADDR_W),
        .DATA_W(`REGION_WCODE_W)
    ) u_wbank_r0 (
        .clk(clk),
        .wr_en(w_wr_en_q && (w_wr_region_q == 2'd0)),
        .wr_addr(w_wr_addr_q),
        .wr_data(w_wr_data_q),
        .rd_en(bank_rd_en),
        .rd_addr(k_idx),
        .rd_data(wcode_r0)
    );

    wbank_region #(
        .DEPTH(K_LEN),
        .ADDR_W(K_ADDR_W),
        .DATA_W(`REGION_WCODE_W)
    ) u_wbank_r1 (
        .clk(clk),
        .wr_en(w_wr_en_q && (w_wr_region_q == 2'd1)),
        .wr_addr(w_wr_addr_q),
        .wr_data(w_wr_data_q),
        .rd_en(bank_rd_en),
        .rd_addr(k_idx),
        .rd_data(wcode_r1)
    );

    wbank_region #(
        .DEPTH(K_LEN),
        .ADDR_W(K_ADDR_W),
        .DATA_W(`REGION_WCODE_W)
    ) u_wbank_r2 (
        .clk(clk),
        .wr_en(w_wr_en_q && (w_wr_region_q == 2'd2)),
        .wr_addr(w_wr_addr_q),
        .wr_data(w_wr_data_q),
        .rd_en(bank_rd_en),
        .rd_addr(k_idx),
        .rd_data(wcode_r2)
    );

    wbank_region #(
        .DEPTH(K_LEN),
        .ADDR_W(K_ADDR_W),
        .DATA_W(`REGION_WCODE_W)
    ) u_wbank_r3 (
        .clk(clk),
        .wr_en(w_wr_en_q && (w_wr_region_q == 2'd3)),
        .wr_addr(w_wr_addr_q),
        .wr_data(w_wr_data_q),
        .rd_en(bank_rd_en),
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

                default: state <= S_IDLE;
            endcase

            // Readback drives the address by LOADING THE COUNTER, not by muxing
            // the address.
            //
            // The mux version cost one LUT level directly in front of the BRAM
            // address pins and immediately became the worst setup path in the
            // design:
            //
            //   -0.063 ns, u_gate_gemv/c_reg[5] -> u_wbank_r1/mem/ADDRBWRADDR[10]
            //
            // With the counter loaded instead, k_idx stays a plain register output
            // straight to the BRAM.  The engine is idle during readback, and
            // S_IDLE/S_CLEAR both reload c from zero on the next GEMV, so the
            // readback address cannot leak into a computation.
            if (rb_bank_en) c <= {1'b0, rb_bank_addr};
        end
    end

endmodule
