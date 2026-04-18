# octagon

> the *jack* of all OpenComputers trades

MIT-licensed, see the files themselves for confirmation.

---

This fork adds install ergonomics, a palette-quantizing viewer for T2 GPUs,
a host-side PNG resizer that understands the OC energy budget, and a README
that documents every edge the upstream code quietly assumes you already know
about (relative paths, GPU depth quantization, energy per inflate, display
resolution caps). The upstream library is unchanged apart from one path fix
in `png.lua` — see [Changes from upstream](#changes-from-upstream).

## What's in the box

| File | Role |
|---|---|
| `crc32.lua` | CRC32. Data-card-accelerated if one is installed. |
| `inflate.lua` | DEFLATE decompressor. Data-card-accelerated. |
| `png.lua` | PNG reader. `require("crc32")` + `require("inflate")`. |
| `pngview.lua` | Upstream viewer. Maps pixels to OC's fixed 256-color cube. Best on **T3 GPU + T3 screen**. |
| `pngview_palette.lua` | **New.** Median-cut 16-color palette per image, pushed via `gpu.setPaletteColor`. Looks much better on T2 GPUs. |
| `resize.lua` | **New.** On-OC PNG resizer. Writes an uncompressed IDAT so encoding doesn't cost energy. |
| `multi_pngview.lua` | **New, prototype.** Displays a PNG across an H×V grid of screens by rebinding the GPU between tiles — one screen draws its 320×200, keeps it in VRAM, GPU moves on. |
| `oczip.lua` | ZIP decompression program. |
| `tools/resize_for_oc.py` | **New.** Host-side: scales a PNG down until its IDAT fits the OC's energy budget. Supports aspect-preserving `--fit thumbnail` and screen-filling `--fit crop`. |
| `examples/batgros_46.png` | **New.** 46×45 demo. Decodes in the default ~500 energy buffer. |
| `examples/batgros_fit.png` | **New.** 200×196 aspect-preserved demo (no crop, black bars left/right on a 320×200 screen). Needs ~6 k energy to decode. |
| `examples/batgros_max.png` | **New.** 320×200 crop-filled demo (fills the screen, edges of the source cropped). Needs ~10 k energy to decode. |

## Install

Drop `crc32.lua`, `inflate.lua`, `png.lua` into a directory that's on your
OpenOS `package.path` (default includes `/home/lib/?.lua` and `/lib/?.lua`):

```
/home/lib/crc32.lua
/home/lib/inflate.lua
/home/lib/png.lua
/home/bin/pngview.lua            # or pngview_palette.lua
/home/bin/resize.lua             # optional
```

Everything is pure Lua. `wget` from GitHub raw URLs works, [OPPM](https://ocdoc.cil.li/tutorial:program:oppm)
works, dropping files into the save folder while the OC is off works.

### Usage

```
pngview foo.png                  # upstream: OC's fixed 256-color cube
pngview foo.png 10               # auto-return after 10 s
pngview_palette foo.png          # per-image 16-color palette (better on T2)
pngview_palette foo.png 5        # auto-return after 5 s
multi_pngview foo.png 3 3 --delay=8    # multi-screen, hold 8 s
resize in.png out.png 46         # on-OC nearest-neighbor resize (max side 46)
resize in.png out.png 32x32      # explicit dimensions
```

Without a delay, the viewer holds the image indefinitely — exit with
Ctrl+C in the shell. With an optional delay (positional for
`pngview`/`pngview_palette`, `--delay=N` flag for `multi_pngview`), the
viewer auto-returns after N seconds — useful when driving the OC from an
MCP bridge or an automation script that needs its shell back.

## Hardware required

| Part | Min | Recommended | Why |
|---|---|---|---|
| **Data Card** | **yes** | T3 | Without it, `inflate` falls back to pure-Lua DEFLATE and hits the 5 s "too long without yielding" watchdog on any nontrivial PNG. |
| Energy pool | 500 | 10 k+ | See [Energy](#energy-budget-in-one-page). The computer's internal buffer is usually 500; extend it with capacitors adjacent to a Power Distributor, or flip `ignorePower=true`. |
| CPU + RAM | T2 | T3 | |
| GPU | T2 | T3 | `pngview_palette` handles T2 gracefully. Upstream `pngview` wants T3. |
| Screen | T2 | T3 | `gpu.maxDepth()` / `gpu.maxResolution()` = `min(GPU_tier, screen_tier)`. Both must be T3 for 160×50 / 8-bit. |

## Why `pngview_palette`

Upstream `pngview` quantizes each pixel into OC's fixed 256-color palette
(6×8×5 RGB cube + 16 gray) and then writes the resulting RGB directly with
`gpu.setBackground(rgb)`. On a T3 GPU that renders cleanly. On a **T2 GPU
or T2 screen** the effective depth is 4-bit and OC re-quantizes every RGB
it receives into its internal stock 16-color palette — which is heavy on
pure magenta / cyan / yellow. Photos come out with a strong magenta/cyan
cast.

`pngview_palette` fixes this:

1. **Median-cut** over the source pixels to pick 16 colors that represent
   *this* image (skin tones, blacks, ambient, etc.).
2. Push those into the GPU's 16 palette slots with `gpu.setPaletteColor`.
3. Quantize every source pixel to the palette and render with
   `gpu.setBackground(index, true)` / `setForeground(index, true)` —
   passing the **index** instead of an RGB, so the GPU uses our palette
   rather than re-quantizing.

Same braille-dithering output stage as upstream. Works on T2 *and* T3 GPUs
(both expose 16 custom palette slots). On a clean T3 GPU+screen upstream
`pngview` gives more color variety (240-cube); everywhere else, palette
wins.

## Energy budget in one page

Every `data.inflate(IDAT)` call costs energy out of the computer's pool:

```
cost_inflate = 6   + 0.1   × IDAT_bytes     (dataCardComplex)
cost_crc32   = 0.2 + 0.005 × IDAT_bytes     (dataCardTrivial, one per chunk)
cost_total   ≈ 6.2 + 0.105 × IDAT_bytes
```

When a call would exceed the available pool, the data card silently
returns `nil`, and `png.lua:177` crashes with
*"attempt to index a nil value (local 'png_data')"*.

### Where the pool comes from

Unlike most OC documentation implies, the **case tier doesn't raise the
energy buffer by itself** in most modpack configs — `settings.conf`'s
`computer=500` is a flat number applied to every tier. The real knobs:

1. **Capacitor adjacency**.  Each capacitor block is 1600 energy, with
   a configurable 800 bonus per adjacent capacitor (up to two neighbors).
   3 capacitors in a row pool 8.8 k; a 5-wall of them pools tens of k.
   Connect the first capacitor to a **Power Distributor**, and the
   Distributor to the OC case. The pool is reported live by
   `computer.maxEnergy()`.

2. **`ignorePower=true`** in `config/opencomputers/settings.conf`
   (nuclear option). Every energy check succeeds; pool size no longer
   matters. Requires MC restart.

3. **Lower the per-byte cost** via the same config
   (`dataCardComplexByte=0.01` instead of `0.1` = 10× cheaper). Also
   requires MC restart.

### What source size fits a given pool

| Pool | Max IDAT bytes | ~Max Batgros-like photo |
|---|---:|---|
| 500   (stock) | ~4 700   | 46×45   |
| 2 500 | ~23 700  | 115×113 |
| 10 000 | ~95 200  | ~200×196 |
| 40 000 | ~380 800 | fills full 320×200 screen with room to spare |

`tools/resize_for_oc.py --energy <pool>` picks the exact size that fits.

## Resolution ceiling: 160×50 chars = 320×200 px

`pngview` renders one 2×4-pixel block per terminal character using Braille
glyphs. The max is set by the GPU:

| GPU + Screen | Max chars | Effective pixels |
|---|---|---|
| both T1 | 50×16 | 100×64 |
| both T2 | 80×25 | 160×100 |
| both T3 | **160×50** | **320×200** |

A single GPU cannot go beyond 160×50 characters no matter what. You *can*
build a **physically larger screen** in-world (`maxScreenWidth=8`,
`maxScreenHeight=6` in config, so up to 8×6 = 48 blocks), but the
addressable resolution stays at 160×50 — each logical pixel just covers
more in-game blocks.

For **more than 320×200 px**, use multiple screens and have one GPU paint
each in turn — that's what `multi_pngview.lua` does. See
[Multi-screen clusters](#multi-screen-clusters).

## Multi-screen clusters

`multi_pngview.lua` displays a single PNG across an H×V grid of screens.
Borrowed pattern from MineOS's Multiscreen.app: one GPU is rebound to
each screen sequentially via `gpu.bind(addr, false)`, and every bound
screen keeps its VRAM after the GPU moves on. So one T3 GPU can paint a
2×1 cluster for 540×200 px, 3×3 for 810×600 px, 4×4 for 1080×800 px, etc.

```
multi_pngview --list                              # enumerate screens + addresses
multi_pngview img.png 3 3                         # auto-pick 9 screens
multi_pngview img.png 3 3 addr1 addr2 ...         # explicit row-major order
multi_pngview img.png 3 3 --delay=60              # auto-return after 60 s
multi_pngview img.png 3 3 --tile=320x200          # override per-screen pixel dims
```

Quantization (median-cut to 16 colors) runs once over the whole source
image so tile boundaries don't show palette shifts — each screen gets the
same palette via `gpu.setPaletteColor`.

### Per-tile pixel size (`--tile=WxH`)

Defaults to **270×200**, which matches the physical aspect of a T3 screen
better than the full 320×200 GPU resolution. Override with `--tile=320x200`
if you want to use every last char column on each screen (physical image
stretches slightly wider), or `--tile=200x200` for a square tile on very
tall multi-block screens.

Char resolution per screen = `ceil(tileW/2) × ceil(tileH/4)`. The default
270×200 → 135×50 chars per screen, leaving 25 unused char cols that
blend into the tile's background color (palette slot 0 = darkest from the
median-cut, usually near-black).

### No-crop centering

If the source PNG is smaller than `H × tileW` by `V × tileH`, it's drawn
**centered** with palette-0 padding around it — no cropping. That matches
what Pillow's `ImageOps.fit` with *thumbnail* mode produces host-side.
Useful when the image aspect doesn't perfectly match the grid aspect.

### Memory and grid size

Each source pixel goes through two heavy buffers during render:

1. `png.lua` defilter keeps one string per row of decoded RGB → total
   size `height × width × 3` bytes.
2. Quantized palette indices (`idx_rows`) → `height × width` bytes.

Peak RAM ≈ **4 × width × height bytes**. A stock-ish T3 server reports
~4 MB free after boot, so:

| Grid | Tile | Canvas | Peak RAM | Fits 4 MB free? |
|---|---|---|---:|---|
| 3×3 | 270×200 | 810×600 | 1.9 MB | ✅ |
| 4×4 | 270×200 | 1080×800 | 3.5 MB | ✅ (tight) |
| 5×5 | 270×200 | 1350×1000 | 5.4 MB | ❌ OOM |
| 6×6 | 270×200 | 1620×1200 | 7.8 MB | ❌ OOM |
| 7×7 | 270×200 | 1890×1400 | 10.6 MB | ❌ OOM |

If your server RAM is larger (RAM-upgraded modpack or beefier memory
config), scale accordingly. The component limit is separate — a T3 server
with Component Bus cards lifts the component cap to ~64, enough for 7×7
on the component side, but RAM will cut you off before then unless you
raise it explicitly.

### Rendering time

Roughly **2–3 s per 1000 char cells** on a T3 APU. A 4×4 at 270×200 is
16 × 135 × 50 = 108 k cells → ~3–4 min end-to-end including decode.
Most of that is pure-Lua quantize + dither — scales linearly in canvas
pixels.

### Calibration: who-is-who

The row-major address list you pass to `multi_pngview` has to match the
physical wall layout. To figure that out, run `calibrate.lua` once:

```
wget https://raw.githubusercontent.com/Eloi-Desbrosses/octagon/master/calibrate.lua /home/calibrate.lua
./calibrate.lua
```

It paints each screen with a distinct color and a big 1–N digit (two
digits for grids bigger than 9). Walk up to the wall, take a screenshot,
and read off the indices. The N-th digit corresponds to the N-th address
returned by `component.list("screen")`, which is also what `--list` prints.

Build your row-major `multi_pngview` argv from that map. Example for a
3×3 where the wall looks like:

```
 2 9 8
 3 10 6
 7 5 4
```

Pass `<screens[2]> <screens[9]> <screens[8]> <screens[3]> ...` to
`multi_pngview`. Screens not in the visible grid (the console, standalone
screens in the world) just don't show up in the screenshot.

### Other limitations

- Energy budget applies to the one-shot `inflate` on the whole IDAT plus
  the CRC32 on each chunk. For a 1080×800 source that's ~60 k energy.
- RAM is the real ceiling — see the table above.
- One GPU drives all screens via rebinding. Multiple GPUs could parallelize
  but the current code is sequential.

## Host-side resizing — `tools/resize_for_oc.py`

Two shapes, same budget logic:

```bash
# Aspect-preserving thumbnail that fits in a max×max box
python tools/resize_for_oc.py img.png --max 200 --energy 10000

# Screen-filling crop into a width×height box (default 320×200 = full T3)
python tools/resize_for_oc.py img.png --fit crop --width 320 --height 200 --energy 10000
```

Outputs `img_oc.png` next to the input (or use an explicit output path).
Probes decreasing sizes until the resulting IDAT fits
`(energy − 6.2) / 0.105` bytes, which matches the total energy cost of
CRC32 + inflate through `png.loadPNG`.

Requires Python ≥ 3.8 and Pillow.

## On-OC resizing — `resize.lua`

If you want a smaller copy of a PNG that already lives on the OC:

```
resize in.png out.png 46           # aspect-preserved, longest side = 46 px
resize in.png out.png 32x32        # explicit dimensions
```

Uses nearest-neighbor resampling. Emits a valid PNG with an
**uncompressed** IDAT (zlib of `BTYPE=00` / "stored" DEFLATE blocks), so
the encode step does **not** touch `data.deflate` — it can't, because
deflate's energy cost profile is the same as inflate and would blow the
same budget we're trying to dodge.

The catch: the output IDAT is larger than a properly compressed PNG would
be (essentially: raw filtered scanlines), which means its *inflate* cost
at display time is `6 + filtered_bytes × 0.1`. For a 46×45 RGB image
that's ~632 energy — more than a default 500 pool holds. `resize.lua`
prints the expected inflate cost after writing.

| Scenario | Tool |
|---|---|
| Big PNG on disk, want to drop it on an OC | `tools/resize_for_oc.py` on the host — optimal compression, smallest IDAT |
| Small PNG already on OC, want a smaller copy | `resize.lua` on the OC — works, but the output IDAT is larger |

## Changes from upstream

Compared to [ChenThread/octagon@c9d8783](https://github.com/ChenThread/octagon):

1. **`png.lua`** — `dofile("./crc32.lua")` / `dofile("./inflate.lua")`
   replaced with `require("crc32")` / `require("inflate")`.

   *Why:* `dofile` resolves its path against the shell's CWD, not the
   script's directory. Install `png.lua` to `/home/lib/` (the natural
   location on OpenOS because it's on `package.path`) and invoke `pngview`
   from anywhere else, and the dofiles fail with
   `file not found:./crc32.lua`. `require` uses `package.path` and is
   location-independent.

2. **`pngview_palette.lua`** — new viewer using a per-image median-cut
   palette (details above).

3. **`resize.lua`** — new on-OC resizer that emits uncompressed IDATs so
   the encode step costs no data-card energy.

4. **`tools/resize_for_oc.py`** — new host helper. Budget formula
   accounts for both CRC32 and inflate (0.105/byte), and supports both
   thumbnail and crop fit modes.

5. **`multi_pngview.lua`** (prototype) — paints one image across N screens
   by rebinding a single GPU, same approach as MineOS's Multiscreen.app.

6. **Examples** — `examples/batgros_46.png` (small demo) and
   `examples/batgros_max.png` (full 320×200 screen-filler).

7. **README** — install, hardware, energy, colors, resolution, tools,
   troubleshooting.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `png.lua:177: attempt to index a nil value (local 'png_data')` | `data.inflate` returned nil → source IDAT too big for the current energy pool. Check `computer.maxEnergy()`, add capacitors, or resize smaller with `resize_for_oc.py`. |
| `file not found:./crc32.lua` | Using the unpatched upstream `png.lua`. Replace it with this fork's `png.lua`, or do the one-line patch by hand. |
| `too long without yielding` | No Data Card — pure-Lua inflate can't finish in 5 s. Install a Data Card (T1 is fine for the call). |
| Image renders but colors are heavy magenta / cyan | GPU or screen is T2 → use `pngview_palette`, or upgrade both to T3. |
| `computer.maxEnergy()` returns 500 even after building a huge capacitor bank | The capacitors aren't connected to the OC's power network. They need to sit adjacent to a **Power Distributor** (or to another capacitor that's adjacent to one), with the Distributor in turn adjacent to the OC case. Watch `computer.maxEnergy()` change live while you place blocks. |
| `shell.execute` returns `false, nil` | Silent error inside pngview. Run via `loadfile(...) + xpcall(..., debug.traceback)` to get the real stack. |
| After editing files in the save folder, the OC doesn't see the change | OC caches FS in memory while running. Edit with the OC **off**, or have the OC re-fetch with `internet.request`. |
| pngview hangs after rendering | It's waiting for a keypress on the OC keyboard. Press any key in-game to exit. |

## API reference (unchanged from upstream)

**crc32.lua**

* `crc32.crc32(data, start_value)` — calculate CRC32. Optionally change the start value.

**inflate.lua**

* `inflate.inflate(data)` — like a balloon.

**png.lua** — PNG reader. Depends on `crc32` and `inflate`.

* `png.loadPNG(filename)` — returns a table with:
    * `w`, `h` — width and height.
    * `get(x, y, paletted)` — pixel color, RGB888. If `paletted` is true
      and the image is paletted, returns a palette index instead.
    * `getAlpha(x, y)` — alpha 0–255.
    * `isPaletted()` — bool.
    * `getPaletteCount()` — number of palette colors or 0.
    * `getPaletteEntry(i)` — specific palette entry.

Palette colors are 1-indexed, so a 16-color image has palette colors 1..16.

Still incomplete; please get in touch if your PNGs depend on:

* grayscale images (not indexed or RGB)
* 16 bpc images (48/64 bpp)
* sPLT / hIST chunks

Out of scope: gamma / colorspace adjustments.

**oczip.lua** — ZIP decompression. Depends on `crc32` and `inflate`.

Currently a program, not a library. `oczip <filename>` with hardcoded
output path `results/`. TODO: refactor into a library.
