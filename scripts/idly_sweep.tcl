open_hw
connect_hw_server -url localhost:3121
open_hw_target
set dev [lindex [get_hw_devices] 0]
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev
set axi [lindex [get_hw_axis] 0]
puts "TAP  READBACK  PINGS_OK"
for {set tap 0} {$tap < 32} {incr tap} {
    set hex [format %02x $tap]
    catch {delete_hw_axi_txn sw}
    create_hw_axi_txn sw $axi -address 00000010 -data 000000$hex -type write
    run_hw_axi [get_hw_axi_txns sw]
    catch {delete_hw_axi_txn sr}
    create_hw_axi_txn sr $axi -address 0000002c -type read -len 1
    run_hw_axi [get_hw_axi_txns sr]
    set rb [get_property DATA [get_hw_axi_txns sr]]
    catch {exec cmd.exe /c "arp -d 192.168.8.6"}
    set ok 0
    catch {
        set out [exec cmd.exe /c "ping -n 8 -w 400 192.168.8.6"]
        foreach line [split $out \n] {
            if {[regexp {Received = (\d+)} $line -> n]} { set ok $n }
        }
    }
    puts [format "%3d  %s      %d" $tap $rb $ok]
}
close_hw_target
disconnect_hw_server
exit 0
