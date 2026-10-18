# -----------------------------------------------------------------------------
# path_analysis.tcl - what are ALL the tight paths, not just the worst one?
# -----------------------------------------------------------------------------
#   vivado -mode batch -nolog -nojournal -notrace -source build/moe/path_analysis.tcl
#
# The text report only details the single worst path per group, which hides the
# pattern.  If many paths share a root cause, that root cause is worth fixing
# once; if they are all different, pre-emptive micro-optimisation is a waste.
#
# Prints the worst N setup paths with source, destination, delay, levels and the
# slack, then groups them by destination module so a common cause is obvious.
# -----------------------------------------------------------------------------

set ROOT {D:/ai/moe_fpga_proto_verilog}
set DCP  $ROOT/build/moe/physopt/post_physopt.dcp

foreach ch {stdout stderr} { catch { fconfigure $ch -buffering none } }

if {![file exists $DCP]} {
    puts "==== FAILED: no $DCP (run physopt_only.tcl first)"
    exit 1
}
open_checkpoint $DCP

puts "==== worst 25 SETUP paths"
puts "==== slack      delay   lvl  source  ->  destination"
set paths {}
catch { set paths [get_timing_paths -max_paths 25 -setup] }
set n 0
foreach p $paths {
    incr n
    set slk "?"; set src "?"; set dst "?"; set dly "?"; set lvl "?"
    catch { set slk [get_property SLACK          $p] }
    catch { set src [get_property STARTPOINT_PIN $p] }
    catch { set dst [get_property ENDPOINT_PIN   $p] }
    catch { set dly [get_property DATAPATH_DELAY $p] }
    catch { set lvl [get_property LOGIC_LEVELS   $p] }
    # shorten the names so the pattern is visible
    regsub -all {u_moe_proto_top/u_expert_engine/u_gate_gemv/} $src "" src2
    regsub -all {u_moe_proto_top/u_expert_engine/u_gate_gemv/} $dst "" dst2
    regsub -all {u_moe_proto_top/} $src2 "" src3
    regsub -all {u_moe_proto_top/} $dst2 "" dst3
    puts [format "==== %8s  %7s  %3s  %s" $slk $dly $lvl $src3]
    puts [format "==== %8s  %7s  %3s      -> %s" "" "" "" $dst3]
}
flush stdout

# Group by destination instance prefix to spot a shared cause.
puts ""
puts "==== destination grouping (top module of each endpoint)"
array set cnt {}
foreach p $paths {
    set dst "?"
    catch { set dst [get_property ENDPOINT_PIN $p] }
    if {[regexp {^(.*?)/gen_lane} $dst m grp]} {
        incr cnt($grp)
    } elseif {[regexp {^(.*?)/[^/]+$} $dst m grp]} {
        incr cnt($grp)
    } else {
        incr cnt(other)
    }
}
foreach k [lsort [array names cnt]] {
    puts "====   $cnt($k) x $k"
}
flush stdout

# How much fanout do the control nets carry?  acc_en and clear_acc both drive
# one pin per accumulator bit, so they are prime suspects for a routing-bound
# control path.
puts ""
puts "==== high-fanout control nets"
foreach name {acc_en_q clear_acc rd_start capture} {
    set pins {}
    catch { set pins [get_pins -quiet -hier -filter "REF_PIN_NAME == CE || REF_PIN_NAME == CLR" ] }
}
set ce [get_pins -quiet -hier -filter {REF_PIN_NAME == CE}]
set clr [get_pins -quiet -hier -filter {REF_PIN_NAME == CLR}]
set sr  [get_pins -quiet -hier -filter {REF_PIN_NAME == R || REF_PIN_NAME == S}]
puts "====   CE  pins in design : [llength $ce]"
puts "====   CLR pins in design : [llength $clr]"
puts "====   R/S pins in design : [llength $sr]"
flush stdout

close_design
puts "==== DONE"
