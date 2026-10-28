`include "moe_params.vh"

// -----------------------------------------------------------------------------
// eth_mdio  -  management interface, write only
// -----------------------------------------------------------------------------
// The RGMII receive path here assumes 100 Mb: it samples one nibble per rising
// edge of RX_CLK and ignores the falling edge, which is only correct at 100 Mb.
// So the link has to be pinned there rather than left to auto-negotiation, which
// settles on 1000 Mb and produces garbage.
//
// The PHY address and the register values come from the vendor's ethernet_test
// demo rather than from guesswork:
//
//   ethernet_test/eth_test.srcs/sources_1/mdio/mdio_com.v
//     cyc_count 5..9 -> 00001, i.e. PHY ADDRESS 1
//
//   ethernet_test/eth_test.srcs/sources_1/mdio/phy_reg_config.v
//     register 0 written three times: 0x1900 (power down), 0x1100 (wake with
//     auto-negotiation and full duplex), 0x1300 (same plus restart)
//
// Four defects in earlier versions of this module are recorded here because each
// one made the whole configuration silently do nothing:
//
//   1. reg_addr was declared reg [7:0] against a 5-bit field, so the frame
//      concatenation was 67 bits wide assigned to a 64-bit wire.  The top three
//      preamble bits were truncated and every field shifted.
//
//   2. MDC was a one-clock pulse every 40 clocks - 5 MHz at 2.5 % duty.  MDC is
//      a real clock: 50 % duty, 2.5 MHz maximum.
//
//   3. THE BIT SEQUENCER WAS OFF BY ONE.  It shifted the frame first and then
//      drove frame[62], so the most significant bit never left the pin and only
//      63 of the 64 bits were sent.  Because the preamble is all ones this is
//      invisible on a scope; the PHY simply sees a malformed frame.
//
//   4. ANAR was written as 0x0100, without the selector field in bits 4:0.  An
//      advertisement with a zero selector is invalid and the link partner
//      ignores it, which is why restricting the speed appeared to have no
//      effect at all.
//
// Configuration
//   Auto-negotiation stays ENABLED but advertisement is restricted to 100BASE-TX
//   full duplex, so both ends agree on 100 Mb while keeping the handshake.
//   Forcing a speed with auto-negotiation disabled would fail outright against a
//   partner that is still negotiating.
//
//     reg 4 (ANAR) = 0x0101   selector 802.3 (bits 4:0 = 00001) + 100BASE-TX-FD
//     reg 0 (BMCR) = 0x1300   auto-negotiation enable, restart, full duplex
// -----------------------------------------------------------------------------
module eth_mdio #(
    parameter integer CLK_HZ   = 200_000_000,
    parameter integer MDC_HZ   = 20_000,         // vendor demo rate, far inside spec
    parameter [4:0]   PHY_ADDR = 5'd1            // vendor demo: address 1
)(
    input      clk,           // 200 MHz
    input      rst_n,

    output     mdc,
    output reg mdio_oe,       // 1 = driving, 0 = high impedance
    output reg mdio_o,
    input      mdio_i,

    output     phy_rst_n,     // active low reset to the PHY
    output reg busy,
    output reg done,          // pulses when the configuration has finished

    // How far the sequence got: 0 = reset, 1..4 = writes done, 5 = all done.
    output reg [2:0] step_done
);

    // One bit every DIV clocks, so MDC toggles every DIV clocks and its period
        // is 2*DIV.  At the vendor's 20 kHz the period is 50 us, well inside the
    // 2.5 MHz maximum.
    localparam integer DIV = CLK_HZ / (2 * MDC_HZ);

    localparam integer RST_CLKS  = CLK_HZ / 100;      // 10 ms PHY reset
    localparam integer WAIT_CLKS = CLK_HZ / 10;       // 100 ms after release
    localparam integer GAP_CLKS  = CLK_HZ / 50;       // 20 ms between writes

    localparam [4:0]  REG_BMCR = 5'd0;
    // (ANAR advertisement removed: the link runs at gigabit, see cur_data below)

    localparam S_RESET = 3'd0;
    localparam S_WAIT  = 3'd1;
    localparam S_GAP   = 3'd2;
    localparam S_FRAME = 3'd3;
    localparam S_DONE  = 3'd4;

    reg [2:0]  st;
    reg [2:0]  rep;            // 0 = ANAR, 1 = BMCR, 2 = BMCR again, 3 = last
    reg [31:0] cnt;
    // 13 bits, not 7.  DIV is CLK_HZ/(2*MDC_HZ) = 5000 at the vendor's 20 kHz,
    // and a 7-bit counter wraps at 128 - which would have produced MDC at 781 kHz
    // instead of 20 kHz.  Same failure class as rx_rp + 2'd4 and bit_idx [2:0]:
    // a counter narrower than the value it has to reach.
    reg [12:0] div_cnt;
    reg        mdc_r;
    reg [6:0]  bit_cnt;        // 7 bits: must be able to hold 64
    reg [63:0] frame;
    // Set on the falling edge that drives the 64th bit.  mdio_oe must stay
    // asserted for one more MDC period, because the PHY samples that last bit on
    // the FOLLOWING rising edge.  Releasing on the same falling edge made the last
    // data bit read back as the pull-up value - every frame came out one LSB too
    // high (0x1900 arrived as 0x1901).
    reg        tail;

    assign phy_rst_n = (st != S_RESET);
    assign mdc       = mdc_r;

    // Write order: ANAR, BMCR, BMCR.  BMCR is repeated because a PHY that is
    // still settling after reset ignores the first one - the vendor demo does the
    // same thing.
    // The vendor demo writes register 0 only, four times, and does NOT restrict
    // the speed: the link ends up at 1000 Mb, which is what the gigabit path here
    // wants.  Their values, in their order, with the last one repeated.
    //
    //   0x1900  power down, auto-negotiate, full duplex
    //   0x1100  wake up, auto-negotiate, full duplex
    //   0x1300  same plus restart auto-negotiation
    reg [15:0] cur_data;
    always @* begin
        case (rep)
            3'd0:    cur_data = 16'h1900;
            3'd1:    cur_data = 16'h1100;
            default: cur_data = 16'h1300;
        endcase
    end

    wire [4:0] cur_reg = REG_BMCR;

    // IEEE 802.3 clause 22 write frame, exactly 64 bits:
    //   32 preamble ones | 2 start (01) | 2 opcode (01 = write)
    //   | 5 PHY address  | 5 register address | 2 turnaround (10) | 16 data
    wire [63:0] new_frame = {32'hFFFF_FFFF, 2'b01, 2'b01,
                             PHY_ADDR, cur_reg, 2'b10, cur_data};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st        <= S_RESET;
            rep       <= 3'd0;
            cnt       <= 32'd0;
            div_cnt   <= 13'd0;
            mdc_r     <= 1'b0;
            bit_cnt   <= 7'd0;
            frame     <= 64'd0;
            mdio_oe   <= 1'b0;
            mdio_o    <= 1'b0;
            busy      <= 1'b0;
            done      <= 1'b0;
            step_done <= 3'd0;
        end else begin
            done <= 1'b0;

            case (st)
                // ---- hold the PHY in reset ----
                S_RESET: begin
                    mdc_r     <= 1'b0;
                    mdio_oe   <= 1'b0;
                    step_done <= 3'd0;
                    if (cnt == RST_CLKS) begin
                        cnt <= 32'd0;
                        st  <= S_WAIT;
                    end else begin
                        cnt <= cnt + 32'd1;
                    end
                end

                // ---- wait for the PHY to come up ----
                S_WAIT: begin
                    if (cnt == WAIT_CLKS) begin
                        cnt     <= 32'd0;
                        rep     <= 3'd0;
                        busy    <= 1'b1;
                        st      <= S_FRAME;
                        // Present bit 0 BEFORE the first rising edge of MDC.
                        // Driving the first bit on the first falling edge instead
                        // lets the PHY see one clock edge with no data and shift
                        // its own bit counter by one.
                        mdio_oe <= 1'b1;
                        mdio_o  <= new_frame[63];
                        frame   <= {new_frame[62:0], 1'b0};
                        bit_cnt <= 7'd1;
                            div_cnt <= 13'd0;
                        mdc_r   <= 1'b0;
                    end else begin
                        cnt <= cnt + 32'd1;
                    end
                end

                // ---- gap between writes ----
                S_GAP: begin
                    if (cnt == GAP_CLKS) begin
                        cnt     <= 32'd0;
                        st      <= S_FRAME;
                        mdio_oe <= 1'b1;
                        mdio_o  <= new_frame[63];
                        frame   <= {new_frame[62:0], 1'b0};
                        bit_cnt <= 7'd1;
                            div_cnt <= 13'd0;
                        mdc_r   <= 1'b0;
                    end else begin
                        cnt <= cnt + 32'd1;
                    end
                end

                // ---- shift out one 64-bit frame ----
                S_FRAME: begin
                    if (div_cnt == DIV-1) begin
                            div_cnt <= 13'd0;
                        mdc_r   <= ~mdc_r;

                        // Data changes on the falling edge, so the PHY - which
                        // samples MDIO on the rising edge - sees it stable.
                        if (mdc_r) begin
                            if (tail) begin
                                // The last bit has now been sampled by the PHY:
                                // release the bus and move on.
                                mdio_oe   <= 1'b0;
                                tail      <= 1'b0;
                                step_done <= rep + 3'd1;
                                cnt       <= 32'd0;
                                if (rep == 3'd3) begin
                                    busy      <= 1'b0;
                                    done      <= 1'b1;
                                    step_done <= 3'd5;
                                    st        <= S_DONE;
                                end else begin
                                    rep <= rep + 3'd1;
                                    st  <= S_GAP;
                                end
                            end else begin
                                mdio_o <= frame[63];
                                frame  <= {frame[62:0], 1'b0};
                                if (bit_cnt == 7'd63) tail    <= 1'b1;
                                else                  bit_cnt <= bit_cnt + 7'd1;
                            end
                        end
                    end else begin
                            div_cnt <= div_cnt + 13'd1;
                    end
                end

                S_DONE: begin
                    mdc_r <= 1'b0;
                    st    <= S_DONE;
                end

                default: st <= S_RESET;
            endcase
        end
    end

endmodule