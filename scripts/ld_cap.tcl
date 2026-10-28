# -----------------------------------------------------------------------------
# ld_cap.tcl  -  dump the bytes the shim actually forwarded into the loader
# -----------------------------------------------------------------------------
# The wire capture already proved the frames on the cable are valid, so whatever
# is going wrong is between the vendor's udp_rx and the loader.  This reads back
# the last 64 bytes that crossed that boundary, plus the two lengths the shim
# worked from, so the forwarded stream can be compared with what was sent.
#
# Registers:
#   0x30 write  capture read index
#   0x34 read   captured byte at that index
#   0x38 read   {payload_len the shim derived, total bytes forwarded}
#   0x3C read   {16'd0, udp_rec_data_length at packet start}
# -----------------------------------------------------------------------------
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

scan [rd $axi 00000038] %x s
set pay   [expr {($s >> 16) & 0xFFFF}]
set count [expr {$s & 0xFFFF}]
scan [rd $axi 0000003C] %x dl
set dlen [expr {$dl & 0xFFFF}]

puts ""
puts "======== loader feed =============================="
puts [format "  udp_rec_data_length = %d   (expect 13 = 8 header + 5 payload)" $dlen]
puts [format "  shim payload length = %d   (expect 5)" $pay]
puts [format "  bytes forwarded     = %d" $count]
puts "  first 16 forwarded bytes:"
set line ""
for {set i 0} {$i < 16} {incr i} {
    wr $axi 00000030 [format %08X $i]
    set raw [rd $axi 00000034]
    scan $raw %x v
    append line [format " %02X" [expr {$v & 0xFF}]]
}
puts "   $line"
puts "  expected:                 A5 04 00 00 AB"
puts "==================================================="
puts ""

close_hw_target
disconnect_hw_server
exit 0
