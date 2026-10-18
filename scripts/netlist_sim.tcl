# -----------------------------------------------------------------------------
# netlist_sim.tcl - gate-level functional simulation of the ROUTED design
# -----------------------------------------------------------------------------
#   vivado -mode batch -nolog -nojournal -notrace -source build/moe/netlist_sim.tcl
#
# The RTL simulation passes.  The board does not.  Something between the two is
# wrong, and the only description of the real circuit is the routed netlist, so
# simulate that.
#
# If the netlist produces ffffc6e2 but the board does not, the fault is in
# programming or I/O rather than in the logic.  If the netlist produces
# something else, the synthesiser did something the RTL simulation never saw -
# most likely the act_rom elimination, which has no counterpart in RTL.
# -----------------------------------------------------------------------------

set ROOT {D:/ai/moe_fpga_proto_verilog}
set OUT  $ROOT/build/moe/netsim
set DCP  $ROOT/build/moe/out/post_route.dcp

file delete -force $OUT
file mkdir $OUT
foreach ch {stdout stderr} { catch { fconfigure $ch -buffering none } }

if {![file exists $DCP]} { puts "FAILED: no $DCP"; exit 1 }

puts "==== open routed checkpoint"
open_checkpoint $DCP

puts "==== write functional netlist"
write_verilog -mode funcsim -force $OUT/moe_netlist.v
puts "==== netlist written: [file size $OUT/moe_netlist.v] bytes"

# How many block RAMs claim to hold data, and specifically what happened to the
# activation ROM that the RTL instantiates but the netlist does not contain?
set arom [get_cells -hier -quiet -filter {NAME =~ *act_rom*}]
puts "==== act_rom cells in routed design = [llength $arom]"

set abuf [get_cells -hier -quiet -filter {NAME =~ *act_buffer*}]
puts "==== act_buffer cells = [llength $abuf]"
foreach c $abuf {
    set ref "?"
    catch { set ref [get_property REF_NAME $c] }
    puts "====   $c ($ref)"
}

close_design
puts "==== DONE"
