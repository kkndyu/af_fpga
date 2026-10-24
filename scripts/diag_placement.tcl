# -----------------------------------------------------------------------------
# diag_placement.tcl - where are the modules actually placed?
# -----------------------------------------------------------------------------
# Several claims in this project have been about things being "far apart" - the
# loader from the bridge, the banks from the engine, and so on.  Those were
# inferred from routing delay, never measured.  This reads the placement of
# representative cells straight out of the placed checkpoint so the distances are
# numbers instead of adjectives.
#
# On xc7a200t a SLICE is named SLICE_X<col>Y<row>.  Column and row are CLB grid
# coordinates; the difference between two cells is roughly how many CLB tiles the
# router has to cross.  The device is about 168 columns wide by 200 rows tall.
# -----------------------------------------------------------------------------

set ROOT {D:/ai/moe_fpga_proto_verilog}
set DCP  $ROOT/build/moe/out/post_place.dcp

foreach ch {stdout stderr} { catch { fconfigure $ch -buffering none } }

puts "==== opening $DCP"
open_checkpoint $DCP

proc probe {label pattern} {
    set c [get_cells -quiet -hier -filter "NAME =~ $pattern"]
    if {[llength $c] == 0} {
        puts [format "====  %-28s NOT FOUND  (%s)" $label $pattern]
        return ""
    }
    set cell [lindex $c 0]
    set loc ""
    catch { set loc [get_property LOC $cell] }
    puts [format "====  %-28s %-24s %s" $label $loc `$cell]
    return $loc
}

puts ""
puts "==== PLACEMENT OF INTERESTING CELLS"

set l_loader   [probe "loader FSM"        {u_loader/FSM_sequential_st_reg[0]}]
set l_cmd      [probe "loader cmd"        {u_loader/cmd_reg[0]}]
set l_shift    [probe "loader w_shift"    {u_loader/w_shift_reg[0]}]
set l_fifo     [probe "loader fifo"       {u_loader/fifo_reg[0][0]}]

set l_bridge   [probe "bridge tx_word"    {u_axil_bridge/tx_word_reg[0]}]
set l_bvalid   [probe "bridge tvalid"     {u_axil_bridge/s_axis_tvalid_reg}]
set l_rxfifo   [probe "bridge rx_fifo"    {u_axil_bridge/rx_fifo_reg[0][0]}]

set l_wb0      [probe "wbank 0"           {u_moe_proto_top/u_expert_engine/u_gate_gemv/u_wbank_r0/mem_reg_*}]
set l_wb1      [probe "wbank 1"           {u_moe_proto_top/u_expert_engine/u_gate_gemv/u_wbank_r1/mem_reg_*}]
set l_wb2      [probe "wbank 2"           {u_moe_proto_top/u_expert_engine/u_gate_gemv/u_wbank_r2/mem_reg_*}]
set l_wb3      [probe "wbank 3"           {u_moe_proto_top/u_expert_engine/u_gate_gemv/u_wbank_r3/mem_reg_*}]

set l_r0       [probe "region 0 lane 0"   {u_moe_proto_top/u_expert_engine/u_gate_gemv/u_region0/gen_lane[0].u_lane/acc_out_reg[0]}]
set l_r3       [probe "region 3 lane 63"  {u_moe_proto_top/u_expert_engine/u_gate_gemv/u_region3/gen_lane[63].u_lane/acc_out_reg[0]}]

set l_jtag     [probe "jtag_axi"          {u_jtag_axi/*}]
set l_dbg      [probe "dbg_hub"           {dbg_hub/inst/*}]

# -----------------------------------------------------------------------------
proc coords {loc} {
    if {[regexp {X(\d+)Y(\d+)} $loc -> x y]} { return [list $x $y] }
    return [list -1 -1]
}
proc dist {a b} {
    if {$a eq "" || $b eq ""} { return "n/a" }
    set ca [coords $a]; set cb [coords $b]
    set dx [expr {abs([lindex $ca 0] - [lindex $cb 0])}]
    set dy [expr {abs([lindex $ca 1] - [lindex $cb 1])}]
    return [format "%d cols, %d rows, manhattan %d" $dx $dy [expr {$dx + $dy}]]
}

puts ""
puts "==== DISTANCES (CLB grid)"
puts [format "====  %-40s %s" "loader FSM  <-> bridge tx_word" [dist $l_loader $l_bridge]]
puts [format "====  %-40s %s" "loader FIFO <-> bridge rx_fifo" [dist $l_fifo $l_rxfifo]]
puts [format "====  %-40s %s" "wbank 0     <-> wbank 3"       [dist $l_wb0 $l_wb3]]
puts [format "====  %-40s %s" "region 0    <-> region 3"      [dist $l_r0 $l_r3]]
puts [format "====  %-40s %s" "loader      <-> wbank 1"       [dist $l_loader $l_wb1]]
puts [format "====  %-40s %s" "bridge      <-> wbank 1"       [dist $l_bridge $l_wb1]]

# -----------------------------------------------------------------------------
puts ""
puts "==== CLOCK REGIONS IN USE"
set crs {}
foreach c [get_cells -quiet -hier -filter {REF_NAME == FDRE}] {
    set loc ""
    catch { set loc [get_property LOC $c] }
    if {[regexp {X(\d+)Y(\d+)} $loc -> x y]} {
        set cx [expr {$x / 17}]
        set cy [expr {$y / 25}]
        lappend crs "X${cx}Y${cy}"
    }
}
set uniq [lsort -unique $crs]
puts "====  distinct clock regions holding flip-flops: [llength $uniq]"
puts "====  $uniq"

puts ""
puts "==== DONE"
exit 0
