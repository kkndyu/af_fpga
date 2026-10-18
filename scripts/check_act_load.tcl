# -----------------------------------------------------------------------------
# check_act_load.tcl - did the activation load path survive synthesis?
# -----------------------------------------------------------------------------
#   vivado -mode batch -nolog -nojournal -notrace -source scripts/check_act_load.tcl
#
# act_buffer has no INIT_FILE parameter - it is a plain writable RAM - so the only
# way to fill it in RTL is the write port, driven by moe_proto_board's S_LOAD
# sequencer, which copies 1024 values out of an on-chip act_rom.
#
# But that whole copy is provably redundant: the ROM contents are constant, and
# the copy writes them unchanged into the buffers.  So the synthesiser is free to
# fold the ROM into the buffers' INIT_* attributes and delete both the ROM and
# the copy loop.  This script checks whether it did.
#
# If it did, then on the board:
#   * the activation vector is baked into the bitstream exactly like the weights
#   * the write port still exists electrically but has nothing driving it
#   * "loading" costs zero cycles, not 1024
# -----------------------------------------------------------------------------

set ROOT {D:/ai/moe_fpga_proto_verilog}
set DCP  $ROOT/build/moe/out/post_route.dcp

foreach ch {stdout stderr} { catch { fconfigure $ch -buffering none } }

if {![file exists $DCP]} {
    puts "==== FAILED: no routed checkpoint at $DCP"
    exit 1
}
open_checkpoint $DCP

puts "==== activation ROM"
set arom [get_cells -quiet -hier -filter {NAME =~ *act_rom*}]
puts "====   act_rom cells = [llength $arom]   (0 means it was folded into the buffers)"
foreach c $arom { puts "====     $c" }

puts ""
puts "==== load sequencer (S_LOAD copies act_rom -> act_buffer)"
foreach sig {ld_idx act_wr_en act_wr_data act_wr_addr} {
    set cells [get_cells -quiet -hier -filter "NAME =~ *${sig}*"]
    puts "====   $sig related cells = [llength $cells]"
    foreach c [lrange $cells 0 2] { puts "====     $c" }
}

puts ""
puts "==== activation buffers and their init state"
set abuf [get_cells -quiet -hier -filter {NAME =~ *u_act_buffer/mem_reg*}]
puts "====   act_buffer mem cells = [llength $abuf]"
foreach c $abuf {
    set props [list_property $c]
    set nz 0; set tot 0
    foreach p $props {
        if {![string match "INIT_*" $p]} { continue }
        incr tot
        set v ""
        catch { set v [get_property $p $c] }
        if {$v ne "" && [string trim $v 0] ne ""} { incr nz }
    }
    puts "====   $c : $nz / $tot INIT_* non-zero"
    if {$nz > 0} {
        puts "====     -> preloaded at configuration time, i.e. the copy was optimised away"
    }
}

puts ""
puts "==== board-level sequencer state register (is S_LOAD still there?)"
set st [get_cells -quiet -hier -filter {NAME =~ *st_reg*}]
puts "====   st_reg cells = [llength $st]"
foreach c $st { puts "====     $c" }

close_design
puts "==== DONE"
