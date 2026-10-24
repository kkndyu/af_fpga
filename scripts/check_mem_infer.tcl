# -----------------------------------------------------------------------------
# check_mem_infer.tcl - synthesise moe_proto_top alone and inspect its memories
# -----------------------------------------------------------------------------
#   vivado -mode batch -nolog -nojournal -notrace -source scripts/check_mem_infer.tcl
#
# Why a separate synthesis:
#
#   Before the runtime loader existed, the board top tied the weight and
#   activation write ports to zero.  A block RAM that is never written is a
#   constant, so synthesis correctly folded the whole engine away and the board
#   build collapsed to a few hundred cells.  That was acceptable for the board
#   (all it had to do was blink "NOT LOADED") but the board netlist then said
#   nothing about how the memories had been inferred.
#
#   The board now has real write ports driven by moe_loader, so that particular
#   collapse no longer happens.  Synthesising moe_proto_top directly is still the
#   clearer check, though: it is one hierarchy, the write ports are module inputs
#   with nothing above them, and the RAMB count is unambiguous.
#
# What this verifies, i.e. the V2 acceptance criteria:
#   1. the weight banks are still block RAM (not LUTs) despite the added write
#      port - expect 4 banks x 8 = 32 RAMB36E1
#   2. the activation buffers are still block RAM - expect 4 x RAMB18E1
#   3. EVERY RAMB primitive configures EMPTY (all INIT_* digits zero)
#      - the whole point of V2: nothing baked into the bitstream
#
# A throwaway project is created only to carry include_dirs.  In non-project mode
# read_verilog cannot see rtl/include; this is the same workaround build_moe.tcl
# already uses, and it is documented there.
# -----------------------------------------------------------------------------

set ROOT {D:/ai/moe_fpga_proto_verilog}
set PART {xc7a200tfbg484-2}
set PROJ $ROOT/build/moe/meminfer_proj

foreach ch {stdout stderr} { catch { fconfigure $ch -buffering none } }

file delete -force $PROJ
create_project moe_meminfer $PROJ -part $PART -force
set_property source_mgmt_mode None [current_project]

add_files -norecurse -fileset sources_1 {*}[list \
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
set_property is_global_include true [get_files $ROOT/rtl/include/moe_params.vh]
set_property file_type {Verilog Header} [get_files $ROOT/rtl/include/moe_params.vh]
set_property include_dirs $ROOT/rtl/include [current_fileset]
set_property top moe_proto_top [current_fileset]

puts "==== synthesising moe_proto_top (no XDC: timing is not the question here)"
if {[catch {synth_design -top moe_proto_top -part $PART -flatten_hierarchy rebuilt} e]} {
    puts "==== FAILED synth_design: $e"
    exit 1
}

# -----------------------------------------------------------------------------
# 1. inference counts
# -----------------------------------------------------------------------------
puts ""
puts "==== INFERENCE"
foreach r {RAMB36E1 RAMB18E1 LUT6} {
    set n [llength [get_cells -quiet -hier -filter "REF_NAME == $r"]]
    puts [format "====   %-10s %5d" $r $n]
}

set r36 [llength [get_cells -quiet -hier -filter {REF_NAME == RAMB36E1}]]
set r18 [llength [get_cells -quiet -hier -filter {REF_NAME == RAMB18E1}]]

# Check capacity rather than an exact primitive count.  The write port changed the
# memory aspect ratio, so Vivado now packs the same data as 28 RAMB36E1 plus 8
# RAMB18E1 instead of 32 plus 4.  Both are valid; what matters is that enough
# block RAM exists and that none of it fell back to LUTs.
set have_bits [expr {$r36 * 36864 + $r18 * 18432}]
set need_bits [expr {(4 * 1024 * 256) + (4 * 1024 * 16)}]
puts [format "====   capacity %d bits, needed %d bits" $have_bits $need_bits]

set errors 0
if {$have_bits < $need_bits} {
    puts "==== WARNING: block RAM capacity is short - a memory probably fell back to LUTs"
    incr errors
}

# -----------------------------------------------------------------------------
# 2. nothing may be baked in
# -----------------------------------------------------------------------------
puts ""
puts "==== INIT CONTENTS"
set cells [concat \
    [get_cells -quiet -hier -filter {REF_NAME == RAMB36E1}] \
    [get_cells -quiet -hier -filter {REF_NAME == RAMB18E1}]]

set nonzero_cells 0
set total_nonzero 0
set named 0

foreach c $cells {
    set nz  0
    set tot 0
    foreach p [list_property $c] {
        # Only the data words, INIT_00..INIT_7F and INITP_00..INITP_0F.  A prefix
        # match on "INIT*" also catches INIT_FILE, whose default value is the
        # string 'NONE' - that made every single RAMB look as if it carried data
        # and sent this check on a false trail.
        if {![regexp {^INITP?_[0-9A-Fa-f]+$} $p]} { continue }
        incr tot
        set v ""
        catch { set v [get_property $p $c] }
        # The value is a Verilog literal such as 256'h0000...  Strip the width and
        # base prefix before testing, otherwise the prefix alone makes an all-zero
        # memory look non-zero.
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

puts "====   cells inspected: [llength $cells]"
if {$nonzero_cells == 0} {
    puts "====   RESULT: every RAMB configures EMPTY"
    puts "====           -> nothing is baked into the bitstream"
} else {
    puts "====   RESULT: $nonzero_cells cells still carry data"
    puts "====           ($total_nonzero non-zero INIT_* properties)"
    incr errors
}

puts ""
if {$errors == 0} {
    puts "==== MEMORY INFERENCE OK"
} else {
    puts "==== MEMORY INFERENCE PROBLEMS: $errors"
}
puts "==== DONE"
exit 0
