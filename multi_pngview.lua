-- multi_pngview: display a PNG across multiple screens.
--
-- Pattern (from MineOS Multiscreen): one GPU is rebound to each target screen
-- via gpu.bind(addr, false). The previously-drawn screen keeps showing its
-- VRAM after unbind, so a single GPU can paint all screens sequentially.
--
-- Each GPU bound to a T3 screen addresses up to 160x50 chars = 320x200 px
-- (with 2x4 braille cells). A 2x1 grid therefore shows 640x200 px, a 2x2
-- grid 640x400 px, etc. The GPU only draws 320x200 at a time but the
-- multi-screen cluster aggregates them.
--
-- Usage:
--   multi_pngview <file.png> <H> <V>                 # auto-picks screens in component.list() order
--   multi_pngview <file.png> <H> <V> <a1> <a2> ...   # explicit row-major addresses
--
-- Flags (any position):
--   --delay=N       display for N seconds then return (default: block until key)
--
-- Calibrate once with `multi_pngview --list` to see screen addresses; then
-- touch each screen in-game and note which one lit up to decide the order.

local ocpng = require("png")
local component = require("component")
local gpu = component.gpu
local event = require("event")
local unicode = require("unicode")

-- Extract --delay=N flag from args before positional parsing
local raw = {...}
local args = {}
local delay = nil
for _, a in ipairs(raw) do
  local n = a:match("^%-%-delay=(%d+%.?%d*)$")
  if n then delay = tonumber(n) else args[#args + 1] = a end
end

if args[1] == "--list" then
  print("connected screens (in component.list order):")
  for addr in component.list("screen") do print("  " .. addr:sub(1, 8) .. "  " .. addr) end
  return
end

local filename = args[1]
local H = tonumber(args[2] or "2")
local V = tonumber(args[3] or "1")

if not filename then
  print("usage: multi_pngview <file.png> <H> <V> [screen_addr1 ...] [--delay=N]")
  print("       multi_pngview --list")
  return
end

-- Collect N = H*V screen addresses, row-major
local N = H * V
local screens = {}
if #args >= 3 + N then
  for i = 1, N do screens[i] = args[3 + i] end
else
  for addr in component.list("screen") do screens[#screens + 1] = addr end
  if #screens < N then
    error("need " .. N .. " screens, have " .. #screens)
  end
end

local origScreen = gpu.getScreen()

-- ========== Load PNG ==========

local png = ocpng.loadPNG(filename)

-- ========== Median-cut 16-color palette over the full image ==========

local NCOLOR = 16
local oDither = {0, 2, 3, 1}
local oDSize = #oDither
local oDWidth = 2

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

local function bucket_range(b)
  local rmin, rmax, gmin, gmax, bmin, bmax = 255, 0, 255, 0, 255, 0
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
  local axis, m = 1, rr
  if gr > m then axis, m = 2, gr end
  if br > m then axis, m = 3, br end
  return m, axis
end

local function bucket_avg(b)
  local r, g, bl = 0, 0, 0
  for i = 1, #b do r, g, bl = r + b[i][1], g + b[i][2], bl + b[i][3] end
  return { math.floor(r / #b), math.floor(g / #b), math.floor(bl / #b) }
end

local function median_cut(samples, n)
  local buckets = { samples }
  while #buckets < n do
    local bi, bm, ba = 1, -1, 1
    for i = 1, #buckets do
      if #buckets[i] > 1 then
        local m, a = bucket_range(buckets[i])
        if m > bm then bi, bm, ba = i, m, a end
      end
    end
    if bm <= 0 then break end
    local b = buckets[bi]
    table.sort(b, function(x, y) return x[ba] < y[ba] end)
    local mid = math.floor(#b / 2)
    local L, R = {}, {}
    for i = 1, mid do L[i] = b[i] end
    for i = mid + 1, #b do R[i - mid] = b[i] end
    buckets[bi] = L
    buckets[#buckets + 1] = R
  end
  local pal = {}
  for i = 1, #buckets do pal[i] = bucket_avg(buckets[i]) end
  while #pal < n do pal[#pal + 1] = { 0, 0, 0 } end
  return pal
end

-- Sample up to 4096 pixels for palette fit
local samples = {}
local total = png.w * png.h
local step = (total > 4096) and math.ceil(math.sqrt(total / 4096)) or 1
for y = 0, png.h - 1, step do
  for x = 0, png.w - 1, step do
    local rgb = png:get(x, y, false)
    samples[#samples + 1] = { (rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF }
  end
end
local palette = median_cut(samples, NCOLOR)

local function colorDistSq(r1, g1, b1, r2, g2, b2)
  local rs = (r1 - r2) * (r1 - r2)
  local gs = (g1 - g2) * (g1 - g2)
  local bs = (b1 - b2) * (b1 - b2)
  local rAvg = (r1 + r2) >> 1
  return (((512 + rAvg) * rs) >> 8) + (4 * gs) + (((767 - rAvg) * bs) >> 8)
end

local function nearest(r, g, b)
  local best, best_d = 0, 1 / 0
  for i = 1, NCOLOR do
    local p = palette[i]
    local d = colorDistSq(r, g, b, p[1], p[2], p[3])
    if d < best_d then best, best_d = i - 1, d end
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

-- Pre-quantize the whole image to palette indices (0..15).
-- Yield every ~10 rows so we don't hit the 5 s "too long without yielding"
-- watchdog on big sources (e.g. 960x600 = 576k pixels).
local idx = {}
for y = 0, png.h - 1 do
  for x = 0, png.w - 1 do
    local rgb = png:get(x, y, false)
    idx[y * png.w + x] = nearest((rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF)
  end
  if y % 10 == 0 then os.sleep(0) end
end

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

-- ========== Render each tile ==========

-- Probe the per-screen resolution by binding to the first screen
gpu.bind(screens[1], false)
local SW, SH = gpu.maxResolution() -- chars per screen

require("term").clear()

for sy = 1, V do
  for sx = 1, H do
    local screen = screens[(sy - 1) * H + sx]
    gpu.bind(screen, false)
    gpu.setResolution(SW, SH)
    gpu.setDepth(gpu.maxDepth())
    for i = 0, NCOLOR - 1 do
      gpu.setPaletteColor(i, (palette[i + 1][1] << 16) | (palette[i + 1][2] << 8) | palette[i + 1][3])
    end
    gpu.setBackground(0, true)
    gpu.setForeground(0, true)
    gpu.fill(1, 1, SW, SH, " ")

    -- Pixel range for this tile: 2*SW wide, 4*SH tall
    local x0 = (sx - 1) * SW * 2
    local y0 = (sy - 1) * SH * 4
    local curBG, curFG = -1, -1

    for yc = 0, SH - 1 do
      for xc = 0, SW - 1 do
        local px = x0 + xc * 2
        local py = y0 + yc * 4
        if px >= png.w or py >= png.h then break end

        local pi = {
          getIdx(px + 1, py + 3), getIdx(px, py + 3),
          getIdx(px + 1, py + 2), getIdx(px, py + 2),
          getIdx(px + 1, py + 1), getIdx(px, py + 1),
          getIdx(px + 1, py),     getIdx(px,     py),
        }

        local cnt, uniq = {}, 0
        for i = 1, 8 do
          if cnt[pi[i]] == nil then uniq = uniq + 1 end
          cnt[pi[i]] = (cnt[pi[i]] or 0) + 1
        end

        local bg, fg, chr
        if uniq == 1 then
          bg, fg, chr = pi[1], pi[1], 0
        else
          local bgc = -1
          for k, v in pairs(cnt) do if v > bgc then bg, bgc = k, v end end
          local bgp = palette[bg + 1]
          local fgc = -1
          for k, v in pairs(cnt) do
            if k ~= bg then
              local kp = palette[k + 1]
              local contrast = colorDistSq(bgp[1], bgp[2], bgp[3], kp[1], kp[2], kp[3]) * v
              if contrast > fgc then fg, fgc = k, contrast end
            end
          end
          chr = 0
          local bgp1, bgp2, bgp3 = bgp[1], bgp[2], bgp[3]
          local fgp = palette[fg + 1]
          local fgp1, fgp2, fgp3 = fgp[1], fgp[2], fgp[3]
          for i = 1, 8 do
            local tpx = px + ((i - 1) & 1)
            local tpy = py + ((i - 1) >> 1)
            local srgb = getRGB(tpx, tpy)
            local sr, sg, sb = (srgb >> 16) & 0xFF, (srgb >> 8) & 0xFF, srgb & 0xFF
            local dDist = ditherDistance(sr, sg, sb, bgp1, bgp2, bgp3, fgp1, fgp2, fgp3)
            local dDi = oDSize - round(dDist * oDSize)
            local dThr = oDither[1 + ((tpy % oDWidth) * oDWidth) + (tpx % oDWidth)]
            if dThr < dDi then chr = chr | (1 << (i - 1)) end
          end
        end

        if bg ~= curBG then gpu.setBackground(bg, true); curBG = bg end
        if fg ~= curFG then gpu.setForeground(fg, true); curFG = fg end
        gpu.set(xc + 1, yc + 1, q[chr + 1])
      end
      if yc % 5 == 0 then os.sleep(0) end
    end
  end
end

-- ========== Wait for key or delay, then restore ==========

if delay then
  event.pull(delay, "key_down")
else
  while true do os.sleep(60) end
end

gpu.bind(origScreen, false)
gpu.setResolution(gpu.maxResolution())
gpu.setBackground(0x000000)
gpu.setForeground(0xFFFFFF)
require("term").clear()
