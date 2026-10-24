# -----------------------------------------------------------------------------
# diag_routability.tcl - why does an UNCONGESTED design route so unreliably?
# -----------------------------------------------------------------------------
# Established so far:
#   * report_design_analysis -congestion returns an EMPTY table: no congestion
#   * the 12 worst paths sit inside 16 ps of each other (0.509 .. 0.525 ns)
#   * 11 of those 12 are inside u_loader
#
# "No congestion but routing will not converge" has three classic causes, none of
# which the congestion report shows:
#
#   1. CONTROL SETS.  Every slice stores one clock-enable and one reset value for
#      all eight of its flops.  A design with many distinct (clock, CE, RST)
#      combinations cannot pack, so the placer has almost no freedom - and the
#      router then fights long, unfavourable connections.  This is the single most
#      common cause of exactly this symptom.
#
#   2. HIGH-FANOUT NETS.  One driver feeding hundreds of CE pins has to be
#      replicated by the tool; if it is not, the net becomes a long, slow,
#      hard-to-route spine.
#
#   3. UNEVEN CELL DISTRIBUTION.  Global utilisation can look fine while one
#      clock region is packed and its neighbours are empty.
#
# This reports all three so the comparison against a pre-JTAG build can be made on
# numbers instead of impressions.
# -----------------------------------------------------------------------------

set ROOT {D:/ai/moe_fpga_proto_verilog}
set OUT  $ROOT/build/logs
set DCP  $ROOT/build/moe/out/post_place.dcp

foreach ch {stdout stderr} { catch { fconfigure $ch -buffering none } }

if {![file exists $DCP]} { puts "==== FAILED: no $DCP"; exit 1 }
puts "==== opening $DCP"
open_checkpoint $DCP

# -----------------------------------------------------------------------------
puts ""
puts "==== CONTROL SETS"
if {[catch {report_control_sets -verbose -file $OUT/control_sets.rpt} e]} {
    puts "====   report_control_sets failed: $e"
}
if {[file exists $OUT/control_sets.rpt]} {
    set fh [open $OUT/control_sets.rpt r]; set txt [read $fh]; close $fh
    set keep 0
    foreach line [split $txt "\n"] {
        set t [string trim $line]
        if {[string match "*Control Set*" $t] || [string match "*Clock Enable*" $t] ||
            [string match "*Total*" $t]         || [string match "*Unique*" $t] ||
            [string match "*Remaining*" $t]} {
            puts "====   $t"
        }
    }
}

# -----------------------------------------------------------------------------
puts ""
puts "==== HIGH FANOUT NETS"
if {[catch {report_high_fanout_nets -timing -max_nets 15 -file $OUT/high_fanout.rpt} e]} {
    puts "====   report_high_fanout_nets failed: $e"
}
if {[file exists $OUT/high_fanout.rpt]} {
    set fh [open $OUT/high_fanout.rpt r]; set txt [read $fh]; close $fh
    set n 0
    foreach line [split $txt "\n"] {
        set t [string trim $line]
        if {$t eq ""} continue
        if {[string match "*Pin*" $t] || [string match "*Net*" $t] ||
            [string match "*Fanout*" $t] || [string match "*Loads*" $t] ||
            [regexp {^\S+\s+\d+} $t]} {
            puts "====   $t"
            incr n
            if {$n > 20} break
        }
    }
}

# -----------------------------------------------------------------------------
puts ""
puts "==== UTILISATION PER CLOCK REGION"
if {[catch {report_utilization -file $OUT/util_placed.rpt} e]} {
    puts "====   report_utilization failed: $e"
}
# Clock-region breakdown is a separate report in 2019.1
if {[catch {report_utilization -clock_regions -file $OUT/util_clock_regions.rpt} e]} {
    puts "====   report_utilization -clock_regions failed: $e"
} else {
    set fh [open $OUT/util_clock_regions.rpt r]; set txt [read $fh]; close $fh
    set n 0
    foreach line [split $txt "\n"] {
        set t [string trim $line]
        if {$t eq ""} continue
        if {[regexp {X\d+Y\d+} $t] || [string match "*Slice LUTs*" $t] ||
            [string match "*CLB*" $t] || [string match "*Region*" $t]} {
            puts "====   $t"
            incr n
            if {$n > 25} break
        }
    }
}

puts ""
puts "==== DONE"
exit 0
