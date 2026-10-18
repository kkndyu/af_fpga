# MoE FPGA Prototype, Pure Verilog Version

This project is a pure Verilog-2001 rewrite of the SystemVerilog prototype.
It avoids SystemVerilog-only constructs such as `logic`, `package`, `enum`,
unpacked array ports, `always_ff`, and `always_comb`.

## Main Parameters

- `H_DIM = 1024`
- `E_DIM = 256`
- `OUT_LANES = 256`
- `REGION_LANES = 64`
- `NUM_REGIONS = 4`
- `WCODE_W = 4`
- `ACT_W = 16`
- `PROD_W = 24`
- `ACC_W = 32`

## Datapath

```text
activation x[k]
  -> fp4_product_gen: creates 16 candidate products
  -> 4 x mac_region
      each region has 64 lanes
      each lane selects one candidate using a 4-bit weight code
      each lane accumulates one output channel
```

## Current Scope

Implemented:

- Single GEMV datapath.
- 256-lane, 4-region MAC structure.
- Region-local weight banks initialized by `$readmemh`.
- Basic simulation scripts.

Skeleton only:

- `expert_engine.v` currently wraps one gate-like GEMV.
- Full `gate -> up -> SiLU/mul -> down` sequencing is intentionally left as
  the next integration step.

## Coding Style

The code intentionally uses a more traditional RTL style:

- Flattened buses instead of array ports.
- Macro include file instead of SystemVerilog package.
- `reg`/`wire` instead of `logic`.
- `always @*` and `always @(posedge clk...)` instead of `always_comb` and
  `always_ff`.
