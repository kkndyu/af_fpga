# -----------------------------------------------------------------------------
# xsdb_program_moe.tcl - program the MoE board bitstream
# -----------------------------------------------------------------------------
#   xsdb -no-ini -eval "source {D:/ai/moe_fpga_proto_verilog/scripts/xsdb_program_moe.tcl}"
#
# Programs the volatile configuration memory only (not the SPI flash), so a
# power cycle restores whatever the flash holds.
#
# This machine's Vivado lacks labtools, so open_hw_manager does not exist and
# xsdb is the only way to talk to the FPGA.  Two quirks learned earlier:
#   * 'targets' returns a FLAT list {id name}, and the id it reports is NOT the
#     number 'jtag targets' prints.
#   * 'targets <name>' does not work; it needs the numeric id.
# -----------------------------------------------------------------------------

set BITFILE {D:/ai/moe_fpga_proto_verilog/build/moe/out/moe_proto.bit}

proc pick_fpga {} {
    set tl [targets]
    set i 0
    while {$i < [llength $tl]} {
        set cand_id   [lindex $tl $i]
        set cand_name [lindex $tl [expr {$i + 1}]]
        if {[string match "*xc7a200t*" [string tolower $cand_name]]} {
            return [list $cand_id $cand_name]
        }
        incr i 2
    }
    return [list "" ""]
}

puts "XSDB --- connect ---"
if {[catch {connect} e]} { puts "XSDB connect failed: $e"; exit 1 }
puts "XSDB connected"
puts "XSDB chain: [jtag targets]"

lassign [pick_fpga] dev_id dev_name
if {$dev_id eq ""} {
    puts "XSDB no xc7a200t on the chain; refusing to program."
    exit 2
}
puts "XSDB FPGA target id=$dev_id name=$dev_name"

if {[catch {targets $dev_id} e]} {
    puts "XSDB select failed: $e"
    exit 3
}

if {![file exists $BITFILE]} {
    puts "XSDB FATAL: bitfile missing: $BITFILE"
    exit 4
}
puts "XSDB bitfile = $BITFILE"
puts "XSDB bitfile size = [file size $BITFILE] bytes"
puts "XSDB programming ..."

if {[catch {fpga -f $BITFILE} e]} {
    puts "XSDB FATAL: fpga -f failed: $e"
    exit 5
}

puts "XSDB programmed OK"
disconnect
puts "XSDB done"
