`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// tb_mdio - reconstruct the MDIO frame on the wire and check it bit by bit
// -----------------------------------------------------------------------------
// Every defect in eth_mdio so far has been a bit-level framing error that a scope
// would not show and that no amount of reading the RTL caught: a 67-bit
// concatenation, a pulse instead of a clock, and an off-by-one sequencer that
// never sent the most significant bit.  So this test rebuilds the frame from the
// pins and compares it against the IEEE 802.3 clause 22 layout.
//
// A shorter clock divider is used so the test runs in a few milliseconds; the
// frame content does not depend on MDC frequency.
// -----------------------------------------------------------------------------
module tb_mdio;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #2.5 clk = ~clk;                 // 200 MHz

    wire mdc;
    wire mdio_oe, mdio_o;
    wire phy_rst_n;
    wire busy, done;
    wire [2:0] step_done;

    // Pull-up: MDIO idles high on a real bus.
    wire mdio_i = 1'b1;

    eth_mdio #(
        .CLK_HZ  (200_000_000),
        .MDC_HZ  (500_000),               // faster than a real PHY; still 50 % duty
        .PHY_ADDR(5'd1)
    ) dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .mdc       (mdc),
        .mdio_oe   (mdio_oe),
        .mdio_o    (mdio_o),
        .mdio_i    (mdio_i),
        .phy_rst_n (phy_rst_n),
        .busy      (busy),
        .done      (done),
        .step_done (step_done)
    );

    // ------------------------------------------------------------------
    // Sample MDIO on every rising edge of MDC, the way a PHY would.
    // ------------------------------------------------------------------
    reg [63:0] captured;
    integer    nbits = 0;
    integer    frames = 0;
    reg [63:0] frame0, frame1, frame2, frame3;

    always @(posedge mdc) begin
        if (mdio_oe) begin
            captured = {captured[62:0], mdio_o};
            nbits = nbits + 1;
            if (nbits == 64) begin
                if (frames == 0) frame0 = captured;
                else if (frames == 1) frame1 = captured;
                else if (frames == 2) frame2 = captured;
                else frame3 = captured;
                frames = frames + 1;
                nbits = 0;
            end
        end
    end
    // ------------------------------------------------------------------
    // Check one frame against the expected layout.
    // ------------------------------------------------------------------
    integer errors = 0;

    task check_frame(input [63:0] f, input [4:0] regad, input [15:0] data,
                     input [8*8-1:0] tag);
        begin
            if (f[63:32] !== 32'hFFFF_FFFF) begin
                $display("TB: ERROR   %0s preamble = %08x, expected ffffffff",
                         tag, f[63:32]);
                errors = errors + 1;
            end
            if (f[31:30] !== 2'b01) begin
                $display("TB: ERROR   %0s start = %b, expected 01", tag, f[31:30]);
                errors = errors + 1;
            end
            if (f[29:28] !== 2'b01) begin
                $display("TB: ERROR   %0s opcode = %b, expected 01 (write)", tag, f[29:28]);
                errors = errors + 1;
            end
            if (f[27:23] !== 5'd1) begin
                $display("TB: ERROR   %0s phy address = %0d, expected 1", tag, f[27:23]);
                errors = errors + 1;
            end
            if (f[22:18] !== regad) begin
                $display("TB: ERROR   %0s register = %0d, expected %0d", tag, f[22:18], regad);
                errors = errors + 1;
            end
            if (f[17:16] !== 2'b10) begin
                $display("TB: ERROR   %0s turnaround = %b, expected 10", tag, f[17:16]);
                errors = errors + 1;
            end
            if (f[15:0] !== data) begin
                $display("TB: ERROR   %0s data = %04x, expected %04x", tag, f[15:0], data);
                errors = errors + 1;
            end
            $display("TB: frame %0s = %016x %016x", tag, f[63:32], f[31:0]);
        end
    endtask

    initial begin
        repeat (5) @(posedge clk);
        rst_n = 1'b1;

        // The full sequence is ~130 ms of reset/wait/gap at the real dividers; here
        // the clocks are faster but the counters are the same, so just wait.
        wait (done);
        repeat (100) @(posedge clk);

        $display("TB: %0d frames sent, step_done = %0d", frames, step_done);

        if (frames != 4) begin
            $display("TB: ERROR   expected 4 frames, saw %0d", frames);
            errors = errors + 1;
        end else begin
            check_frame(frame0, 5'd0, 16'h1900, "BMCR0");
            check_frame(frame1, 5'd0, 16'h1100, "BMCR1");
            check_frame(frame2, 5'd0, 16'h1300, "BMCR2");
            check_frame(frame3, 5'd0, 16'h1300, "BMCR3");
        end

        if (errors == 0) $display("TB: RESULT ALL TESTS PASSED");
        else             $display("TB: RESULT %0d ERRORS", errors);
        $finish;
    end

    // Guard against a hung sequence.
    initial begin
        #200_000_000;
        $display("TB: ERROR   timeout, done never asserted (step_done=%0d, busy=%b)",
                 step_done, busy);
        $finish;
    end

endmodule
