# -----------------------------------------------------------------------------
# idly_sweep.tcl  -  sweep the RGMII receive delay tap and measure the result
# -----------------------------------------------------------------------------
# Write 0x10[4:0] = tap, let frames arrive for a while, then read how many were
# rejected during that window.
#
# The counters are sticky, so the useful number is the DELTA between successive
# reads, not the absolute value.  Deltas are computed modulo 256 because each
# counter is only eight bits wide in the register.
#
# Reading the result:
#   - rec_error delta drops sharply at some tap  -> that is the sampling point
#   - tx_frames becomes non-zero                 -> the MAC answered an ARP, done
#   - nothing changes at any tap                 -> not a sampling-point problem
#
# Run with the host pinging continuously, otherwise there is nothing to receive:
#   ping -t 192.168.8.6
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

# Hold each tap long enough that the host can generate traffic into it.
set DWELL_MS 1200

puts ""
puts "  tap |    rx |  err | d_err | udp | arp |  tx | d_tx"
puts "  ----+-------+------+-------+-----+-----+-----+-----"

set prev_err 0
set prev_tx  0

for {set tap 0} {$tap < 32} {incr tap} {
    # 0x10 write selects the delay tap
    wr $axi 00000010 [format %08X $tap]
    after $DWELL_MS

    scan [rd $axi 00000010] %x d1
    scan [rd $axi 00000014] %x d2

    set rx   [expr {$d1 & 0xFF}]
    set udp  [expr {($d1 >> 8) & 0xFF}]
    set tx   [expr {($d1 >> 16) & 0xFF}]
    set arp  [expr {($d1 >> 31) & 0x1}]
    set err  [expr {($d2 >> 24) & 0xFF}]

    # deltas, modulo 256
    set d_err [expr {($err - $prev_err + 256) % 256}]
    set d_tx  [expr {($tx - $prev_tx + 256) % 256}]
    set prev_err $err
    set prev_tx  $tx

    puts [format "  %3d | %5d | %4d | %5d | %3d | %3d | %3d | %4d" \
          $tap $rx $err $d_err $udp $arp $tx $d_tx]
}

close_hw_target
disconnect_hw_server
exit 0
