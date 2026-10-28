# -----------------------------------------------------------------------------
# ram_chk.tcl  -  was the UDP payload actually written into the receive RAM?
# -----------------------------------------------------------------------------
# Reading the payload back returned all zeroes even though the shim forwarded the
# right number of bytes, so the question is whether udp_rx ever wrote anything.
# These registers answer that directly:
#
#   0x1C  {5'd0, ram_wr_addr[10:0], ram_wr_cnt[15:0]}
#         how many payload writes udp_rx performed, and the last address used
#   0x34  {24'd0, ram_wr_data[7:0]}
#         the last byte written
#   0x38  {shim_payload_len[15:0], bytes_forwarded[15:0]}
#   0x3C  {16'd0, udp_rec_data_length[15:0]}
#
# Reading it:
#   ram_wr_cnt = 0                -> the write never happened at all
#   ram_wr_cnt = N, addr = N-1    -> the payload really is in the RAM, and the
#                                    fault is on the read side
#   addr wandering                -> the write address is being computed wrongly
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

scan [rd $axi 0000001C] %x a
set wr_cnt  [expr {$a & 0xFFFF}]
set wr_addr [expr {($a >> 16) & 0x7FF}]

scan [rd $axi 00000034] %x b
set wr_data [expr {$b & 0xFF}]

scan [rd $axi 00000038] %x s
set pay   [expr {($s >> 16) & 0xFFFF}]
set fwd   [expr {$s & 0xFFFF}]

scan [rd $axi 0000003C] %x d
set dlen [expr {$d & 0xFFFF}]

puts ""
puts "=========== receive RAM check ====================="
puts [format "  udp_rec_data_length  = %d" $dlen]
puts [format "  shim payload length  = %d" $pay]
puts [format "  bytes forwarded      = %d" $fwd]
puts "  --------------------------------------------------"
puts [format "  ram_wr_cnt           = %d      <-- writes udp_rx performed" $wr_cnt]
puts [format "  ram_wr_addr (last)   = %d" $wr_addr]
puts [format "  ram_wr_data (last)   = 0x%02X" $wr_data]
puts "  --------------------------------------------------"
if {$wr_cnt == 0} {
    puts "  => udp_rx never wrote the payload: the fault is on the write side"
} elseif {$fwd > 0} {
    puts "  => the payload WAS written; the fault is on the read side"
} else {
    puts "  => writes happened but the shim forwarded nothing"
}
puts "==================================================="
puts ""

close_hw_target
disconnect_hw_server
exit 0
