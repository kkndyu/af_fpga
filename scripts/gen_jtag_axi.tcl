# -----------------------------------------------------------------------------
# gen_jtag_axi.tcl - generate the JTAG-to-AXI master IP
# -----------------------------------------------------------------------------
#   vivado -mode batch -nolog -nojournal -notrace -source scripts/gen_jtag_axi.tcl
#
# Produces an out-of-context synthesised DCP plus its Verilog wrapper, so the
# main build can read_checkpoint the IP and treat it as a black box called
# jtag_axi_0.  That keeps the project's non-project flow intact.
#

# attempt guessed C_PROTOCOL / C_ADDR_WIDTH / C_DATA_FIFO_DEPTH and all three were
# rejected.  The IP actually exposes PROTOCOL, M_AXI_ADDR_WIDTH, M_AXI_DATA_WIDTH,
# M_AXI_ID_WIDTH and SIGNAL_CLOCK.FREQ_HZ.
#
# Two settings matter here:
#
#   PROTOCOL 1            AXI4-Lite.  The loader bridge is a register interface,
#                         not a burst engine, so Lite is both sufficient and much
#                         smaller than full AXI4.
#
#   SIGNAL_CLOCK.FREQ_HZ  The IP defaults to 100 MHz.  This board runs everything
#                         at 200 MHz, and leaving the IP believing it is on a
#                         100 MHz clock would mis-size its internal synchronisers.
#
# Why this path exists: it needs no pins, no extra clock domain and no protocol
# stack.  When an Ethernet bring-up is going badly, this is what still lets a
# value be written into the machine and read back out.
# -----------------------------------------------------------------------------

set ROOT {D:/ai/moe_fpga_proto_verilog}
set PART {xc7a200tfbg484-2}
set PROJ $ROOT/build/ip/jtag_axil
set OUT  $ROOT/build/ip/jtag_axil_out

foreach ch {stdout stderr} { catch { fconfigure $ch -buffering none } }

file delete -force $PROJ
file delete -force $OUT
file mkdir $OUT

puts "==== creating project"
create_project jtag_axil $PROJ -part $PART -force
set_property source_mgmt_mode None [current_project]

puts "==== creating jtag_axi"
if {[catch {
    # No -dir: in project mode create_ip places the IP under the project's own IP
    # directory, and passing -dir to a non-existent path fails outright.
    create_ip -name jtag_axi -vendor xilinx.com -library ip -version 1.2 \
              -module_name jtag_axi_0
} e]} {
    puts "==== FAILED create_ip: $e"
    exit 1
}

puts "==== configuring"
if {[catch {
    set_property -dict [list \
        CONFIG.PROTOCOL              {2} \
        CONFIG.M_AXI_ADDR_WIDTH      {32} \
        CONFIG.M_AXI_DATA_WIDTH      {32} \
        CONFIG.M_AXI_ID_WIDTH        {1} \
        CONFIG.SIGNAL_CLOCK.FREQ_HZ  {200000000} \
    ] [get_ips jtag_axi_0]
} e]} {
    puts "==== FAILED configure: $e"
    exit 1
}

foreach p {PROTOCOL M_AXI_ADDR_WIDTH M_AXI_DATA_WIDTH M_AXI_ID_WIDTH SIGNAL_CLOCK.FREQ_HZ} {
    set v "?"
    catch { set v [get_property CONFIG.$p [get_ips jtag_axi_0]] }
    puts "====   $p = $v"
}

puts "==== generate_target"
if {[catch {generate_target all [get_files jtag_axi_0.xci]} e]} {
    puts "==== FAILED generate_target: $e"
    exit 1
}

puts "==== synth_ip"
if {[catch {synth_ip [get_ips jtag_axi_0]} e]} {
    puts "==== FAILED synth_ip: $e"
    exit 1
}

set dcp [glob -nocomplain $PROJ/*/sources_1/ip/jtag_axi_0/jtag_axi_0.dcp $PROJ/*.runs/jtag_axi_0_synth_1/jtag_axi_0.dcp]
if {[llength $dcp] == 0} {
    puts "==== FAILED: no synthesised DCP produced"
    exit 1
}
file copy -force [lindex $dcp 0] $OUT/jtag_axi_0.dcp
puts "==== DCP: $OUT/jtag_axi_0.dcp"

# The wrapper goes next to the DCP so the main build can read_verilog it.
set wrap [glob -nocomplain $PROJ/*/sources_1/ip/jtag_axi_0/sim/jtag_axi_0.v]
if {[llength $wrap] == 0} {
    set wrap [glob -nocomplain $PROJ/*/sources_1/ip/jtag_axi_0/synth/jtag_axi_0.v]
}
if {[llength $wrap] > 0} {
    file copy -force [lindex $wrap 0] $OUT/jtag_axi_0.v
    puts "==== wrapper: $OUT/jtag_axi_0.v"
    # Report the port list: this is the ground truth for how the board top has to
    # connect it, and it also settles whether PROTOCOL 1 really produced an
    # AXI4-Lite interface (no awlen/arlen, no ID).
    set fh [open $OUT/jtag_axi_0.v r]
    set src [read $fh]
    close $fh
    puts "==== wrapper ports:"
    foreach line [split $src "\n"] {
        if {[regexp {^\s*(input|output|inout)\s} $line]} {
            puts "====   [string trim $line]"
        }
    }
} else {
    puts "==== WARNING: wrapper Verilog not found; the board top cannot be wired up"
}

puts "==== DONE"
exit 0
