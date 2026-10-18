#!/usr/bin/env python3
"""Generate memory initialization files for the Verilog MoE FPGA prototype.

This script creates:
  sim/data/input.mem
  sim/data/ref_out.hex
  mem_init/expert0/gate_r0.mem ... gate_r3.mem

The integer product codebook mirrors rtl/core/fp4_product_gen.v.
"""

from __future__ import annotations

import random
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

H_DIM = 1024
OUT_LANES = 256
REGION_LANES = 64
NUM_REGIONS = 4
ACT_W = 16
ACC_W = 32

SEED = 7


def to_hex_signed(value: int, width: int) -> str:
    mask = (1 << width) - 1
    return f"{value & mask:0{width // 4}x}"


def fp4_product(a: int, code: int) -> int:
    # Python right shift is arithmetic for signed ints, matching Verilog >>>.
    table = {
        0x0: 0,
        0x1: a >> 1,
        0x2: a,
        0x3: a + (a >> 1),
        0x4: a << 1,
        0x5: a << 2,
        0x6: a >> 2,
        0x7: 0,
        0x8: 0,
        0x9: -(a >> 1),
        0xA: -a,
        0xB: -(a + (a >> 1)),
        0xC: -(a << 1),
        0xD: -(a << 2),
        0xE: -(a >> 2),
        0xF: 0,
    }
    return table[code & 0xF]


def pack_region_row(codes: list[int]) -> str:
    """Pack 64 4-bit codes into one 256-bit hex line.

    RTL convention: lane j reads wcode_row[j*4 +: 4].  Therefore lane 0 is the
    lowest hex nibble, which appears at the rightmost side of the hex string.
    """
    assert len(codes) == REGION_LANES
    return "".join(f"{codes[i] & 0xF:x}" for i in range(REGION_LANES - 1, -1, -1))


def main() -> None:
    random.seed(SEED)

    (ROOT / "sim/data").mkdir(parents=True, exist_ok=True)
    (ROOT / "mem_init/expert0").mkdir(parents=True, exist_ok=True)

    # Keep activations small so integer reference values stay readable.
    act = [random.randint(-32, 31) for _ in range(H_DIM)]

    # weights[k][j] is a 4-bit FP4 code.
    weights = [
        [random.randint(0, 15) for _ in range(OUT_LANES)]
        for _ in range(H_DIM)
    ]

    with (ROOT / "sim/data/input.mem").open("w") as f:
        for x in act:
            f.write(to_hex_signed(x, ACT_W) + "\n")

    for r in range(NUM_REGIONS):
        path = ROOT / f"mem_init/expert0/gate_r{r}.mem"
        lo = r * REGION_LANES
        hi = lo + REGION_LANES
        with path.open("w") as f:
            for k in range(H_DIM):
                f.write(pack_region_row(weights[k][lo:hi]) + "\n")

    ref = []
    for j in range(OUT_LANES):
        acc = 0
        for k in range(H_DIM):
            acc += fp4_product(act[k], weights[k][j])
        ref.append(acc)

    with (ROOT / "sim/data/ref_out.hex").open("w") as f:
        for y in ref:
            f.write(to_hex_signed(y, ACC_W) + "\n")

    print("Generated activation, weight, and reference files.")


if __name__ == "__main__":
    main()
