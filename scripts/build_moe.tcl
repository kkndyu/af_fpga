# -----------------------------------------------------------------------------
# build_moe.tcl - synth/impl/bitstream with per-stage checkpoints and logging
# -----------------------------------------------------------------------------
#   cd <repo root> && vivado -mode batch -nolog -nojournal -notrace \
#        -source build/moe/build_moe.tcl
#
# Launched by run_build.ps1, which redirects stdout to build/moe/vivado.log and
# tails it, so progress is visible while the run is going.
#
# Design notes
# ------------
# * MUST run from the repository root: wbank_region.v and moe_proto_board.v use
#   RELATIVE $readmemh paths, resolved against the working directory.
# * A throwaway project is created only to carry include_dirs.  Non-project mode
#   cannot do it (read_verilog -include needs compile-unit mode; a bare
#   synth_design cannot see rtl/include at all), and launch_runs hangs here.
# * Every stage writes a checkpoint.  The previous run was killed after ~28 min
#   of place and route and lost everything, because direct step driving keeps
#   nothing on disk.  That must not happen again.
# * The clock is relaxed to 100 MHz for this bring-up pass.  The earlier run
#   left tight_setup_hold_pins.txt listing 23 near-critical paths, all on
#   <lane>/acc_out_reg[*]/D - the 16:1 mux plus 32-bit add feeding the
#   accumulators.  That is marginal at 200 MHz.  Verifying the datapath on the
#   board does not need 200 MHz, and a bitstream that exists beats a timing
#   report that is a few picoseconds short.
# -----------------------------------------------------------------------------

set ROOT   {D:/ai/moe_fpga_proto_verilog}
set OUT    $ROOT/build/moe/out
set PROJ   $ROOT/build/moe/proj
set PART   xc7a200tfbg484-2
set CLK_NS 10.000          ;# 100 MHz.  5.000 = 200 MHz once timing is clean.

file delete -force $OUT
file mkdir $OUT

# Unbuffered output, so tailing vivado.log shows what is happening right now.
# Note: "autoflush" is NOT a Tcl command (it is Perl/Scheme); writing it here
# aborted the whole script with 'invalid command name "autoflush"'.  Tcl uses
# fconfigure to change channel buffering, and every phase marker below also
# calls flush explicitly, which is enough.
foreach ch {stdout stderr} {
    catch { fconfigure $ch -buffering none }
}

set ::T0 0
set ::STAGE_T0 0
set ::ERRORS 0

proc stage {name} {
    puts "==== [expr {[clock seconds] - $::T0}]s  STAGE: $name ===="
    flush stdout
    set ::STAGE_T0 [clock seconds]
}
proc stage_done {name} {
    puts "==== [expr {[clock seconds] - $::T0}]s  DONE : $name  ([expr {[clock seconds] - $::STAGE_T0}]s) ===="
    flush stdout
}
proc fail {msg} {
    puts "==== FAILED: $msg ===="
    flush stdout
    set ::ERRORS 1
    return -code error $msg
}

set ::T0 [clock seconds]
puts "==== BUILD START  cwd=[pwd]"
flush stdout

# -----------------------------------------------------------------------------
stage "create project (for include_dirs)"
# -----------------------------------------------------------------------------
create_project moe_build $PROJ -part $PART -force
set_property source_mgmt_mode None [current_project]

set files [list \
    $ROOT/rtl/include/moe_params.vh \
    $ROOT/rtl/core/fp4_select.v \
    $ROOT/rtl/core/fp4_product_gen.v \
    $ROOT/rtl/core/mac_lane.v \
    $ROOT/rtl/core/mac_region.v \
    $ROOT/rtl/mem/wbank_region.v \
    $ROOT/rtl/mem/act_buffer.v \
    $ROOT/rtl/eth/eth_top.v \
    $ROOT/rtl/eth/mac/mac_top.v \
    $ROOT/rtl/eth/mac/mac_rx_top.v \
    $ROOT/rtl/eth/mac/mac_rx.v \
    $ROOT/rtl/eth/mac/mac_tx_top.v \
    $ROOT/rtl/eth/mac/mac_tx.v \
    $ROOT/rtl/eth/mac/mac_tx_mode.v \
    $ROOT/rtl/eth/mac/ip_rx.v \
    $ROOT/rtl/eth/mac/ip_tx.v \
    $ROOT/rtl/eth/mac/ip_tx_mode.v \
    $ROOT/rtl/eth/mac/udp_rx.v \
    $ROOT/rtl/eth/mac/udp_tx.v \
    $ROOT/rtl/eth/mac/arp_rx.v \
    $ROOT/rtl/eth/mac/arp_tx.v \
    $ROOT/rtl/eth/mac/icmp_reply.v \
    $ROOT/rtl/eth/mac/arp_cache.v \
    $ROOT/rtl/eth/mac/crc.v \
    $ROOT/rtl/eth/mac/dpram.v \
    $ROOT/rtl/eth/mac/vendor_ip.v \
    $ROOT/rtl/eth/eth_async_fifo.v \
    $ROOT/rtl/eth/util_gmii_to_rgmii.v \
    $ROOT/rtl/eth/mdio_rw.v \
    $ROOT/rtl/eth/eth_phy_probe.v \
    $ROOT/rtl/eth/eth_sniffer.v \
    $ROOT/rtl/mem/vec_buffer.v \
    $ROOT/rtl/core/gemv_engine.v \
    $ROOT/rtl/core/expert_engine.v \
    $ROOT/rtl/core/result_readout.v \
    $ROOT/rtl/ctrl/moe_loader.v \
    $ROOT/rtl/ctrl/weight_readback.v \
    $ROOT/rtl/periph/uart_rx.v \
    $ROOT/rtl/periph/uart_tx.v \
    $ROOT/rtl/bus/axil_loader_bridge.v \
    $ROOT/rtl/top/moe_proto_top.v \
    $ROOT/rtl/top/moe_proto_board.v \
]
add_files -norecurse -fileset sources_1 {*}$files
set_property is_global_include true [get_files $ROOT/rtl/include/moe_params.vh]
set_property file_type {Verilog Header} [get_files $ROOT/rtl/include/moe_params.vh]
set_property include_dirs $ROOT/rtl/include [current_fileset]

# -----------------------------------------------------------------------------
# JTAG-to-AXI path - OFF by default, see the note below
# -----------------------------------------------------------------------------
# Set WITH_AXI 1 to compile the JTAG-AXI transport in.
#
# It is off because jtag_axi registers itself as a debug core:
#
#     get_debug_cores  ->  dbg_hub, u_jtag_axi
#
# which forces opt_design to synthesise a dbg_hub.  On this machine that step
# stalls indefinitely in "Processing IP xilinx.com:ip:xsdbm:3.0 for cell
# dbg_hub_CV" - 30+ minutes with only ~300 CPU-seconds used and no child process,
# so it is waiting, not computing.  The UART transport does not need any of that.
#
# The IP is added as an .xci, NOT as its out-of-context DCP: synth_design only
# reads RTL, so a DCP added as a source is never linked and elaboration fails with
# "module jtag_axi_v1_2_9_jtag_axi not found".
set WITH_AXI 1
if {$WITH_AXI} {
    set AXI_XCI [glob -nocomplain $ROOT/build/ip/jtag_axil/*/sources_1/ip/jtag_axi_0/jtag_axi_0.xci]
    if {[llength $AXI_XCI] == 0} {
        fail "no jtag_axi_0.xci; run scripts/gen_jtag_axi.tcl first"
    }
    puts "====   jtag_axi xci: [lindex $AXI_XCI 0]"
    add_files -norecurse -fileset sources_1 [lindex $AXI_XCI 0]
    set_property verilog_define {WITH_JTAG_AXI} [current_fileset]
} else {
    puts "====   JTAG-AXI not compiled in (WITH_AXI 0)"
}

set_property top moe_proto_board [current_fileset]
add_files -norecurse -fileset constrs_1 $ROOT/constr/ax7203.xdc
    add_files -norecurse -fileset constrs_1 $ROOT/constr/ax7203_eth.xdc

# The XDC pins 200 MHz; relax it here rather than editing the constraint file,
# so the board constraint stays the single source of truth.
#
# TWO traps here, both hit in the first attempt:
#
#  1. create_clock must run AFTER synth_design.  Before synthesis there is no
#     design loaded, so get_ports returns nothing and the command fails - which
#     the surrounding catch swallowed silently.  The previous run therefore
#     stayed at 200 MHz while the log cheerfully reported "re-constrained to
#     10 ns".  Never print a success message for a caught command without
#     checking its result.
#
#  2. Re-defining a clock on the same source needs -add on newer Vivado; on
#     2019.1 the later definition simply replaces the earlier one, which is the
#     behaviour relied on here.
#
# The observed critical path is act_buffer -> product_gen -> 16:1 mux ->
# 32-bit add -> acc_out, 9.843 ns split 5.330 ns logic / 4.513 ns route.  So the
# design tops out near 100 MHz as written; CLK_NS below leaves real margin.
set CLK_NS 5.000
# No longer overridden from here.
#
# The constraint file now describes the hardware truth: a 200 MHz oscillator
# (5.000 ns) plus a /4 generated clock for the engine.  An earlier version of
# this script re-ran create_clock with 10.000 ns to "make timing pass".  That
# only retargeted the analyser - the FPGA still received 200 MHz - so the
# bitstream closed at 100 MHz and then ran at 200 MHz on the board, producing a
# wrong checksum.  Never override a primary clock to a frequency the board does
# not actually supply; change the clock in RTL and constrain the result instead.
#
# What this script still does is VERIFY: it reads the clock back after
# synthesis and refuses to continue if the engine clock is not what the XDC
# asked for.

proc check_clocks {expect_engine_ns} {
    set ok 1
    foreach c [get_clocks -quiet *] {
        set nm "?"
        set per "?"
        catch { set nm  [get_property NAME   $c] }
        catch { set per [get_property PERIOD $c] }
        if {$per eq "?" || $per == 0} { continue }
        puts "==== clock $nm : period $per ns ([expr {1000.0/$per}] MHz)"
    }
    set eng [get_clocks -quiet clk_engine]
    if {[llength $eng] == 0} {
        puts "==== FAILED: no clk_engine clock - the XDC generated-clock constraint"
        puts "====         did not bind (check the u_bufg_engine/O pin name)."
        flush stdout
        return 0
    }
    set per "?"
    catch { set per [get_property PERIOD $eng] }
    if {$per eq "?" || abs($per - $expect_engine_ns) > 0.001} {
        puts "==== FAILED: engine clock is $per ns, expected $expect_engine_ns ns."
        puts "====         DIV_BITS in moe_proto_board.v and -divide_by in the XDC"
        puts "====         have drifted apart, so timing would be checked against"
        puts "====         a frequency the hardware does not run at."
        flush stdout
        set ok 0
    } else {
        puts "==== engine clock verified at $per ns ([expr {1000.0/$per}] MHz)"
    }
    flush stdout
    return $ok
}
stage_done "create project"

# -----------------------------------------------------------------------------
# Run from the repo root so the $readmemh paths resolve
# -----------------------------------------------------------------------------
cd $ROOT
foreach f {mem_init/expert0/gate_r0.mem sim/data/input.mem} {
    if {![file exists $f]} {
        fail "$f missing relative to [pwd] - memories would come up empty"
    }
    puts "====   present: $f"
}
flush stdout

# -----------------------------------------------------------------------------
stage "synth_design"
# -----------------------------------------------------------------------------
if {[catch {synth_design -top moe_proto_board -part $PART -flatten_hierarchy rebuilt} e]} {
    fail "synth_design: $e"
}

# Now there IS a design, so the clocks can be inspected.  This VERIFIES, it does
# not override: the 200 MHz oscillator is real hardware and the engine's divided
# clock comes from the XDC's create_generated_clock.  DIV_BITS=0 in
# moe_proto_board.v means /1, so the engine clock must read 5.000 ns (200 MHz).
if {![check_clocks 5.000]} {
    fail "engine clock does not match the RTL divider; refusing to build a bitstream that would be timed against the wrong frequency"
}

# -----------------------------------------------------------------------------
# No Ethernet multicycle exception in the gigabit build.
# -----------------------------------------------------------------------------
# The 100 Mb design needed one: it advanced at most once every eight fabric
# clocks (one RGMII nibble per 40 ns), so a 42-way header case plus a 1024-entry
# buffer read legitimately had eight cycles to settle.
#
# In the gigabit design the Ethernet stack runs in the PHY 125 MHz clock domain
# and advances ONE BYTE PER CLOCK.  The exception would grant eight cycles to
# paths that must complete in one, hiding real violations instead of expressing
# a real property.  Removed deliberately; do not add it back without
# re-deriving the pacing from the wire rate.

# The 125 MHz domain comes from RX_CLK (8 ns), 60 % more than the 5 ns the same
# combinational path was measured against.

set ramb [get_cells -hier -quiet -filter {REF_NAME =~ RAMB*}]
puts "==== post-synth RAMB cells = [llength $ramb]"
flush stdout
if {[llength $ramb] == 0} {
    fail "no block RAM inferred - the engine was pruned"
}
write_checkpoint -force $OUT/post_synth.dcp
puts "==== checkpoint: post_synth.dcp"
flush stdout
catch { report_utilization    -file $OUT/util_synth.rpt }
catch { report_timing_summary -file $OUT/timing_synth.rpt }
stage_done "synth_design"

# -----------------------------------------------------------------------------
stage "opt_design"
# -----------------------------------------------------------------------------
if {[catch {opt_design} e]} { fail "opt_design: $e" }
write_checkpoint -force $OUT/post_opt.dcp
puts "==== checkpoint: post_opt.dcp"
flush stdout
stage_done "opt_design"

# -----------------------------------------------------------------------------
stage "place_design"
# -----------------------------------------------------------------------------
if {[catch {place_design} e]} { fail "place_design: $e" }
write_checkpoint -force $OUT/post_place.dcp
puts "==== checkpoint: post_place.dcp"
flush stdout
catch { report_timing_summary -file $OUT/timing_placed.rpt }
stage_done "place_design"

# -----------------------------------------------------------------------------
stage "route_design"
# -----------------------------------------------------------------------------
if {[catch {route_design} e]} { fail "route_design: $e" }
write_checkpoint -force $OUT/post_route.dcp
puts "==== checkpoint: post_route.dcp"
flush stdout
stage_done "route_design"

# -----------------------------------------------------------------------------
stage "phys_opt_design (post-route)"
# -----------------------------------------------------------------------------
# The previous 200 MHz attempt missed by 0.058 ns with only TWO failing
# endpoints.  The failing path started at
#
#   u_region0/prod16_q_reg[123]_rep__1  ->  u_region3/gen_lane[49]/acc_out_reg
#
# i.e. Vivado merged the four identical product registers (they hold the same
# value) and re-replicated them, and one replica ended up placed so that it
# drives a lane in a DIFFERENT region.  That is a placement artefact, not a
# property of the logic: every region's own feed is fine.
#
# phys_opt_design is the targeted tool for exactly this - it re-tunes cell
# placement and replication on the failing paths after routing.  It is far
# cheaper than the alternative, which would be an MMCM: the board divider can
# only produce 200, 100, 66.7 ... MHz, so "run at 190 MHz" is not available
# without adding a clock generator.
#
# Try the retimed netlist first; if it does not recover the 58 ps, the fallback
# is to stop the register from being shared across regions (keep_hierarchy on
# mac_region, or dont_touch on prod16_q).
if {[catch {phys_opt_design} e]} {
    puts "==== WARNING: phys_opt_design failed: $e"
} else {
    puts "==== phys_opt_design done"
}
flush stdout
write_checkpoint -force $OUT/post_physopt.dcp
stage_done "phys_opt_design (post-route)"

# -----------------------------------------------------------------------------
stage "reports"
# -----------------------------------------------------------------------------
catch { report_utilization       -file $OUT/util_impl.rpt }
catch { report_timing_summary    -file $OUT/timing_impl.rpt }
catch { report_drc               -file $OUT/drc.rpt }
catch { report_clock_utilization -file $OUT/clock_util.rpt }

set wns "?"
set whs "?"
catch { set wns [get_property SLACK [get_timing_paths -max_paths 1 -setup]] }
catch { set whs [get_property SLACK [get_timing_paths -max_paths 1 -hold]] }
puts "==== WNS(setup) = $wns ns   WHS(hold) = $whs ns"
flush stdout
stage_done "reports"

# -----------------------------------------------------------------------------
stage "write_bitstream"
# -----------------------------------------------------------------------------
if {[catch {write_bitstream -force $OUT/moe_proto.bit} e]} {
    fail "write_bitstream: $e"
}
if {![file exists $OUT/moe_proto.bit]} {
    fail "bitstream missing after write_bitstream"
}
puts "==== bitstream = $OUT/moe_proto.bit  ([file size $OUT/moe_proto.bit] bytes)"
flush stdout
stage_done "write_bitstream"

# -----------------------------------------------------------------------------
stage "pin check"
# -----------------------------------------------------------------------------
foreach p {sys_clk_p rst_n} {
    if {[catch {set loc [get_property PACKAGE_PIN [get_ports $p]]} e]} {
        puts "====   $p : not placed"
    } else {
        puts "====   $p -> $loc"
    }
}
stage_done "pin check"

if {$::ERRORS} {
    puts "==== BUILD FAILED"
    exit 1
}
puts "==== BUILD OK  total [expr {[clock seconds] - $::T0}]s"
flush stdout