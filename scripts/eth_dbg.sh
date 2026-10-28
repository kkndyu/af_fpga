#!/bin/bash
# -----------------------------------------------------------------------------
# eth_dbg.sh  -  read the Ethernet bring-up counters over JTAG, from cygwin
# -----------------------------------------------------------------------------
#   ./scripts/eth_dbg.sh            read the counters only
#   ./scripts/eth_dbg.sh flash      reprogram (clears the counters), then read
#   ./scripts/eth_dbg.sh ping       send 10 ARP requests, then read
#   ./scripts/eth_dbg.sh flash ping clear, generate traffic, then read
#
# Notes on running Vivado from cygwin
#   bin/vivado (the shell launcher) is used, not vivado.bat.  Driving the .bat
#   through "cmd //c" opens an interactive shell instead of running anything,
#   because cygwin rewrites the /c.
#
#   The -source argument must be a WINDOWS path.  Vivado is a Windows program and
#   its Tcl cannot open /cygdrive/... , so the script path is passed as D:/...
#   while bash itself stays on the /cygdrive view.
#
#   -notrace keeps Vivado from echoing every Tcl command into the output.
# -----------------------------------------------------------------------------
set -u

ROOT=/cygdrive/d/ai/moe_fpga_proto_verilog
VIVADO=/cygdrive/d/Xilinx/Vivado/2019.1/bin/vivado
XSDB=/cygdrive/d/Xilinx/SDK/2019.1/bin/xsdb
SRC_WIN=D:/ai/moe_fpga_proto_verilog/scripts
FPGA_IP=192.168.8.6

cd "$ROOT" || exit 1

do_flash() {
    echo "== reprogramming (clears every counter) =="
    "$XSDB" -no-ini -eval "source {$SRC_WIN/xsdb_program_moe.tcl}" 2>&1 |
        grep -E 'programmed OK|ERROR' || true
    echo
}

do_ping() {
    echo "== sending ARP requests to $FPGA_IP =="
    ping -n 10 "$FPGA_IP" 2>&1 | tail -4
    echo
    echo "== PC ARP table =="
    arp -a 2>&1 | grep -E '192\.168\.8\.' || echo "  (no 192.168.8.x entry)"
    echo
}

do_read() {
    echo "== reading counters =="
    "$VIVADO" -mode batch -nolog -nojournal -notrace \
        -source "$SRC_WIN/eth_dbg.tcl" 2>&1 |
        sed -n '/Ethernet counters/,/^=\{10,\}$/p'
}

for arg in "$@"; do
    case "$arg" in
        flash) do_flash ;;
        ping)  do_ping  ;;
    esac
done

do_read
