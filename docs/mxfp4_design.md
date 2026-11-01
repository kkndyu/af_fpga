# BF16 x MXFP4 weight profile

This profile implements a 1024-input, 256-output GEMV with BF16 activations,
E2M1 FP4 weight elements, E8M0 block scales, exact accumulation, and FP32 output.
It is selected at compile time with `MOE_MXFP4`; the default integer profile
retains its existing protocol and reference data.

## Numerical contract

For output channel j and input k:

`y[j] = round_fp32_RNE(sum_k BF16(x[k]) * E2M1(w[k,j]) * 2^(S[k/32,j]-127))`

- E2M1 positive codes 0..7 mean 0, 0.5, 1, 1.5, 2, 3, 4, 6. Bit 3 is sign,
  including negative zero. The old integer codebook is not reused.
- One scale per 32 consecutive input positions **per output channel**.
- E8M0 codes 0..254 mean exponents -127..127; code 255 is NaN. Code 0 does
  not mean zero. Total scale storage: 32 x 256 bytes = 8 KiB.
- BF16 normal numbers, subnormals, signed zero, infinities and NaNs are decoded.
- NaN propagates; infinity times an FP4 zero is NaN; opposing signed infinities
  produce NaN. The output uses canonical quiet NaN 0x7fc00000.
- Finite accumulation is exact, followed by one FP32 rounding, nearest/even,
  including gradual underflow, signed underflow-to-zero, and overflow to infinity.
  A mathematically exact zero is +0, consistent with starting a dot product at +0.
- This is weight-only MXFP4 with BF16 activations, rather than an activation
  quantizer. Its internal precision differs from per-term FP32 rounding; GPU
  kernels with other accumulation orders need not be bit-identical.

Format and conversion definitions:
[OCP Microscaling Formats v1.0, sections 5.3.3, 5.4.1, 6](https://www.opencompute.org/documents/ocp-microscaling-formats-mx-v1-0-spec-final-pdf).
Internal dot-product precision/order is explicitly implementation-defined there.

## Datapath and throughput

Each region retains its own activation buffer and shared eight-candidate BF16
significand generator. Its 32 physical lanes process logical channels 0..31,
then repeat the input traversal for channels 32..63, saving both result halves.
The four regions therefore provide 128 physical lanes and 256 logical outputs.
Each lane selects the exact magnitude, applies its block
scale through the exponent, and accumulates into a 544-bit signed register.

The accumulator LSB is 2^-261, the smallest finite BF16 x E2M1 x E8M0 product.
The largest product occupies at most bit 518; summing 1024 terms requires at
most bit 528. The width includes sign and additional headroom. Thus large finite
terms can cancel before FP32 output conversion without intermediate overflow.

A rotating 32-bit carry chain consumes 17 cycles per product. BRAM reads,
local decode, registered product generation, product capture and shift preparation bring this to 22 cycles per
input position. Final absolute-value extraction and normalization add a small,
data-dependent completion latency. Rounding and final packing have separate
register stages, including a registered rounding decision before the mantissa
increment. There are no multicycle timing exceptions for this arithmetic.

This trades throughput for full-range numerical correctness on Artix-7. It does
not retain the integer profile's one-input-per-cycle throughput. A 1024-input
run takes about 45,170 clocks across the two output groups, approximately
226 us **if** implementation closes at 200 MHz. Actual timing/resource results
must be taken from this profile's own implementation reports.

## Loading and wire layout

The frame envelope, CRC, WRITE_W, WRITE_A, RUN, READ_OUT and READ_W stay the same.
WRITE_A now carries BF16 bit patterns; READ_OUT carries FP32 bit patterns,
little-endian within each lane. The checksum register is still a sum of raw
32-bit words, not a floating-point sum.

New command `0x08 WRITE_S` has exactly 67 payload bytes:

`region | 0 | block_index | scale_lane0 | ... | scale_lane63`

- Region 0..3; block index 0..31; each byte is an E8M0 scale.
- The engine write address is `{block_index[4:0], lane_index[5:0]}`.
- All 128 scale rows must pass CRC before COMMIT can set weights_ready.
- Updating a scale clears weights_ready and invalidates that row until the
  complete frame passes CRC. Malformed lengths/addresses are rejected.
- A bad scale CRC prevents COMMIT until that row is reloaded successfully.
- Scales are loaded at runtime, with no bitstream initialization.

Disk files use `weight_r0.mem`..`weight_r3.mem` (1024 rows, 64 hex nibbles per
row), `scale_r0.mem`..`scale_r3.mem` (32 rows, 128 hex characters per row),
`activation.mem` (1024 BF16 values), and `ref_1024.hex` (256 FP32 values).
Within a weight or scale row, the rightmost element is local lane 0.
The logical layout is documented here; no GPU-specific tiled scale layout is
implied by the files.

## Tools and verification

Generate directed/random fixtures and an independent BigInt reference:

```powershell
node scripts/gen_mxfp4_vectors.js
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/sim_fp4_arithmetic.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/sim_mxfp4.ps1 -Target engine
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/sim_mxfp4.ps1 -Target loader
```

The arithmetic tests exhaust all 1,048,576 BF16/E2M1 pairs, check 200,400 FP32
additions, and 100,244 integer-significand/exponent conversions. The FP32 adder
and packer are independently tested primitives; the GEMV uses the rotating
exact accumulator described above.

Engine tests cover scale block boundaries, scale reload, repeated RUN, memory
retention across control reset, infinities and NaNs. Loader tests use the full
1024 x 256 shape, compare every output bit against the BigInt oracle, test
scale completeness, malformed frames, CRC recovery, COMMIT, backpressure and
raw weight readback. Fixtures include overflow cancellation, rounding ties,
subnormal results and invalid scales.

Convert finite FP32 JSON data with weights indexed [input][output]:

```powershell
node scripts/quantize_mxfp4.js --self-test
node scripts/quantize_mxfp4.js input.json build/my_mxfp4_model
```

The JSON keys are `weights` ([1024][256]) and `activations` ([1024]). The
converter applies OCP section 6.3 scale selection, RNE E2M1 quantization with
saturation, and RNE BF16 conversion; it writes the disk format and exact
reference above. Zero weight blocks use scale 1. Scale exponents are clamped
to the finite E8M0 range. It reports saturated element counts in metadata.

Build independently from the integer bitstream:

```powershell
vivado -mode batch -nolog -nojournal -notrace -source scripts/build_moe.tcl -tclargs mxfp4_20261101 mxfp4
```

The integer bank3 pblock is not applicable to this hierarchy and cannot be
combined with mxfp4 mode. Existing setup/hold gates remain enabled.

After programming the corresponding bitstream, the UDP hardware test supports
the new profile and all weight readback:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/hw_udp_e2e.ps1 -Profile mxfp4 -VerifyWeights
# For a converted model, add: -DataDir build/my_mxfp4_model
```

JTAG-AXI loading and verification also accept the arithmetic profile:

```powershell
vivado -mode batch -nolog -nojournal -notrace -source scripts/hw_axi_full_load.tcl -tclargs mxfp4
# A second Tcl argument can name a converted model directory.
```

Simulation logs and generated vectors live under build/. Implementation and
hardware results are recorded separately when measured; passing RTL tests alone
does not establish that the full profile fits or closes timing on the board.

## Implementation experiments (2026-11-01)

The first synthesis (`build/moe/mxfp4_20261101/util_synth.rpt`) reported
143,351 LUTs (106.50%), 93,496 registers, and 37 BRAM tiles. It does not fit
the device, and no bitstream was generated. The rotating accumulator was
extracted into SRLs with substantial extra logic for synchronous clearing.

The revised accumulator explicitly disables SRL extraction so that its
synchronous clear can use FF reset pins. The independent follow-up run is
`build/moe/mxfp4_ff_20261101`, with its log at
`build/logs/mxfp4_ff_build_20261101.log`. Its synthesis reports 131,039 LUTs
(97.35%), 204,344 registers (75.91%), and 37 BRAM tiles. This is below the
raw device capacity but leaves little LUT margin; placement/routing feasibility
and 200 MHz timing are still pending. Neither is established by simulation.

The FF run's pre-placement timing report exposed a -2.573 ns path from word
phase selection through the carry chain and nonzero reduction into window
register enables. Implementation was stopped to fix that path: the selected
signed word is now registered alongside the already delayed step control, and
absolute-word nonzero is computed directly from the source word/sign/carry.
The engine and full loader regressions pass with unchanged cycle counts
(21,553 observed cycles per full loader GEMV). The loader regression
and the new implementation run use logs `build/logs/mxfp4_pipeline_loader.log`
and `build/logs/mxfp4_pipe_build_20261101.log`; output directory is
`build/moe/mxfp4_pipe_20261101`. This was the last 256-physical-lane run.
Its synthesis reports 131,509 LUTs (97.70%), 212,507 registers (78.94%), and
37 BRAM tiles. Pre-placement worst slack improved to -0.643 ns, but detailed
placement failed: 2,742 control sets prevented legal slice packing despite the
raw LUT/FF totals being below capacity. No bitstream was generated.

Current RTL reuses 32 physical lanes per region for two output groups and saves
the two result halves separately. Its wire layout, logical output ordering and
numeric contract are unchanged. A separate rounding-decision stage also removes
the reduction-to-mantissa-increment path exposed by the previous timing report.
The first shared-lane implementation is `build/moe/mxfp4_shared_20261101`, with log
`build/logs/mxfp4_shared_build_20261101.log`. Synthesis reports 78,932 LUTs
(58.64%), 123,246 registers (45.78%), and 37 BRAM tiles. Pre-placement worst
slack is -0.632 ns, now from activation BRAM through product generation.
Routed timing remains pending. Its loader regression passes all 256 output
comparisons on both full GEMVs at 43,116 observed cycles; log is
`build/logs/mxfp4_shared_loader.log`. The final engine regression also passes
(`build/logs/mxfp4_shared_engine_final.log`), including scale reload and Inf/NaN.

The shared-lane implementation was stopped before placement to register the
region's eight product candidates separately from lane selection. This adds one
cycle per input position, separating the BRAM-to-product-to-lane path. Current
RTL is being implemented in `build/moe/mxfp4_products_20261101`, with log
`build/logs/mxfp4_products_build_20261101.log` and loader regression log
`build/logs/mxfp4_products_loader.log`. This loader regression passes all
checks, including both complete GEMVs at 45,164 observed cycles. The engine
regression (`build/logs/mxfp4_products_engine.log`) passes repeated RUN,
scale reload, reset retention and Inf/NaN tests (2,932 cycles for finite 64-input
fixtures). Its synthesis used 79,771 LUTs and 123,374 registers. Detailed path
inspection showed that the remaining -0.620 ns path bypassed product registers
through combinational Inf/NaN classification from the activation BRAM.

The final revision registers activation exponent, sign, Inf and NaN metadata
alongside product candidates, with unchanged cycle counts. Its full loader
regression passes (`build/logs/mxfp4_metadata_loader.log`). The implementation
run is `build/moe/mxfp4_final_20261101`, log
`build/logs/mxfp4_final_build_20261101.log`; input SHA256 hashes are saved in
`build/logs/mxfp4_final_source_manifest.json`. Its synthesis uses 80,007 LUTs
(59.44%), 123,418 registers (45.85%), and 37 BRAM tiles. Pre-placement worst
slack is -0.172 ns (40 failing endpoints), now in the Ethernet FIFO-to-loader
control path. The final engine regression also passes
(`build/logs/mxfp4_final_engine.log`). Routed timing remains pending.
