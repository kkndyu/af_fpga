# XC7A200T (AX7203) Resource Realisability Assessment

OOC synthesis results for the MoE FPGA prototype, Vivado 2019.1, part
`xc7a200tfbg484-2`. No RTL was modified for this assessment.

Reproduce with:

```
vivado -mode batch -source scripts/ooc_layer1_mac_array.tcl
vivado -mode batch -source scripts/ooc_layer2_wbank.tcl
vivado -mode batch -source scripts/ooc_layer3_expert.tcl
```

Raw reports: `build/ooc/layer{1,2,3}/summary.txt`

---

## 1. Measured results per layer

| Layer | Scope | LUT | FF | DSP | BRAM36E1 | BRAM Tile |
|---|---|---|---|---|---|---|
| 1 | one `mac_region` (64 lanes) + `fp4_product_gen` + `fp4_select` | 7,722 (5.74%) | 2,048 (0.76%) | **0** | 0 | 0 |
| 2 | one `wbank_region`, 1024 × 256 bit | 52 (0.04%) | 1 | **0** | **8** | 8 (2.19%) |
| 3 | `expert_engine` as built (1 gate GEMV, 4 banks) | 30,587 (22.72%) | 8,209 (3.05%) | **0** | **32** | 32.5 (8.90%) |

Device: 134,600 LUT / 269,200 FF / 740 DSP / 365 RAMB36 / 285 IOB.

### Layer 1 detail

64 lanes × 32-bit accumulator = 2,048 FF, exactly as expected. The array is
purely combinational apart from the accumulators. **DSP48 count is zero** — the
product generator uses shifts and adds, and the "multiply" is a 16:1 mux.

Scaling to the full 256-lane array (4 regions) gives approximately
**30,888 LUT / 8,192 FF / 0 DSP**, which matches the layer-3 measurement.

### Layer 2 detail

One 1024 × 256-bit bank:

```
262,144 bits / 32,768 usable bits per RAMB36E1 = 8
```

Measured: exactly **8 RAMB36E1**, all eight carrying non-zero `INIT_*` data, so
the `$readmemh` weight payload is genuinely synthesised into the primitives.

Width slicing is why 8 primitives are needed for a single bank: RAMB36E1 is
1024 × 36 bit, so a 256-bit-wide row needs 8 parallel primitives.

### Layer 3 detail

Four weight banks × 8 primitives = 32 RAMB36E1, plus 1 RAMB18E1 for the
activation buffer = 33 RAMB cells.

---

## 2. Modules that are missing, dangling, constant or optimised away

| Item | Finding |
|---|---|
| `vec_buffer.v` | **Never instantiated.** Zero instances anywhere in the hierarchy. It is dead source. |
| Two-expert support | **Absent.** `NUM_EXPERTS = 2` exists in the original SystemVerilog package but the Verilog port has no expert index, no router, no second bank set. |
| Up / Down weight storage | **Absent.** Only `gate_r0..r3.mem` exist. |
| Output cache | **Absent** in the base RTL; added separately as `result_readout.v`. |
| `expert_engine` sequencing | **Absent.** It wires `start`/`busy`/`done` straight through to a single `gemv_engine`. No `gate → up → SiLU → down` schedule. |
| Black boxes | **None.** `black box cell count = 0` in layer 3. |
| Unresolved references | **None.** All modules elaborate; 0 errors, 0 critical warnings. |
| `stage` / `out_valid` / `oblk_idx` | Present in the original SystemVerilog engine, **removed in the Verilog port**. The output-block loop that let one engine produce 1024 outputs was dropped. |

### Pruning hazard (observed, not theoretical)

A module with an unobservable output is deleted. Measured three times:

| Run | Result |
|---|---|
| `wbank_region` synthesised alone | **0 RAMB** — read port never consumed |
| harness consuming only 64 of 256 bits | **2 RAMB** — the other 192 bits pruned |
| harness consuming all 256 bits | **8 RAMB** — correct |

Any future OOC measurement must consume every observed bit, or the numbers are
meaningless.

---

## 3. Integer codebook prototype vs real BF16 × FP4

**This design is an integer codebook prototype, not a BF16 × FP4 implementation.**

| Aspect | Real BF16 × FP4 | This prototype |
|---|---|---|
| Activation | BF16, 8-bit exponent + 7-bit mantissa | signed INT16, flat integer |
| Weight | FP4 (E2M1), 4-bit float | 4-bit **code index** into a table |
| Product | floating multiply | shift / add / negate of the integer activation |
| Alignment | exponent comparison and mantissa shift per term | not present |
| Accumulation | wide fixed-point with alignment, then round to BF16 | plain integer addition |

Evidence: `PROD_W = 24` holds `|a| · 4` for INT16 `a`, and DSP count is zero.
The candidate set `{0, ±x/4, ±x/2, ±x, ±1.5x, ±2x, ±4x}` is an exact
shift/add codebook, so the multiply is replaced by selection.

Consequences:

- **Zero DSP48 and no floating-point alignment hardware.** That is why the
  design is cheap.
- The codes are **not** FP4 E2M1 encodings. Real FP4 requires per-term exponent
  alignment, which would add significant shifter and accumulator logic.
- Therefore the measured numbers **do not transfer** to a true BF16 × FP4 design.
  Treat them as a lower bound for a much cheaper datapath.

---

## 4. Projection: the full two-expert design does NOT fit

Weight ROM is the binding constraint, not compute.

```
one bank (1024 x 256 bit)                 =   8 RAMB36E1

per expert:
  gate  (1024 ->  256,  4 regions)        =  32
  up    (1024 ->  256,  4 regions)        =  32
  down  ( 256 -> 1024, 16 regions)        = 128
                                          ------
  one expert                              = 192 RAMB36E1
  two experts                             = 384 RAMB36E1
```

**384 required vs 365 available = 105.2% — it does not fit.**

Down-projection weight storage dominates: it needs 1024 output accumulators, so
it must read 16 banks per k step.

| Resource | Projected | Device | Utilisation |
|---|---|---|---|
| BRAM36E1 | 384 + act buffer | 365 | **>100% — infeasible** |
| LUT | ~34,600 | 134,600 | ~25.7% |
| FF | ~57,400 (buffers in registers) | 269,200 | ~21.3% |
| DSP | 0 | 740 | 0% |

Compute and logic are comfortable. **Only weight storage fails.**

### Ways to recover feasibility

1. **Share banks between the two experts** — not possible without a weight write
   port or external storage; the banks are synthesis-time ROM.
2. **Store two experts in external memory** (the board has DDR3) and page them
   in. Requires a memory controller and a bank write port — neither exists.
3. **Reduce to one expert** — 192 RAMB36E1 = 52.6% of device. Fits.
4. **Reduce output lanes per pass and time-multiplex more** — the down stage
   currently needs 16 banks because it produces 1024 outputs at once. Producing
   them in 4 blocks of 256 with a shared bank set cuts down-stage storage 4×,
   to 32 banks per expert. One expert then needs 96 banks (26.3%), two experts
   192 banks (52.6%) — **fits**. This is exactly what the original
   SystemVerilog `OBLOCK_W` / `GEMV_NEXT_BLOCK` mechanism did.
5. **Narrow `ACC_W`** — does not help; it reduces FF, not ROM. Weight codes are
   already 4 bit.

**Recommendation: (4).** The original design already contained the mechanism;
the Verilog port dropped it, and that omission is what makes the two-expert
version infeasible.

---

## 5. IOB note

Top-level IOB limits are **not** used as evidence anywhere in this document.
Layer 1/2/3 were synthesised `-mode out_of_context`, where IOB count is 0 by
construction. The earlier 8,224-IOB figure came from exposing the 8,192-bit
accumulator vector as a top-level port; that is an interface decision, not an
internal resource limit, and is orthogonal to this assessment.
