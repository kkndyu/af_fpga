# -----------------------------------------------------------------------------
# physopt_only.tcl - recover a marginal post-route violation without rebuilding
# -----------------------------------------------------------------------------
#   vivado -mode batch -nolog -nojournal -notrace -source build/moe/physopt_only.tcl
#
# The 200 MHz build missed setup by 0.058 ns on TWO endpoints, after place had
# actually met (+0.112 ns).  Re-running the whole 35 minute flow to chase 58 ps
# is wasteful when the routed checkpoint already exists, so this opens it and
# runs phys_opt_design on top.
#
# The constraint set travels inside the checkpoint, so the clock period, the
# generated clock and the pin assignments all come along unchanged.
#
# Outputs:
#   build/moe/physopt/post_physopt.dcp
#   build/moe/physopt/timing.rpt
#   build/moe/out/moe_proto.bit          (only if setup AND hold are met)
# -----------------------------------------------------------------------------

set ROOT {D:/ai/moe_fpga_proto_verilog}
set OUT  $ROOT/build/moe/physopt
set DCP  $ROOT/build/moe/out/post_route.dcp
set BIT  $ROOT/build/moe/out/moe_proto.bit

file delete -force $OUT
file mkdir $OUT
foreach ch {stdout stderr} { catch { fconfigure $ch -buffering none } }

set ::T0 [clock seconds]
proc stage {name} {
    puts "==== [expr {[clock seconds] - $::T0}]s  STAGE: $name"
    flush stdout
}

if {![file exists $DCP]} {
    puts "==== FAILED: no routed checkpoint at $DCP"
    exit 1
}

stage "open_checkpoint"
open_checkpoint $DCP

# Report the starting point so the improvement is measurable, not assumed.
set wns0 "?"
set whs0 "?"
catch { set wns0 [get_property SLACK [get_timing_paths -max_paths 1 -setup]] }
catch { set whs0 [get_property SLACK [get_timing_paths -max_paths 1 -hold]] }
puts "==== BEFORE phys_opt: WNS(setup)=$wns0 ns  WHS(hold)=$whs0 ns"
flush stdout

stage "phys_opt_design"
if {[catch {phys_opt_design} e]} {
    puts "==== WARNING: phys_opt_design failed: $e"
} else {
    puts "==== phys_opt_design done"
}
flush stdout

stage "report"
# Write to the CANONICAL locations as well as the local one.
#
# The first time this ran, the reports stayed in build/moe/physopt/ while
# build/moe/out/timing_impl.rpt still held the pre-phys_opt result (-0.058 ns).
# Anyone reading out/ afterwards would have concluded the board was running a
# violating bitstream, because the bitstream in out/ IS the post-phys_opt one.
# A stale report next to a fresh bitstream is worse than no report.
catch { report_timing_summary -file $OUT/timing.rpt }
catch { report_utilization    -file $OUT/util.rpt }
catch { report_timing_summary -file $ROOT/build/moe/out/timing_impl.rpt }
catch { report_utilization    -file $ROOT/build/moe/out/util_impl.rpt }

set wns "?"
set whs "?"
catch { set wns [get_property SLACK [get_timing_paths -max_paths 1 -setup]] }
catch { set whs [get_property SLACK [get_timing_paths -max_paths 1 -hold]] }
puts "==== AFTER  phys_opt: WNS(setup)=$wns ns  WHS(hold)=$whs ns"
flush stdout

# What is still failing, if anything?
set paths {}
catch { set paths [get_timing_paths -max_paths 4 -setup] }
set n 0
foreach p $paths {
    incr n
    set slk "?"; set src "?"; set dst "?"; set dly "?"; set lvl "?"
    catch { set slk [get_property SLACK          $p] }
    catch { set src [get_property STARTPOINT_PIN $p] }
    catch { set dst [get_property ENDPOINT_PIN   $p] }
    catch { set dly [get_property DATAPATH_DELAY $p] }
    catch { set lvl [get_property LOGIC_LEVELS   $p] }
    puts "==== PATH $n slack=$slk delay=$dly levels=$lvl"
    puts "====   from $src"
    puts "====   to   $dst"
}
flush stdout

write_checkpoint -force $OUT/post_physopt.dcp

# Only emit a bitstream if the design actually meets timing.  Writing one that
# violates would repeat the mistake that had the board running at twice its
# closing frequency: a bitstream that exists is not a bitstream that works.
set met 1
if {$wns eq "?" || $wns < 0} { set met 0 }
if {$whs eq "?" || $whs < 0} { set met 0 }

if {$met} {
    stage "write_bitstream"
    if {[catch {write_bitstream -force $BIT} e]} {
        puts "==== FAILED: write_bitstream: $e"
        exit 1
    }
    puts "==== bitstream = $BIT ([file size $BIT] bytes)"
} else {
    puts "==== NOT writing a bitstream: timing is still not met"
    puts "====   WNS=$wns  WHS=$whs"
}

puts "==== DONE in [expr {[clock seconds] - $::T0}]s"
flush stdout
