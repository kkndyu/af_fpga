# Hardware verification record: FP4 codebook GEMV on AX7203B

Status: **verified on silicon at 50 MHz, 100 MHz and 200 MHz.**

The 256-lane FP4 codebook GEMV computes the golden result on a real
XC7A200T at 200 MHz, with zero DSPs, and the board self-reports PASS.  The
engine is fully pipelined: one tap per cycle, ~100 % array utilisation,
51 GMAC/s, and 200 MHz is met with **+0.248 ns** of real margin.

## 1a. Verified clock rates, in the order they were tried

| Engine clock | Board result | Timing margin (clk_engine) |
|---|---|---|
| 50 MHz (DIV_BITS=2, /4) | PASS | WNS +2.745 ns |
| 100 MHz (DIV_BITS=1, /2) | PASS | WNS +0.575 ns |
| 200 MHz (DIV_BITS=0, direct) | PASS (first version) | WNS 0.000 ns |
| **200 MHz, pipelined + replicated** | **PASS** | **WNS +0.248 ns** |

Each rate was tried only after the previous one passed, so a failure at any step
could be attributed.  50 MHz first was deliberate: with ~14 % margin, timing
could be ruled out as a variable, so a failure would have meant a logic bug.

The first 200 MHz build closed at exactly 0.000 ns only after a post-route
`phys_opt_design` rescued 58 ps.  That is met but has nothing spare.  The
pipelining and register replication described in section 3b then made the
routed design close **by itself** - `phys_opt_design` reported
"worst setup slack >= 0.000, skipping".

## 1b. Why 200 MHz is not a hardware ceiling

Two separate limits applied, and neither is fundamental:

- **Clock source.** The oscillator on R4/T4 is 200 MHz and the engine now runs
  directly off it.  An MMCM could synthesise a faster clock from that reference.
- **Logic depth.** After all the pipelining, the binding path is no longer the
  MAC array at all - it is the readout's 256:1 lane selector at 4.744 ns.  See
  section 8.

Splitting a stage is cheap now, because adding a pipeline stage costs one cycle
of latency per GEMV rather than one cycle per tap.

---

## 1. What was verified

The design computes one GEMV of a 1024-element activation vector against a
1024 x 256 matrix of 4-bit weight codes:

```
y[n] = sum(k) x[k] * W[k][n]        n = 0..255, k = 0..1023
```

Each weight code selects one of sixteen precomputed candidate products, so the
multiply is a 16:1 mux.  The claim under test was that this replacement is
viable in hardware - specifically that the design needs **no DSP48 at all**.

Measured result on the board: the on-chip comparison of `result_checksum`
against `32'hffffc6e2` evaluates true, and the board signals PASS by blinking
LED1 and LED2 together.

## 2. Evidence chain

Every layer was checked, and each one isolates a different class of fault.

| Layer | Result | What it rules out |
|---|---|---|
| RTL simulation (`tb_result_readout`) | 256/256 lanes exact, checksum `ffffc6e2` | arithmetic and FSM logic |
| Board-top RTL simulation (`tb_moe_board`) | checksum `ffffc6e2`, LED pattern `4'b1100` = PASS | activation load, sequencer, readout, LED mapping |
| **Gate-level simulation of the routed netlist** | `4'b0000` matching RTL | synthesis changing behaviour; `act_rom` elimination being wrong |
| Synthesis / place / route reports | all constraint groups met | timing closure |
| **On-board run** | LED1 + LED2 blinking = PASS | the whole chain, in silicon |

The gate-level run mattered: RTL simulation passing does not prove the
synthesiser preserved the design.  It proved the logic was fine, which pointed
the remaining fault at timing rather than arithmetic.

## 3. Final implementation numbers

200 MHz build (the one currently on the board):

```
Slice LUTs        35,660 / 133,800    26.65 %
Slice Registers   26,611 / 267,600     9.94 %
F7 Muxes          13,424 /  66,900    20.07 %   <-- the 16:1 selects
Block RAM Tile      34.0 /     365     9.32 %   (RAMB36 x32 + RAMB18 x4)
DSPs                   0 /     740      0.00 %   <-- the point of the design
Bonded IOB             7 /     285      2.46 %
```

Timing, both groups met:

```
sys_clk_p   200.000 MHz   5.000 ns   WNS +3.716 ns   WHS +0.263 ns
clk_engine  200.000 MHz   5.000 ns   WNS +0.248 ns   WHS +0.065 ns
```

Critical path - note what it is NOT:

```
u_result_readout/lane_idx_reg[*]  ->  lane_word_q_reg[*]
4.744 ns:  logic 1.347 ns, route 3.397 ns, 6 levels
```

**The MAC array is no longer the critical path.**  It is the readout's 256:1
lane selector (section 8), which is not on the compute path at all.

Bitstream: 9,730,764 bytes
SHA256: `21EBCD4EB096D57DC6E7D86B90FD7936DE44E0B3A0DBC0BD5958C755B08F9C94`

Throughput at 200 MHz:

```
1 cycle per tap x 1024 taps + 4 pipeline cycles = 1028 cycles per GEMV
1028 / 200 MHz                                 = 5.14 us
262,144 MACs / 5.14 us                         = 51.0 GMAC/s
array utilisation                              = 256 MACs/cycle / 256 lanes ~ 100 %
```

## 3b. How the throughput was obtained

Measured progression.  Every step was driven by a measurement, not a guess.

| Step | Critical path | Cycles/GEMV | What it fixed |
|---|---|---|---|
| start: 3 cycles/tap, top-level broadcast | 9.896 ns routed | 3,072 | 33 % utilisation |
| per-region product generator | 5.619 ns | 3,072 | activation net fanout 1288, 45 % of the path |
| + weight-code register, delay-matched | 5.398 ns | 3,072 | mux select had become the long pole |
| + activation register, **FSM pipelined** | 4.099 ns | 1,027 | accumulator now works every cycle |
| + readout lane-word register | 4.099 ns | 1,027 | 256:1 and 4:1 muxes shared one cycle |
| + per-region `acc_en` register | 4.982 ns routed | 1,027 | one bit driving 8192 clock enables |
| + post-route `phys_opt_design` | 4.982 ns | 1,027 | recovered the last 58 ps -> **0.000 ns** |
| + `keep_hierarchy`/`dont_touch`, per-lane weight register | 4.736 ns | 1,027 | cross-region pooling of identical registers |
| + per-region activation buffer | 4.114 ns | 1,027 | one BRAM output dragged to four regions |
| + per-lane select register (mux/adder split) | 4.744 ns routed | 1,028 | select + 32-bit add in one cycle |
| **final** | **4.744 ns** | **1,028** | **WNS +0.248 ns, phys_opt skipped** |

The lesson that repeated: **fixing one path moves the bottleneck somewhere
else**, and the next bottleneck was never where expected.  Three separate times
it was control or memory distribution (`acc_en`, the register replicas, the
activation buffer), and in the end it was the readout rather than the MAC array.

## 3c. Mapping to the reference architecture diagrams

The design follows the two reference figures (sub-array and weight distribution).
The figures draw ONE region; there are four of everything.

| Reference | Implementation |
|---|---|
| WBank 0..N in 参数缓存 SRAM | `u_wbank_r0..r3`, 1024 x 256 bit each, central |
| 权重读出寄存器 523 | each wbank's `rd_data` output register (`wcode_r*`) |
| 局部分发寄存器 524 (optional) | `wcode_d`, 256 bit per region, `dont_touch` |
| 通道权重寄存器 | `wcode_q` inside `mac_lane` - one 4-bit register per lane, `dont_touch` |
| 候选乘积生成模块 517 | `fp4_product_gen`, one per region |
| 候选乘积选择模块 | `fp4_select`, one per lane |
| 缩放计算模块 | **not implemented** - position reserved at `sel_prod_q` |
| 激活数据 | activation buffer replicated per region |
| Daisy-chain Write Network | **not implemented** - wbanks have no write port |

The pipeline is six stages deep: read, activation register, product register,
select register, enable register, accumulate.  Each boundary is `dont_touch` or
`keep_hierarchy` where the registers are bit-identical across regions, because
otherwise the synthesiser pools them and places replicas with no regard for
which region they serve (section 4.5).

## 4. Bugs found and fixed on the way

These are recorded because each one produced a *plausible looking* result while
the hardware was wrong.

### 4.1 The board ran at twice the frequency it was signed off for

The oscillator is 200 MHz.  An earlier build "closed timing at 100 MHz" by
re-running `create_clock -period 10.000` in the build script.  That only
retargeted the timing analyser; the FPGA still received 200 MHz, so the engine
ran at twice its closing frequency and produced a wrong checksum.

Fixed by dividing the clock in RTL (`DIV_BITS = 2`, /4 -> 50 MHz) and
constraining the result with `create_generated_clock`.  The build script no
longer overrides any clock; it *verifies* the engine clock against the expected
period and aborts if the RTL divider and the XDC `-divide_by` disagree.

**Rule learned: never override a primary clock to a frequency the board does not
supply.  Change the clock in RTL and constrain the result.**

### 4.2 The board sequencer restarted the GEMV forever

`moe_proto_board.v` waited for `!done && !done_d && !busy` before launching.
After the first GEMV, `done` pulsed and dropped, the condition became true
again, and the engine restarted endlessly - re-capturing the result and
re-running the readout every time, so `result_checksum` accumulated without
bound and could never equal the golden value.

Caught by board-level simulation before any bitstream was programmed.  Fixed
with a one-shot FSM (`S_LOAD -> S_START -> S_RUN -> S_FIN`, with `S_FIN`
latching).

### 4.3 A width bug in the new self-judging LED logic

```verilog
localparam [10:0] SETTLE_CYCLES = 11'd2048;   // 2048 does not fit in 11 bits -> 0
if (settle_cnt == SETTLE_CYCLES - 1)          // 0 - 1 = 32'hFFFFFFFF, never true
```

`result_valid` never asserted and `settle_cnt` wrapped between 0 and 2047.
Caught by simulation.  Fixed by declaring `localparam integer SETTLE_CYCLES`
and widening the counter to 12 bits.

### 4.4 Per-region product registers restored from the original SystemVerilog

The Verilog port had dropped `prod16_region_flat`, broadcasting the product
vector from one generator to all four regions.  The original SystemVerilog
carries an explicit comment: *"This avoids one large fanout from the product
generator to all 256 lanes."*  Without it, the activation net measured
**4.425 ns with fanout 1288** - 45 % of a 9.896 ns critical path.

Restored as four registered copies plus a new `S_PROD` FSM state (a tap is now
3 cycles instead of 2, because registering the products adds a cycle).

**The stated goal was only partly achieved, and the mechanism was not the one
intended.**  Counting the netlist afterwards:

```
prod16_region_flat_reg  distinct bit indices : 138   (not 1536)
_replica instances                          : 1027
```

Vivado merged the four copies - they hold the same value - and then replicated
as it saw fit.  So there is no guarantee that a copy sits beside its own region;
the physical-locality benefit the original comment was after did NOT happen.
The 100 MHz critical path confirms this: it starts at
`prod16_region_flat_reg[*]` and spends 82 % of its 9.064 ns in routing to the
lane muxes.

What actually helped was the **extra pipeline stage**.  Measured effect: timing
at 100 MHz went from not closing to closing at +0.575 ns.

**However, throughput did not improve at equal effort:** the frequency gain was
about 10 % while the cycle count rose 50 %.  Relative to the pre-modification
design the change is a throughput regression (28.4 us vs 20.9 us per GEMV at
their respective best placements).  It buys timing margin, not speed.

To get genuine locality the product generator would have to live *inside* each
`mac_region`, so the tool sees four independent pieces of logic rather than four
identical registers it is free to merge.

### 4.5 The tool still shares the replicated registers across regions

Moving the generator inside each region (section 3b) removed the product
generator from the critical path, but it did NOT stop the tool from sharing the
*registers*.  In the 200 MHz build the remaining worst path is

```
u_region0/prod16_q_reg[148]_rep__2  ->  u_region3/gen_lane[49]/acc_out_reg[31]
4.982 ns, slack 0.000 ns
```

A register that belongs to region 0's hierarchy is driving a lane in region 3,
because `_rep__2` is one of the replicas Vivado created after merging the four
identical copies.  Placement is then free to put that replica anywhere, and it
chose badly.

Effect: the design meets 200 MHz by exactly 0.000 ns, and post-route
`phys_opt_design` was needed to recover the last 58 ps.  Every region's own feed
is comfortably fast; only the shared replicas are marginal.

Cheapest real fixes, in order of intrusiveness:
1. `(* dont_touch = "true" *)` on `prod16_q`, so the four copies cannot be
   merged and each region keeps its own.
2. `keep_hierarchy` on `mac_region`.
3. Synthesise with `-flatten_hierarchy none`.

None of these has been tried yet.  They trade some area (the full 1536 product
flip-flops instead of the ~307 the merged form costs) for a guaranteed local
placement.

## 5. What this does NOT prove

Being explicit, because the result is easy to over-read.

- **Not a full MoE.** There is no router, no top-k selection, no second expert,
  and no `gate -> up -> SiLU -> down` schedule.  `expert_engine.v` wires a
  single GEMV engine straight through.  This verifies the *compute slice*, not
  the mixture.
- **Not real FP4.** The codebook is integer shift multiples
  `{0, +-x/4, +-x/2, +-x, +-1.5x, +-2x, +-4x}` with no exponent alignment, and
  the per-lane scaling stage from the reference diagram is absent.  It
  demonstrates multiplier elimination, not FP4 (E2M1) arithmetic.
- **Timing margin is real but modest.** 200 MHz is met at +0.248 ns (5 % of the
  period), without needing physical optimisation.  That is a defensible bench
  margin; it is not a production sign-off.
- **Not area-efficient in the fabric sense.** Only 27 % of the LUTs are used,
  but the constraint is weight storage, not arithmetic: two experts do not fit
  (see section 6).
- **Not loadable at runtime.** Weights live in BRAM initialised from the
  bitstream via `$readmemh`.  `wbank_region` has no write port, so changing
  weights means re-synthesising.
- **Not measured for power or long-term reliability.** One board, room
  temperature, volatile configuration only.

## 6. Two-expert capacity

`docs/resource_assessment.md` records the blocker: one weight bank is
1024 x 256 bit = 8 RAMB36E1, and a two-expert MoE needs 384 RAMB36E1 against
365 available (105.2 %).  The bottleneck is weight storage, not arithmetic
(LUT usage stays near 27 %).

The fix is output-block time-multiplexing, which exists in the original
SystemVerilog as `OBLOCK_W` / `GEMV_NEXT_BLOCK` and was dropped in the Verilog
port.  Restoring it reduces the down projection from 16 banks to 4, bringing
two experts to 192 RAMB36E1 (52.6 %).

## 7. Reproducing

```powershell
# full build: synth -> opt -> place -> route -> bitstream, with checkpoints
powershell -NoProfile -ExecutionPolicy Bypass -File build\moe\run_build.ps1

# program the board (volatile configuration only)
xsdb -no-ini -eval "source {D:/ai/moe_fpga_proto_verilog/scripts/xsdb_program_moe.tcl}"
```

Interpretation of the LEDs (active LOW - the factory `led_test.v` drives
`4'b1110` to light "LED1"):

| Pattern | Meaning |
|---|---|
| LED1 + LED2 blinking together | PASS, `result_checksum == 32'hffffc6e2` |
| LED3 + LED4 blinking together | FAIL, checksum mismatch |
| nothing lit | still running, or not configured |

Two LEDs per verdict on purpose, so a single dead LED still leaves the answer
readable.

## 8. Next steps, in a defensible order

1. **Fix the readout's 256:1 lane selector.** It is now the ONLY critical path
   (4.744 ns, 6 levels), and it is not on the compute path at all.  There is
   also a self-inflicted waste there: `res_buf` is a full 8,192-flop copy of
   `acc_flat`, and copying it does not reduce the mux depth because the copy is
   indexed the same way.  The accumulators already hold their value after
   `done`, so the copy can be dropped and the select split into
   64:1 per region then 4:1 - roughly 4 levels instead of 6, and 8,192
   flip-flops saved.  Expected margin afterwards: around +0.8 ns.
2. **Read out the checksum properly** (UART or ILA) so verification does not
   depend on counting LEDs.  Vivado here lacks `labtools`, so `open_hw_manager`
   is unavailable and ILA has to be instantiated as RTL primitives.
3. **Implement 缩放计算模块** - the per-lane scaling stage from the diagrams,
   which receives 缩放参数 from the parameter cache.  Deferred deliberately
   until real FP4 multiplication is implemented; the pipeline position is
   already reserved at `sel_prod_q`.
4. **Implement the daisy-chain write network** so weights can be loaded at
   runtime.  Currently `wbank_region` has no write port and weights are frozen
   into the bitstream by `$readmemh`, so changing models means re-synthesising.
5. **Restore `OBLOCK`** to make a two-expert design fit (105.2 % -> 52.6 % of the
   RAMB36E1 budget), and to let one engine produce more than 256 outputs.
6. **Add the router and top-k**, which is a different class of hardware
   (comparators and priority encoding, not MAC arrays).
7. **Only then consider going past 200 MHz.** It needs both an MMCM to multiply
   the 200 MHz reference and a further split of whatever stage is then critical.
   The array is already at ~100 % utilisation, so further speed would come only
   from the clock, not from structure.
