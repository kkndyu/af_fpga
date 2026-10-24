# -----------------------------------------------------------------------------
# hw_axi_full_load.tcl - load the whole model over JTAG-AXI and verify 256 lanes
# -----------------------------------------------------------------------------
#   vivado -mode batch -nolog -nojournal -notrace -source scripts/hw_axi_full_load.tcl
#
# The acceptance test for the JTAG-AXI transport: everything the board needs is
# pushed through AXI one 32-bit write at a time, the GEMV runs, and all 256 lanes
# are read back and compared against the golden reference.
#
#   weights  : 4 banks x 1024 rows x 32 bytes = 131072 bytes  (~32772 AXI writes)
#   inputs   : 1024 x 16 bit                  =   2048 bytes  (~514 AXI writes)
#   RUN
#   output   : 256 lanes x 4 bytes           =   1024 bytes  (256 AXI reads)
#
# AXI4-Lite has no bursts, so every 4 bytes costs one transaction.  That is the
# whole reason this takes minutes rather than milliseconds - a burst-capable
# jtag_axi (PROTOCOL 0) plus burst support in the bridge would cut it by ~100x,
# at the cost of rewriting the bridge.
#
# Progress is printed with a running ETA so a slow run is visible immediately
# rather than looking like a hang.
# -----------------------------------------------------------------------------

foreach ch {stdout stderr} { catch { fconfigure $ch -buffering none } }

set ROOT {D:/ai/moe_fpga_proto_verilog}
set t_start [clock seconds]

proc mark {msg} {
    global t_start
    set el [expr {[clock seconds] - $t_start}]
    puts "==== \[[format %3d $el]s\] $msg"
    flush stdout
}

proc crc8 {crc din} {
    set c [expr {$crc ^ $din}]
    for {set i 0} {$i < 8} {incr i} {
        if {$c & 0x80} { set c [expr {(($c << 1) ^ 0x07) & 0xFF}] } \
        else           { set c [expr {($c << 1) & 0xFF}] }
    }
    return $c
}

proc hexval {s} {
    set s [string toupper $s]
    if {[string length $s] > 8} { set s [string range $s end-7 end] }
    if {![regexp {^[0-9A-F]+$} $s]} { return -1 }
    return [expr "0x$s"]
}

# -----------------------------------------------------------------------------
# Read the data files
# -----------------------------------------------------------------------------
proc read_lines {path} {
    set fh [open $path r]
    set data [read $fh]
    close $fh
    set out {}
    foreach ln [split $data "\n"] {
        set ln [string trim $ln]
        if {$ln eq ""} continue
        lappend out $ln
    }
    return $out
}

mark "reading data files"
set W {}
for {set b 0} {$b < 4} {incr b} {
    lappend W [read_lines [format {%s/mem_init/expert0/gate_r%d.mem} $ROOT $b]]
}
set ACT   [read_lines $ROOT/sim/data/input.mem]
set REF   [read_lines $ROOT/sim/data/ref_out.hex]
mark "  weights: [llength [lindex $W 0]] rows x 4 banks   act: [llength $ACT]   ref: [llength $REF]"

# -----------------------------------------------------------------------------
# Hardware
# -----------------------------------------------------------------------------
mark "opening hardware manager"
if {[catch {open_hw} e]} { mark "FAILED open_hw: $e"; exit 1 }
if {[catch {connect_hw_server -url localhost:3121} e]} { mark "FAILED connect: $e"; exit 1 }
if {[catch {open_hw_target} e]} { mark "FAILED open_hw_target: $e"; exit 1 }
set dev [lindex [get_hw_devices] 0]
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev
set axis [get_hw_axis]
if {[llength $axis] == 0} { mark "FAILED: no hw_axi"; exit 1 }
set axi [lindex $axis 0]
mark "device $dev   axi $axi"

set txnid 0
proc axi_wr {axi addr data} {
    global txnid
    incr txnid
    set nm w$txnid
    create_hw_axi_txn $nm $axi -address $addr -data $data -type write -len 1
    run_hw_axi [get_hw_axi_txns $nm]
    delete_hw_axi_txn [get_hw_axi_txns $nm]
}
proc axi_rd {axi addr} {
    global txnid
    incr txnid
    set nm r$txnid
    create_hw_axi_txn $nm $axi -address $addr -type read -len 1
    run_hw_axi [get_hw_axi_txns $nm]
    set v [get_property DATA [get_hw_axi_txns $nm]]
    delete_hw_axi_txn [get_hw_axi_txns $nm]
    return $v
}

# -----------------------------------------------------------------------------
# Send a byte list as 32-bit TXDATA writes, zero padded to a word boundary.
# -----------------------------------------------------------------------------
set words_sent 0
proc send_bytes {axi bytes} {
    global words_sent
    set n [llength $bytes]
    set nw [expr {($n + 3) / 4}]
    for {set i 0} {$i < $nw} {incr i} {
        # Guard each byte with a plain if.  Writing this as
        #     expr {$cond ? [lindex $bytes $k] : 0}
        # does NOT work: Tcl substitutes [lindex ...] before expr parses it, so a
        # partial final word takes "" from the out-of-range index and expr then
        # fails on a non-numeric operand.
        set p [expr {$i*4}]
        set b0 0; set b1 0; set b2 0; set b3 0
        if {[expr {$p+0}] < $n} { set b0 [lindex $bytes [expr {$p+0}]] }
        if {[expr {$p+1}] < $n} { set b1 [lindex $bytes [expr {$p+1}]] }
        if {[expr {$p+2}] < $n} { set b2 [lindex $bytes [expr {$p+2}]] }
        if {[expr {$p+3}] < $n} { set b3 [lindex $bytes [expr {$p+3}]] }
        set w [expr {$b0 | ($b1 << 8) | ($b2 << 16) | ($b3 << 24)}]
        axi_wr $axi 00000000 [format %08X $w]
        incr words_sent
        if {($words_sent % 2000) == 0} {
            mark "  ... $words_sent words sent"
        }
    }
}

# -----------------------------------------------------------------------------
# Build one frame: magic, cmd, len_hi, len_lo, payload..., crc8
# -----------------------------------------------------------------------------
proc build_frame {cmd payload} {
    set len [llength $payload]
    set b [list 0xA5 $cmd [expr {($len >> 8) & 0xFF}] [expr {$len & 0xFF}]]
    set crc 0
    foreach x [list $cmd [expr {($len >> 8) & 0xFF}] [expr {$len & 0xFF}]] {
        set crc [crc8 $crc $x]
    }
    foreach x $payload { set crc [crc8 $crc $x] }
    set out [concat $b $payload [list $crc]]
    # pad to a 4-byte boundary with zeros; the parser ignores non-0xA5 bytes
    while {[expr {[llength $out] % 4}] != 0} { lappend out 0 }
    return $out
}

# =============================================================================
# 1. Weights: four frames, one per region
# =============================================================================
# Each frame is verified before moving on.
#
# This used to fire all four frames back to back and only look at STATUS once at
# the end.  A single corrupted frame therefore failed silently: the loader clears
# weights_ready and raises ERR_CRC, and the *next* successful frame - the
# activation - clears err_code again, so the final STATUS showed "act_valid=1,
# err=0, weights_ready=0" with no evidence of what went wrong or which region.
#
# Checking after each frame turns an intermittent cable glitch into a visible,
# recoverable event, and pins the blame to one region.
set errors 0
for {set r 0} {$r < 4} {incr r} {
    mark "building weight frame for region $r"
    set payload [list $r 0x00 0x00]
    set rows [lindex $W $r]
    foreach row $rows {
        # row is 64 hex chars = 256 bits; the loader shifts the first byte into
        # bits 255:248, so send the pairs left to right
        for {set k 0} {$k < 64} {incr k 2} {
            lappend payload [expr "0x[string range $row $k [expr {$k+1}]]"]
        }
    }
    set bytes [build_frame 0x01 $payload]
    mark "  frame: [llength $bytes] bytes"

    set ok 0
    for {set attempt 1} {$attempt <= 3 && !$ok} {incr attempt} {
        send_bytes $axi $bytes
        after 50
        set st [hexval [axi_rd $axi 00000004]]
        set we [expr {$st & 1}]
        set er [expr {($st >> 8) & 0xFF}]
        if {$we == 1 && $er == 0} {
            mark "  region $r loaded (attempt $attempt)"
            set ok 1
        } else {
            mark "  region $r REJECTED on attempt $attempt: STATUS=[format %08X $st] err_code=$er"
        }
    }
    if {!$ok} { mark "  region $r could not be loaded"; incr errors }
}

# =============================================================================
# 2. Activations
# =============================================================================
mark "building activation frame"
set payload [list 0x00 0x00]
foreach v $ACT {
    # 16-bit value, MSB first: the loader assembles {shift[7:0], din}
    lappend payload [expr "0x[string range $v 0 1]"]
    lappend payload [expr "0x[string range $v 2 3]"]
}
set bytes [build_frame 0x02 $payload]
mark "  frame: [llength $bytes] bytes"
send_bytes $axi $bytes

# verify the loader reports it ready
after 300
set st [hexval [axi_rd $axi 00000004]]
mark "STATUS after load = [format %08X $st]   (bit0 weights_ready, bit1 act_valid)"
if {($st & 3) != 3} {
    mark "ERROR: weights_ready/act_valid not both set"
}

# =============================================================================
# 3. RUN
# =============================================================================
mark "RUN"
send_bytes $axi [build_frame 0x03 {}]

# =============================================================================
# 4. READ_OUT 256 lanes
# =============================================================================
mark "READ_OUT"
set payload [list 0x00 0xFF]        ;# lane_start = 0, nlanes-1 = 255
send_bytes $axi [build_frame 0x05 $payload]

set got {}
set tries 0
while {[llength $got] < 256 && $tries < 2000} {
    incr tries
    set cnt [hexval [axi_rd $axi 0000000C]]
    while {$cnt >= 4 && [llength $got] < 256} {
        set d [hexval [axi_rd $axi 00000008]]
        lappend got [expr {$d & 0xFFFFFFFF}]
        set cnt [expr {$cnt - 4}]
    }
}
mark "read [llength $got] lanes"

# =============================================================================
# 5. Compare
# =============================================================================
set bad 0
set sum 0
for {set i 0} {$i < [llength $got]} {incr i} {
    set v [lindex $got $i]
    set sum [expr {($sum + $v) & 0xFFFFFFFF}]
    if {$i < [llength $REF]} {
        set r [expr "0x[string trim [lindex $REF $i]]"]
        if {$v != $r} {
            if {$bad < 8} {
                mark [format "  lane %3d: got %08X  expect %08X" $i $v $r]
            }
            incr bad
        }
    }
}
mark [format "checksum over returned lanes = %08X (expect FFFFC6E2)" $sum]
mark "mismatched lanes: $bad of [llength $got]"

if {$bad == 0 && [llength $got] == 256 && $errors == 0} {
    mark "RESULT: FULL LOAD PASSED - all 256 lanes match ref_out.hex"
} else {
    if {$errors != 0} { mark "RESULT: FAILED - $errors weight region(s) never loaded" }
    mark "RESULT: FAILED"
}

catch {close_hw_target}
catch {disconnect_hw_server}
catch {close_hw}
mark "done"
exit 0
