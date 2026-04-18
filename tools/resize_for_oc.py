#!/usr/bin/env python3
"""Resize a PNG to fit OpenComputers' octagon pngview budget.

Usage:
    python resize_for_oc.py <input.png> [<output.png>] [options]

Options:
    --max N           longest-side pixel cap (default 46)
    --energy N        OC energy buffer the target has (default 488)
    --fit thumbnail   aspect-preserving fit inside --max x --max box (default)
    --fit crop        fill a --width x --height box exactly by scale+center-crop
    --width W         with --fit crop: output width in pixels
    --height H        with --fit crop: output height in pixels

Empirical calibration (default case, data card, one render):
    cost_per_byte_through_loadPNG ~= 0.1  (inflate) + 0.005 (crc32)
    max IDAT bytes = (energy - 6.2) / 0.105

Display cap on a T3 GPU + T3 screen is 160x50 characters. pngview uses 2x4
braille cells, so the rendered pixel buffer tops out at 320x200 effective
pixels regardless of source. Going larger than 320x200 in source just means
pngview's setResolution request exceeds maxResolution.
"""
import argparse
import os
import sys
from PIL import Image, ImageOps


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


def save_and_measure(im: Image.Image, path: str) -> int:
    im.save(path, "PNG", optimize=True, compress_level=9)
    with open(path, "rb") as f:
        data = f.read()
    return extract_idat(data)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("input")
    ap.add_argument("output", nargs="?")
    ap.add_argument("--max", type=int, default=46,
                    help="longest-side pixel cap (default 46, safe for default case)")
    ap.add_argument("--energy", type=float, default=488,
                    help="available OC energy buffer (default 488)")
    ap.add_argument("--fit", choices=("thumbnail", "crop"), default="thumbnail",
                    help="thumbnail = aspect-preserving inside --max box (default); "
                         "crop = fill a --width x --height box exactly")
    ap.add_argument("--width", type=int, default=320, help="with --fit crop")
    ap.add_argument("--height", type=int, default=200, help="with --fit crop")
    args = ap.parse_args()

    out = args.output or args.input.rsplit(".", 1)[0] + "_oc.png"
    budget = budget_to_max_idat(args.energy)
    print(f"energy budget: {args.energy:.0f} -> max IDAT ~{budget:.0f} bytes")

    im = Image.open(args.input).convert("RGB")
    print(f"source: {im.size} mode=RGB")

    if args.fit == "crop":
        tw, th = args.width, args.height
        # Shrink the target box until the resulting IDAT fits the budget.
        # Maintain the box aspect ratio — we just scale box_w and box_h together.
        scale = 1.0
        while scale >= 0.05:
            w = max(4, int(tw * scale))
            h = max(4, int(th * scale))
            im2 = ImageOps.fit(im, (w, h), Image.LANCZOS, centering=(0.5, 0.5))
            idat = save_and_measure(im2, out)
            fits = idat <= budget
            print(f"  try {w}x{h} -> IDAT={idat} [{'OK' if fits else 'TOO BIG'}]")
            if fits:
                print(f"saved: {out}  ({im2.size}, IDAT {idat})")
                return 0
            scale *= 0.9
    else:  # thumbnail
        target = args.max
        while target >= 8:
            im2 = im.copy()
            im2.thumbnail((target, target))
            idat = save_and_measure(im2, out)
            fits = idat <= budget
            print(f"  try {target}px -> {im2.size} IDAT={idat} [{'OK' if fits else 'TOO BIG'}]")
            if fits:
                print(f"saved: {out}  ({im2.size}, IDAT {idat})")
                return 0
            target -= max(1, target // 16)

    print("ERROR: couldn't find a size that fits the budget. Raise --energy (bigger "
          "buffer via capacitors / config) or drop --max/--width/--height.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
