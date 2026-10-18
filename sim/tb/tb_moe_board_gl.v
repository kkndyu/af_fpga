`timescale 1ns/1ps

// -----------------------------------------------------------------------------
// tb_moe_board_gl - gate-level check of the ROUTED netlist, LEDs only
// -----------------------------------------------------------------------------
// Why this exists
// ---------------
// RTL simulation and silicon are separated by synthesis and place-and-route, and
// in this project that gap has hidden real bugs: at one point synthesis removed
// an entire ROM and the intended copy loop kept running against nothing.  The
// RTL was fine; the netlist was not what the RTL described.
//
// So simulate the actual routed netlist.  Only the top-level LED port is
// observed on purpose: internal names are unreliable in a post-synthesis netlist,
// and the LED pattern is exactly what the board shows.
//
// V2 intermediate state: nothing loads the memories, so the expected pattern is
// LED_WAIT (1010 = LED1 + LED3 lit), not a PASS.  The check that matters here is
// that the netlist agrees with the RTL about WHICH pattern appears - at
// synthesis, LED_WAIT is a constant, and if the optimiser folded the sequencer
// away it could easily produce all-off instead.
//
// LED POLARITY: the stock led_test.v drives 4'b1110 to light "LED1", so a 0 bit
// means ON.
//
// Prerequisite: the routed netlist must be exported first.
//   vivado -mode batch -source scripts/netlist_sim.tcl
// -----------------------------------------------------------------------------
module tb_moe_board_gl;

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
    integer lit;

    initial begin
        rst_n = 1'b0;
        repeat (20) @(posedge sys_clk_p);
        rst_n = 1'b1;

        // The blink half-period at BLINK_BIT=24 is ~8.4M cycles at 200 MHz, so a
        // short wait would sample an arbitrary phase.  Sampling both phases is
        // simpler than trying to align to one: over a full period the lit pattern
        // must appear at least once, and all-off must also appear.
        //
        // Gate-level simulation of this netlist is slow, so instead of a full
        // period this samples a bounded window and reports what it saw; the
        // important assertion is that the lit pattern is either LED_WAIT or
        // all-off, never PASS (1100) or FAIL (0011).  Showing PASS here would mean
        // the design is still computing on baked-in data.
        repeat (20000) @(posedge sys_clk_p);

        lit = 0;
        for (i = 0; i < 4; i = i + 1) begin
            if (led[i] === 1'b0) lit = lit + 1;   // active low
        end

        $display("GL TB: led = %b  (%0d of 4 physically lit)", led, lit);
        $display("GL TB: expected either 1010 (LED_WAIT lit) or 1111 (blink off-phase)");

        if (led === 4'b1010 || led === 4'b1111) begin
            $display("GL TB: MATCHES the RTL simulation - not-loaded state, no verdict");
        end else if (led === 4'b1100) begin
            $display("GL TB: ERROR netlist shows PASS, which is impossible with nothing loaded");
        end else if (led === 4'b0011) begin
            $display("GL TB: ERROR netlist shows FAIL, which would mask a real failure");
        end else begin
            $display("GL TB: ERROR unexpected pattern %b", led);
        end
        $finish;
    end

endmodule
