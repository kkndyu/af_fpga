# -----------------------------------------------------------------------------
# build_moe_synth.tcl - synthesis only, for a fast timing/area answer
# -----------------------------------------------------------------------------
#   cd <repo root> && vivado -mode batch -nolog -nojournal -notrace \
#        -source build/moe/build_moe_synth.tcl
#
# Stops after synth_design so a timing question can be answered in ~5 minutes
# instead of ~24.  Place and route only make sense once the synthesis number
# looks acceptable.
#
# Remember synthesis is OPTIMISTIC about routing: for this design it estimated
# 8.114 ns where the routed result was 9.896 ns, about 22% low.  Treat the
# number here as an upper bound on the achievable frequency.
# -----------------------------------------------------------------------------

set ROOT   {D:/ai/moe_fpga_proto_verilog}
set OUT    $ROOT/build/moe/synth_out
set PROJ   $ROOT/build/moe/synth_proj
set PART   xc7a200tfbg484-2
set CLK_NS 10.000          ;# 100 MHz

file delete -force $OUT
file mkdir $OUT

foreach ch {stdout stderr} { catch { fconfigure $ch -buffering none } }

set ::T0 0
set ::ERRORS 0

proc stage {name} {
    puts "==== [expr {[clock seconds] - $::T0}]s  STAGE: $name ===="
    flush stdout
}
proc fail {msg} {
    puts "==== FAILED: $msg"
    flush stdout
    set ::ERRORS 1
    return -code error $msg
}

# The XDC pins 200 MHz.  Re-constrain AFTER synthesis - before it, get_ports
# returns nothing and the command fails silently, which is exactly the mistake
# that made an earlier run stay at 200 MHz while reporting success.
proc retime_clock {period_ns} {
    set ports [get_ports -quiet sys_clk_p]
    if {[llength $ports] == 0} {
        puts "==== WARNING: sys_clk_p not found; clock left at the XDC value"
        flush stdout
        return 0
    }
    if {[catch {create_clock -period $period_ns -name sys_clk_p $ports} e]} {
        puts "==== WARNING: re-constraining failed: $e"
        flush stdout
        return 0
    }
    set applied "?"
    catch { set applied [get_property PERIOD [get_clocks -quiet sys_clk_p]] }
    if {$applied eq "?" || abs($applied - $period_ns) > 0.001} {
        puts "==== WARNING: period is $applied ns, not $period_ns ns"
        flush stdout
        return 0
    }
    puts "==== clock period = $applied ns (verified)"
    flush stdout
    return 1
}

set ::T0 [clock seconds]
puts "==== SYNTH-ONLY START  cwd=[pwd]  target $CLK_NS ns"
flush stdout

stage "create project"
create_project moe_synth $PROJ -part $PART -force
set_property source_mgmt_mode None [current_project]

set files [list \
    $ROOT/rtl/include/moe_params.vh \
    $ROOT/rtl/core/fp4_select.v \
    $ROOT/rtl/core/fp4_product_gen.v \
    $ROOT/rtl/core/mac_lane.v \
    $ROOT/rtl/core/mac_region.v \
    $ROOT/rtl/mem/wbank_region.v \
    $ROOT/rtl/mem/act_buffer.v \
    $ROOT/rtl/eth/eth_rgmii_rx.v \
    $ROOT/rtl/eth/eth_rgmii_tx.v \
    $ROOT/rtl/eth/eth_mdio.v \
    $ROOT/rtl/mem/vec_buffer.v \
    $ROOT/rtl/core/gemv_engine.v \
    $ROOT/rtl/core/expert_engine.v \
    $ROOT/rtl/core/result_readout.v \
    $ROOT/rtl/top/moe_proto_top.v \
    $ROOT/rtl/top/moe_proto_board.v \
]
add_files -norecurse -fileset sources_1 {*}$files
set_property is_global_include true [get_files $ROOT/rtl/include/moe_params.vh]
set_property file_type {Verilog Header} [get_files $ROOT/rtl/include/moe_params.vh]
set_property include_dirs $ROOT/rtl/include [current_fileset]
set_property top moe_proto_board [current_fileset]
add_files -norecurse -fileset constrs_1 $ROOT/constr/ax7203.xdc

cd $ROOT
foreach f {mem_init/expert0/gate_r0.mem sim/data/input.mem} {
    if {![file exists $f]} { fail "$f missing relative to [pwd]" }
}
puts "====   memories present"
flush stdout

stage "synth_design"
if {[catch {synth_design -top moe_proto_board -part $PART -flatten_hierarchy rebuilt} e]} {
    fail "synth_design: $e"
}
puts "==== synthesis ok"
flush stdout

retime_clock $CLK_NS

set ramb [get_cells -hier -quiet -filter {REF_NAME =~ RAMB*}]
puts "==== RAMB cells = [llength $ramb]"
flush stdout

# The interesting question for this change: did the per-region product
# registers actually appear, and did the activation net's fanout drop?
set prodreg [get_cells -hier -quiet -filter {NAME =~ *prod16_region_flat*}]
puts "==== prod16_region_flat registers = [llength $prodreg]"
foreach c $prodreg {
    set nm "?"
    catch { set nm [get_property NAME $c] }
    puts "====   $nm"
}
flush stdout

stage "reports"
catch { report_utilization    -file $OUT/util.rpt }
catch { report_timing_summary -file $OUT/timing.rpt }

set wns "?"
catch { set wns [get_property SLACK [get_timing_paths -max_paths 1 -setup]] }
set whs "?"
catch { set whs [get_property SLACK [get_timing_paths -max_paths 1 -hold]] }
puts "==== WNS(setup) = $wns ns   WHS(hold) = $whs ns"
if {$wns ne "?"} {
    puts "==== implied max frequency = [expr {1000.0 / ($CLK_NS - $wns)}] MHz"
}
flush stdout

# Where does the critical path start and end now?
set path ""
catch { set path [get_timing_paths -max_paths 1 -setup] }
if {$path ne ""} {
    set src "?"
    set dst "?"
    catch { set src [get_property STARTPOINT_PIN $path] }
    catch { set dst [get_property ENDPOINT_PIN $path] }
    set lvl "?"
    set dly "?"
    catch { set lvl [get_property LOGIC_LEVELS $path] }
    catch { set dly [get_property DATAPATH_DELAY $path] }
    puts "==== critical path: $src"
    puts "====          -> $dst"
    puts "==== logic levels = $lvl, data path delay = $dly"
}

write_checkpoint -force $OUT/post_synth.dcp
puts "==== checkpoint: post_synth.dcp"
flush stdout

if {$::ERRORS} { puts "==== SYNTH FAILED"; exit 1 }
puts "==== SYNTH-ONLY OK  total [expr {[clock seconds] - $::T0}]s"
flush stdout