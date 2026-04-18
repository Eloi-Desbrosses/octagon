# octagon

> the *jack* of all OpenComputers trades

MIT-licensed, see the files themselves for confirmation.

---

This fork adds install ergonomics, a palette-quantizing viewer for T2 GPUs,
and a host-side PNG resizer so people can actually get octagon running on a
new OC computer in < 5 minutes. The upstream library is unchanged apart from
one path fix in `png.lua` — see [Changes from upstream](#changes-from-upstream).

## What's in the box

| File | Role |
|---|---|
| `crc32.lua` | CRC32. Data-card-accelerated if one is installed. |
| `inflate.lua` | DEFLATE decompressor. Data-card-accelerated. |
| `png.lua` | PNG reader. `require("crc32")` + `require("inflate")`. |
| `pngview.lua` | Upstream viewer. Maps pixels to OC's fixed 256-color cube. Best on **T3 GPU + T3 screen**. |
| `pngview_palette.lua` | **New.** Median-cut 16-color palette per image, pushed via `gpu.setPaletteColor`. Looks much better on T2 GPUs. |
| `oczip.lua` | ZIP decompression program. |
| `tools/resize_for_oc.py` | **New.** Host-side: shrinks a PNG until its IDAT fits the OC's energy budget. |

## Install

Drop `crc32.lua`, `inflate.lua`, `png.lua` into a directory that's on your
OpenOS `package.path` (default includes `/home/lib/?.lua` and `/lib/?.lua`):

```
/home/lib/crc32.lua
/home/lib/inflate.lua
/home/lib/png.lua
/home/bin/pngview.lua          # or pngview_palette.lua
```

Quick one-liner using [OPPM](https://ocdoc.cil.li/tutorial:program:oppm)
or manual `wget` from GitHub raw URLs both work — everything is pure Lua.

### Usage

```
pngview foo.png                  # upstream: 256-color cube
pngview_palette foo.png          # per-image 16-color palette (better on T2)
```

Press any key to exit.

## Hardware required

| Part | Min | Recommended | Why |
|---|---|---|---|
| **Data Card (any tier)** | **yes** | T3 | Without it, `inflate` falls back to pure-Lua DEFLATE and hits the 5 s "too long without yielding" watchdog on any nontrivial PNG. |
| Case | T1 (500 energy) | T3 (3200) | `data.inflate` costs ≈ `6 + IDAT_bytes × 0.1` from the buffer. T1 caps source size around **46×45** RGB. |
| CPU + RAM | T2 | T3 | |
| GPU | T2 | T3 | `pngview_palette` handles T2 gracefully. Upstream `pngview` wants T3. |
| Screen | T2 | T3 | `maxDepth`/`maxResolution = min(GPU_tier, screen_tier)`. You need **both** T3 for 160×50 / 8-bit. |

If you pick a large source image but can't afford its inflate, `data.inflate`
returns `nil` silently and `png.lua:177` crashes with
*"attempt to index a nil value (local 'png_data')"*. Resize smaller, upgrade
the case tier, or wire the OC to an external energy source.

## Why `pngview_palette`

Upstream `pngview` quantizes each pixel into OC's fixed 256-color palette
(6×8×5 RGB cube + 16 gray) and then writes the resulting RGB directly with
`gpu.setBackground(rgb)`. On a T3 GPU that renders cleanly. On a **T2 GPU or
T2 screen** the effective depth is 4-bit and OC re-quantizes every RGB it
receives into its internal stock 16-color palette — which is heavy on pure
magenta / cyan / yellow. Photos come out with a strong magenta/cyan cast.

`pngview_palette` fixes this:

1. **Median-cut** over the source pixels to pick 16 colors that represent
   *this* image (skin tones, blacks, ambient, etc.).
2. Push those into the GPU's 16 palette slots with `gpu.setPaletteColor`.
3. Quantize every source pixel to the palette and render with
   `gpu.setBackground(index, true)` / `setForeground(index, true)` — passing
   the **index** instead of an RGB, so the GPU uses our palette, not its
   internal quantizer.

Same braille-dithering output stage as upstream, so rendering performance
is essentially identical.

It works on both T2 and T3 GPUs (both expose the same 16 customizable
palette slots).

## Host-side resizing — `tools/resize_for_oc.py`

```
python tools/resize_for_oc.py image.png                  # T1 case defaults
python tools/resize_for_oc.py image.png --max 80 --energy 1500   # T2
python tools/resize_for_oc.py image.png --max 160 --energy 3100  # T3
```

Outputs `image_oc.png` next to the input. Probes decreasing thumbnail sizes
until the file's combined IDAT chunks fit `(energy − 6) / 0.1` bytes, which
is the largest payload the target OC can inflate in a single `data.inflate`
call without the buffer going dry.

Requires Python ≥ 3.8 and Pillow.

## Changes from upstream

Compared to [ChenThread/octagon@c9d8783](https://github.com/ChenThread/octagon):

1. **`png.lua`** — `dofile("./crc32.lua")` / `dofile("./inflate.lua")` replaced
   with `require("crc32")` / `require("inflate")`.

   *Why:* `dofile` resolves its path against the shell's CWD, not the script's
   directory. If you install `png.lua` to `/home/lib/` (the natural location
   on OpenOS because it's on `package.path`) and run `pngview` from anywhere
   other than `/home/lib/`, the dofiles fail with `file not found:./crc32.lua`.
   `require` uses `package.path` and is location-independent.

2. **`pngview_palette.lua`** added — new viewer (details above).

3. **`tools/resize_for_oc.py`** added — new host helper (details above).

## API reference (unchanged from upstream)

**crc32.lua**

* `crc32.crc32(data, start_value)` — calculate CRC32. Optionally change the start value.

**inflate.lua**

* `inflate.inflate(data)` — like a balloon.

**png.lua** — PNG reader. Depends on `crc32` and `inflate`.

* `png.loadPNG(filename)` — loads the file. Returns a table with:
    * `w`, `h` — width and height
    * `get(x, y, paletted)` — pixel color, RGB888. If `paletted` is true and
      the image is paletted, returns a palette index.
    * `getAlpha(x, y)` — alpha 0–255.
    * `isPaletted()` — bool.
    * `getPaletteCount()` — number of palette colors or 0.
    * `getPaletteEntry(i)` — specific palette entry.

Palette colors are 1-indexed, so a 16-color image has palette colors 1..16.

Still incomplete, please get in touch if your PNGs depend on:

* grayscale images (not indexed or RGB)
* 16 bpc images (48/64 bpp)

Or if you need sPLT / hIST chunks. Out of scope: gamma / colorspace adjustments.

**oczip.lua** — ZIP decompression. Depends on `crc32` and `inflate`.

Currently a program, not a library. `oczip <filename>` with hardcoded output
path `results/`. TODO: refactor into a library.
