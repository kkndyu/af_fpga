# -----------------------------------------------------------------------------
# build_demo.tcl  -  build the vendor's ethernet_test demo unmodified
# -----------------------------------------------------------------------------
# The point of this build is a hardware sanity check, not a deliverable: if the
# untouched vendor demo ARPs and our integration does not, the fault is in the
# integration.  If neither works, the fault is in the board, the PHY or the host.
#
# Built with the non-project flow from the file list recorded in eth_test.xpr, so
# nothing is inferred from directory structure.  The seven Xilinx cores are
# regenerated from their .xci rather than replaced with the local equivalents,
# because the whole purpose is to run exactly what the vendor shipped.
# -----------------------------------------------------------------------------
set ROOT "D:/ai/moe_fpga_proto_verilog/build/vendor/demo/ethernet_test"
set SRC  "$ROOT/eth_test.srcs"
set PART "xc7a200tfbg484-2"

create_project -in_memory -part $PART

# ---- generated IP -----------------------------------------------------------
foreach ip {
    clk_wiz_0
    eth_data_fifo
    icmp_rx_ram_8_256
    len_fifo
    udp_checksum_fifo
    udp_rx_ram_8_2048
    udp_tx_data_fifo
} {
    read_ip "$SRC/sources_1/ip/$ip/$ip.xci"
}
generate_target all [get_ips]
synth_ip [get_ips]

# ---- RTL, exactly the list in the .xpr --------------------------------------
set srcs [list \
    "$SRC/sources_1/imports/src/ethernet_test.v" \
    "$SRC/sources_1/imports/src/util_gmii_to_rgmii.v" \
    "$SRC/sources_1/new/ethernet_2port.v" \
    "$SRC/sources_1/new/reset.v" \
    "$SRC/sources_1/mac/arp_cache.v" \
    "$SRC/sources_1/mac/crc.v" \
    "$SRC/sources_1/mac/icmp_reply.v" \
    "$SRC/sources_1/mac/mac_test.v" \
    "$SRC/sources_1/mac/mac_top.v" \
    "$SRC/sources_1/mac/rx/arp_rx.v" \
    "$SRC/sources_1/mac/rx/ip_rx.v" \
    "$SRC/sources_1/mac/rx/mac_rx.v" \
    "$SRC/sources_1/mac/rx/mac_rx_top.v" \
    "$SRC/sources_1/mac/rx/udp_rx.v" \
    "$SRC/sources_1/mac/tx/arp_tx.v" \
    "$SRC/sources_1/mac/tx/ip_tx.v" \
    "$SRC/sources_1/mac/tx/ip_tx_mode.v" \
    "$SRC/sources_1/mac/tx/mac_tx.v" \
    "$SRC/sources_1/mac/tx/mac_tx_mode.v" \
    "$SRC/sources_1/mac/tx/mac_tx_top.v" \
    "$SRC/sources_1/mac/tx/udp_tx.v" \
    "$ROOT/src/arbi/gmii_arbi.v" \
    "$ROOT/src/arbi/gmii_rx_buffer.v" \
    "$ROOT/src/arbi/gmii_tx_buffer.v" \
    "$ROOT/src/mdio/smi_config.v" \
    "$ROOT/src/mdio/smi_read_write.v" \
    "$ROOT/src/dp_ram.v" \
]
foreach f $srcs {
    if {![file exists $f]} { puts "MISSING: $f"; exit 1 }
    read_verilog $f
}
read_xdc "$SRC/constrs_1/new/top.xdc"

# ---- implementation ---------------------------------------------------------
synth_design -top ethernet_2port -part $PART
opt_design
place_design
route_design

puts "==== demo WNS(setup) = [get_property SLACK [lindex [get_timing_paths -max_paths 1 -delay_type max] 0]]"
report_utilization -file "$ROOT/demo_util.rpt"
report_timing_summary -file "$ROOT/demo_timing.rpt" -max_paths 5
write_checkpoint -force "$ROOT/demo_routed.dcp"

write_bitstream -force "D:/ai/moe_fpga_proto_verilog/build/vendor/demo/ethernet_2port.bit"
puts "==== DEMO BITSTREAM WRITTEN"
