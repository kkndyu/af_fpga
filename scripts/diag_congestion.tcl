# -----------------------------------------------------------------------------
# diag_congestion.tcl - why does this design route so slowly and unreliably?
# -----------------------------------------------------------------------------
# route_design has varied from 686 s to over 2355 s on essentially the same
# design, and one attempt did not converge at all.  That spread means the design
# sits near a routability threshold rather than being simply "a bit tight".
#
# This analyses the placed checkpoint (the build was stopped during routing, so
# post_place.dcp is the newest usable artefact) and reports:
#   * congestion per clock region
#   * the worst setup paths and where their endpoints actually are
#   * design complexity / control-set pressure
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
puts "==== CONGESTION"
set rc [catch {
    report_design_analysis -congestion -file $OUT/congestion.rpt
} e]
if {$rc} { puts "====   report_design_analysis failed: $e" }

if {[file exists $OUT/congestion.rpt]} {
    set fh [open $OUT/congestion.rpt r]; set txt [read $fh]; close $fh
    # Show only the lines that carry numbers, so the summary is readable.
    set n 0
    foreach line [split $txt "\n"] {
        if {[string match "*Congestion*" $line] ||
            [string match "*congested*" $line] ||
            [string match "*Region*" $line] ||
            [string match "*Level*" $line]} {
            puts "====   [string trim $line]"
            incr n
            if {$n > 40} break
        }
    }
}

# -----------------------------------------------------------------------------
puts ""
puts "==== WORST SETUP PATHS ON THE PLACED DESIGN"
set rc [catch {
    report_timing -max_paths 12 -sort_by slack -path_type summary \
                  -file $OUT/placed_paths.rpt
} e]
if {$rc} { puts "====   report_timing failed: $e" }

if {[file exists $OUT/placed_paths.rpt]} {
    set fh [open $OUT/placed_paths.rpt r]; set txt [read $fh]; close $fh
    set n 0
    foreach line [split $txt "\n"] {
        if {[string match "*Slack*" $line] ||
            [string match "*Source*" $line] ||
            [string match "*Destination*" $line] ||
            [string match "*Logic Levels*" $line]} {
            puts "====   [string trim $line]"
            incr n
            if {$n > 60} break
        }
    }
}

# -----------------------------------------------------------------------------
puts ""
puts "==== COMPLEXITY"
set rc [catch {
    report_design_analysis -complexity -file $OUT/complexity.rpt
} e]
if {$rc} { puts "====   complexity report failed: $e" }
if {[file exists $OUT/complexity.rpt]} {
    set fh [open $OUT/complexity.rpt r]; set txt [read $fh]; close $fh
    set n 0
    foreach line [split $txt "\n"] {
        if {[string trim $line] ne ""} {
            puts "====   [string trim $line]"
            incr n
            if {$n > 30} break
        }
    }
}

puts ""
puts "==== DONE"
exit 0
