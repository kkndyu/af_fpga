# -----------------------------------------------------------------------------
# hw_axi_test.tcl - drive the loader over JTAG-AXI from the host
# -----------------------------------------------------------------------------
#   vivado -mode batch -nolog -nojournal -notrace -source scripts/hw_axi_test.tcl
#
# The real end-to-end test of the JTAG-AXI transport: the host issues AXI reads
# and writes over the JTAG cable (hw_axi), through dbg_hub and jtag_axi in the
# FPGA, into axil_loader_bridge, and out to the loader.
#
# It mirrors scripts/sim.cmd axil so a pass here means the RTL verified in
# simulation is the RTL running on the board.
#
# Register map (word aligned):
#   0x00 W TXDATA    four bytes pushed LSB-first into the loader's byte stream
#   0x04 R STATUS    [0] weights_ready [1] act_valid [2] busy [15:8] err_code
#   0x08 R RXDATA    pops four reply bytes
#   0x0C R RXCOUNT   bytes available in the reply FIFO
# -----------------------------------------------------------------------------

foreach ch {stdout stderr} { catch { fconfigure $ch -buffering none } }

proc mark {msg} { puts "==== $msg"; flush stdout }

# CRC-8, polynomial 0x07, init 0 - must match rtl/ctrl/moe_loader.v
proc crc8 {crc din} {
    set c [expr {$crc ^ $din}]
    for {set i 0} {$i < 8} {incr i} {
        if {$c & 0x80} {
            set c [expr {(($c << 1) ^ 0x07) & 0xFF}]
        } else {
            set c [expr {($c << 1) & 0xFF}]
        }
    }
    return $c
}

# Last 8 hex digits of whatever DATA comes back, as an integer.
proc hexval {s} {
    set s [string toupper $s]
    if {[string length $s] > 8} { set s [string range $s end-7 end] }
    if {![regexp {^[0-9A-F]+$} $s]} { return -1 }
    return [expr "0x$s"]
}

set txnid 0

proc axi_rd {axi addr} {
    global txnid
    incr txnid
    set nm rtxn$txnid
    create_hw_axi_txn $nm $axi -address $addr -type read -len 1
    run_hw_axi [get_hw_axi_txns $nm]
    set v [get_property DATA [get_hw_axi_txns $nm]]
    delete_hw_axi_txn [get_hw_axi_txns $nm]
    return $v
}

proc axi_wr {axi addr data} {
    global txnid
    incr txnid
    set nm wtxn$txnid
    create_hw_axi_txn $nm $axi -address $addr -data $data -type write -len 1
    run_hw_axi [get_hw_axi_txns $nm]
    delete_hw_axi_txn [get_hw_axi_txns $nm]
}

mark "opening hardware manager"
if {[catch {open_hw} e]}                    { mark "FAILED open_hw: $e"; exit 1 }
if {[catch {connect_hw_server -url localhost:3121} e]} {
    mark "FAILED connect_hw_server: $e"; exit 1
}
mark "targets: [get_hw_targets]"
if {[catch {open_hw_target} e]}             { mark "FAILED open_hw_target: $e"; exit 1 }

set dev [lindex [get_hw_devices] 0]
mark "device: $dev"
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev

set axis [get_hw_axis]
mark "hw_axi instances: $axis"
if {[llength $axis] == 0} {
    mark "FAILED: no hw_axi found - the jtag_axi core is not reachable"
    exit 1
}
set axi [lindex $axis 0]
mark "using: $axi"

set errors 0

# -----------------------------------------------------------------------------
mark "eth debug: 0x10 = {arp,tx,udp,rx}  0x14 = {recerr,txdone,0,0}"
set e1 [axi_rd $axi 00000010]
set e2 [axi_rd $axi 00000014]
mark "  ETH_DBG  (0x10) = $e1"
mark "  ETH_DBG2 (0x14) = $e2"
set e3 [axi_rd $axi 00000018]
mark "  PHY_PROBE (0x18) = $e3"

mark "test 1: STATUS before anything (expect 0)"
set raw [axi_rd $axi 00000004]
set st  [hexval $raw]
mark "  raw DATA = $raw   -> STATUS = [format %08X $st]"
if {$st != 0} { mark "  ERROR expected 0"; incr errors }

# -----------------------------------------------------------------------------
mark "test 2: RUN through TXDATA must be refused with ERR_NOT_LOADED"
set crc 0
foreach b {0x03 0x00 0x00} { set crc [crc8 $crc $b] }
set w0 [format %08X [expr {0xA5 | (0x03 << 8)}]]
set w1 [format %08X $crc]
mark "  word0=$w0 word1=$w1 (crc=0x[format %02X $crc])"
axi_wr $axi 00000000 $w0
axi_wr $axi 00000000 $w1

# Poll rather than read once.
#
# hw_axi queues transactions: run_hw_axi guarantees that the transaction it was
# given has completed, but not that a later read observes an earlier write's
# effect, and the loader also needs a few clocks after the last byte before it
# judges the frame.  Polling turns "sometimes the read wins the race" into a
# deterministic pass, and the poll trace shows when the write actually landed.
set st  0
set err 0
for {set i 0} {$i < 5} {incr i} {
    after 150
    set st  [hexval [axi_rd $axi 00000004]]
    set err [expr {($st >> 8) & 0xFF}]
    mark "  poll $i: STATUS = [format %08X $st]  err_code = [format %02X $err]"
    if {$err == 2} { break }
}
mark "  final STATUS = [format %08X $st]   err_code = [format %02X $err] (expect 02)"
if {$err != 2} { mark "  ERROR expected ERR_NOT_LOADED"; incr errors }

# -----------------------------------------------------------------------------
mark "test 3: STATUS command -> 8-byte reply"
set crc 0
foreach b {0x04 0x00 0x00} { set crc [crc8 $crc $b] }
set w0 [format %08X [expr {0xA5 | (0x04 << 8)}]]
set w1 [format %08X $crc]
axi_wr $axi 00000000 $w0
axi_wr $axi 00000000 $w1

set cnt [hexval [axi_rd $axi 0000000C]]
mark "  RXCOUNT = $cnt (expect 8)"
if {$cnt != 8} { mark "  ERROR expected 8 reply bytes"; incr errors }

set d0 [hexval [axi_rd $axi 00000008]]
set d1 [hexval [axi_rd $axi 00000008]]
mark "  reply word0 = [format %08X $d0]   word1 = [format %08X $d1]"

set b2 [expr {($d0 >> 16) & 0xFF}]
set b3 [expr {($d0 >> 24) & 0xFF}]
mark "  byte2 (err_code) = [format %02X $b2]   byte3 (any_error) = [format %02X $b3]"
if {$b2 != 2} { mark "  ERROR expected err_code 02"; incr errors }
if {$b3 != 1} { mark "  ERROR expected any_error 01"; incr errors }

set cnt [hexval [axi_rd $axi 0000000C]]
mark "test 4: RXCOUNT after draining = $cnt (expect 0)"
if {$cnt != 0} { mark "  ERROR reply FIFO not empty"; incr errors }

# -----------------------------------------------------------------------------
if {$errors == 0} {
    mark "RESULT: ALL JTAG-AXI TESTS PASSED"
} else {
    mark "RESULT: $errors ERROR(S)"
}

catch {close_hw_target}
catch {disconnect_hw_server}
catch {close_hw}
exit 0
