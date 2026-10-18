`include "moe_params.vh"

// -----------------------------------------------------------------------------
// moe_proto_board
// -----------------------------------------------------------------------------
// ALINX AX7203B board level wrapper.
//
//   part : xc7a200tfbg484-2
//   clock: 200 MHz differential oscillator on R4 / T4 (DIFF_SSTL15)
//   reset: rst_n on T6, active low (LVCMOS15)
//   led  : B13 / C13 / D14 / D15 (LVCMOS33)
//
// Clock input style follows the factory led_test.v: a differential input pair
// buffered through IBUFDS.  The constraint file therefore drives only
// sys_clk_p; sys_clk_n is handled by the IBUFDS primitive.
//
// The GEMV engine cannot drive act_wr_* from outside the FPGA, so this wrapper
// self-starts: it loads the activation vector from an inferred ROM and then
// pulses start.  This is the on-board stimulus source for ILA bring-up.
// -----------------------------------------------------------------------------
module moe_proto_board (
    input         sys_clk_p,
    input         sys_clk_n,
    input         rst_n,
    output [3:0]  led
);

    // ------------------------------------------------------------------
    // Clock
    // ------------------------------------------------------------------
    //
    // THE BOARD OSCILLATOR IS 200 MHz, NOT 100 MHz.
    //
    // The factory design proves it: led_test.v counts 49_999_999 cycles for
    // "0.25 sec", which is only true at 200 MHz, and its own constraint file
    // says create_clock -period 5.000.
    //
    // The engine's routed critical path is 9.268 ns, so it tops out just under
    // 108 MHz and CANNOT run at 200 MHz.  An earlier build "closed timing" only
    // because the build script overrode the constraint to 10 ns - which changed
    // the analysis target but not the hardware.  The FPGA therefore ran the
    // logic at twice the frequency it was signed off for, and the checksum came
    // out wrong (three LEDs lit instead of four).
    //
    // Both the RTL simulation and a gate-level simulation of the routed netlist
    // produce the expected value, which pins the fault on timing rather than
    // logic.
    //
    // So divide the oscillator down and let the engine run at a rate it was
    // actually closed for.
    //
    //   DIV_BITS = 1  ->  /2  -> 100 MHz  (current; closed at +0.732 ns once)
    //   DIV_BITS = 2  ->  /4  ->  50 MHz  (the cautious first hardware run)
    //
    // Keep DIV_BITS and the XDC's create_generated_clock -divide_by in step.
    // build/moe/build_moe.tcl checks them against each other and refuses to
    // build a bitstream if they disagree.
    //   DIV_BITS = 0  ->  /1  -> 200 MHz  (direct, no division)
    //   DIV_BITS = 1  ->  /2  -> 100 MHz
    //   DIV_BITS = 2  ->  /4  ->  50 MHz  (the cautious first hardware run)
    //
    // Keep DIV_BITS and the XDC's create_generated_clock -divide_by in step.
    // build/moe/build_moe.tcl checks them against each other and refuses to
    // build a bitstream if they disagree.
    localparam DIV_BITS  = 0;
    localparam BLINK_BIT = 24;              // ~6 Hz at 200 MHz (see blink_cnt)

    wire sys_clk_raw;
    wire clk_engine_raw;
    wire sys_clk;

    IBUFDS u_sys_clk_ibufds (
        .O  (sys_clk_raw),
        .I  (sys_clk_p),
        .IB (sys_clk_n)
    );

    // DIV_BITS = 0 means "do not divide": the engine runs straight off the
    // oscillator.  Only viable because the pipelined engine's critical path is
    // now a single region's mux plus adder rather than a 384-bit broadcast.
    generate
        if (DIV_BITS == 0) begin : g_no_div
            assign clk_engine_raw = sys_clk_raw;
        end else begin : g_div
            reg [DIV_BITS-1:0] div_cnt;
            reg                clk_div_q;

            always @(posedge sys_clk_raw or negedge rst_n) begin
                if (!rst_n) begin
                    div_cnt   <= {DIV_BITS{1'b0}};
                    clk_div_q <= 1'b0;
                end else begin
                    div_cnt <= div_cnt + 1'b1;
                    // Toggle when the counter is 1: with DIV_BITS=2 that happens
                    // at counts 1 and 3, so the output period is 4 input cycles
                    // (/4).  With DIV_BITS=1 it toggles every cycle (/2).
                    if (div_cnt == 1'b1) begin
                        clk_div_q <= ~clk_div_q;
                    end
                end
            end

            assign clk_engine_raw = clk_div_q;
        end
    endgenerate

    // A register driving a clock net needs a global buffer, otherwise the skew
    // is uncontrolled.  Vivado would usually infer one, but naming it here keeps
    // the constraint file's generated-clock reference unambiguous.
    BUFG u_bufg_engine (
        .I (clk_engine_raw),
        .O (sys_clk)
    );

    // ------------------------------------------------------------------
    // Startup sequencer: load activations from ROM, then start one GEMV
    // ------------------------------------------------------------------
    localparam LOAD_LAST = `H_DIM - 1;

    // One-shot sequencer.
    //
    // The previous version stayed in a wait state and re-armed 'start' whenever
    // it saw !done && !done_d && !busy.  After the first GEMV finished, done
    // pulsed for one cycle and then dropped, so that condition became true
    // again and the engine restarted forever.  Every restart re-captured the
    // result and re-ran the readout, and because result_checksum is never
    // cleared it accumulated run after run - the board would have shown a
    // steadily changing value that could never equal the expected one.
    //
    // Board-level simulation caught this before any bitstream was programmed:
    // the checksum read fff8a322 instead of ffffc6e2 and busy was still high.
    //
    // S_FIN latches, so the GEMV runs exactly once per reset.
    localparam S_LOAD  = 2'd0;
    localparam S_START = 2'd1;
    localparam S_RUN   = 2'd2;
    localparam S_FIN   = 2'd3;

    (* rom_style = "block" *) reg [`ACT_W-1:0] act_rom [0:`H_DIM-1];

    reg [1:0]                st;
    reg [`H_ADDR_W-1:0]      ld_idx;
    reg                      act_wr_en;
    reg [`H_ADDR_W-1:0]      act_wr_addr;
    reg [`ACT_W-1:0]         act_wr_data;
    reg                      start;
    reg                      rd_start;
    reg [3:0]                led_r;

    wire busy;
    wire done;

    // Narrow readout window onto the captured GEMV result.
    wire                     rd_valid;
    wire [`E_ADDR_W-1:0]     rd_lane;
    wire [1:0]               rd_byte;
    wire [7:0]               rd_data;
    wire                     rd_busy;
    wire [31:0]              result_checksum;

    // Readout throttle.  Tied low for now, which keeps the stream free-running
    // exactly as before.  It exists so the readout can be slowed without a FIFO
    // when a UART is attached: at 115200 baud a byte takes 17360 engine cycles,
    // while the readout produces one every 6, so the readout MUST be able to
    // wait.  Wiring it to a slow consumer is then a one-line change here.
    wire                     rd_pause = 1'b0;

    integer i;

    initial begin
        for (i = 0; i < `H_DIM; i = i + 1) begin
            act_rom[i] = {`ACT_W{1'b0}};
        end
        $readmemh("sim/data/input.mem", act_rom);
    end

    // Sequencer.  Loads the activations, launches exactly one GEMV, starts the
    // readout when it completes, then latches in S_FIN forever.
    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) begin
            st           <= S_LOAD;
            ld_idx       <= {`H_ADDR_W{1'b0}};
            act_wr_en    <= 1'b0;
            act_wr_addr  <= {`H_ADDR_W{1'b0}};
            act_wr_data  <= {`ACT_W{1'b0}};
            start        <= 1'b0;
            rd_start     <= 1'b0;
        end else begin
            // Both are one-cycle pulses.
            start    <= 1'b0;
            rd_start <= 1'b0;

            case (st)
                S_LOAD: begin
                    act_wr_en   <= 1'b1;
                    act_wr_addr <= ld_idx;
                    act_wr_data <= act_rom[ld_idx];

                    if (ld_idx == LOAD_LAST) begin
                        st <= S_START;
                    end else begin
                        ld_idx <= ld_idx + {{(`H_ADDR_W-1){1'b0}}, 1'b1};
                    end
                end

                // One idle cycle after the last write, then launch.
                S_START: begin
                    act_wr_en <= 1'b0;
                    start     <= 1'b1;
                    st        <= S_RUN;
                end

                // Wait for the engine to report completion.  done is a single
                // cycle; on it, result_readout snapshots the accumulators
                // (capture is wired to done) and the readout is kicked off.
                S_RUN: begin
                    if (done) begin
                        rd_start <= 1'b1;
                        st       <= S_FIN;
                    end
                end

                // Latch.  Returning to S_LOAD here would restart the whole
                // GEMV and make the checksum meaningless.
                S_FIN: begin
                    st <= S_FIN;
                end

                default: begin
                    st <= S_LOAD;
                end
            endcase
        end
    end

    // ------------------------------------------------------------------
    // Status LEDs: self-judging PASS / FAIL instead of a few raw bits
    // ------------------------------------------------------------------
    // The previous mapping exposed busy, done and two xor-fold bits.  That is
    // almost useless at the bench: done is a single cycle, busy lasts ~60 us,
    // and "all LEDs in one state" cannot be told apart from "the FPGA was never
    // configured".  A wrong pattern then forces a guessing game - exactly what
    // happened when three LEDs came on and there was no way to tell which bit
    // was responsible.
    //
    // So compare on-chip against the golden checksum and show the verdict as a
    // slow blink.  LEDs are active LOW (the factory led_test.v drives 4'b1110
    // to light "LED1", and 4'b0000 on reset means all lit).
    //
    //   nothing lit                  -> still running, or not configured
    //   LED1 + LED2 blinking together -> PASS, checksum == GOLDEN
    //   LED3 + LED4 blinking together -> FAIL, checksum != GOLDEN
    //
    // Two LEDs per verdict rather than one, so a single dead LED still leaves
    // the answer readable.
    localparam [31:0] GOLDEN_CHECKSUM = 32'hffffc6e2;

    // Wait for the readout to finish streaming before judging.  The readout
    // takes E_DIM (256) lanes x 4 bytes plus a little overhead, so 2048 engine
    // cycles is comfortably enough at 50 MHz.
    // Declared as a plain integer on purpose.  Writing it as an 11-bit vector
    // (localparam [10:0] SETTLE_CYCLES = 11'd2048) silently truncated 2048 to
    // 0, so "SETTLE_CYCLES - 1" evaluated to 32'hFFFFFFFF in the comparison
    // and result_valid never asserted while settle_cnt wrapped forever.  The
    // counter needs 12 bits to hold 2048 anyway.
    localparam integer SETTLE_CYCLES = 2048;

    reg [11:0] settle_cnt;
    reg        result_valid;

    // Wide enough to reach BLINK_BIT.  Writing this as [23:0] while indexing
    // bit 24 put the read out of range: simulation returned X and synthesis
    // would have folded it to a constant, so the LEDs would sit steady instead
    // of blinking and look like a different result than they were.
    reg [24:0] blink_cnt;

    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) begin
            settle_cnt   <= 12'd0;
            result_valid <= 1'b0;
            blink_cnt    <= 24'd0;
        end else begin
            blink_cnt <= blink_cnt + 24'd1;

            if (st == S_FIN && !result_valid) begin
                if (settle_cnt == SETTLE_CYCLES - 1) begin
                    result_valid <= 1'b1;
                end else begin
                    settle_cnt <= settle_cnt + 12'd1;
                end
            end
        end
    end

    // At 100 MHz, bit 23 of the free-running counter toggles about every 84 ms,
    // giving a visible few-Hz blink.  BLINK_BIT is tuned alongside DIV_BITS so
    // the rate stays readable when the engine clock changes.
    wire blink_phase = blink_cnt[BLINK_BIT];

    wire checksum_ok = (result_checksum == GOLDEN_CHECKSUM);

    // Active low: a 0 lights the LED.
    localparam [3:0] LED_ALL_OFF = 4'b1111;
    localparam [3:0] LED_PASS    = 4'b1100;   // LED1 + LED2 lit
    localparam [3:0] LED_FAIL    = 4'b0011;   // LED3 + LED4 lit

    always @* begin
        if (!result_valid) begin
            led_r = LED_ALL_OFF;                      // running
        end else if (blink_phase) begin
            led_r = LED_ALL_OFF;                      // blink off-phase
        end else if (checksum_ok) begin
            led_r = LED_PASS;
        end else begin
            led_r = LED_FAIL;
        end
    end

    assign led = led_r;

    // ------------------------------------------------------------------
    // DUT
    // ------------------------------------------------------------------
    moe_proto_top u_moe_proto_top (
        .clk          (sys_clk),
        .rst_n        (rst_n),
        .start        (start),
        .busy         (busy),
        .done         (done),
        .act_wr_en    (act_wr_en),
        .act_wr_addr  (act_wr_addr),
        .act_wr_data  (act_wr_data),
        .rd_start     (rd_start),
        .rd_pause     (rd_pause),
        .rd_valid     (rd_valid),
        .rd_lane      (rd_lane),
        .rd_byte      (rd_byte),
        .rd_data      (rd_data),
        .rd_busy      (rd_busy),
        .result_checksum(result_checksum)
    );

    // The result now leaves the engine through the narrow rd_* window instead
    // of an 8192-bit port.  That window is the attachment point for the next
    // step: an ILA probe, a UART transmitter, or an on-chip checker.

endmodule
