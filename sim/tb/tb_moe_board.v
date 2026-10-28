`timescale 1ns/1ps
`include "moe_params.vh"

// -----------------------------------------------------------------------------
// tb_moe_board - what will the four LEDs show on the real board?
// -----------------------------------------------------------------------------
// V2 intermediate state.  The weight and activation BRAMs have no initial
// contents any more, and the runtime loader (uart_rx + moe_loader) is not
// implemented yet, so moe_proto_board ties load_done low and parks in S_WAIT.
//
// What this testbench therefore has to prove is NOT "the checksum matches" - it
// cannot, nothing has been loaded - but that the board fails in an *unambiguous*
// way:
//
//   * no GEMV is ever launched (busy and done stay low)
//   * the sequencer never leaves S_WAIT
//   * the LEDs show LED_WAIT, the dedicated "not loaded" pattern, rather than
//     the FAIL pattern
//
// That last point is the whole reason LED_WAIT exists: an unloaded board and a
// wrong-but-loaded board look identical if both show FAIL, and a bench session
// then starts by debugging arithmetic that was never executed.
//
// When the loader lands, this testbench goes back to checking a real PASS.
// -----------------------------------------------------------------------------
module tb_moe_board;

    reg  sys_clk_p;
    reg  sys_clk_n;
    reg  rst_n;
    wire [3:0] led;

    moe_proto_board #(.WITH_ETH(0)) dut (
        .sys_clk_p (sys_clk_p),
        .sys_clk_n (sys_clk_n),
        .rst_n     (rst_n),
        .led       (led)
    );

    // 200 MHz differential clock, matching the on-board oscillator.
    initial begin
        sys_clk_p = 1'b0;
        sys_clk_n = 1'b1;
        forever begin
            #2.5 sys_clk_p = 1'b1;
                 sys_clk_n = 1'b0;
            #2.5 sys_clk_p = 1'b0;
                 sys_clk_n = 1'b1;
        end
    end

    integer i;
    integer start_seen;
    integer errors;

    initial begin
        rst_n      = 1'b0;
        start_seen = 0;
        errors     = 0;

        repeat (20) @(posedge sys_clk_p);
        rst_n = 1'b1;

        // Watch for the engine being launched.  In the not-loaded state it never
        // must be: launching a GEMV on empty memories produces a plausible all
        // zero result, which is far more confusing than doing nothing.
        for (i = 0; i < 200000; i = i + 1) begin
            @(posedge sys_clk_p);
            if (dut.gemv_start === 1'b1 || dut.gemv_busy === 1'b1 || dut.gemv_done === 1'b1) begin
                start_seen = start_seen + 1;
            end
        end

        $display("BOARD TB: weights_ready=%b act_valid=%b err_code=%0d", dut.weights_ready, dut.act_valid, dut.err_code);
        $display("BOARD TB: busy=%b done=%b  start pulses seen = %0d",
                 dut.gemv_busy, dut.gemv_done, start_seen);

        if (dut.weights_ready !== 1'b0) begin
            $display("BOARD TB: ERROR weights_ready is set although nothing was loaded");
            errors = errors + 1;
        end        if (start_seen != 0) begin
            $display("BOARD TB: ERROR the engine was launched with no data loaded");
            errors = errors + 1;
        end

        // Wait for the lit half of the blink so the pattern can be compared.
        // blink_phase is bit 24 of a free-running counter, so one half-period is
        // ~16.7M cycles at 200 MHz; the bound below covers a full period.
        for (i = 0; i < 40000000; i = i + 1) begin
            @(posedge sys_clk_p);
            if (dut.blink_phase === 1'b0) begin
                i = 40000000;
            end
        end
        @(posedge sys_clk_p);

        $display("BOARD TB: led[3:0] = %b  (active low: 0 = LED lit)", led);
                $display("BOARD TB: expected 1111 - all off.  led[0]=~weights_ready,");
        $display("BOARD TB: led[1]=~act_valid, led[2]=~busy, led[3]=receive activity,");
        $display("BOARD TB: and with nothing loaded all four are off.");

        if (led !== 4'b1111) begin
            $display("BOARD TB: ERROR unexpected LED pattern %b for the not-loaded state", led);
            errors = errors + 1;
        end

        $display("BOARD TB: --- what to look for on the board after programming ---");
        $display("BOARD TB:   all LEDs off             = NOT LOADED (the expected state here)");
        $display("BOARD TB:   LED1+LED2 off after loading = weights and activations present");
        $display("BOARD TB:   LED3+LED4 blinking together = FAIL");
        $display("BOARD TB:   nothing lit                  = blink off-phase / not configured");

        if (errors == 0) begin
            $display("BOARD TB: NOT-LOADED STATE OK");
        end else begin
            $display("BOARD TB: %0d ERROR(S)", errors);
        end
        $finish;
    end

endmodule
