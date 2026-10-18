# -----------------------------------------------------------------------------
# check_mem_init.tcl - verify the on-chip memories actually carry their data
# -----------------------------------------------------------------------------
#   vivado -mode batch -nolog -nojournal -notrace -source build/moe/check_mem_init.tcl
#
# Opens the routed checkpoint and inspects the INIT_* contents of the block RAMs.
# A RAMB primitive exposes its power-on contents that way, so this answers the
# question "did $readmemh actually make it into the silicon" for BOTH memories
# that matter:
#
#   u_wbank_r*  - the FP4 weight codes, from mem_init/expert0/gate_r*.mem
#   act_rom     - the activation vector, from sim/data/input.mem
#
# The activation ROM is the new suspect: synthesis reports it was mapped into
# block RAM this time ("Trying to map ROM act_rom into Block RAM"), whereas an
# earlier build left it in registers.  If its INIT data is empty the engine
# computes with zeros and every checksum is wrong.
# -----------------------------------------------------------------------------

set ROOT {D:/ai/moe_fpga_proto_verilog}
set OUT  $ROOT/build/moe/memcheck
set DCP  $ROOT/build/moe/out/post_route.dcp

file delete -force $OUT
file mkdir $OUT

foreach ch {stdout stderr} { catch { fconfigure $ch -buffering none } }

if {![file exists $DCP]} {
    puts "CHECK FAILED: no routed checkpoint at $DCP"
    exit 1
}

puts "==== opening $DCP"
open_checkpoint $DCP

puts ""
puts "==== block RAM inventory"
set cells [get_cells -hier -quiet -filter {REF_NAME =~ RAMB*}]
puts "==== RAMB cells = [llength $cells]"
foreach c $cells {
    set ref "?"
    catch { set ref [get_property REF_NAME $c] }
    puts "====   $c  ($ref)"
}

puts ""
puts "==== INIT data per cell (is the memory really loaded?)"
set all_nonzero 1
foreach c $cells {
    set props {}
    catch { set props [list_property $c] }
    set nz 0
    set total 0
    foreach p $props {
        if {![string match "INIT_*" $p]} { continue }
        incr total
        set v ""
        catch { set v [get_property $p $c] }
        if {$v ne "" && [string trim $v 0] ne ""} { incr nz }
    }
    puts "====   $c : $nz / $total INIT_* props non-zero"
    if {$nz == 0} { set all_nonzero 0 }
}

puts ""
if {$all_nonzero} {
    puts "==== VERDICT: every RAMB carries non-zero init data"
} else {
    puts "==== VERDICT: at least one RAMB is EMPTY - its \$readmemh did not take effect"
}

# Focus on the activation ROM specifically, since that is the new suspect.
puts ""
puts "==== activation ROM detail"
set arom [get_cells -hier -quiet -filter {NAME =~ *act_rom*}]
puts "==== act_rom cells = [llength $arom]"
foreach c $arom {
    set ref "?"
    catch { set ref [get_property REF_NAME $c] }
    set props {}
    catch { set props [list_property $c] }
    set nz 0
    set sample ""
    foreach p $props {
        if {![string match "INIT_*" $p]} { continue }
        set v ""
        catch { set v [get_property $p $c] }
        if {$v ne "" && [string trim $v 0] ne ""} {
            incr nz
            if {$sample eq ""} { set sample "$p=[string range $v 0 31]..." }
        }
    }
    puts "====   $c ($ref) non-zero INIT props = $nz   $sample"
    if {$nz == 0} {
        puts "====   *** this one is EMPTY ***"
    }
}

close_design
puts ""
puts "==== CHECK DONE"
