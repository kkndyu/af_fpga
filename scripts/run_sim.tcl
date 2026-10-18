# -----------------------------------------------------------------------------
# run_sim.tcl - compile and run tb_gemv_engine with the Vivado simulator
# -----------------------------------------------------------------------------
# Run from the repository root:
#
#   vivado -mode batch -source scripts/run_sim.tcl
#
# Produces, relative to the repository root:
#   build/xsim/tb_gemv_engine.vcd      waveform
#   sim/data/rtl_out.hex               DUT output, written by the testbench
#
# Then check the result with scripts/check_result.py (or the PowerShell
# equivalent), which compares sim/data/rtl_out.hex against sim/data/ref_out.hex.
#
# To open the waveform in the GUI afterwards:
#   vivado -mode gui build/xsim/tb_gemv_engine.vcd
# -----------------------------------------------------------------------------

set ROOT  {D:/ai/moe_fpga_proto_verilog}
set OUT   $ROOT/build/xsim
set TB    $ROOT/sim/tb/tb_gemv_engine.v
set INCL  $ROOT/rtl/include

file mkdir $OUT

# Run everything from build/xsim so xsim's own scratch files (xsim.dir, logs)
# do not land in the repository root.
cd $OUT

# -----------------------------------------------------------------------------
# Compile
# -----------------------------------------------------------------------------
# Order follows the module hierarchy: leaf modules first, then the engine, then
# the testbench.
set rtl_files [list \
    $ROOT/rtl/core/fp4_select.v \
    $ROOT/rtl/core/fp4_product_gen.v \
    $ROOT/rtl/core/mac_lane.v \
    $ROOT/rtl/core/mac_region.v \
    $ROOT/rtl/mem/wbank_region.v \
    $ROOT/rtl/mem/act_buffer.v \
    $ROOT/rtl/mem/vec_buffer.v \
    $ROOT/rtl/core/gemv_engine.v \
]

puts "INFO: xvlog -i $INCL"
if {[catch {exec xvlog -i $INCL {*}$rtl_files {*}[list $TB]} msg]} {
    puts "ERROR: xvlog failed:\n$msg"
    exit 1
}
puts $msg

# -----------------------------------------------------------------------------
# Elaborate
# -----------------------------------------------------------------------------
# -timescale is required, not optional.  The testbenches carry `timescale
# directives but none of the 12 RTL files do, and xelab refuses to elaborate a
# design that mixes the two:
#
#   ERROR: [XSIM 43-4099] Module gemv_engine doesn't have a timescale but at
#                         least one module in design has a timescale
#
# This was missing from the very first version of this script, so the procedure
# documented in README.md never worked.  The real fix is to add `timescale to
# every RTL file; until then the flag papers over it.
if {[catch {exec xelab tb_gemv_engine -debug typical -timescale 1ns/1ps -s tb_gemv_engine_sim} msg]} {
    puts "ERROR: xelab failed:\n$msg"
    exit 1
}
puts $msg

# -----------------------------------------------------------------------------
# Simulate and dump a waveform
# -----------------------------------------------------------------------------
set batch_file $OUT/run_sim_batch.tcl
set fh [open $batch_file w]
puts $fh "log_wave -recursive *"
puts $fh "run all"
puts $fh "exit"
close $fh

if {[catch {exec xsim tb_gemv_engine_sim -tclbatch $batch_file -wdb $OUT/tb.wdb} msg]} {
    puts "ERROR: xsim failed:\n$msg"
    exit 1
}
puts $msg

puts "INFO: simulation finished"
puts "INFO: DUT output -> $ROOT/sim/data/rtl_out.hex"
puts "INFO: waveform   -> $OUT/tb.wdb"
