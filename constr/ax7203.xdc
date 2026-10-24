# -----------------------------------------------------------------------------
# ax7203.xdc - ALINX AX7203B (xc7a200tfbg484-2)
# -----------------------------------------------------------------------------
# Pin values are taken from the factory led_test project, which is a proven
# working design on this board:
#
#   ref/alinx_ax7203/led.xdc                  create_clock + PACKAGE_PIN
#   ref/alinx_ax7203/led_test_io_placed.rpt   post-implementation pin report
#
# The post-placement report confirms the differential pair is physically
# consistent with the RTL:
#
#   sys_clk_p  R4  IO_L13P_T2_MRCC_34  DIFF_SSTL15  bank 34
#   sys_clk_n  T4  IO_L13N_T2_MRCC_34  DIFF_SSTL15  bank 34
#
# R4/T4 are the P/N halves of one MRCC clock-capable differential pair, so
# IBUFDS in moe_proto_board.v is the correct primitive.
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
set_property CFGBVS VCCO        [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]

# SPIx4 flash, matching the factory bitstream settings.
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH  4 [current_design]
set_property CONFIG_MODE SPIx4                [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 50   [current_design]

# -----------------------------------------------------------------------------
# Clock: 200 MHz differential oscillator -> 5.000 ns period
# -----------------------------------------------------------------------------
# Only the P side is constrained.  sys_clk_n is consumed by the IBUFDS
# primitive inside moe_proto_board.v, so it is not a separate clock port.
create_clock -period 5.000 -name sys_clk_p [get_ports sys_clk_p]

# -----------------------------------------------------------------------------
# Engine clock: the oscillator is 200 MHz, the engine is NOT
# -----------------------------------------------------------------------------
# moe_proto_board divides the 200 MHz oscillator down and drives all engine logic
# from u_bufg_engine/O, so timing must be checked against THAT clock.
#
#   DIV_BITS = 0  ->  /1  -> 200 MHz  (current build)
#   DIV_BITS = 1  ->  /2  -> 100 MHz
#   DIV_BITS = 2  ->  /4  ->  50 MHz
#
# Keep this in step with DIV_BITS in rtl/top/moe_proto_board.v.  When the two
# drifted apart earlier, the engine was analysed at 100 MHz while the board ran
# it at 200 MHz: timing "passed" and the hardware produced a wrong checksum.
create_generated_clock -name clk_engine \
    -source [get_ports sys_clk_p] \
    -divide_by 1 \
    [get_pins u_bufg_engine/O]

set_property PACKAGE_PIN R4 [get_ports sys_clk_p]
set_property IOSTANDARD DIFF_SSTL15 [get_ports sys_clk_p]

# -----------------------------------------------------------------------------
# Reset, active low
# -----------------------------------------------------------------------------
set_property PACKAGE_PIN T6 [get_ports rst_n]
set_property IOSTANDARD LVCMOS15 [get_ports rst_n]

# -----------------------------------------------------------------------------
# Status LEDs, active LOW
# -----------------------------------------------------------------------------
#   led[0] B13  weights loaded
#   led[1] C13  activation vector loaded
#   led[2] D14  blinking while a GEMV runs
#   led[3] D15  blinking on a sticky protocol error
set_property PACKAGE_PIN B13 [get_ports {led[0]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[0]}]

set_property PACKAGE_PIN C13 [get_ports {led[1]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[1]}]

set_property PACKAGE_PIN D14 [get_ports {led[2]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[2]}]

set_property PACKAGE_PIN D15 [get_ports {led[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[3]}]

# -----------------------------------------------------------------------------
# USB-UART: the on-board bridge, no external adapter needed
# -----------------------------------------------------------------------------
# Pin numbers come from the ALINX uart_test demo's own constraint file, which
# labels them "usb uart define":
#
#   uart_rx  P20  LVCMOS33   FPGA receives
#   uart_tx  N15  LVCMOS33   FPGA transmits
#
# The bridge chip part number is not documented in anything machine-readable
# here, so 115200 is the only rate that is known good.  Anything higher has to be
# measured - see docs/board_pinout.md.
#
# These are asynchronous inputs with respect to sys_clk; the receiver in
# rtl/periph/uart_rx.v double-registers the line before using it, so no separate
# set_input_delay is meaningful without a datasheet figure for the bridge.
set_property PACKAGE_PIN P20 [get_ports uart_rx]
set_property IOSTANDARD LVCMOS33 [get_ports uart_rx]

set_property PACKAGE_PIN N15 [get_ports uart_tx]
set_property IOSTANDARD LVCMOS33 [get_ports uart_tx]
