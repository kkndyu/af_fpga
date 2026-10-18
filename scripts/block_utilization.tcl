# -----------------------------------------------------------------------------
# block_utilization.tcl - resource breakdown by functional block
# -----------------------------------------------------------------------------
#   vivado -mode batch -nolog -nojournal -notrace -source scripts/block_utilization.tcl
#
# Opens the ROUTED checkpoint and attributes every primitive to a functional
# block, so the numbers describe the design that is actually on the board rather
# than an out-of-context estimate of each module in isolation.
#
# Method: count primitives whose instance path matches a block's hierarchy
# pattern.  This is exact (no estimation), and it survives flattening because the
# instance NAMES still carry the hierarchy even after synthesis has merged the
# logic.
#
# Hierarchy that still exists at this point:
#   moe_proto_board and moe_proto_top are effectively flat, BUT mac_region
#   carries keep_hierarchy = "yes" - deliberately, so the four regions cannot
#   pool their identical pipeline registers across the boundary.  So
#   u_region0..3 and their children (u_act_buffer, u_prod_gen) are separate
#   cells here, while gen_lane[*] and fp4_select are flattened into the region.
#
# Outputs:
#   build/moe/out/util_hier.rpt   raw report_utilization -hierarchical
#   stdout                        the per-block table
# -----------------------------------------------------------------------------

set ROOT {D:/ai/moe_fpga_proto_verilog}
set DCP  $ROOT/build/moe/out/post_route.dcp
set OUT  $ROOT/build/moe/out/util_hier.rpt

foreach ch {stdout stderr} { catch { fconfigure $ch -buffering none } }

if {![file exists $DCP]} {
    puts "==== FAILED: no routed checkpoint at $DCP"
    puts "====         run scripts/run_build.ps1 first"
    exit 1
}

puts "==== opening $DCP"
open_checkpoint $DCP
catch { report_utilization -hierarchical -hierarchical_depth 6 -file $OUT }
puts "==== raw report: $OUT"

# -----------------------------------------------------------------------------
# Count primitives under a hierarchy pattern.
# -----------------------------------------------------------------------------
proc count_in {pattern primRegex} {
    set cells [get_cells -quiet -hier -filter "NAME =~ $pattern && REF_NAME =~ $primRegex"]
    return [llength $cells]
}

# Vivado's =~ is GLOB matching, not regular expressions.  Writing ^LUT[1-6]$ here
# silently matched nothing (the anchors are literal), which produced a table of
# zeros while the primitive totals below were correct - a good reminder that a
# zero from a filter is not the same as a zero in the design.
proc block {label pattern} {
    set lut   [count_in $pattern {LUT*}]
    set ff    [count_in $pattern {FD*}]
    set cy    [count_in $pattern {CARRY4}]
    set f7    [count_in $pattern {MUXF7}]
    set f8    [count_in $pattern {MUXF8}]
    set r36   [count_in $pattern {RAMB36E1}]
    set r18   [count_in $pattern {RAMB18E1}]
    set dsp   [count_in $pattern {DSP48E1}]
    puts [format "==== %-26s LUT=%6d FF=%6d CARRY4=%5d MUXF7=%5d MUXF8=%5d RAMB36=%3d RAMB18=%2d DSP=%d" \
              $label $lut $ff $cy $f7 $f8 $r36 $r18 $dsp]
    flush stdout
}

puts ""
puts "==== PER-BLOCK BREAKDOWN (routed design)"
puts "===="

block "whole design"            *
block "engine wrapper"          {*u_expert_engine*}
block "gemv_engine"             {*u_gate_gemv*}
block "  region0 only"          {*u_region0/*}
block "  4 regions total"       {*u_region[0-3]/*}
block "    activation buffers"  {*u_region[0-3]/u_act_buffer/*}
block "    product generators"  {*u_region[0-3]/u_prod_gen/*}
block "    lane array (4x64)"   {*u_region[0-3]/gen_lane*}
block "  16:1 selectors (256)"  {*u_fp4_select/*}
block "  weight banks (4)"      {*u_wbank_r*}
block "result_readout"          {*u_result_readout*}
block "board wrapper logic"     {*u_moe_proto_top*}
block "clock buffer"            {*u_sys_clk_ibufds*}

puts ""
puts "==== HIGH-LEVEL GATE COUNTS"
foreach p {LUT6 LUT5 LUT4 LUT3 LUT2 LUT1 MUXF7 MUXF8 CARRY4 FDRE FDCE FDSE RAMB36E1 RAMB18E1 DSP48E1 BUFG} {
    puts [format "====   %-10s %6d" $p [count_in * $p]]
}
flush stdout

close_design
puts "==== DONE"
