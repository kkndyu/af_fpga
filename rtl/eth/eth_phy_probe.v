`include "moe_params.vh"

// -----------------------------------------------------------------------------
// eth_phy_probe  -  find out whether the PHY answers MDIO at all, and where
// -----------------------------------------------------------------------------
// Context
//   Both this design and the vendor's own prebuilt demo report "no link" on this
//   board, while the PHY's own link LEDs are lit on both ports.  Those are two
//   independent observations of the same thing: the PHY says it has a link, the
//   FPGA says it does not.  The only path between them is MDIO, so MDIO is not
//   working - and until now every assumption in this project rested on MDIO
//   working (PHY address 1, writes landing, configuration taking effect).
//
// What this does
//   Holds the PHY in reset, releases it, waits, then reads register 2 (PHY
//   identifier, high half) by sweeping MDIO addresses.  Address 1 is tried first
//   because that is what the vendor demo hardcodes, then 0 and 2..7.
//
//   The first address that returns something other than 0x0000 or 0xFFFF is
//   latched, with its identifier.  That single result separates the three cases
//   which have been indistinguishable so far:
//
//     valid = 1, addr = 1, id = 0x0141   MDIO works and the address was right
//     valid = 1, addr = 3, id = 0x....   MDIO works, the address was wrong
//     valid = 0                          nothing on the bus answers
//
// Why read register 2 and not the status register
//   Register 1 (BMSR) would report link and speed, which is the thing we want to
//   know - but only meaningful if the read itself is trustworthy.  Register 2 is
//   a constant, so it validates the read path without depending on link state.
//   Status can be read once this works.
//
// The MDIO master is the vendor's smi_read_write (rtl/eth/mdio_rw.v), not a new
// one, precisely because its read timing is the part that has to be right and it
// is already proven on this board.
// -----------------------------------------------------------------------------
module eth_phy_probe #(
    parameter integer CLK_HZ   = 200_000_000,
    parameter integer RST_CLKS = 2_000_000,    // 10 ms of PHY reset
    parameter integer WAIT_CLKS= 20_000_000    // 100 ms before the first access
)(
    input             clk,
    input             rst_n,

    // MDIO pins, tristate handled by the vendor master
    output            mdc,
    inout             mdio,

    output            phy_rst_n,

    output reg        found_valid,
    output reg [4:0]  found_addr,
    output reg [15:0] phy_id,

    // keeps the old LED indicator meaningful: 1 once the sweep has finished
    output reg        probe_done
);

    // ------------------------------------------------------------------
    // PHY reset and settle
    // ------------------------------------------------------------------
    localparam S_RESET = 3'd0;
    localparam S_WAIT  = 3'd1;
    localparam S_REQ   = 3'd2;
    localparam S_BUSY  = 3'd3;
    localparam S_NEXT  = 3'd4;
    localparam S_DONE  = 3'd5;

    reg [2:0]  st;
    reg [31:0] cnt;
    reg [3:0]  step;            // index into the address order
    reg [4:0]  cur_addr;
    reg        read_req;
    wire [15:0] read_data;
    wire        data_valid;
    wire        done;

    assign phy_rst_n = (st != S_RESET);

    // Address 1 first, then the rest of the plausible range.
    function [4:0] addr_for;
        input [3:0] i;
        begin
            case (i)
                4'd0: addr_for = 5'd1;
                4'd1: addr_for = 5'd0;
                4'd2: addr_for = 5'd2;
                4'd3: addr_for = 5'd3;
                4'd4: addr_for = 5'd4;
                4'd5: addr_for = 5'd5;
                4'd6: addr_for = 5'd6;
                default: addr_for = 5'd7;
            endcase
        end
    endfunction

    // ------------------------------------------------------------------
    // Vendor MDIO master
    // ------------------------------------------------------------------
    mdio_rw #(
        .REF_CLK (CLK_HZ / 1_000_000),   // MHz
        .MDC_CLK (100)                   // kHz, deliberately slow
    ) u_rw (
        .clk        (clk),
        .rst_n      (rst_n),
        .mdc        (mdc),
        .mdio       (mdio),
        .phy_addr   (cur_addr),
        .reg_addr   (5'd2),              // PHY identifier, high half
        .write_req  (1'b0),
        .write_data (16'd0),
        .read_req   (read_req),
        .read_data  (read_data),
        .data_valid (data_valid),
        .done       (done)
    );

    // ------------------------------------------------------------------
    // Sequencer
    // ------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st          <= S_RESET;
            cnt         <= 32'd0;
            step        <= 4'd0;
            cur_addr    <= 5'd1;
            read_req    <= 1'b0;
            found_valid <= 1'b0;
            found_addr  <= 5'd0;
            phy_id      <= 16'd0;
            probe_done  <= 1'b0;
        end else begin
            read_req <= 1'b0;

            case (st)
                S_RESET: begin
                    if (cnt == RST_CLKS) begin
                        cnt <= 32'd0;
                        st  <= S_WAIT;
                    end else cnt <= cnt + 32'd1;
                end

                S_WAIT: begin
                    if (cnt == WAIT_CLKS) begin
                        cnt      <= 32'd0;
                        step     <= 4'd0;
                        cur_addr <= addr_for(4'd0);
                        st       <= S_REQ;
                    end else cnt <= cnt + 32'd1;
                end

                // Pulse read_req for one cycle.
                S_REQ: begin
                    read_req <= 1'b1;
                    st       <= S_BUSY;
                end

                // Wait for the transaction to finish.
                S_BUSY: begin
                    if (done) st <= S_NEXT;
                end

                S_NEXT: begin
                    // A read is valid when it is neither all zeros nor all ones:
                    // both are what a dead bus or an absent PHY returns.
                    if (data_valid && read_data != 16'h0000 && read_data != 16'hFFFF) begin
                        found_valid <= 1'b1;
                        found_addr  <= cur_addr;
                        phy_id      <= read_data;
                        probe_done  <= 1'b1;
                        st          <= S_DONE;
                    end else if (step == 4'd7) begin
                        // swept everything, nothing answered
                        found_valid <= 1'b0;
                        probe_done  <= 1'b1;
                        st          <= S_DONE;
                    end else begin
                        step     <= step + 4'd1;
                        cur_addr <= addr_for(step + 4'd1);
                        cnt      <= 32'd0;
                        st       <= S_REQ;
                    end
                end

                S_DONE: st <= S_DONE;

                default: st <= S_RESET;
            endcase
        end
    end

endmodule
