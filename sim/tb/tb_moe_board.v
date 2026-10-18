`timescale 1ns/1ps
`include "moe_params.vh"

// -----------------------------------------------------------------------------
// tb_moe_board - what will the four LEDs show on the real board?
// -----------------------------------------------------------------------------
// The board exposure is only four LEDs:
//
//   led[0] = busy
//   led[1] = done
//   led[2] = chk_fold0 (a reduction of the 32-bit checksum)
//   led[3] = chk_fold1
//
// Two bits is a weak check of a 32-bit value, so before programming the board
// it is worth knowing EXACTLY which pattern to expect.  Guessing the reduction
// semantics in my head is precisely the kind of thing that has been wrong
// several times in this project, so this testbench lets the simulator evaluate
// the real RTL instead.
//
// It drives the same differential clock the board does, waits for the self
// start sequence, and prints the settled LED pattern together with the full
// checksum.
// -----------------------------------------------------------------------------
module tb_moe_board;

    reg  sys_clk_p;
    reg  sys_clk_n;
    reg  rst_n;
    wire [3:0] led;

    moe_proto_board dut (
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

    integer idle_cycles;
    integer i;
    reg     seen_done;

    initial begin
        rst_n       = 1'b0;
        seen_done   = 1'b0;
        idle_cycles = 0;

        repeat (20) @(posedge sys_clk_p);
        rst_n = 1'b1;

        // Wait for the engine to finish.  The board top loads 1024 activation
        // values, runs one GEMV and then streams the result out; done pulses
        // once when the GEMV completes.
        //
        // A plain polling loop instead of fork/join_any + disable: xvlog rejects
        // "disable <named fork block>" as Verilog-2000 misuse, and a bounded
        // loop expresses the same timeout without it.
        for (i = 0; i < 200000; i = i + 1) begin
            @(posedge sys_clk_p);
            if (dut.done === 1'b1) begin
                seen_done = 1'b1;
                i = 200000;          // break out
            end
        end

        if (!seen_done) begin
            $display("BOARD TB: done never asserted within the window");
        end

        // Give the readout and the checksum accumulation time to finish.
        //
        // Two separate waits: first for the settle counter to declare the
        // result valid, then for the blink phase to reach its "lit" half.  They
        // must be separate because blink_phase is bit 22 of a free-running
        // counter - one half-period is ~4.2M sys_clk cycles, which is longer
        // than a single bounded wait would allow for.
        for (i = 0; i < 2000000; i = i + 1) begin
            @(posedge sys_clk_p);
            if (dut.result_valid === 1'b1) begin
                i = 2000000;          // break out
            end
        end
        $display("BOARD TB: after settle wait: result_valid=%b st=%0d settle_cnt=%0d",
                 dut.result_valid, dut.st, dut.settle_cnt);

        // Now wait for the lit half of the blink, with room for a full period.
        for (i = 0; i < 9000000; i = i + 1) begin
            @(posedge sys_clk_p);
            if (dut.blink_phase === 1'b0) begin
                i = 9000000;
            end
        end
        @(posedge sys_clk_p);

        $display("BOARD TB: result_checksum = %08x", dut.result_checksum);
        $display("BOARD TB: result_valid=%b checksum_ok=%b blink_phase=%b",
                 dut.result_valid, dut.checksum_ok, dut.blink_phase);
        $display("BOARD TB: led[3:0] = %b  (active low: 0 = LED lit)", led);
        $display("BOARD TB: busy=%b done=%b", dut.busy, dut.done);

        if (dut.result_checksum === 32'hffffc6e2) begin
            $display("BOARD TB: checksum == ffffc6e2  MATCH");
        end else begin
            $display("BOARD TB: checksum != ffffc6e2  expected ffffc6e2");
        end

        $display("BOARD TB: --- what to look for on the board after programming ---");
        $display("BOARD TB:   LED1+LED2 blinking together = PASS");
        $display("BOARD TB:   LED3+LED4 blinking together = FAIL");
        $display("BOARD TB:   nothing lit                  = still running / not configured");
        if (led === 4'b1100) begin
            $display("BOARD TB: simulated pattern is LED1+LED2 lit -> PASS verdict");
        end else if (led === 4'b0011) begin
            $display("BOARD TB: simulated pattern is LED3+LED4 lit -> FAIL verdict");
        end else if (led === 4'b1111) begin
            $display("BOARD TB: simulated pattern is all off (blink off-phase or not ready)");
        end else begin
            $display("BOARD TB: simulated pattern is unexpected: %b", led);
        end
        $finish;
    end

endmodule
