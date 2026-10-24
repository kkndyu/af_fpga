# How the input and the output are verified

What is actually proven about the data path, what is only inferred, and the
second opinion that removes the "both implementations share the same
misunderstanding" worry.

## The chain

```
scripts/gen_mem.py                (Python, seed 7)
   |-- sim/data/input.mem                  1024 x 16 bit   activations
   |-- mem_init/expert0/gate_r{0..3}.mem   4 x 1024 x 256 bit   weights
   `-- sim/data/ref_out.hex                256 x 32 bit   golden output
                    |
                    |  over JTAG-AXI, CRC-8 checked frame by frame
                    v
              moe_loader -> weight banks -> 256-lane FP4 GEMV
                    |
                    v
     256 lanes read back over AXI, compared lane by lane
```

## What each stage actually proves

| Claim | Strength | Evidence |
|---|---|---|
| bytes arrive intact | **direct** | CRC-8 per frame; one wrong bit and the loader answers `ERR_CRC` |
| the loader accepted four banks | **direct** | `weights_ready` / `act_valid` |
| the bytes landed at the right addresses | **direct** | weight readback, `CMD_READ_W` (0x06) - see below |
| the arithmetic is right | **direct** | 256 lanes compared one by one |
| the reference itself is right | **second opinion** | `scripts/golden.ps1` |
| the model is right | **first principles** | designed vectors T1-T4, see below |

### Weight readback (`CMD_READ_W`)

The weight memories used to be unobservable: `wbank_region` has one write port and
one compute read port, and both are always in use. What makes readback possible
without extra memory is that the read port is *idle whenever the engine is*, and
all four banks share `rd_en` and the address. So a small module drives that port
directly, captures one 256-bit row from its registered output, and serialises it
into bytes.

```
0x06  W  READ_W   payload: region, addr_hi, addr_lo, nrows-1
                  reply:   nrows x 32 bytes, most significant byte first
                           (same order as the .mem file, so a diff is trivial)
```

Cost: a mux, not a RAM. `rtl/ctrl/weight_readback.v` lives inside `gemv_engine`
next to the banks - see `docs/postmortem_readback_routing.md` for why putting it
in the loader instead cost two hours of place-and-route.

### Designed test vectors

`scripts/hw_axi_designed.tcl`. Every expected value here is derived from first
principles; none of them consult a model, so a shared misunderstanding has nowhere
to hide.

| Test | Weights | Expected | What it pins down |
|---|---|---|---|
| **T1** | all zero | every lane 0 | accumulator clear, no stale data |
| **T2** | every code = 2 (x1) | every lane = sum of all activations | exactly 1024 rows accumulated, none skipped or doubled |
| **T3** | one-hot: lane j has code 2 only at row j | **out[j] = x[j]** | lane->region mapping, nibble order in a row, big-endian bit layout, row addressing, sign extension, all at once |
| **T4** | row 0 holds nibbles 0,1,2,...15,0,1,... | out[j] = codebook[x[0]][j mod 16] | all 16 codebook entries through real hardware |
| **T5** | - | readback equals what T4 wrote | the readback path itself |

T3 is the strongest single check: its expected value is literally the input file,
so any mapping error changes the answer.

Result on hardware:

```
T1: PASS (256/256)
T2: PASS (256/256)          sum of activations = -926
T3: PASS (256/256)
T4: PASS (256/256)          x[0] = 9 -> lanes 0..15 = 0 4 9 13 18 36 2 0 0 -4 -9 -13 -18 -36 -2 0
T5: PASS (32/32 bytes)      readback matches the row T4 wrote
RESULT: ALL DESIGNED VECTORS PASSED
```

The T4 numbers are worth reading: with `x[0] = 9` the sixteen lanes are
`9/2=4`, `9`, `9+4=13`, `9*2=18`, `9*4=36`, `9/4=2`, then the negated set. Each one
is checkable by hand, which is the whole point.

## The second implementation

`sim/data/ref_out.hex` comes from `gen_mem.py`, which says in its own header that
the codebook "mirrors rtl/core/fp4_product_gen.v". If both were wrong in the same
way they would still compare equal, so agreement proves nothing about correctness
of the model - only about RTL matching its own description.

`scripts/golden.ps1` is a second implementation written from the RTL:

- **PowerShell, not Python.** Different language, different integer semantics -
  64-bit by default, so the 32-bit wrap is applied explicitly rather than by
  masking arbitrary-precision integers.
- **codebook transcribed from `fp4_product_gen.v`**, not from the Python.
- **lane mapping derived from `result_readout.v` and `mac_region.v`**, not from the
  generator:
  - lane `j` -> region `floor(j/64)`, local lane `j mod 64`
    (`acc_flat[g*2048 + lane_lo*32 +: 32]`)
  - local lane `i` -> nibble `i` of the row (`wcode_d[i*WCODE_W +: WCODE_W]`)
  - the `.mem` line is MSB first, so nibble `i` is hex character `63 - i`

Result:

```
checksum over 256 lanes = FFFFC6E2
mismatches vs ref_out.hex = 0 of 256
RESULT: two independent implementations agree
```

and the hardware returns the same `FFFFC6E2`. Three implementations - Python
reference, independent PowerShell model, and the FPGA - agree.

## Proving the check can fail

A test that always passes is worth nothing, so both subtle points were deliberately
broken and the model was required to notice:

| Mutation | Mismatches | Checksum |
|---|---|---|
| `1.5a` computed as round(1.5a) instead of the hardware's `a + (a >>> 1)` | **233 / 256** | `FFFFC5AD` |
| lane mapping reversed (nibble taken from the wrong end of the row) | **256 / 256** | **`FFFFC6E2` - unchanged** |

Two things follow.

**The arithmetic-shift subtlety is load-bearing.** `a_x_1p5 = a_ext + (a_ext >>> 1)`
is an arithmetic shift, so for negative `a` it is `a + floor(a/2)`, not `1.5a`. Get
it wrong and 233 of 256 lanes move.

**The checksum is invariant under lane permutation.** It is a sum, so a completely
scrambled lane order produces the identical `FFFFC6E2`. Reporting only a checksum
would therefore hide the single most likely wiring mistake. The per-lane comparison
is what catches it, and both are needed.

## Still open

1. **Back-to-back READ_OUT.** A single 256-lane readout is verified on hardware, as
   is a multi-row weight readback, but two full READ_OUT commands in a row have not
   been exercised. The readout FSM is re-armed per command (`rd_have_prev` is
   cleared on restart) so it should work; it just has not been run.
2. **Long-run stability.** Every JTAG-AXI run here loaded a few hundred kilobytes at
   most. Nothing has run continuously for hours, so marginal timing
   (WNS +0.049 ns) has not been stressed over temperature.
3. **Designed vectors for the other two GEMVs.** T1-T5 exercise the gate GEMV only.
   The up and down GEMVs in the expert sequence are not in the datapath yet.

## Timing headroom is thin

The design closes at 200 MHz with **WNS +0.049 ns** and WHS +0.048 ns. Before the
readback feature it was +0.190 ns. The 0.14 ns went to the readback's control path,
and one further regression (-0.034 ns) was fixed by putting a one-entry skid buffer
between the engine's byte-valid output and the loader's FIFO push logic.

Anything added from here should be assumed to cost margin. Check `WNS` after any
RTL change rather than assuming there is room.

## Reproducing

```powershell
# independent golden model (about 3 s)
powershell -NoProfile -File scripts/golden.ps1

# hardware: 131 KB load, GEMV, 256-lane comparison against ref_out.hex (about 2 min)
vivado -mode batch -source scripts/hw_axi_full_load.tcl

# hardware: designed vectors T1-T5, no model involved (about 10 min)
vivado -mode batch -source scripts/hw_axi_designed.tcl

# simulation: loader protocol, 256 lanes, slow consumer, weight readback
scripts\sim.cmd loader
```

`golden.ps1` writes `sim/data/golden_ps.hex`, so it can be diffed against
`ref_out.hex` directly. Note that a mutant copy of the script would overwrite it -
re-run the real one before trusting the file.

`hw_axi_designed.tcl` needs the wider sandbox, like every JTAG-AXI hardware run,
because it starts `hw_server`. Building the bitstream that contains `jtag_axi`
needs it too - see `docs/jtag_axi_findings.md`.
