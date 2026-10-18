# -----------------------------------------------------------------------------
# ooc_layer2_wbank.tcl - OOC synthesis of one WBank Region
# -----------------------------------------------------------------------------
#   vivado -mode batch -source scripts/ooc_layer2_wbank.tcl
#
# Scope: wbank_region alone, DEPTH=1024, DATA_W=256 bit.
# Checks whether the array is inferred as block RAM and how many RAMB36E1 it
# costs.  The $readmemh path is relative, so this runs from the repo root.
# -----------------------------------------------------------------------------

set ROOT {D:/ai/moe_fpga_proto_verilog}
set OUT  $ROOT/build/ooc/layer2
file delete -force $OUT
file mkdir $OUT

set fh [open $OUT/summary.txt w]
proc say {msg} {
    global fh
    puts $msg
    puts $fh $msg
    flush $fh
}

say "=== LAYER 2: wbank_region 1024 x 256 bit (OOC) ==="

# -----------------------------------------------------------------------------
# Measurement harness.
#
# Synthesising wbank_region on its own produces ZERO block RAM: nothing reads
# the read port in an out-of-context run, so the whole array looks unobservable
# and is removed.  A consumer is required for the RAM to be inferred at all.
#
# The harness below is generated into build/ and instantiates the ORIGINAL,
# UNMODIFIED rtl/mem/wbank_region.v, folding the read data into a checksum
# register so the memory becomes observable.
# -----------------------------------------------------------------------------
set harness $OUT/wbank_harness.v
set f [open $harness w]
puts $f "// Generated measurement harness - instantiates the unmodified wbank_region."
puts $f "module wbank_harness ("
puts $f "    input          clk,"
puts $f "    input          rd_en,"
puts $f "    input  \[9:0\]    rd_addr,"
puts $f "    output \[31:0\]   chk"
puts $f ");"
puts $f "    wire \[255:0\] rd_data;"
puts $f "    reg  \[31:0\]  chk_r;"
puts $f "    wbank_region #("
puts $f "        .DEPTH(1024), .ADDR_W(10), .DATA_W(256),"
puts $f "        .INIT_FILE(\"mem_init/expert0/gate_r0.mem\")"
puts $f "    ) u_wbank ("
puts $f "        .clk(clk), .rd_en(rd_en), .rd_addr(rd_addr), .rd_data(rd_data)"
puts $f "    );"
puts $f "    always @(posedge clk) chk_r <= chk_r ^ (^rd_data);"
puts $f "    assign chk = chk_r;"
puts $f "endmodule"
close $f

create_project ooc_l2 $OUT/proj -part xc7a200tfbg484-2 -force
set_property source_mgmt_mode None [current_project]
add_files -norecurse -fileset sources_1 [list \
    $ROOT/rtl/include/moe_params.vh \
    $ROOT/rtl/mem/wbank_region.v \
    $harness \
]
set_property is_global_include true [get_files $ROOT/rtl/include/moe_params.vh]
set_property file_type {Verilog Header} [get_files $ROOT/rtl/include/moe_params.vh]
set_property include_dirs $ROOT/rtl/include [current_fileset]
set_property top wbank_harness [current_fileset]

# The module's INIT_FILE default is "mem_init/expert0/gate_r0.mem".
cd $ROOT
if {![file exists mem_init/expert0/gate_r0.mem]} {
    say "WARNING: gate_r0.mem not found relative to $ROOT"
}

if {[catch {
    synth_design -top wbank_harness -part xc7a200tfbg484-2 -mode out_of_context \
        -flatten_hierarchy none
} e]} {
    say "SYNTH FAILED: $e"
    close $fh
    exit 1
}

set util {}
catch { set util [report_utilization -return_string] }
foreach line [split $util "\n"] {
    if {[string match "*Slice LUTs*" $line] || [string match "*Slice Registers*" $line] || \
        [string match "*Block RAM Tile*" $line] || [string match "*RAMB36*" $line] || \
        [string match "*RAMB18*" $line] || [string match "*DSPs*" $line] || \
        [string match "*Bonded IOB*" $line]} {
        say $line
    }
}

say ""
say "--- structure ---"
set cells {}
catch { set cells [get_cells -hier -filter {REF_NAME =~ RAMB*}] }
say "RAMB cell count = [llength $cells]"
set r36 0
set r18 0
foreach c $cells {
    set ref "?"
    catch { set ref [get_property REF_NAME $c] }
    if {[string match "*36*" $ref]} { incr r36 } else { incr r18 }
    say "   $c  ($ref)"
}
say "RAMB36 count = $r36"
say "RAMB18 count = $r18"

# Is the memory really initialised with the weight data?
set nonz 0
foreach c $cells {
    set props {}
    catch { set props [list_property $c] }
    foreach p $props {
        if {![string match "INIT_*" $p]} { continue }
        set v ""
        catch { set v [get_property $p $c] }
        if {$v ne "" && [string trim $v 0] ne ""} { incr nonz; break }
    }
}
say "RAMB cells carrying non-zero INIT data = $nonz"

say ""
say "theory: 1024 deep x 256 bit = 262144 bits; RAMB36E1 = 36864 bits"
say "        minimum = ceil(262144/36864) = 8 RAMB36E1 (width-sliced)"
close $fh
puts "LAYER2 report -> $OUT/summary.txt"
