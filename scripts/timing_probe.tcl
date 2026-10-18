# -----------------------------------------------------------------------------
# timing_probe.tcl - what frequency can the engine actually reach?
# -----------------------------------------------------------------------------
#   vivado -mode batch -nolog -nojournal -notrace -source build/moe/timing_probe.tcl
#
# Synthesises moe_proto_top (the engine, without the board wrapper) and reports
# the worst paths against an AGGRESSIVE clock.
#
# Why constrain harder than the target: Vivado stops optimising once a
# constraint is met.  A 50 MHz constraint produced a 17.2 ns path that would
# never run at 50 MHz's real equivalent, and a 100 MHz constraint produced
# 9.264 ns.  Overshooting on purpose makes the tool try, so the resulting path
# delay is a usable estimate of the design's capability rather than an artefact
# of an easy target.
#
# Read the REPORTED path delay, not the slack.
# -----------------------------------------------------------------------------

set ROOT    {D:/ai/moe_fpga_proto_verilog}
set OUT     $ROOT/build/moe/probe
set PROJ    $ROOT/build/moe/probe_proj
set PART    xc7a200tfbg484-2
set TOP     moe_proto_top
set CLK_NS  4.000          ;# 250 MHz - deliberately unreachable, to force effort

file delete -force $OUT
file mkdir $OUT
foreach ch {stdout stderr} { catch { fconfigure $ch -buffering none } }

set ::T0 [clock seconds]
puts "==== PROBE top=$TOP target=$CLK_NS ns ([expr {1000.0/$CLK_NS}] MHz)"
flush stdout

create_project moe_probe $PROJ -part $PART -force
set_property source_mgmt_mode None [current_project]

set files [list \
    $ROOT/rtl/include/moe_params.vh \
    $ROOT/rtl/core/fp4_select.v \
    $ROOT/rtl/core/fp4_product_gen.v \
    $ROOT/rtl/core/mac_lane.v \
    $ROOT/rtl/core/mac_region.v \
    $ROOT/rtl/mem/wbank_region.v \
    $ROOT/rtl/mem/act_buffer.v \
    $ROOT/rtl/mem/vec_buffer.v \
    $ROOT/rtl/core/gemv_engine.v \
    $ROOT/rtl/core/expert_engine.v \
    $ROOT/rtl/core/result_readout.v \
    $ROOT/rtl/top/moe_proto_top.v \
]
add_files -norecurse -fileset sources_1 {*}$files
set_property is_global_include true [get_files $ROOT/rtl/include/moe_params.vh]
set_property file_type {Verilog Header} [get_files $ROOT/rtl/include/moe_params.vh]
set_property include_dirs $ROOT/rtl/include [current_fileset]
set_property top $TOP [current_fileset]

cd $ROOT
foreach f {mem_init/expert0/gate_r0.mem} {
    if {![file exists $f]} { puts "==== FAILED: $f missing"; exit 1 }
}

puts "==== synth_design"
flush stdout
if {[catch {synth_design -top $TOP -part $PART -flatten_hierarchy rebuilt} e]} {
    puts "==== FAILED: $e"
    exit 1
}

# The engine has a single clock port named clk.
set clk_port [get_ports -quiet clk]
if {[llength $clk_port] == 0} { puts "==== FAILED: no clk port"; exit 1 }
create_clock -period $CLK_NS -name clk $clk_port
set applied "?"
catch { set applied [get_property PERIOD [get_clocks -quiet clk]] }
puts "==== clock clk = $applied ns"
flush stdout

catch { report_utilization    -file $OUT/util.rpt }
catch { report_timing_summary -file $OUT/timing.rpt }

set wns "?"
catch { set wns [get_property SLACK [get_timing_paths -max_paths 1 -setup]] }
puts "==== WNS(setup) = $wns ns against $applied ns"
flush stdout

# The interesting output: the individual worst paths, with their real delays.
puts "==== worst paths (delay is the design's capability; slack is not)"
set paths {}
catch { set paths [get_timing_paths -max_paths 12 -setup -sort_by group] }
set n 0
foreach p $paths {
    incr n
    set src "?"; set dst "?"; set lvl "?"; set dly "?"; set slk "?"; set grp "?"
    catch { set src $p }
    catch { set src [get_property STARTPOINT_PIN $p] }
    catch { set dst [get_property ENDPOINT_PIN   $p] }
    catch { set lvl [get_property LOGIC_LEVELS    $p] }
    catch { set dly [get_property DATAPATH_DELAY  $p] }
    catch { set slk [get_property SLACK           $p] }
    catch { set grp [get_property PATH_GROUP      $p] }
    puts "==== PATH $n  slack=$slk  delay=$dly  levels=$lvl"
    puts "====   from $src"
    puts "====   to   $dst"
    if {$dly ne "?" && $dly > 0} {
        puts "====   implied max freq = [expr {1000.0/$dly}] MHz"
    }
    flush stdout
}

write_checkpoint -force $OUT/post_synth.dcp
puts "==== PROBE DONE in [expr {[clock seconds] - $::T0}]s"
flush stdout
