`timescale 1ns/1ps

// -----------------------------------------------------------------------------
// tb_moe_board_gl - gate-level check of the ROUTED netlist, LEDs only
// -----------------------------------------------------------------------------
// Why this exists
// ---------------
// The RTL simulation passes and reproduces result_checksum = ffffc6e2, but the
// board shows three LEDs lit instead of the expected four.  Between those two
// facts sits synthesis, and synthesis did something the RTL never showed: it
// removed the act_rom entirely (0 cells in the routed design) and kept only
// u_act_buffer/mem_reg, whose INIT contents it presumably rewrote with the ROM
// data.  If that reasoning was wrong the engine computes on zeros.
//
// So simulate the actual routed netlist.  Only the top-level LED port is
// observed on purpose: internal names are not reliable in a post-synthesis
// netlist, and the LED pattern is exactly the thing the board shows.
//
// LED POLARITY: the stock led_test.v drives 4'b1110 to light "LED1", so a 0 bit
// means ON.  A fully correct run is expected to drive led = 4'b0000, which is
// all four lit.
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

        // The whole run is roughly 1024 load + 3072 GEMV + 1024 readout cycles.
        // Wait far past that, then sample the settled LED pattern.
        repeat (20000) @(posedge sys_clk_p);

        lit = 0;
        for (i = 0; i < 4; i = i + 1) begin
            if (led[i] === 1'b0) lit = lit + 1;   // active low
        end

        $display("GL TB: led = %b", led);
        $display("GL TB: LEDs physically lit (active low) = %0d of 4", lit);
        if (led === 4'b0000) begin
            $display("GL TB: MATCHES the RTL simulation (0000 -> all four lit)");
        end else begin
            $display("GL TB: DIFFERS from the RTL simulation, which gave 4'b0000");
        end
        $finish;
    end

endmodule
