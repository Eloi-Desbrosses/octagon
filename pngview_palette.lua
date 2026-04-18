-- pngview_palette: PNG viewer with per-image median-cut palette (16 colors)
--
-- Unlike the upstream pngview.lua (which maps pixels to OC's fixed 256-color
-- cube — heavy magenta/cyan cast on T2 GPUs), this version computes a custom
-- 16-color palette tuned to the source image and pushes it to the GPU via
-- setPaletteColor. Works on T2 and T3 GPUs (both expose 16 palette slots).
--
-- Usage:  pngview_palette <file.png> [delay_seconds]
--         pngview_palette <file.png>       -- blocks until any key
--         pngview_palette <file.png> 5     -- displays for 5s then returns
--
-- Source: adapted from ChenThread/octagon pngview.lua

local args = {...}
local filename = args[1]
local delay = tonumber(args[2])
if not filename then
  print("usage: pngview_palette <file.png> [delay_seconds]")
  return
end

local ocpng = require("png")
local component = require("component")
local event = require("event")
local gpu = component.gpu
local unicode = require("unicode")
local keyboard = require("keyboard")

local NCOLOR = 16 -- OC GPUs expose 16 custom palette slots

-- 2x2 Bayer dither
local oDither = {0, 2, 3, 1}
local oDSize = #oDither
local oDWidth = 2

-- Braille chars (0x2800 base + 8-bit dot mask, bit-reordered to pngview's scheme)
local q = {}
for i = 0, 255 do
  local dat = (i & 0x01) << 7
  dat = dat | (i & 0x02) >> 1 << 6
  dat = dat | (i & 0x04) >> 2 << 5
  dat = dat | (i & 0x08) >> 3 << 2
  dat = dat | (i & 0x10) >> 4 << 4
  dat = dat | (i & 0x20) >> 5 << 1
  dat = dat | (i & 0x40) >> 6 << 3
  dat = dat | (i & 0x80) >> 7
  q[i + 1] = unicode.char(0x2800 | dat)
end

local function round(v) return math.floor(v + 0.5) end

-- ========== Median-cut palette generation ==========
-- Samples: flat list of {r,g,b} 0..255
-- Returns: table of n {r,g,b}

local function bucket_range(b)
  local rmin, rmax = 255, 0
  local gmin, gmax = 255, 0
  local bmin, bmax = 255, 0
  for i = 1, #b do
    local p = b[i]
    if p[1] < rmin then rmin = p[1] end
    if p[1] > rmax then rmax = p[1] end
    if p[2] < gmin then gmin = p[2] end
    if p[2] > gmax then gmax = p[2] end
    if p[3] < bmin then bmin = p[3] end
    if p[3] > bmax then bmax = p[3] end
  end
  local rr, gr, br = rmax - rmin, gmax - gmin, bmax - bmin
  local axis = 1
  local m = rr
  if gr > m then axis = 2; m = gr end
  if br > m then axis = 3; m = br end
  return m, axis
end

local function bucket_avg(b)
  local r, g, bl = 0, 0, 0
  local n = #b
  for i = 1, n do
    r = r + b[i][1]; g = g + b[i][2]; bl = bl + b[i][3]
  end
  return {math.floor(r / n), math.floor(g / n), math.floor(bl / n)}
end

local function median_cut(samples, n)
  local buckets = {samples}
  while #buckets < n do
    local best_idx, best_m, best_axis = 1, -1, 1
    for i = 1, #buckets do
      if #buckets[i] > 1 then
        local m, axis = bucket_range(buckets[i])
        if m > best_m then best_m = m; best_idx = i; best_axis = axis end
      end
    end
    if best_m <= 0 then break end
    local b = buckets[best_idx]
    table.sort(b, function(a, c) return a[best_axis] < c[best_axis] end)
    local mid = math.floor(#b / 2)
    local left, right = {}, {}
    for i = 1, mid do left[i] = b[i] end
    for i = mid + 1, #b do right[i - mid] = b[i] end
    buckets[best_idx] = left
    buckets[#buckets + 1] = right
  end
  local palette = {}
  for i = 1, #buckets do palette[i] = bucket_avg(buckets[i]) end
  -- pad with zeros if we got fewer (e.g. tiny images)
  while #palette < n do palette[#palette + 1] = {0, 0, 0} end
  return palette
end

-- ========== Color math ==========

local function rgb_pack(rgb)
  return (rgb[1] << 16) | (rgb[2] << 8) | rgb[3]
end

local function colorDistSq(r1, g1, b1, r2, g2, b2)
  local rs = (r1 - r2) * (r1 - r2)
  local gs = (g1 - g2) * (g1 - g2)
  local bs = (b1 - b2) * (b1 - b2)
  local rAvg = (r1 + r2) >> 1
  return (((512 + rAvg) * rs) >> 8) + (4 * gs) + (((767 - rAvg) * bs) >> 8)
end

-- nearest palette index (0..NCOLOR-1) for rgb integer
local function nearest(palette, r, g, b)
  local best, best_d = 0, 1 / 0
  for i = 1, #palette do
    local p = palette[i]
    local d = colorDistSq(r, g, b, p[1], p[2], p[3])
    if d < best_d then best_d = d; best = i - 1 end
  end
  return best
end

local function ditherDistance(r, g, b, r1, g1, b1, r2, g2, b2)
  if r1 == r2 and g1 == g2 and b1 == b2 then return 0.5 end
  local num = (r * r1 - r * r2 - r1 * r2 + r2 * r2 +
               g * g1 - g * g2 - g1 * g2 + g2 * g2 +
               b * b1 - b * b2 - b1 * b2 + b2 * b2)
  local den = ((r1 - r2) * (r1 - r2) + (g1 - g2) * (g1 - g2) + (b1 - b2) * (b1 - b2))
  return num / den
end

-- ========== Optional raw-pixel cache ==========
-- Sidecar file <source>.oct holds the decoded RGB pixel buffer. When
-- present and newer than the source, pngview_palette skips ocpng.loadPNG
-- entirely — no data.inflate call, no CRC32, no energy. Median-cut and
-- quantization still run (pure Lua, no energy cost). Cache format:
--   "OCT1"       4 bytes magic
--   w  (u16 BE)  image width
--   h  (u16 BE)  image height
--   pixels       w*h*3 bytes, row-major RGB
local fs = require("filesystem")
local CACHE_MAGIC = "OCT1"

local function cache_path_for(src) return src .. ".oct" end

local function load_cache(src)
  local cp = cache_path_for(src)
  if not fs.exists(cp) then return nil end
  if fs.lastModified(cp) < fs.lastModified(src) then return nil end
  local f = io.open(cp, "rb")
  if not f then return nil end
  local magic = f:read(4)
  if magic ~= CACHE_MAGIC then f:close(); return nil end
  local hdr = f:read(4)
  if not hdr or #hdr < 4 then f:close(); return nil end
  local w = (hdr:byte(1) << 8) | hdr:byte(2)
  local h = (hdr:byte(3) << 8) | hdr:byte(4)
  local data = f:read(w * h * 3)
  f:close()
  if not data or #data < w * h * 3 then return nil end
  return {
    w = w, h = h,
    get = function(_, x, y)
      if x >= w then x = w - 1 end
      if y >= h then y = h - 1 end
      local off = (y * w + x) * 3 + 1
      return (data:byte(off) << 16) | (data:byte(off + 1) << 8) | data:byte(off + 2)
    end,
  }
end

local function write_cache(png, src)
  local f = io.open(cache_path_for(src), "wb")
  if not f then return end
  f:write(CACHE_MAGIC)
  f:write(string.char((png.w >> 8) & 0xFF, png.w & 0xFF,
                      (png.h >> 8) & 0xFF, png.h & 0xFF))
  for y = 0, png.h - 1 do
    local row = {}
    for x = 0, png.w - 1 do
      local rgb = png:get(x, y, false)
      row[#row + 1] = string.char((rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF)
    end
    f:write(table.concat(row))
  end
  f:close()
end

-- ========== Main pipeline ==========

local png = load_cache(filename)
if not png then
  png = ocpng.loadPNG(filename)
  pcall(write_cache, png, filename)
end

-- Sample pixels for palette. For source <=4096 px we use all; else decimate.
local samples = {}
local total = png.w * png.h
local step = 1
if total > 4096 then step = math.ceil(math.sqrt(total / 4096)) end
for y = 0, png.h - 1, step do
  for x = 0, png.w - 1, step do
    local rgb = png:get(x, y, false)
    samples[#samples + 1] = {(rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF}
  end
end

local palette = median_cut(samples, NCOLOR)

-- Pre-index the full image against the chosen palette
local idx = {} -- y*w + x -> palette index (0..15)
for y = 0, png.h - 1 do
  for x = 0, png.w - 1 do
    local rgb = png:get(x, y, false)
    idx[y * png.w + x] = nearest(palette, (rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF)
  end
end

-- Clear the terminal BEFORE shrinking resolution so stale prompt text doesn't
-- persist in the new coordinate space.
require("term").clear()

-- Push palette to GPU slots 0..15
local function hexcol(p) return (p[1] << 16) | (p[2] << 8) | p[3] end
for i = 0, NCOLOR - 1 do gpu.setPaletteColor(i, hexcol(palette[i + 1])) end

-- Render: each char = 2x4 pixels, pick 2 most common palette indices, dither
local charW = math.ceil(png.w / 2)
local charH = math.ceil(png.h / 4)
gpu.setResolution(charW, charH)
gpu.setBackground(0, true)
gpu.setForeground(0, true)
gpu.fill(1, 1, charW, charH, " ")

local function getIdx(x, y)
  if x >= png.w then x = png.w - 1 end
  if y >= png.h then y = png.h - 1 end
  return idx[y * png.w + x]
end

local function getRGB(x, y)
  if x >= png.w then x = png.w - 1 end
  if y >= png.h then y = png.h - 1 end
  return png:get(x, y, false)
end

local curBG, curFG = -1, -1
for yc = 0, charH - 1 do
  local runStr = ""
  local runBG, runFG, runX = -1, -1, 0
  for xc = 0, charW - 1 do
    -- Collect the 8 pixel indices in the block
    local pi = {
      getIdx(xc * 2 + 1, yc * 4 + 3), getIdx(xc * 2, yc * 4 + 3),
      getIdx(xc * 2 + 1, yc * 4 + 2), getIdx(xc * 2, yc * 4 + 2),
      getIdx(xc * 2 + 1, yc * 4 + 1), getIdx(xc * 2, yc * 4 + 1),
      getIdx(xc * 2 + 1, yc * 4),     getIdx(xc * 2,     yc * 4),
    }
    -- Count palette indices
    local cnt = {}
    local uniq = 0
    for i = 1, 8 do
      if cnt[pi[i]] == nil then uniq = uniq + 1 end
      cnt[pi[i]] = (cnt[pi[i]] or 0) + 1
    end
    local bg, fg, chr
    if uniq == 1 then
      bg = pi[1]; fg = pi[1]; chr = 0
    else
      -- bg = most common
      local bgc = -1
      for k, v in pairs(cnt) do if v > bgc then bg = k; bgc = v end end
      -- fg = farthest-weighted from bg
      local bgp = palette[bg + 1]
      local fgc = -1
      for k, v in pairs(cnt) do
        if k ~= bg then
          local kp = palette[k + 1]
          local contrast = colorDistSq(bgp[1], bgp[2], bgp[3], kp[1], kp[2], kp[3]) * v
          if contrast > fgc then fg = k; fgc = contrast end
        end
      end
      -- Bayer-dither each pixel between bg and fg
      chr = 0
      local bgp1, bgp2, bgp3 = bgp[1], bgp[2], bgp[3]
      local fgp = palette[fg + 1]
      local fgp1, fgp2, fgp3 = fgp[1], fgp[2], fgp[3]
      for i = 1, 8 do
        local px = xc * 2 + ((i - 1) & 1)
        local py = yc * 4 + ((i - 1) >> 1)
        local srgb = getRGB(px, py)
        local sr, sg, sb = (srgb >> 16) & 0xFF, (srgb >> 8) & 0xFF, srgb & 0xFF
        local dDist = ditherDistance(sr, sg, sb, bgp1, bgp2, bgp3, fgp1, fgp2, fgp3)
        local dDi = oDSize - round(dDist * oDSize)
        local dThr = oDither[1 + ((py % oDWidth) * oDWidth) + (px % oDWidth)]
        if dThr < dDi then chr = chr | (1 << (i - 1)) end
      end
    end
    -- Flush: set BG/FG indices, draw one char
    if bg ~= curBG then gpu.setBackground(bg, true); curBG = bg end
    if fg ~= curFG then gpu.setForeground(fg, true); curFG = fg end
    gpu.set(xc + 1, yc + 1, q[chr + 1])
  end
end

if delay then
  event.pull(delay, "key_down")
else
  while true do os.sleep(60) end
end

gpu.setResolution(gpu.maxResolution())
gpu.setBackground(0x000000)
gpu.setForeground(0xFFFFFF)
require("term").clear()
