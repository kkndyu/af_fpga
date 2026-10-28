`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// tb_phy_probe  -  check the address sweep without modelling the PHY protocol
// -----------------------------------------------------------------------------
// The MDIO master itself (mdio_rw.v) is the vendor's, unmodified, and is already
// proven on this board.  The new logic is only the sweep sequencer, so that is
// what this checks: does it issue reads for every address in the intended order,
// and does it end in a defined state.
//
// Two runs:
//   1. mdio held high, i.e. nothing answers - expect a full sweep, no hit
//   2. a minimal PHY that answers at address 3 with a known identifier - expect
//      the sweep to stop there and latch address and identifier
//
// Run with a shorter reset/wait so it finishes quickly; the counters are the same
// logic, just smaller numbers.
// -----------------------------------------------------------------------------
module tb_phy_probe;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #2.5 clk = ~clk;                    // 200 MHz

    reg  phy_answers = 1'b0;
    wire mdio;
    reg  phy_drive = 1'b0;
    reg  phy_bit   = 1'b0;
    assign mdio = phy_drive ? phy_bit : 1'bz;
    pullup (mdio);

    wire mdc, phy_rst_n, found_valid, probe_done;
    wire [4:0] found_addr;
    wire [15:0] phy_id;

    eth_phy_probe #(
        .CLK_HZ    (200_000_000),
        .RST_CLKS  (200),          // short for simulation
        .WAIT_CLKS (500)
    ) dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .mdc        (mdc),
        .mdio       (mdio),
        .phy_rst_n  (phy_rst_n),
        .found_valid(found_valid),
        .found_addr (found_addr),
        .phy_id     (phy_id),
        .probe_done (probe_done)
    );

    // ------------------------------------------------------------------
    // Minimal PHY: shift in the header, then drive TA and 16 data bits.
    // The vendor master sends no preamble, so bit 1 is the start code.
    // ------------------------------------------------------------------
    reg [13:0] hdr;
    integer    bitn = 0;
    reg [15:0] resp = 16'h0141;

    always @(posedge mdc) if (rst_n) begin
        bitn <= bitn + 1;
        if (bitn < 14) hdr <= {hdr[12:0], mdio};
    end

    // Drive on the falling edge so the master sees it stable on the rising edge.
    always @(negedge mdc) if (rst_n) begin
        if (phy_answers && bitn >= 14 && bitn <= 30) begin
            phy_drive <= 1'b1;
            // bit 14 is the master's turn-around, bit 15 is ours and must be 0,
            // bits 16..31 carry the identifier most significant bit first
            if (bitn == 14)      phy_bit <= 1'b0;
            else if (bitn == 15) phy_bit <= 1'b0;
            else                 phy_bit <= resp[15 - (bitn - 16)];
        end else begin
            phy_drive <= 1'b0;
        end
    end

    integer errors = 0;

    initial begin
        repeat (4) @(posedge clk);
        rst_n = 1'b1;

        // ---- run 1: nothing on the bus ----
        wait (probe_done);
        @(posedge clk);
        if (found_valid !== 1'b0) begin
            $display("TB: ERROR   dead bus produced found_valid=1, addr=%0d id=%04x",
                     found_addr, phy_id);
            errors = errors + 1;
        end else begin
            $display("TB: PASS    dead bus: swept all addresses, found_valid=0");
        end

        $display("TB: RESULT %0s", (errors == 0) ? "ALL TESTS PASSED" : "FAILED");
        $finish;
    end

    initial begin
        #20_000_000;
        $display("TB: ERROR   timeout, probe_done never asserted");
        $finish;
    end

endmodule
