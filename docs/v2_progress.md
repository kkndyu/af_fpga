# V2 progress - runtime loading, transports, and what is still open

State as of the JTAG-AXI session. Written down because a lot was learned the hard
way and none of it should have to be learned twice.

## Working and verified

| Item | Evidence |
|---|---|
| `rtl/ctrl/moe_loader.v` | `sim.cmd loader`: 4 x 1024 weight rows + activations loaded, RUN, 256 lanes byte-for-byte equal to `sim/data/ref_out.hex` |
| Slow-consumer mode | same test with `m_axis_tready` held low 255 of 256 cycles, forcing `rd_pause` to assert - still all 256 lanes correct. This is the mode that matters; the fast one cannot reach the hardware's actual state |
| Protocol guards | RUN before load -> `ERR_NOT_LOADED` (02); corrupted frame -> `ERR_CRC` (01) and the data is invalidated; RUN after that -> `ERR_NODATA` (05) |
| `rtl/mem/wbank_region.v` | `check_mem_infer.tcl`: 36 RAMB primitives, capacity 1,179,648 bits for 1,114,112 needed, **every INIT_* configures empty** |
| `rtl/bus/axil_loader_bridge.v` | `sim.cmd axil`: `ALL TESTS PASSED`; write path, STATUS register, reply FIFO and RXCOUNT all correct |
| **`jtag_axi` transport on hardware** | `hw_axi_test.tcl`: `ALL JTAG-AXI TESTS PASSED` - RUN frame arrives intact, STATUS register and reply both correct |
| **Full model load on hardware** | `hw_axi_full_load.tcl`: 131 KB of weights + 2 KB activations over ~32,800 AXI writes in 108 s, RUN, 256 lanes read back, **0 mismatches**, checksum `FFFFC6E2` |
| `rtl/top/moe_proto_board.v` | built and running; LED pattern after load matches the expected `weights_ready=1, act_valid=1, err=0` |
| `constr/ax7203.xdc` | UART P20/N15 and the four LEDs all built and confirmed on the board |
| **Weight readback** | `CMD_READ_W` (0x06) reads rows straight out of the weight banks. Sim: 128/128 bytes equal `gate_r0.mem`. Hardware: T5, 32/32 bytes |
| **Independent golden model** | `scripts/golden.ps1` (PowerShell, written from the RTL) agrees with `gen_mem.py` on all 256 lanes, checksum `FFFFC6E2` |
| **Designed test vectors** | `hw_axi_designed.tcl` T1-T5 all pass on hardware, expected values derived from first principles with no model involved |

Bitstream `CA5FB7B91D955967...` (full hash in `build/moe/out`), LUT 37,756 (28.22 %),
FF 22,165 (8.28 %), BRAM 34.5, DSP 0, **WNS +0.049 ns**, WHS +0.048 ns.

**Timing headroom is now thin.** It was +0.190 ns before the readback feature. Read
`docs/verification.md` before adding anything: check WNS after every RTL change.

Details of the transport, including the five bugs it took to get there, are in
`docs/jtag_axi_findings.md`. The one change that made place-and-route pathologically
slow, and why, is in `docs/postmortem_readback_routing.md`.

## Written but NOT yet verified

| Item | State |
|---|---|
| `rtl/periph/uart_tx.v` | **fixed** - `bit_idx` was `reg [2:0]` but the shift phase steps it to 8 to select the stop bit, so 7+1 wrapped to 0 and the stop-bit branch was unreachable: the transmitter re-sent the same byte forever. Loopback now passes for 5A A5 00 FF and a STATUS command returns its 8-byte reply. Unverified on hardware. |
| Readout in a tight loop | a single READ_OUT of 256 lanes is verified, as is a multi-row weight readback; two full READ_OUT commands in a row have not been exercised |
| Up / down GEMVs | only the gate GEMV is in the datapath; the rest of the expert sequence is not built |

## Things learned that are worth keeping

**A wide bus is a global placement constraint, not a local cost.** Putting the
weight-readback serialiser inside `moe_loader` instead of `gemv_engine` added only
200 flip-flops - the design got *smaller* by 114 LUT - and took `route_design` from
499 s to over two hours, because a 256-bit star between four far-apart banks and the
loader compromised the placement of everything else. Moving the serialiser next to
the banks brought it back to 550 s. Full postmortem in
`docs/postmortem_readback_routing.md`.

**A streaming loader cannot roll back.** The original V2 design said a bad frame
would be "committed in full or aborted before its first row". That is impossible
without buffering the entire payload: the bytes are already in the memory by the
time the CRC arrives. The guarantee that IS achievable is invalidation - clear the
validity flag of whatever the frame was writing, and refuse the next RUN. That is
what the loader does now, and it is why `ERR_NODATA` (0x05) exists.

**A memory with no write activity is a constant and gets folded away.** Tying the
load ports to zero made synthesis delete the whole engine: RAMB count dropped from
36 to 6. Fine for the board (it only has to report state), fatal for any claim
about memory inference - hence `check_mem_infer.tcl`, which synthesises
`moe_proto_top` where the write ports are real inputs.

**`INIT_FILE` is not an initialisation data property.** A RAMB primitive exposes
`INIT_00..INIT_7F`, `INITP_00..INITP_0F` **and** `INIT_FILE`, whose default value
is the string `NONE`. A prefix match on `INIT*` therefore reports every memory as
carrying data. Match `^INITP?_[0-9A-Fa-f]+$`.

**Vivado 2019.1 uses `open_hw`, not `open_hw_manager`.** The latter arrived in a
later release. An earlier note in this project concluded "labtools is missing"
from that error; it was wrong, and it wrongly ruled out JTAG-to-AXI for a while.
`create_hw_axi_txn` and `run_hw_axi` are present and `connect_hw_server` reaches
the Digilent HS1.

**`jtag_axi` PROTOCOL: 0 is full AXI4, 2 is AXI4-Lite.** The default (0) produced a
master with `awlen/awsize/awburst/awid`, which a simple register bridge cannot
serve. Valid values are 0 and 2 only. The real parameter names are
`CONFIG.PROTOCOL`, `CONFIG.M_AXI_ADDR_WIDTH`, `CONFIG.M_AXI_ID_WIDTH`,
`CONFIG.SIGNAL_CLOCK.FREQ_HZ` - not the `C_*` names one might guess, and the clock
defaults to 100 MHz which is wrong for this board.

**Testbench handshake races cost more time than the RTL.** Three separate hangs in
this session came from drivers changing AXI or valid/ready signals with blocking
assignments in the same delta as a posedge the DUT was sampling. Drive on the
negedge, or add `#1` after the posedge, and always put a watchdog in the
testbench: a hung simulator produces no log at all, which looks exactly like a
slow one.

**Check a literal's width against its value, every time.** Two separate bugs in
this project were the same mistake: `localparam [10:0] SETTLE_CYCLES = 11'd2048`
in `moe_proto_board.v`, and `rx_rp <= rx_rp + 2'd4` in the AXI bridge. Both
silently became something other than what was written, and both took a long time
to find because the symptom looked like something else entirely. Size a literal
from the value, not from habit.

**A bug that needs a slow consumer will never show up in a fast testbench.**
`rd_pause` only asserts when the reply is drained slower than it is produced. Every
testbench drained instantly, so the loader's duplicate-byte bug was invisible for
the whole project and only appeared on the JTAG path, where a reply byte takes
about a millisecond. When a design has a backpressure path, the test must drive it.

**Vivado hangs instead of failing when a write is denied.** The `dbg_hub`
generation step that `jtag_axi` forces blocked for 30+ minutes under the
workspace-write sandbox with no error, no child process and almost no CPU use. The
same build completed in 201 s with the sandbox widened. `build_moe.tcl` therefore
defaults to `WITH_AXI 0`, which needs no debug hub and builds anywhere.

## Next steps, in order

1. **Ethernet.** It is the actual product data path and the only transport that
   matters for the target hardware. JTAG-AXI is a debug back door - it requires a
   live Vivado Tcl session on the host, so it cannot be the operating interface.
2. **Recover timing headroom.** WNS is +0.049 ns; it was +0.190 ns before the
   readback. Every remaining feature has to fit in that margin, so this is worth
   effort before adding more logic. Levers: multicycle paths on the readout,
   registering further along the loader's FIFO push, or a lower clock for the loader.
3. **Burst loading**, if JTAG loading speed matters for day-to-day use: AXI4-Lite
   costs one transaction per 4 bytes, so 131 KB takes 108 s. PROTOCOL 0 plus
   `awlen`/`wlast` support in the bridge would cut that by roughly 100x.
4. `uart` on real hardware, if a pin-based fallback transport is still
   wanted. Both directions now pass in simulation; nothing has been tried
   against a USB-serial adapter.