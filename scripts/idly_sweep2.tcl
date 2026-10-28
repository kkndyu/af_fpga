# -----------------------------------------------------------------------------
# idly_sweep2.tcl  -  tap sweep with readback verification
# -----------------------------------------------------------------------------
# The first sweep was worthless: the IDELAY load pulse was one 200 MHz cycle
# (5 ns), shorter than the 8 ns period of the 125 MHz clock the primitive is
# clocked by, so the tap was probably never loaded and every value looked the
# same.  The pulse is now 32 cycles, and this script reads back CNTVALUEOUT to
# prove the tap actually took effect before trusting any measurement.
#
# Metric: the change in mac_err over a fixed dwell at each tap.  Lower is better;
# a tap that makes mac_err fall towards zero is the correct sampling point.
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

set DWELL_MS 1500

puts ""
puts "  tap | back | mac_err | d_mac | ip_addr | rx"
puts "  ----+------+---------+-------+---------+-----"

set prev 0

for {set tap 0} {$tap < 32} {incr tap} {
    wr $axi 00000010 [format %08X $tap]
    after 20

    # read back what the primitive actually holds
    scan [rd $axi 0000002C] %x rb
    set back [expr {$rb & 0x1F}]

    after $DWELL_MS

    scan [rd $axi 00000020] %x g
    set mac_err  [expr {($g >> 16) & 0xFF}]
    set addr_err [expr {$g & 0xFF}]

    scan [rd $axi 00000010] %x d1
    set rx [expr {$d1 & 0xFF}]

    set d [expr {($mac_err - $prev + 256) % 256}]
    set prev $mac_err

    puts [format "  %3d | %4d | %7d | %5d | %7d | %3d" $tap $back $mac_err $d $addr_err $rx]
}

close_hw_target
disconnect_hw_server
exit 0
