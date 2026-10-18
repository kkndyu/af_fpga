# -----------------------------------------------------------------------------
# ooc_layer3_expert.tcl - OOC synthesis of the Expert Engine hierarchy as built
# -----------------------------------------------------------------------------
#   vivado -mode batch -source scripts/ooc_layer3_expert.tcl
#
# Scope: expert_engine as it EXISTS in this repo, i.e. one gate GEMV with four
# region weight banks plus the activation buffer.  It does NOT contain:
#   - two experts
#   - up / down weight storage
#   - an output cache
#   - the gate->up->SiLU->down sequencer
# Those are reported as gaps against the stated target parameters, not measured.
#
# The engine's 8192-bit expert_out_flat is a black-box output so the array is
# not pruned.  This is an OOC internal-resource question; top-level IOB limits
# are irrelevant here and are not used as evidence.
# -----------------------------------------------------------------------------

set ROOT {D:/ai/moe_fpga_proto_verilog}
set OUT  $ROOT/build/ooc/layer3
file delete -force $OUT
file mkdir $OUT

set fh [open $OUT/summary.txt w]
proc say {msg} {
    global fh
    puts $msg
    puts $fh $msg
    flush $fh
}

say "=== LAYER 3: expert_engine hierarchy (OOC) ==="

create_project ooc_l3 $OUT/proj -part xc7a200tfbg484-2 -force
set_property source_mgmt_mode None [current_project]
add_files -norecurse -fileset sources_1 [list \
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
    $ROOT/rtl/top/moe_proto_top.v \
]
set_property is_global_include true [get_files $ROOT/rtl/include/moe_params.vh]
set_property file_type {Verilog Header} [get_files $ROOT/rtl/include/moe_params.vh]
set_property include_dirs $ROOT/rtl/include [current_fileset]
set_property top expert_engine [current_fileset]

cd $ROOT
if {[catch {
    synth_design -top expert_engine -part xc7a200tfbg484-2 -mode out_of_context \
        -flatten_hierarchy none
} e]} {
    say "SYNTH FAILED: $e"
    close $fh
    exit 1
}

set util {}
catch { set util [report_utilization -return_string] }
foreach line [split $util "\n"] {
    if {[string match "*Slice LUTs*" $line] || [string match "*LUT as Logic*" $line] || \
        [string match "*LUT as Memory*" $line] || [string match "*Slice Registers*" $line] || \
        [string match "*Register as Flip Flop*" $line] || [string match "*DSPs*" $line] || \
        [string match "*Block RAM Tile*" $line] || [string match "*RAMB36*" $line] || \
        [string match "*RAMB18*" $line] || [string match "*Bonded IOB*" $line] || \
        [string match "*BUFGCTRL*" $line]} {
        say $line
    }
}

say ""
say "--- structure ---"
say "gemv_engine instances   = [llength [get_cells -hier -filter {REF_NAME == gemv_engine}]]"
say "wbank_region instances  = [llength [get_cells -hier -filter {REF_NAME == wbank_region}]]"
say "mac_region instances    = [llength [get_cells -hier -filter {REF_NAME == mac_region}]]"
say "mac_lane instances      = [llength [get_cells -hier -filter {REF_NAME == mac_lane}]]"
say "act_buffer instances    = [llength [get_cells -hier -filter {REF_NAME == act_buffer}]]"
say "vec_buffer instances    = [llength [get_cells -hier -filter {REF_NAME == vec_buffer}]]"
say "RAMB cells              = [llength [get_cells -hier -filter {REF_NAME =~ RAMB*}]]"
say "DSP48 cells             = [llength [get_cells -hier -filter {REF_NAME =~ DSP48*}]]"
say "sequential acc registers= [llength [get_cells -hier -filter {NAME =~ *acc_out* && IS_SEQUENTIAL}]]"

# ---- unresolved / black box check -------------------------------------------
say ""
say "--- unresolved references (black boxes) ---"
set unresolved {}
catch { set unresolved [get_cells -hier -filter {IS_BLACKBOX == 1}] }
say "black box cell count = [llength $unresolved]"
foreach c $unresolved { say "   $c" }

close $fh
puts "LAYER3 report -> $OUT/summary.txt"
