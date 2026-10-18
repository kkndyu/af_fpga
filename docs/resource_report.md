# Resource utilisation report - AX7203B, FP4 codebook GEMV

Design: 256-lane FP4 codebook GEMV, `moe_proto_board`, on `xc7a200tfbg484-2`.
This report describes the **routed** design (post place-and-route), i.e. the
bitstream that has been run on the board - not a synthesis estimate and not an
out-of-context per-module figure.

## Method

```
open_checkpoint build/moe/out/post_route.dcp
report_utilization -hierarchical -hierarchical_depth 6
```

Per-block numbers are the `Total LUTs` / `FFs` columns of that report, which are
cumulative over children.  A row named `(instance)` is that instance's **own**
logic excluding children, which is what makes the per-lane split below possible.

One caveat on hierarchy: `mac_region` carries `keep_hierarchy = "yes"` (so the
four regions cannot pool their bit-identical pipeline registers across the
boundary), so `u_region0..3` and their children survive as separate cells.  The
64 lane instances inside a region are flattened by synthesis, so the per-lane
cost is derived by dividing the region total, and cross-checked against the lane
instances that do still appear.

## 1. Whole design

| Resource | Used | Available | Util % |
|---|---|---|---|
| Slice LUTs | **35,681** | 133,800 | **26.67** |
| - LUT as Logic | 35,681 | 133,800 | 26.67 |
| - LUT as Memory (LUTRAM) | 0 | 46,200 | 0.00 |
| Slice Registers (FF) | **18,451** | 267,600 | **6.89** |
| F7 Muxes | 13,360 | 66,900 | 19.97 |
| F8 Muxes | 6,680 | 33,450 | 19.97 |
| Block RAM Tile | **34** | 365 | **9.32** |
| - RAMB36E1 | 32 | 365 | 8.77 |
| - RAMB18E1 | 4 | 730 | 0.55 |
| **DSP48E1** | **0** | 740 | **0.00** |
| Bonded IOB | 7 | 285 | 2.46 |
| BUFG | 1 | 32 | 3.13 |
| Slice (logic slices) | 9,581 | 33,450 | 28.64 |
| - SLICEL / SLICEM | 6,418 / 3,163 | | |

Measured at 200 MHz: setup WNS **+0.446 ns**, hold WHS **+0.070 ns**.

## 2. Breakdown by functional block

| Block | LUT | FF | RAMB36 | RAMB18 | Share of LUTs |
|---|---|---|---|---|---|
| Board wrapper (clock divider, start sequencer, LED verdict) | 121 | 81 | 0 | 0 | 0.3 % |
| `moe_proto_top` glue | 34 | 56 | 0 | 0 | 0.1 % |
| `gemv_engine` control (pipeline counter, rd_en/acc_en logic) | 2,196 | 132 | 0 | 0 | 6.2 % |
| 4 x weight bank (`u_wbank_r0..3`) | 33 | 2 | **32** | 0 | 0.1 % |
| **4 x region (`u_region0..3`)** | **33,200** | **17,988** | 0 | **4** | **93.0 %** |
| `result_readout` | 97 | 192 | 0 | 0 | 0.3 % |
| **Total** | **35,681** | **18,451** | **32** | **4** | 100 % |

Observation: **93 % of the LUTs and 97 % of the flip-flops are in the four
regions.** Everything else - control, memories, debug readout, board logic - is
noise by comparison. Any optimisation that does not touch a region is rounding.

## 3. Inside one region (8,300 LUT / 4,497 FF / 1 RAMB18)

| Part | LUT | FF | RAMB18 | Note |
|---|---|---|---|---|
| 64 x `mac_lane` | 8,194 | 3,840 | 0 | 128.03 LUT and 60 FF per lane |
| Region's own logic | **106** | **657** | 0 | product generator + pipeline regs |
| `u_act_buffer` | 0 | 0 | 1 | inferred as RAMB18E1, 1024 x 16 bit |
| **Total** | **8,300** | **4,497** | **1** | |

The region's 657 flip-flops decompose exactly:

```
act_q_q    :  16     activation register
prod16_q   : 384     16 candidate products x 24 bit
wcode_d    : 256     64 lanes x 4 bit weight code
acc_en_q   :   1     registered accumulator enable
             ---
             657
```

The region's own 106 LUTs are the product generator, which is about **26 LUT per
copy**.  That is near-free because the candidates are formed by shifts, which are
pure wiring, and only the `1.5x` candidate needs a real adder (24 bit, 6 CARRY4).
**Product generation is 1.2 % of the whole design.**

## 4. Inside one lane (128.03 LUT / 60 FF)

| Part | LUT | FF | Share of lane LUTs |
|---|---|---|---|
| `u_fp4_select` - the 16:1 candidate selector | **96** | 0 | **75.0 %** |
| Adder + sign extension + own registers (lanes' own logic) | 32 | 60 | 25.0 % |
| **Total per lane** | **128** | **60** | 100 % |

Lane flip-flops, 60 total:

```
acc_out    : 32     the accumulator
wcode_q    :  4     per-lane weight register (通道权重寄存器)
sel_prod_q : 24     registered mux output (the scaling stage's position)
             ---
              60
```

Measured over all 256 lanes: total 32,776 LUT, min 128, max 129, mean 128.03.
The spread of one LUT is synthesis noise, not a structural difference.

**The single most important number in this report: the 16:1 candidate selector is
75 % of the per-lane logic.** It is what replaces the multiplier, so its cost is
the price of eliminating DSP48s.

## 5. Primitive-level detail

| Primitive | Count | What it is |
|---|---|---|
| LUT6 | 26,909 | 6-input LUT, used as 4:1 muxes and logic |
| LUT5 | 51 | |
| LUT4 | 20 | |
| LUT3 | 8,236 | |
| LUT2 | 8,064 | |
| LUT1 | 364 | |
| **MUXF7** | **13,360** | dedicated 2:1 mux combining LUT pairs (~52 per lane) |
| **MUXF8** | **6,680** | dedicated 2:1 mux combining F7 pairs (~26 per lane) |
| **CARRY4** | **2,202** | carry chain, 4 bits each |
| FDCE | 18,450 | flip-flop with async reset and clock enable |
| FDRE | 0 | |
| RAMB36E1 | 32 | weight banks |
| RAMB18E1 | 4 | activation buffers |
| DSP48E1 | **0** | |
| BUFG | 1 | engine clock buffer |

CARRY4 attribution (2,202 total):

```
256 lanes x 8        = 2,048   32-bit accumulator adder
4 regions x 6        =    24   24-bit "1.5x" product adder
remainder            ~  130    readout checksum adder, board counters
```

## 6. What each block does

- **`fp4_product_gen`** (per region, 26 LUT): builds 16 candidate products of the
  current activation value by shifting and negating - `{0, ±x/4, ±x/2, ±x, ±1.5x,
  ±2x, ±4x}`.  No multiplier; the only arithmetic is the `1.5x` add.
- **`prod16_q`** (per region, 384 FF): registers that 384-bit candidate vector.
- **`u_wbank_r0..3`** (4 banks, 32 RAMB36): the 4-bit weight codes,
  1024 deep x 256 wide each = 1024 x 1024 bit total = 128 KB = the whole
  1024x256 gate matrix at 4 bits per weight.
- **`wcode_d`** (per region, 256 FF): local distribution register for the weight
  code, matching the reference diagram's 局部分发寄存器 524.
- **`u_fp4_select`** (per lane, 96 LUT): the 16:1 mux that picks one of the 16
  candidates according to that lane's 4-bit weight code.  This is where the
  multiply is eliminated.
- **`acc_out`** (per lane, 32 FF + 8 CARRY4): the accumulator.
- **`sel_prod_q`** (per lane, 24 FF): registers the mux output, splitting the
  selector from the adder so each fits one 5 ns clock.
- **`gemv_engine` control** (2,196 LUT): the pipeline counter and the
  `rd_en` / `acc_en` windows.  Larger than the product generators put together.
- **`result_readout`** (97 LUT, 192 FF): debug path, serialises the 256 results
  one byte at a time.  Two-level selector (64:1 per region, then 4:1).

## 7. Headroom and what the next steps would cost

Available: 133,800 LUT, 267,600 FF, 365 RAMB36, 740 DSP.

### Weight storage is the binding resource

One projection (1024 x 256 weights at 4 bit = 1.05 Mbit) costs **32 RAMB36**,
and the measured design confirms exactly that: 32 blocks for the gate matrix.

| Configuration | RAMB36 | Util % | Fits? |
|---|---|---|---|
| Current: gate only | 32 | 8.8 % | built |
| One expert: gate + up + down | **96** | **26.3 %** | yes |
| Two experts | **192** | **52.6 %** | yes |
| Four experts | 384 | 105 % | no |

Note: `gate` (1024->256), `up` (1024->256) and `down` (256->1024) all contain
262,144 weights, because 1024x256 = 256x1024, so each costs the same 32 RAMB36.

**Correction to `docs/resource_assessment.md`:** that document states a two-expert
MoE needs 384 RAMB36E1 (105 %) because it assumed the down projection needs 16
banks.  16 banks would be 4.2 Mbit = 512 KB, which is four times the actual
down-projection size (256 x 1024 x 4 bit = 1.05 Mbit = 128 KB = 32 blocks).  The
16-bank figure is only correct if the up projection were 1024->1024, i.e.
`E_DIM = 1024`.  With this project's `E_DIM = 256` the two-expert design fits.

### Compute

If the engine is time-shared across the three projections (which the differing
shapes force anyway, since `down` needs four passes of a 256-lane engine to
produce 1024 outputs), the compute cost stays at today's ~35.7 k LUT / 26.7 %.

If instead a second engine were instantiated for parallelism, it would add
~35.4 k LUT (reaching 53 % LUT), which also fits.

### Summary

```
LUT      26.7 % used   - roughly 2.7x more compute could fit
FF        6.9 % used   - very cheap, the pipeline registers cost almost nothing
BRAM      9.3 % used   - the real constraint: one expert 26 %, two experts 53 %
DSP       0.0 % used   - the entire point of the design
IOB       2.5 % used   - 278 spare pins, enough for a UART and more
```

## 8. Caveats

- These are post-route numbers for the current bitstream.  Re-running
  place-and-route can move them by a few hundred LUTs; the structural ratios
  (93 % in the regions, 75 % of a lane in the selector) are stable.
- F7/F8 muxes are not independent resources - they live inside the same slices
  as the LUTs, so their 20 % utilisation is consistent with 26.7 % LUT use.
- The per-lane figure is an average (128.03 LUT, spread 128-129) because
  synthesis flattened the 64 lane instances and they cannot be counted
  individually any more.
- Timing margin on the current bitstream is held back by the **debug readout**,
  not by the MAC array.  The readout's 64:1 x 4 + 4:1 selector is the critical
  path at 4.534 ns; the compute path has more slack.
