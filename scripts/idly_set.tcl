# -----------------------------------------------------------------------------
# idly_set.tcl  -  set the receive delay tap and report what the MAC does
# -----------------------------------------------------------------------------
# The sweep showed ip_addr_err first appearing at tap 13 and rising to 6 by tap 31,
# which means frames only start passing the MAC (preamble, ethertype, FCS) at the
# high end of the delay range.  This sets one tap, generates traffic, and reports
# every counter so the effect on ARP can be seen directly.
#
#   tap 0..31
# -----------------------------------------------------------------------------
if {![info exists argv] || [llength $argv] < 1} {
    puts "usage: idly_set.tcl <tap>"
    exit 1
}
set TAP [lindex $argv 0]

open_hw
connect_hw_server -url localhost:3121
open_hw_target
set dev [lindex [get_hw_devices] 0]
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev

set axi [lindex [get_hw_axis] 0]
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

proc wr {axi addr data} {
    global txnid
    incr txnid
    set nm wtxn$txnid
    create_hw_axi_txn $nm $axi -address $addr -data $data -type write -len 1
    run_hw_axi [get_hw_axi_txns $nm]
    delete_hw_axi_txn [get_hw_axi_txns $nm]
}

wr $axi 00000010 [format %08X $TAP]
after 200

scan [rd $axi 0000002C] %x rb
scan [rd $axi 00000010] %x d1
scan [rd $axi 00000014] %x d2
scan [rd $axi 00000020] %x g
scan [rd $axi 00000018] %x pr

set rx    [expr {$d1 & 0xFF}]
set udp   [expr {($d1 >> 8) & 0xFF}]
set tx    [expr {($d1 >> 16) & 0xFF}]
set arp   [expr {($d1 >> 31) & 0x1}]
set rec_err [expr {($d2 >> 24) & 0xFF}]
set mac_err  [expr {($g >> 16) & 0xFF}]
set csum_err [expr {($g >> 8) & 0xFF}]
set addr_err [expr {$g & 0xFF}]
set probe_ok [expr {($pr >> 31) & 0x1}]
set probe_addr [expr {($pr >> 23) & 0x1F}]
set probe_id [expr {$pr & 0xFFFF}]

puts ""
puts "======== tap = $TAP (IDELAY readback [expr {$rb & 0x1F}]) ========"
puts [format "  rx_frames   = %d" $rx]
puts [format "  mac_err     = %d   (preamble / ethertype / FCS)" $mac_err]
puts [format "  ip_csum_err = %d" $csum_err]
puts [format "  ip_addr_err = %d   (MAC ok, addressed elsewhere)" $addr_err]
puts [format "  udp_rx      = %d" $udp]
puts [format "  arp_found   = %d" $arp]
puts [format "  tx_frames   = %d   <-- non-zero means an ARP reply went out" $tx]
puts [format "  phy probe   = valid %d addr %d id 0x%04X" $probe_ok $probe_addr $probe_id]
puts "================================================="
puts ""

close_hw_target
disconnect_hw_server
exit 0
