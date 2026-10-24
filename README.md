# MoE FPGA Prototype - Pure Verilog

256-lane FP4 codebook GEMV on an ALINX AX7203B (`xc7a200tfbg484-2`), written in
Verilog-2001.  The multiply is replaced by a 16-way select over precomputed
shift-and-add products, so the design uses **zero DSP48**.

## Status

**V2: weights and activations are loaded at run time, not baked into the
bitstream.** Changing a model costs a reload, not a rebuild.

| | |
|---|---|
| Clock | 200 MHz, single domain |
| Timing | WNS **+0.145 ns**, WHS +0.029 ns |
| Resources | LUT 37,627 (28.1 %), FF 22,473 (8.4 %), BRAM 34.5 (9.5 %), **DSP 0** |
| One gate GEMV | 1,028 cycles = 5.14 us = **51 GMAC/s** at 100 % array utilisation |
| Weight capacity | 4 banks x 1024 x 256 bit = 131 KB (one expert's gate matrix) |
| Loading 131 KB | ~108 s over JTAG-AXI (AXI4-Lite has no bursts; one transfer per 4 bytes) |

Verified three independent ways, all agreeing on checksum `0xffffc6e2`:

1. **Simulation** - `scripts\sim.cmd loader`, 256 lanes byte-for-byte equal to
   `sim/data/ref_out.hex`, including a slow-consumer mode that forces the reply
   backpressure path.
2. **Independent golden model** - `scripts\golden.ps1`, a second implementation
   written from the RTL in PowerShell rather than Python, so a shared
   misunderstanding of the codebook cannot cancel out.
3. **Hardware** - five designed vectors (`scripts\hw_axi_designed.tcl`) whose
   expected values are derived from first principles and consult no model at all.

Details: `docs/verification.md`.

## Layout

```
rtl/include/moe_params.vh      global macros
rtl/core/                      fp4_select, fp4_product_gen, mac_lane,
                               mac_region, gemv_engine, expert_engine,
                               result_readout
rtl/mem/                       wbank_region, act_buffer, vec_buffer
rtl/ctrl/                      moe_loader (protocol FSM), weight_readback
rtl/bus/                       axil_loader_bridge (AXI4-Lite -> byte stream)
rtl/periph/                    uart_rx, uart_tx            (see Known gaps)
rtl/top/moe_proto_top.v        engine + readout
rtl/top/moe_proto_board.v      board wrapper: clock, UART/JTAG byte arbitration,
                               jtag_axi instantiation, status LEDs
constr/ax7203.xdc              pins and clocks
mem_init/expert0/gate_r*.mem   weight codes, used as TEST DATA only - the
                               memories configure empty and are filled at runtime
sim/tb/                        eight testbenches, see below
sim/data/                      stimulus and golden reference
scripts/                       build, simulation, programming, hardware tests,
                               diagnostics
docs/                          design notes, verification records, pin map
docs/ref/alinx_ax7203/         factory LED project (pin reference)
build/                         generated artefacts; see build/README.md
```

## Build

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\run_build.ps1
```

Logs go to `build/logs/vivado.log`.  **Expect 25-45 minutes**, and be aware that
`route_design` time is erratic on this design (499 s to 2355 s, occasionally not
converging at all) - see `docs/postmortem_readback_routing.md` for five controlled
experiments that failed to attribute it to any block.  If a build gets stuck, kill
it and run it again; the same source usually routes the second time.

`scripts\build_moe.tcl` has a `set WITH_AXI 0|1` switch near the top:

- `1` = compile the JTAG-AXI transport in.  **Requires a wider sandbox** when
  building under a confined environment, because `jtag_axi` forces Vivado to
  synthesise a `dbg_hub`, and that step hangs forever if a write is denied rather
  than failing.  See `docs/jtag_axi_findings.md`.
- `0` = UART-only, no `jtag_axi`, no `dbg_hub`.  Builds anywhere.

Cheaper entry points:

```powershell
vivado -mode batch -source scripts\build_moe_synth.tcl   # synthesis only, ~4 min
vivado -mode batch -source scripts\check_mem_infer.tcl   # assert memories config empty
```

## Simulate

```cmd
scripts\sim.cmd loader    :: THE main test - protocol, 256 lanes, slow consumer,
                          :: weight readback
scripts\sim.cmd axil      :: AXI bridge - register map, STATUS, reply FIFO
scripts\sim.cmd readout   :: result_readout only
scripts\sim.cmd engine    :: gemv_engine only, also dumps a waveform
scripts\sim.cmd board     :: board top
scripts\sim.cmd gl        :: gate level on the ROUTED netlist
scripts\sim.cmd uart      :: UART loopback (the test itself is flawed, see gaps)
```

`loader` and `axil` are the useful ones.  Run everything from the repository root -
the memories are loaded with relative paths by `$readmemh`, which resolves at
runtime, so a wrong working directory silently produces an empty memory rather
than an error.

Simulation artefacts are swept into `build/logs/<mode>/` so the root stays clean.

**No RTL file carries a `timescale`.** `xelab` therefore needs
`-timescale 1ns/1ps`, which `scripts\sim.cmd` passes for you.

## Program the board

```powershell
xsdb -no-ini -eval "source {D:/ai/moe_fpga_proto_verilog/scripts/xsdb_program_moe.tcl}"
```

Volatile configuration only - a power cycle restores the factory flash bitstream.

## Load a model and check the result

All three run over the JTAG cable and need the FPGA programmed first.

```powershell
# smoke test, seconds
vivado -mode batch -source scripts\hw_axi_test.tcl

# 131 KB of real weights + 2 KB activations, GEMV, 256-lane comparison (~2 min)
vivado -mode batch -source scripts\hw_axi_full_load.tcl

# five designed vectors, expected values derived by hand (~10 min)
vivado -mode batch -source scripts\hw_axi_designed.tcl
```

The designed vectors are the strongest evidence in the project:

| Test | Weights | Expected | What it pins down |
|---|---|---|---|
| T1 | all zero | every lane 0 | accumulator clear |
| T2 | every code = 2 (x1) | every lane = sum of activations | exactly 1024 rows accumulated |
| T3 | one-hot | **out[j] = x[j]** | lane mapping, nibble order, byte order, row addressing, sign extension |
| T4 | row 0 = codes 0..15 | out[j] = codebook[x[0]][j mod 16] | all 16 codebook entries |
| T5 | - | readback equals what T4 wrote | the readback path |

## Status LEDs

Active low.

| LED | Meaning |
|---|---|
| 1 | `weights_ready` (lit = loaded) |
| 2 | `act_valid` (lit = loaded) |
| 3 | `~busy` (lit = idle) |
| 4 | healthy heartbeat; **solid means `err_code != 0`** |

After a successful load: LEDs 1 and 2 lit, 3 off, 4 blinking.

## Host protocol

Frames are `A5 | cmd | len_hi | len_lo | payload | crc8`, CRC-8 polynomial 0x07.

| Code | Command | Payload |
|---|---|---|
| 0x01 | WRITE_W | region, addr_hi, addr_lo + 1024 x 32 B |
| 0x02 | WRITE_A | addr_hi, addr_lo + 1024 x 2 B |
| 0x03 | RUN | - |
| 0x04 | STATUS | - (replies 8 bytes) |
| 0x05 | READ_OUT | lane_start, nlanes-1 |
| 0x06 | READ_W | region, addr_hi, addr_lo, nrows-1 |

Register map at the AXI slave: `0x00` TXDATA, `0x04` STATUS, `0x08` RXDATA
(pops four reply bytes), `0x0C` RXCOUNT.

See `docs/v2_design.md` for the full protocol and `docs/jtag_axi_findings.md` for
the transport.

## Regenerating the memories

```bash
python3 scripts/gen_mem.py        # writes mem_init/expert0/gate_r*.mem and
                                  # sim/data/{input.mem,ref_out.hex}
python3 scripts/check_result.py   # compares a simulation output to ref_out.hex
```

Note: Python is broken in the current environment (exits with `0xC0000409`), so
these are kept for reproducibility rather than as working tools here.  The
generated files are checked in.  `scripts\golden.ps1` is a working replacement for
checking the result.

## Known gaps

Recorded so they are not mistaken for finished work:

- **Not a full MoE.** No router, no top-k, no second expert.  Only the gate GEMV
  is in the datapath; `gate -> up -> SiLU -> down` is not scheduled.
- **Not real FP4.** The codebook is integer shift multiples with no exponent
  alignment, and the per-lane scaling stage from the reference architecture is not
  implemented.
- **UART is unverified on hardware.** Both directions work in simulation
  (`scripts\sim.cmd uart`, which also drives a STATUS command through the loader),
  but nothing has been tried against a real USB-serial adapter - the baud rate
  above 115200 is untested, and the pins P20/N15 come from the vendor's demo
  rather than from a scope.  JTAG-AXI is the transport that has been proven on
  silicon.
- **One expert only.** 131 KB of weight storage fits one gate matrix.  See
  `docs/resource_assessment.md` for the projection to a full expert.
- **`route_design` is erratic.** 499-2355 s with occasional non-convergence, not
  attributable to any single block by five controlled experiments.  See
  `docs/postmortem_readback_routing.md`.
- **Timing headroom is thin.** WNS +0.145 ns.  Check it after every RTL change;
  do not assume there is room.
