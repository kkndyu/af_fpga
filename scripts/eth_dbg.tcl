# -----------------------------------------------------------------------------
# eth_dbg.tcl  -  read the Ethernet bring-up counters over JTAG
# -----------------------------------------------------------------------------
# Run:
#   D:\Xilinx\Vivado\2019.1\bin\vivado.bat -mode batch -nolog -nojournal ^
#       -source scripts\eth_dbg.tcl
#
# Counters are sticky: they only ever increase, and are cleared by reconfiguring
# the FPGA.  To measure a fresh interval, re-program the bitstream first.
# -----------------------------------------------------------------------------
if {[catch {open_hw} e]} { puts "ERROR: open_hw: $e"; exit 1 }
if {[catch {connect_hw_server -url localhost:3121} e]} {
    puts "ERROR: connect_hw_server: $e"; exit 1
}
if {[catch {open_hw_target} e]} { puts "ERROR: open_hw_target: $e"; exit 1 }
open_hw_target
current_hw_device [lindex [get_hw_devices] 0]
refresh_hw_device -update_hw_probes false [lindex [get_hw_devices] 0]

set axi_list [get_hw_axis]
if {[llength $axi_list] == 0} {
    puts "ERROR: no hw_axi core found"
    exit 1
}
set axi [lindex $axi_list 0]

set txnid 0

proc rd {axi addr} {
    global txnid
    incr txnid
    set nm rtxn$txnid
    create_hw_axi_txn $nm $axi -address $addr -type read -len 1
    run_hw_axi [get_hw_axi_txns $nm]
    set v [get_property DATA [get_hw_axi_txns $nm]]
    delete_hw_axi_txn [get_hw_axi_txns $nm]
    return $v
}

set d1 [rd $axi 00000010]
set d2 [rd $axi 00000014]

# The DATA property comes back as a hex string, so scan it into an integer -
# expr would try to read "00000078" as an octal literal.
scan $d1 %x v1
scan $d2 %x v2

# ---- decode ---------------------------------------------------------------
# 0x10 = { arp_found, tx_frames[7:0], udp_rx[7:0], rx_frames[7:0] }
# 0x14 = { rec_error[7:0], tx_done[7:0], 8'd0, 8'd0 }
set rx_frames [expr {$v1 & 0xFF}]
set udp_rx    [expr {($v1 >> 8) & 0xFF}]
set tx_frames [expr {($v1 >> 16) & 0xFF}]
set arp_found [expr {($v1 >> 31) & 0x1}]
set rec_error [expr {($v2 >> 24) & 0xFF}]
set tx_done   [expr {($v2 >> 16) & 0xFF}]

puts ""
puts "================ Ethernet counters ================"
puts [format "  0x10            = %s" $d1]
puts [format "  0x14            = %s" $d2]
puts "  ------------------------------------------------"
puts [format "  rx_frames       = %d    frame carrier arrivals" $rx_frames]
puts [format "  rec_error       = %d    frames rejected by the MAC" $rec_error]
puts [format "  udp_rx          = %d    datagrams that passed every check" $udp_rx]
puts [format "  arp_found       = %d    ARP replies received" $arp_found]
puts [format "  tx_frames       = %d    frames the MAC transmitted" $tx_frames]
puts [format "  tx_done         = %d    frames fully transmitted" $tx_done]
puts "  ------------------------------------------------"

if {$rx_frames == 0} {
    puts "  => nothing is arriving at the MAC at all"
} elseif {$rec_error >= $rx_frames && $udp_rx == 0 && $arp_found == 0} {
    puts "  => every frame is being rejected: the received data is corrupt"
    puts "     (preamble / FCS failing, i.e. the RGMII receive sampling point)"
} elseif {$tx_frames == 0} {
    puts "  => frames are accepted but nothing is transmitted"
} elseif {$arp_found == 0} {
    puts "  => transmitting, but no ARP reply is coming back"
} else {
    puts "  => the chain is working end to end"
}
puts "==================================================="

close_hw_target
disconnect_hw_server
exit 0
