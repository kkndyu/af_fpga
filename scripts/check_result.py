#!/usr/bin/env python3
"""Compare RTL output against Python reference."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REF = ROOT / "sim/data/ref_out.hex"
RTL = ROOT / "sim/data/rtl_out.hex"


def read_hex_lines(path: Path) -> list[str]:
    return [line.strip().lower() for line in path.read_text().splitlines() if line.strip()]


def main() -> None:
    if not RTL.exists():
        raise SystemExit(f"Missing {RTL}. Run simulation first.")

    ref = read_hex_lines(REF)
    rtl = read_hex_lines(RTL)

    if len(ref) != len(rtl):
        raise SystemExit(f"Length mismatch: ref={len(ref)} rtl={len(rtl)}")

    mismatches = []
    for i, (a, b) in enumerate(zip(ref, rtl)):
        if a != b:
            mismatches.append((i, a, b))
            if len(mismatches) >= 16:
                break

    if mismatches:
        print("Mismatch examples:")
        for idx, a, b in mismatches:
            print(f"  lane {idx}: ref={a} rtl={b}")
        raise SystemExit(1)

    print(f"PASS: {len(ref)} lanes match.")


if __name__ == "__main__":
    main()
