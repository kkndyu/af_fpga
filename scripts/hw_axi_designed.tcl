# -----------------------------------------------------------------------------
# hw_axi_designed.tcl - designed test vectors, expected answers derived by hand
# -----------------------------------------------------------------------------
#   vivado -mode batch -nolog -nojournal -notrace -source scripts/hw_axi_designed.tcl
#
# Every previous test compared hardware against a model.  Even with two
# independent implementations, both could be wrong in the same way - they were
# written by the same person from the same understanding.  These four vectors do
# not consult any model: each expected value is derived from first principles, so
# a shared misunderstanding has nowhere to hide.
#
#   T1  all weights zero            -> every lane 0
#       Catches a stale accumulator or a clear that does not clear.
#
#   T2  every weight code = 2 (x1)  -> every lane = sum of all 1024 activations
#       Catches rows that are skipped, double-counted, or read from the wrong
#       address: the sum only comes out right if exactly 1024 rows are accumulated.
#
#   T3  one-hot: lane j gets code 2 at row j only, zero elsewhere
#       -> out[j] = x[j]
#       This is the strongest single check.  The expected value is literally the
#       input file, so it verifies lane->region mapping, nibble order within a
#       row, big-endian bit layout, row addressing and sign extension all at once.
#       Any of them wrong and the answer is not x[j].
#
#   T4  row 0 of every region holds nibbles 0,1,2,...15,0,1,...
#       -> out[j] = codebook[x[0]][j mod 16]
#       Exercises all 16 codebook entries through the hardware, including the
#       arithmetic-shift subtlety in 1.5a for negative activations.
#
# The weights are built in Tcl, not read from disk, precisely so that no generated
# file is involved in deciding what the right answer is.
# -----------------------------------------------------------------------------

foreach ch {stdout stderr} { catch { fconfigure $ch -buffering none } }

set ROOT {D:/ai/moe_fpga_proto_verilog}
set H_DIM 1024
set LANES 256

proc mark {msg} { puts "==== $msg"; flush stdout }

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
proc s32 {v} {
    set w [expr {$v % 4294967296}]
    if {$w < 0} { set w [expr {$w + 4294967296}] }
    return $w
}

# --- hardware ---------------------------------------------------------------
open_hw
connect_hw_server -url localhost:3121
open_hw_target
set dev [lindex [get_hw_devices] 0]
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev
set axi [lindex [get_hw_axis] 0]
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

set words_sent 0
proc send_bytes {axi bytes} {
    global words_sent
    set n [llength $bytes]
    set nw [expr {($n + 3) / 4}]
    for {set i 0} {$i < $nw} {incr i} {
        set p [expr {$i*4}]
        set b0 0; set b1 0; set b2 0; set b3 0
        if {[expr {$p+0}] < $n} { set b0 [lindex $bytes [expr {$p+0}]] }
        if {[expr {$p+1}] < $n} { set b1 [lindex $bytes [expr {$p+1}]] }
        if {[expr {$p+2}] < $n} { set b2 [lindex $bytes [expr {$p+2}]] }
        if {[expr {$p+3}] < $n} { set b3 [lindex $bytes [expr {$p+3}]] }
        axi_wr $axi 00000000 [format %08X [expr {$b0 | ($b1<<8) | ($b2<<16) | ($b3<<24)}]]
        incr words_sent
    }
}

proc build_frame {cmd payload} {
    set len [llength $payload]
    set b [list 0xA5 $cmd [expr {($len >> 8) & 0xFF}] [expr {$len & 0xFF}]]
    set crc 0
    foreach x [list $cmd [expr {($len>>8)&0xFF}] [expr {$len&0xFF}]] { set crc [crc8 $crc $x] }
    foreach x $payload { set crc [crc8 $crc $x] }
    set out [concat $b $payload [list $crc]]
    while {[expr {[llength $out] % 4}] != 0} { lappend out 0 }
    return $out
}

# --- activations -------------------------------------------------------------
set fh [open "$ROOT/sim/data/input.mem" r]
set ACT {}
foreach ln [split [read $fh] "\n"] {
    set t [string trim $ln]
    if {$t eq ""} continue
    set v [expr "0x$t"]
    if {$v >= 0x8000} { set v [expr {$v - 0x10000}] }     ;# signed 16 bit
    lappend ACT $v
}
close $fh
mark "read [llength $ACT] activations"

# sum of all activations, for T2
set SUMS 0
foreach v $ACT { set SUMS [expr {$SUMS + $v}] }
mark "sum of activations = $SUMS"

# Arithmetic right shift, floor semantics.
#
# Tcl has >> for shifts, but relying on its sign behaviour is asking for trouble,
# and -shr / -shl (which this script originally used) are POWERSHELL operators -
# Tcl reports 'invalid bareword "shr"'.  Spelling the floor out removes both
# questions: for a negative value, floor(a / 2^n) == -ceil(-a / 2^n).
proc ashr {a n} {
    if {$a >= 0} { return [expr {$a >> $n}] }
    return [expr {-((( -$a) + (1 << $n) - 1) >> $n)}]
}

# codebook, from fp4_product_gen.v: 1.5a is a + (a>>>1), an ARITHMETIC shift
proc cb {a code} {
    set h [ashr $a 1]
    set q [ashr $a 2]
    switch -- $code {
        0  { return 0 }
        1  { return $h }
        2  { return $a }
        3  { return [expr {$a + $h}] }
        4  { return [expr {$a << 1}] }
        5  { return [expr {$a << 2}] }
        6  { return $q }
        7  { return 0 }
        8  { return 0 }
        9  { return [expr {-$h}] }
        10 { return [expr {-$a}] }
        11 { return [expr {-($a + $h)}] }
        12 { return [expr {-($a << 1)}] }
        13 { return [expr {-($a << 2)}] }
        14 { return [expr {-$q}] }
        15 { return 0 }
    }
}

proc zero_row {} { return [string repeat "0" 64] }

# Place one nibble in a 64-character row string.  The .mem line is MSB first, so
# nibble i sits at character 63 - i.
proc put_nibble {row i code} {
    set pos [expr {63 - $i}]
    return [string replace $row $pos $pos [format %x $code]]
}

# Load one weight set: $rowspec is a 4-element list, each a dict row -> rowstring.
proc load_weights {axi rowspec} {
    for {set r 0} {$r < 4} {incr r} {
        set payload [list $r 0x00 0x00]
        set sparse [lindex $rowspec $r]
        set z [zero_row]
        for {set k 0} {$k < 1024} {incr k} {
            set row $z
            if {[dict exists $sparse $k]} { set row [dict get $sparse $k] }
            for {set c 0} {$c < 64} {incr c 2} {
                lappend payload [expr "0x[string range $row $c [expr {$c+1}]]"]
            }
        }
        send_bytes $axi [build_frame 0x01 $payload]
    }
}

proc load_acts {axi} {
    global ACT
    set payload [list 0x00 0x00]
    foreach v $ACT {
        set w [expr {$v & 0xFFFF}]
        lappend payload [expr {($w >> 8) & 0xFF}] [expr {$w & 0xFF}]
    }
    send_bytes $axi [build_frame 0x02 $payload]
}

proc do_run {axi} {
    send_bytes $axi [build_frame 0x03 {}]
}

proc read_lanes {axi} {
    send_bytes $axi [build_frame 0x05 [list 0x00 0xFF]]
    set got {}
    set tries 0
    while {[llength $got] < 256 && $tries < 4000} {
        incr tries
        set cnt [hexval [axi_rd $axi 0000000C]]
        while {$cnt >= 4 && [llength $got] < 256} {
            lappend got [hexval [axi_rd $axi 00000008]]
            set cnt [expr {$cnt - 4}]
        }
    }
    return $got
}

# -----------------------------------------------------------------------------
set errors 0
proc check {name got expected} {
    global errors
    set bad 0
    for {set j 0} {$j < 256} {incr j} {
        set g [expr {[lindex $got $j] & 0xFFFFFFFF}]
        set e [lindex $expected $j]
        if {$g != $e} {
            if {$bad < 4} { mark [format "  %s lane %3d: got %08X expect %08X" $name $j $g $e] }
            incr bad
        }
    }
    if {$bad == 0} {
        mark "$name: PASS (256/256)"
    } else {
        mark "$name: FAIL ($bad of 256)"
        incr errors
    }
}

# =============================================================================
# T1 - all weights zero -> all lanes zero
# =============================================================================
mark "=== T1: all-zero weights ==="
load_weights $axi [list [dict create] [dict create] [dict create] [dict create]]
load_acts $axi
do_run $axi
set got [read_lanes $axi]
set exp {}
for {set j 0} {$j < 256} {incr j} { lappend exp 0 }
check "T1" $got $exp

# =============================================================================
# T2 - every code is 2 (x1) -> every lane = sum of all activations
# =============================================================================
mark "=== T2: all weights code 2 (x1) ==="
set all2 [string repeat "2" 64]
set sp [dict create]
for {set k 0} {$k < 1024} {incr k} { dict set sp $k $all2 }
load_weights $axi [list $sp $sp $sp $sp]
load_acts $axi
do_run $axi
set got [read_lanes $axi]
set e2 [s32 $SUMS]
set exp {}
for {set j 0} {$j < 256} {incr j} { lappend exp $e2 }
check "T2" $got $exp

# =============================================================================
# T3 - one-hot per lane -> out[j] = x[j]
# =============================================================================
mark "=== T3: one-hot, out\[j\] should equal x\[j\] ==="
set spec {}
for {set g 0} {$g < 4} {incr g} {
    set sp [dict create]
    for {set i 0} {$i < 64} {incr i} {
        set k [expr {$g*64 + $i}]
        dict set sp $k [put_nibble [zero_row] $i 2]
    }
    lappend spec $sp
}
load_weights $axi $spec
load_acts $axi
do_run $axi
set got [read_lanes $axi]
set exp {}
for {set j 0} {$j < 256} {incr j} { lappend exp [s32 [lindex $ACT $j]] }
check "T3" $got $exp

# =============================================================================
# T4 - every codebook entry at row 0 -> out[j] = cb(x[0], j mod 16)
# =============================================================================
mark "=== T4: all 16 codebook entries ==="
set row0 [zero_row]
for {set i 0} {$i < 64} {incr i} { set row0 [put_nibble $row0 $i [expr {$i % 16}]] }
set spec {}
for {set g 0} {$g < 4} {incr g} { lappend spec [dict create 0 $row0] }
load_weights $axi $spec
load_acts $axi
do_run $axi
set got [read_lanes $axi]
set a0 [lindex $ACT 0]
set exp {}
for {set j 0} {$j < 256} {incr j} { lappend exp [s32 [cb $a0 [expr {$j % 16}]]] }
mark "  x\[0\] = $a0   expected lane 0..15 = [lrange $exp 0 15]"
check "T4" $got $exp

# =============================================================================
# T5 - weight readback of what T4 just loaded
# =============================================================================
mark "=== T5: read back region 0 row 0, must equal the row T4 wrote ==="
send_bytes $axi [build_frame 0x06 [list 0x00 0x00 0x00 0x00]]   ;# region 0, addr 0, 1 row
set rb {}
set tries 0
while {[llength $rb] < 32 && $tries < 4000} {
    incr tries
    set cnt [hexval [axi_rd $axi 0000000C]]
    while {$cnt >= 4 && [llength $rb] < 32} {
        set d [hexval [axi_rd $axi 00000008]]
        lappend rb [expr {$d & 0xFF}] [expr {($d>>8)&0xFF}] [expr {($d>>16)&0xFF}] [expr {($d>>24)&0xFF}]
        set cnt [expr {$cnt - 4}]
    }
}
set rbad 0
for {set c 0} {$c < 32} {incr c} {
    set want [expr "0x[string range $row0 [expr {$c*2}] [expr {$c*2+1}]]"]
    set have [lindex $rb $c]
    if {$have != $want} {
        if {$rbad < 4} { mark [format "  byte %2d: got %02X expect %02X" $c $have $want] }
        incr rbad
    }
}
if {$rbad == 0} {
    mark "T5: PASS (32/32 bytes read back match)"
} else {
    mark "T5: FAIL ($rbad of 32)"
    incr errors
}

# =============================================================================
mark ""
if {$errors == 0} {
    mark "RESULT: ALL DESIGNED VECTORS PASSED"
} else {
    mark "RESULT: $errors TEST(S) FAILED"
}
catch {close_hw_target}
catch {disconnect_hw_server}
catch {close_hw}
exit 0
