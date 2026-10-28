# -----------------------------------------------------------------------------
# snf_dump.tcl  -  read out the 2048-entry receive capture
# -----------------------------------------------------------------------------
# Also prints the graded receive errors, which say whether the MAC rejected the
# frames on preamble/ethertype/FCS (bytes are wrong) or on destination address
# (bytes are fine, the frames are simply not ours).
#
# Register map added for bring-up:
#   0x14 write  capture read address
#   0x20 read   {8'd0, mac_err[7:0], ip_csum_err[7:0], ip_addr_err[7:0]}
#   0x24 read   {5'd0, wr_ptr[10:0], byte_count[15:0]}
#   0x28 read   {16'd0, captured entry at the address written to 0x14}
#
# Reading the capture:
#   A healthy Ethernet frame starts   55 55 55 55 55 55 55 D5  <dst mac> ...
#   Anything else - random bytes, all zero, all ones - means the bytes reaching
#   the FPGA are not a frame, and no amount of protocol debugging will help.
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

# ---- graded errors ---------------------------------------------------------
scan [rd $axi 00000020] %x g
set mac_err  [expr {($g >> 16) & 0xFF}]
set csum_err [expr {($g >> 8)  & 0xFF}]
set addr_err [expr {$g & 0xFF}]
puts ""
puts "================ graded receive errors ============"
puts [format "  mac_err (preamble/ethertype/FCS) = %d" $mac_err]
puts [format "  ip_csum_err                      = %d" $csum_err]
puts [format "  ip_addr_err (not for us)         = %d" $addr_err]
if {$mac_err == 0 && $addr_err > 0} {
    puts "  => the bytes are FINE; the frames simply are not addressed to us"
} elseif {$mac_err > 0} {
    puts "  => the MAC rejects frames: the bytes on the wire are damaged"
}

# ---- capture status --------------------------------------------------------
scan [rd $axi 00000024] %x st
set wr_ptr [expr {($st >> 16) & 0x7FF}]
set count  [expr {$st & 0xFFFF}]
puts ""
puts "================ capture ==========================="
puts [format "  bytes captured so far = %d" $count]
puts [format "  write pointer         = 0x%03X" $wr_ptr]

# ---- dump the most recent 256 bytes ---------------------------------------
set N 256
set base [expr {($wr_ptr - $N) & 0x7FF}]

puts "  last $N captured bytes (oldest first):"
set line ""
for {set i 0} {$i < $N} {incr i} {
    set a [expr {($base + $i) & 0x7FF}]
    wr $axi 00000014 [format %08X $a]
    set raw [rd $axi 00000028]
    scan $raw %x v
    set b [expr {$v & 0xFF}]
    set used [expr {($v >> 8) & 0x1}]
    if {$used} { set s [format "%02X" $b] } else { set s "--" }
    append line " $s"
    if {($i % 16) == 15} { puts "    $line"; set line "" }
}
if {$line ne ""} { puts "    $line" }
puts "==================================================="
puts ""

close_hw_target
disconnect_hw_server
exit 0
