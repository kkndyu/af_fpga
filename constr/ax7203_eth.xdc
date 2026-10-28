# -----------------------------------------------------------------------------
# ax7203_eth.xdc  -  Ethernet port 1 (RGMII) on the AX7203B
# -----------------------------------------------------------------------------
# Every pin, I/O standard and bit order here is taken from the vendor's own
# ethernet_test demo:
#
#   AX7203_2019.1/01_demo_document.zip
#     -> 01_demo_document/demo/ethernet_test.zip
#     -> ethernet_test/eth_test.srcs/constrs_1/new/top.xdc
#
# The first version of this file got two things wrong that the demo would have
# caught immediately, and both are silent failures:
#
#   1. BIT ORDER.  The vendor constrains C19 to rgmii1_rxd[3] and A16 to
#      rgmii1_rxd[0].  This file had the reverse, which turns every received
#      nibble into its bit-reversed value.  Nothing reports an error: frames
#      arrive, the FCS and the protocol checks fail, and the parser rejects
#      them.  The same reversal applied to TXD, so transmitted frames were
#      equally wrong.
#
#   2. SLEW.  The demo sets SLEW FAST on all RGMII outputs.  This file had SLOW.
#      At 100 Mb (40 ns bit period) it makes no measurable difference, but it is
#      not what the vendor characterised.
#
# The demo also declares:
#
#     create_clock -period 8.000 [get_ports rgmii1_rxc]
#
# an 8 ns period, i.e. 125 MHz, i.e. GIGABIT.  This design deliberately runs at
# 100 Mb instead (see eth_rgmii_rx.v for why), so the PHY has to be pinned to
# 100 Mb over MDIO and RX_CLK is then 25 MHz.  RX_CLK is NOT declared as a clock
# here because eth_rgmii_rx oversamples it in the 200 MHz domain - declaring it
# would create a second clock domain the design does not have.
# -----------------------------------------------------------------------------

# ---- receive clock ----
# The vendor demo declares the receive clock at 8 ns, i.e. 125 MHz, which is
# gigabit RGMII.  It is the clock for the whole wire side of this design:
# util_gmii_to_rgmii derives its transmit clock from it, so there is one 125 MHz
# domain, not two.
create_clock -period 8.000 [get_ports rgmii_rxc]

# ---- receive ----  rxd[3] is the HIGH-numbered pin in the vendor file
set_property PACKAGE_PIN C19 [get_ports {rgmii_rxd[3]}]
set_property PACKAGE_PIN C18 [get_ports {rgmii_rxd[2]}]
set_property PACKAGE_PIN B18 [get_ports {rgmii_rxd[1]}]
set_property PACKAGE_PIN A16 [get_ports {rgmii_rxd[0]}]
set_property PACKAGE_PIN A15 [get_ports rgmii_rxctl]
set_property PACKAGE_PIN B17 [get_ports rgmii_rxc]

# ---- transmit ----
set_property PACKAGE_PIN A18 [get_ports {rgmii_txd[3]}]
set_property PACKAGE_PIN A19 [get_ports {rgmii_txd[2]}]
set_property PACKAGE_PIN D20 [get_ports {rgmii_txd[1]}]
set_property PACKAGE_PIN C20 [get_ports {rgmii_txd[0]}]
set_property PACKAGE_PIN F18 [get_ports rgmii_txctl]
set_property PACKAGE_PIN E18 [get_ports rgmii_txc]

# ---- management ----
set_property PACKAGE_PIN B16 [get_ports phy_mdc]
set_property PACKAGE_PIN B15 [get_ports phy_mdio]
set_property PACKAGE_PIN D16 [get_ports phy_rst_n]

# ---- I/O standard ----
set_property IOSTANDARD LVCMOS33 [get_ports {rgmii_rxd[*]}]
set_property IOSTANDARD LVCMOS33 [get_ports rgmii_rxc]
set_property IOSTANDARD LVCMOS33 [get_ports rgmii_rxctl]
set_property IOSTANDARD LVCMOS33 [get_ports {rgmii_txd[*]}]
set_property IOSTANDARD LVCMOS33 [get_ports rgmii_txc]
set_property IOSTANDARD LVCMOS33 [get_ports rgmii_txctl]
set_property IOSTANDARD LVCMOS33 [get_ports phy_mdc]
set_property IOSTANDARD LVCMOS33 [get_ports phy_mdio]
set_property IOSTANDARD LVCMOS33 [get_ports phy_rst_n]

# ---- output drive, matching the vendor demo ----
set_property SLEW FAST [get_ports {rgmii_txd[*]}]
set_property SLEW FAST [get_ports rgmii_txctl]
set_property SLEW FAST [get_ports rgmii_txc]

# Timing exceptions for the Ethernet logic are applied in build_moe.tcl, right
# after synth_design.  They cannot live here: constraint files are read before
# synthesis, when no cell exists yet, so a get_cells based filter in an XDC
# matches nothing and the exception is silently dropped.

# ---- clock domain crossing ----
# The Ethernet wire side runs at 125 MHz (rgmii_rxc) and the fabric at 200 MHz
# (clk_engine).  They cross through eth_async_fifo, which is a proper dual-clock
# FIFO: gray-coded pointers with two-flop synchronisers.  Declaring the groups
# asynchronous is what that design requires - without it the tool times paths
# across the boundary as if they were synchronous, which is both meaningless and
# what made the first gigabit build report WNS -3.945 ns with 8,256 failing
# endpoints between these two clocks.
set_clock_groups -asynchronous \
    -group [get_clocks -include_generated_clocks clk_engine] \
    -group [get_clocks rgmii_rxc]