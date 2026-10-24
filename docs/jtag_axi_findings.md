# JTAG-AXI: runtime loading without any pins

Complete record of the JTAG-to-AXI transport: what it is, how to run it, and the
bugs it took to make it work. Written down because most of them were non-obvious
and two were repeat mistakes from earlier in this project.

## Outcome

The whole model now loads from the host over the JTAG cable, and the result is
verified lane by lane:

```
STATUS after load = 00000003          weights_ready=1, act_valid=1
read 256 lanes
checksum over returned lanes = FFFFC6E2   (expected FFFFC6E2)
mismatched lanes: 0 of 256
RESULT: FULL LOAD PASSED - all 256 lanes match ref_out.hex
```

131 KB of weights (4 banks x 1024 rows) plus a 2 KB activation vector, pushed as
about **32,800 single-beat AXI writes in 108 s**, then one GEMV, then 256 AXI
reads compared against `sim/data/ref_out.hex`.

Bitstream: `4C2448B8A235DA35A3882D86A005995DDA88FD9C712E6AB688A870C07491FD78`
LUT 37,371 (27.93 %)  FF 21,856 (8.17 %)  BRAM 34.5 tiles  DSP 0  IOB 9
WNS +0.190 ns  WHS +0.017 ns.

## Architecture

```
host Vivado Tcl  (create_hw_axi_txn / run_hw_axi)
   |
   v
hw_server --JTAG--> BSCANE2 --> dbg_hub --> jtag_axi (generated IP, AXI4-Lite master)
                                            |
                                            v
                              axil_loader_bridge   (register file -> byte stream)
                                            |
                                            v
                                  moe_loader       (frames, CRC, memories)
                                            |
                          +-----------------+------------------+
                          v                 v                  v
                    weight banks      activation bufs      engine / readout
```

The bridge is the only new design; everything downstream already existed and was
verified by `scripts/sim.cmd loader`.

### Register map (32-bit words)

| Offset | Type | Name | Meaning |
|---|---|---|---|
| 0x00 | W | TXDATA | write 32 bits -> four bytes pushed LSB-first into the loader |
| 0x04 | R | STATUS | `[0]` weights_ready `[1]` act_valid `[2]` busy `[15:8]` err_code |
| 0x08 | R | RXDATA | pops four reply bytes (side effect: poll RXCOUNT first) |
| 0x0C | R | RXCOUNT | bytes available in the reply FIFO |

### Frame format

Unchanged from `docs/v2_design.md`: `0xA5 | cmd | len_hi | len_lo | payload | crc8`,
CRC-8 polynomial 0x07 init 0 over cmd/len/payload. The host recomputes it; see
`crc8` in `scripts/hw_axi_test.tcl`.

## Running it

```powershell
# 1. generate the IP once
vivado -mode batch -source scripts/gen_jtag_axi.tcl

# 2. build with the transport compiled in  (WITH_AXI 1 in build_moe.tcl)
#    NOTE: needs the sandbox widened - see below
powershell -File scripts/run_build.ps1

# 3. program
xsdb -no-ini -eval "source scripts/xsdb_program_moe.tcl"

# 4. smoke test (four checks, seconds)
vivado -mode batch -source scripts/hw_axi_test.tcl

# 5. full model load and 256-lane verification (about 2 minutes)
vivado -mode batch -source scripts/hw_axi_full_load.tcl
```

## The sandbox blocks the build, and Vivado hangs instead of failing

`jtag_axi` registers itself as a debug core:

```
get_debug_cores  ->  dbg_hub, u_jtag_axi
```

so `opt_design` has to synthesise a `dbg_hub`, assembled on the fly from
`axi_dbg_hub_v1_0` + `xsdbm_v3_0`. **Neither can be created standalone** - both
report "restricted for IP Integrator subcore use only". That generation step needs
to write outside the workspace, and under the workspace-write sandbox the write is
denied.

**Vivado does not report the denial - it waits forever.** The evidence:

| Observation | Sandboxed | Sandbox widened |
|---|---|---|
| `opt_design` | 30+ min, no progress | **201-256 s, completes** |
| Parent CPU during the wait | ~300 s over 30 min, no child process | normal |
| dbg_hub artifacts | none created at all | generated |
| Full build | never reached P&R | **BUILD OK** |

Same design, same Vivado, same command line; the only variable was the sandbox.

**Consequence:** `build_moe.tcl` has `set WITH_AXI 0` by default so the project
still builds anywhere; `1` requires the wider sandbox.

### Ruled out - do not re-investigate

- stale `hw_server` holding the cable: none running, ports 3121/3042 free
- `xsdbm` generatable alone: no, refused fast (an error, not a hang)
- `axi_jtag` as an alternative IP: same restriction
- merely slow: the full 27k-LUT design synthesises in 4.5 minutes
- OOC `.dcp` instead of `.xci`: `synth_design` only reads RTL, so the DCP is never
  linked and elaboration fails with `module jtag_axi_v1_2_9_jtag_axi not found`
- `jtag_axi` PROTOCOL: valid values are **0 (full AXI4) and 2 (AXI4-Lite)**, not 0
  and 1; the default 0 produces `awlen/awsize/awburst` that a register bridge
  cannot serve. `CONFIG.SIGNAL_CLOCK.FREQ_HZ` defaults to 100 MHz and must be set
  to this board's 200 MHz.

## The bugs

### 1. Bridge sent `[b0, b0, b1, b2]` - stale index in a register assignment

```verilog
// wrong
s_axis_tdata  <= tx_word[tx_idx*8 +: 8];   // same block increments tx_idx
s_axis_tvalid <= 1'b1;
```

The expression sampled the *old* `tx_idx`, so each 32-bit word left as first byte
twice and last byte never. Every frame arrived one byte out of step and the loader
correctly rejected it as `ERR_BAD_CMD (0x03)`.

Fix: drive it combinationally, `assign s_axis_tdata = tx_word[tx_idx*8 +: 8];`.

### 2. Bridge status ports were left unconnected

```verilog
.weights_ready(), .act_valid(), .busy(), .err_code()   // all empty
```

So the STATUS **register** read back all zeros forever, while the STATUS
**command** still worked - the command reply comes through the loader's own byte
FIFO, not through this register. A board that says "healthy" no matter what has
gone wrong is worse than one that says nothing at all.

### 3. `rx_rp <= rx_rp + 2'd4` - a 2-bit literal cannot hold 4

It truncates to 0, so the reply FIFO read pointer never moved and every `RXDATA`
read returned the same four bytes. The tell was `rx_cnt` counting down correctly
(8 -> 4 -> 0) while `rx_rp` stayed pinned at 0: two counters, one moving, one not.

**This is the second time in this project.** The first was
`localparam [10:0] SETTLE_CYCLES = 11'd2048` in `moe_proto_board.v`. Any literal
whose width cannot represent its value silently becomes something else - always
size a literal from the value, not from habit.

### 4. Loader pushed the same byte on every paused cycle

`result_push` fired on `rd_valid`. When `rd_pause` freezes the readout, `rd_valid`
and `rd_data` both hold, so the same byte was pushed repeatedly - the reply came
back as `B7 B7 B7 B7`. On JTAG-AXI a reply byte is consumed about once per
millisecond while the readout offers one per six clocks, so the pause is asserted
almost permanently.

Fix: take a byte only when the readout actually advances, detected by watching
`(rd_lane, rd_byte)` for a change. In the fast case they change every cycle and
behaviour is identical.

### 5. Testbench slow-mode registers uninitialised

`slow_mode` / `slow_div` were X, so `m_axis_tready` went X and not one reply byte
transferred - which looks exactly like a broken design.

## The test needs a slow consumer

The most important methodological point here. `rd_pause` **never asserts** when the
reply is drained as fast as it is produced, which is what every earlier testbench
did. That is why bug 4 survived simulation: the test could not reach the state the
hardware is always in.

`sim/tb/tb_loader.v` now has a slow-consumer mode that holds `m_axis_tready` low
255 cycles out of 256, forcing the loader FIFO to fill and `rd_pause` to assert:

```
LOADER TB: reading back 256 lanes (slow consumer: tready 1-in-256)...
LOADER TB: received 1024 bytes (expect 1024)
LOADER TB: PROTOCOL TESTS PASSED        all 256 lanes match ref_out.hex
```

Any change to the readout or the reply path must be checked with this mode on.

## What the board shows

`led[0..3] = ~weights_ready, ~act_valid, ~busy, (err_code==0) ? blink : 0`, active
low. After a successful load:

| LED | Meaning | Loaded state |
|---|---|---|
| 1 | weights_ready | **lit** |
| 2 | act_valid | **lit** |
| 3 | ~busy | off |
| 4 | healthy heartbeat | **blinking** |

LED 4 solid rather than blinking means `err_code != 0`. This is an independent
confirmation of the load: it is driven straight from the loader, not through the
AXI status register, so if the status ports were still unconnected the LEDs would
be right and the register read wrong.

## Known limitations

- **AXI4-Lite has no bursts**, so every 4 bytes costs one transaction. Loading
  131 KB takes 108 s. A burst-capable `jtag_axi` (PROTOCOL 0) plus burst support in
  the bridge would cut this by roughly 100x, at the cost of rewriting the bridge to
  honour `awlen`/`awsize`/`wlast`.
- **The host side is a Vivado Tcl session.** `hw_axi` only exists inside Vivado's
  hardware manager, so this is a debug and validation back door, not a product
  interface. The real data path remains Ethernet.
- **Volatile configuration.** The bitstream is programmed over JTAG, not written to
  flash, so a power cycle erases it and the board must be reprogrammed. A stale
  `hw_server` holding the cable also breaks reprogramming with
  `error DR shift through all ones` - kill it first.
