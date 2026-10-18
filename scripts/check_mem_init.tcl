# -----------------------------------------------------------------------------
# check_mem_init.tcl - V2 acceptance: NO memory may carry baked-in data
# -----------------------------------------------------------------------------
#   vivado -mode batch -nolog -nojournal -notrace -source scripts/check_mem_init.tcl
#
# This check used to do the OPPOSITE.  Before V2 it verified that the weight and
# activation BRAMs DID carry their contents, because $readmemh in an initial block
# was how data got in - and the worry was that synthesis had silently dropped it.
#
# V2 removed every initial block on purpose: the memories must configure EMPTY and
# be filled at runtime.  So the question is now inverted:
#
#   * if a RAMB primitive still has non-zero INIT_* contents, some $readmemh
#     survived a refactor and the "loadable" claim would be a lie;
#   * if the RAMB count dropped, the write port probably forced a memory into
#     LUTs, which would be a much bigger change than it looks.
#
# A RAMB primitive exposes its power-on contents as INIT_00 .. INIT_7F, so both
# questions are answered by reading the netlist.
#
# Exit code is non-zero when the design is not in the expected state, so this can
# gate a build.
# -----------------------------------------------------------------------------

set ROOT {D:/ai/moe_fpga_proto_verilog}

# Prefer the routed checkpoint - it is what becomes the bitstream - and fall back
# to the synthesis one when only synthesis has been run.
set DCP ""
foreach c [list \
        $ROOT/build/moe/out/post_route.dcp \
        $ROOT/build/moe/out/post_physopt.dcp \
        $ROOT/build/moe/synth_out/post_synth.dcp] {
    if {[file exists $c]} { set DCP $c; break }
}
if {$DCP eq ""} {
    puts "==== FAILED: no checkpoint found; run scripts/run_build.ps1 first"
    exit 1
}

foreach ch {stdout stderr} { catch { fconfigure $ch -buffering none } }

puts "==== checkpoint: $DCP"
open_checkpoint $DCP

set cells [get_cells -quiet -hier -filter {REF_NAME =~ RAMB*}]
set ncells [llength $cells]
puts "==== RAMB primitives: $ncells"
if {$ncells == 0} {
    puts "==== FAILED: no RAMB primitives at all - the memories were not inferred as block RAM"
    close_design
    exit 1
}

set total_nonzero 0
set nonzero_cells 0
set named 0

foreach c $cells {
    set nz  0
    set tot 0
    foreach p [list_property $c] {
        # Only the data words, INIT_00..INIT_7F and INITP_00..INITP_0F.  A prefix
        # match on "INIT*" also catches INIT_FILE, whose default value is the
        # string 'NONE', which made every RAMB look as if it carried data.
        if {![regexp {^INITP?_[0-9A-Fa-f]+$} $p]} { continue }
        incr tot
        set v ""
        catch { set v [get_property $p $c] }
        # The property value is a Verilog literal, e.g.
        #     256'h0000000000000000000000000000000000000000000000000000000000000000
        # A naive [string trim $v 0] only strips leading/trailing zeros and leaves
        # the "256'h" prefix behind, so an all-zero memory was reported as
        # non-zero.  Strip the width/base prefix first, then test the digits.
        set digits $v
        if {[regexp {^[0-9]*'[sS]?[hbodHBOD]([0-9a-fA-F_]+)$} $v -> digits]} {
            set digits [string map {_ ""} $digits]
        }
        if {[string trim $digits 0] ne ""} { incr nz }
    }
    if {$nz > 0} {
        incr nonzero_cells
        incr total_nonzero $nz
        if {$named < 8} {
            puts "====   NON-ZERO: $c  ($nz / $tot)"
            incr named
        }
    }
}

puts ""
if {$nonzero_cells == 0} {
    puts "==== RESULT: all $ncells RAMB primitives configure EMPTY"
    puts "====         -> nothing is baked into the bitstream, V2 goal met"
    set rc 0
} else {
    puts "==== RESULT: $nonzero_cells of $ncells RAMB primitives still carry data"
    puts "====         ($total_nonzero non-zero INIT_* properties)"
    puts "====         -> some readmemh survived; the memories are NOT loadable-only"
    set rc 1
}

# 32 weight primitives (4 banks x 8) plus 4 activation buffers = 36 tiles, though
# primitives rather than tiles are counted here, so allow a little slack.
if {$ncells -lt 36} {
    puts "==== WARNING: only $ncells RAMB primitives, at least 36 were expected"
    puts "====          check whether a memory was inferred as distributed RAM"
}

close_design
puts "==== DONE (exit $rc)"
exit $rc
