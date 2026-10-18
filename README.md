# MoE FPGA Prototype - Pure Verilog

256-lane FP4 codebook GEMV on an ALINX AX7203B (`xc7a200tfbg484-2`), written in
Verilog-2001.  The multiply is replaced by a 16-way select over precomputed
shift-and-add products, so the design uses **zero DSP48**.

## Status

Verified on hardware at 50, 100 and 200 MHz.  At 200 MHz the engine computes one
1024x256 GEMV in 1,028 cycles (5.14 us) at ~100 % array utilisation, which is
**51 GMAC/s**, and the on-chip checksum matches the golden value
(`0xffffc6e2`).  Timing closes at 200 MHz with **+0.248 ns** of margin.

Resource use: 26.6 % LUTs, 6.8 % flip-flops, 9.3 % block RAM, **0 DSPs**.

See `docs/hardware_verification.md` for the evidence chain, the bugs found along
the way, and an explicit list of what this does and does NOT prove.

## Layout

```
rtl/include/moe_params.vh      global macros
rtl/core/                      fp4_select, fp4_product_gen, mac_lane,
                               mac_region, gemv_engine, expert_engine,
                               result_readout
rtl/mem/                       wbank_region, act_buffer, vec_buffer
rtl/top/moe_proto_top.v        engine + readout
rtl/top/moe_proto_board.v      board wrapper: clock divider, start sequencer,
                               LED verdict
constr/ax7203.xdc              pins and clocks
mem_init/expert0/gate_r*.mem   weight codes (4 banks x 1024 x 256 bit)
sim/tb/                        four testbenches, see below
sim/data/                      stimulus and golden reference
scripts/                       build, simulation, programming, probes
docs/                          design notes, verification record, pin map
docs/ref/alinx_ax7203/         factory LED project (pin reference)
build/                         generated artefacts; see build/README.md
```

## Build

```powershell
# synth -> opt -> place -> route -> bitstream, checkpoint after every stage
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\run_build.ps1
```

Logs go to `build/logs/vivado.log` and can be tailed while it runs; the full flow
takes roughly 35 minutes.  Cheaper entry points:

```powershell
vivado -mode batch -source scripts\build_moe_synth.tcl   # synthesis only, ~4 min
vivado -mode batch -source scripts\timing_probe.tcl      # worst paths at an
                                                         # aggressive 250 MHz
```

## Simulate

```cmd
scripts\sim.cmd readout    :: moe_proto_top - 256-lane comparison + checksum
scripts\sim.cmd board      :: board top - checksum and the LED PASS/FAIL verdict
scripts\sim.cmd engine     :: gemv_engine only, also dumps a waveform
scripts\sim.cmd gl         :: gate level on the ROUTED netlist
```

`readout` and `board` are the useful ones.  `gl` needs the netlist exported
first (`scripts/netlist_sim.tcl`) and exists to prove that synthesis did not
change the logic - it is what distinguished a timing failure from an arithmetic
one during bring-up.

Simulation artefacts are swept into `build/logs/<mode>/` so the repository root
stays clean.

## Program the board

```powershell
xsdb -no-ini -eval "source {D:/ai/moe_fpga_proto_verilog/scripts/xsdb_program_moe.tcl}"
```

Volatile configuration only - a power cycle restores the factory flash bitstream.

The four LEDs are **active low** and show a self-judging verdict after the single
GEMV completes:

| Pattern | Meaning |
|---|---|
| LED1 + LED2 blinking | PASS, checksum equals the golden value |
| LED3 + LED4 blinking | FAIL |
| nothing lit | still running, or not configured |

Two LEDs per verdict on purpose, so one dead LED still leaves the answer readable.

## Regenerating the memories

```bash
python3 scripts/gen_mem.py        # writes mem_init/expert0/gate_r*.mem and
                                  # sim/data/{input.mem,ref_out.hex}
python3 scripts/check_result.py   # compares a simulation output to ref_out.hex
```

Note: Python is broken in the current environment (exits with
`0xC0000409`), so these are kept for reproducibility rather than as working
tools here.  The generated files are checked in.

## Known gaps

Recorded so they are not mistaken for finished work:

- **Not a full MoE.** No router, no top-k, no second expert, no
  `gate -> up -> SiLU -> down` schedule.  This is the compute slice only.
- **Not real FP4.** The codebook is integer shift multiples with no exponent
  alignment, and the per-lane scaling stage from the reference architecture is
  not implemented.
- **Weights are frozen at synthesis.** `wbank_region` has no write port, so
  changing models means re-synthesising.
- **Two experts do not fit.** 384 RAMB36E1 needed against 365 available; see
  `docs/resource_assessment.md` for the `OBLOCK` fix.
- **No RTL file carries a `timescale`.** `xelab` therefore needs
  `-timescale 1ns/1ps`, which `scripts/sim.cmd` passes for you.
