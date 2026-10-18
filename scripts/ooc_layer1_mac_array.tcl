# -----------------------------------------------------------------------------
# ooc_layer1_mac_array.tcl - OOC synthesis of the 256-lane MAC array
# -----------------------------------------------------------------------------
#   vivado -mode batch -source scripts/ooc_layer1_mac_array.tcl
#
# Scope: fp4_product_gen + fp4_select + mac_lane + mac_region only.
# gemv_engine is NOT elaborated, so its BRAM and activation buffer do not
# contaminate the array numbers.  The array's acc_vec_flat is declared as a
# black-box output so the accumulators are not pruned.
# -----------------------------------------------------------------------------

set ROOT {D:/ai/moe_fpga_proto_verilog}
set OUT  $ROOT/build/ooc/layer1
file delete -force $OUT
file mkdir $OUT

set fh [open $OUT/summary.txt w]
proc say {msg} {
    global fh
    puts $msg
    puts $fh $msg
    flush $fh
}

say "=== LAYER 1: 256-lane compute array (OOC) ==="

# ---- black box declaring only the array's ports ------------------------------
set bb $OUT/mac_array_top.v
set f [open $bb w]
puts $f "// OOC wrapper: exposes the 4-region array with no engine around it."
puts $f "// acc_vec_flat is an output so the accumulator registers survive."
puts $f "module mac_array_top ("
puts $f "    input                           clk,"
puts $f "    input                           rst_n,"
puts $f "    input                           clear_acc,"
puts $f "    input                           acc_en,"
puts $f "    input  \[23:0\]                   act_q,"
puts $f "    input  \[1023:0\]                 wcode_row,"
puts $f "    output \[(\`FP4_CODES*24)-1:0\]    prod16_flat,"
puts $f "    output \[(64*32)-1:0\]           acc_vec_flat"
puts $f ");"
puts $f "    fp4_product_gen #(.ACT_W(\`ACT_W), .PROD_W(24)) u_prod ("
puts $f "        .a(act_q), .prod16_flat(prod16_flat)"
puts $f "    );"
puts $f "    mac_region #(.REGION_LANES(64), .WCODE_W(\`WCODE_W), .PROD_W(24), .ACC_W(32)) u_region ("
puts $f "        .clk(clk), .rst_n(rst_n), .clear_acc(clear_acc), .acc_en(acc_en),"
puts $f "        .prod16_flat(prod16_flat), .wcode_row(wcode_row), .acc_vec_flat(acc_vec_flat)"
puts $f "    );"
puts $f "endmodule"
close $f

# ---- project (non project mode cannot set include dirs easily) ---------------
create_project ooc_l1 $OUT/proj -part xc7a200tfbg484-2 -force
set_property source_mgmt_mode None [current_project]
add_files -norecurse -fileset sources_1 [list \
    $ROOT/rtl/include/moe_params.vh \
    $ROOT/rtl/core/fp4_select.v \
    $ROOT/rtl/core/fp4_product_gen.v \
    $ROOT/rtl/core/mac_lane.v \
    $ROOT/rtl/core/mac_region.v \
    $bb \
]
set_property is_global_include true [get_files $ROOT/rtl/include/moe_params.vh]
set_property file_type {Verilog Header} [get_files $ROOT/rtl/include/moe_params.vh]
set_property include_dirs $ROOT/rtl/include [current_fileset]
set_property top mac_array_top [current_fileset]

if {[catch {
    synth_design -top mac_array_top -part xc7a200tfbg484-2 -mode out_of_context \
        -flatten_hierarchy none -no_lc
} e]} {
    say "SYNTH FAILED: $e"
    close $fh
    exit 1
}

# ---- utilisation -------------------------------------------------------------
set util {}
catch { set util [report_utilization -return_string] }
foreach line [split $util "\n"] {
    if {[string match "*Slice LUTs*" $line] || [string match "*LUT as Logic*" $line] || \
        [string match "*LUT as Memory*" $line] || [string match "*Slice Registers*" $line] || \
        [string match "*Register as Flip Flop*" $line] || [string match "*DSPs*" $line] || \
        [string match "*Block RAM Tile*" $line] || [string match "*RAMB36*" $line] || \
        [string match "*RAMB18*" $line] || [string match "*Bonded IOB*" $line] || \
        [string match "*Carry8*" $line] || [string match "*F7 Muxes*" $line]} {
        say $line
    }
}

# ---- structural checks -------------------------------------------------------
say ""
say "--- structure ---"
set lanes {}
catch { set lanes [get_cells -hier -filter {NAME =~ *gen_lane*} -quiet] }
say "mac_lane instances        = [llength [get_cells -hier -filter {REF_NAME == mac_lane}]]"
say "acc_out register count    = [llength [get_cells -hier -filter {NAME =~ *acc_out* && IS_SEQUENTIAL}]]"
say "fp4_select instances      = [llength [get_cells -hier -filter {REF_NAME == fp4_select}]]"
say "DSP48 cells               = [llength [get_cells -hier -filter {REF_NAME =~ DSP48*}]]"
say "RAMB cells                = [llength [get_cells -hier -filter {REF_NAME =~ RAMB*}]]"

close $fh
puts "LAYER1 report -> $OUT/summary.txt"
