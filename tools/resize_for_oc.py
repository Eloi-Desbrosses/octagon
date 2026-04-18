#!/usr/bin/env python3
"""Resize an image to fit OpenComputers' octagon pngview budget.

Usage:
    python resize_for_oc.py <input.png> [<output.png>] [--max SIZE] [--energy N]

Defaults: max=46 (safe for default case T1 energy buffer ~500, ~488 available).
Raise --max to 80 / 120 / 160 if the target computer has a bigger energy
buffer (case T2 ~1500, case T3 ~3200, or external power).

Empirical calibration (case T1, data card T3, ~488 available energy):
  IDAT bytes <= (E_avail - 6) / 0.1  -> max ~4820 bytes (~46x45 photo)
"""
import argparse
import os
import sys
from PIL import Image


def extract_idat(png_bytes: bytes) -> int:
    pos = 8
    total = 0
    while pos < len(png_bytes):
        ln = int.from_bytes(png_bytes[pos:pos + 4], "big")
        typ = png_bytes[pos + 4:pos + 8]
        if typ == b"IDAT":
            total += ln
        if typ == b"IEND":
            break
        pos += 8 + ln + 4
    return total


def budget_to_max_idat(energy: float) -> float:
    # octagon's png.lua runs CRC32 over each chunk BEFORE it inflates the IDAT.
    # For a single-IDAT photo both calls hit the same data-card byte cost:
    #   inflate: 6     + 0.1   per byte   (dataCardComplex + ComplexByte)
    #   crc32:   0.2   + 0.005 per byte   (dataCardTrivial + TrivialByte)
    # So the effective per-byte cost to get the IDAT through png.loadPNG is
    # ~0.105, plus ~6.2 fixed.
    return (energy - 6.2) / 0.105


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("input")
    ap.add_argument("output", nargs="?")
    ap.add_argument("--max", type=int, default=46,
                    help="max dimension in pixels (default 46, safe for T1 case)")
    ap.add_argument("--energy", type=float, default=488,
                    help="available OC energy buffer (default 488, T1 case)")
    args = ap.parse_args()

    out = args.output or args.input.rsplit(".", 1)[0] + "_oc.png"
    budget = budget_to_max_idat(args.energy)
    print(f"energy budget: {args.energy:.0f} -> max IDAT ~{budget:.0f} bytes")

    im = Image.open(args.input).convert("RGB")
    print(f"source: {im.size} mode=RGB")

    target = args.max
    while target >= 8:
        im2 = im.copy()
        im2.thumbnail((target, target))
        tmp_out = out
        im2.save(tmp_out, "PNG", optimize=True)
        with open(tmp_out, "rb") as f:
            data = f.read()
        idat = extract_idat(data)
        fits = idat <= budget
        flag = "OK" if fits else "TOO BIG"
        print(f"  try {target}px -> {im2.size} file={len(data)} IDAT={idat} [{flag}]")
        if fits:
            print(f"saved: {tmp_out}  ({im2.size}, {len(data)} bytes, IDAT {idat})")
            return 0
        target -= max(1, target // 16)
    print("ERROR: couldn't find a size that fits the budget. Raise --energy (bigger case) or use a smaller --max.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
