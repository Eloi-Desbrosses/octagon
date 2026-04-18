-- resize: shrink a PNG to fit the target OC's inflate energy budget.
--
-- Runs on the OC itself. Useful when you already have a small-enough PNG
-- on the computer and want variants (e.g. sized for a different screen
-- or a tighter energy budget on another machine).
--
-- Usage:
--   resize <in.png> <out.png> <max_dim>
--       max_dim: longest side of the output in pixels, aspect preserved
--   resize <in.png> <out.png> <w>x<h>
--       explicit width x height (no aspect preservation)
--
-- Output format: RGB (color type 2), 8 bpc, one filter-none scanline per row,
-- IDAT payload as "stored" (uncompressed) DEFLATE blocks wrapped in zlib.
-- We skip compression because `data.deflate` has the same energy cost
-- profile as `data.inflate` (6 + bytes * 0.1), so compressing the output
-- just moves the budget problem to write time. Uncompressed blocks cost
-- nothing on the data card and are a perfectly legal DEFLATE stream.
--
-- The input, however, still has to be inflatable: the source image's IDAT
-- must fit `(computer.energy() - 6) / 0.1` bytes. If the source is too big,
-- the underlying png.loadPNG will crash at png.lua:177.

local ocpng = require("png")
local crc32 = require("crc32")

local args = {...}
local inpath  = args[1]
local outpath = args[2]
local spec    = args[3]

if not inpath or not outpath or not spec then
  print("usage: resize <in.png> <out.png> <max_dim>")
  print("       resize <in.png> <out.png> <w>x<h>")
  return
end

-- Parse target size
local tgtW, tgtH
local w_str, h_str = spec:match("^(%d+)[xX](%d+)$")
if w_str then
  tgtW = tonumber(w_str)
  tgtH = tonumber(h_str)
else
  local maxd = tonumber(spec)
  if not maxd then
    print("ERROR: bad size spec '" .. spec .. "'")
    return
  end
  tgtW = maxd -- resolved after load
  tgtH = -1
end

-- Load source
io.write("loading " .. inpath .. "... "); io.flush()
local png = ocpng.loadPNG(inpath)
print(png.w .. "x" .. png.h)

-- Resolve aspect-preserved target if --max used
if tgtH < 0 then
  local maxd = tgtW
  if png.w >= png.h then
    tgtW = maxd
    tgtH = math.max(1, math.floor(png.h * maxd / png.w + 0.5))
  else
    tgtH = maxd
    tgtW = math.max(1, math.floor(png.w * maxd / png.h + 0.5))
  end
end
print(string.format("target: %dx%d", tgtW, tgtH))

-- Nearest-neighbor resample into an RGB byte string
io.write("resampling... "); io.flush()
local scanlines = {}
local xMap = {}
for dx = 0, tgtW - 1 do
  xMap[dx + 1] = math.min(png.w - 1, math.floor(dx * png.w / tgtW))
end
for dy = 0, tgtH - 1 do
  local sy = math.min(png.h - 1, math.floor(dy * png.h / tgtH))
  local row = {"\x00"} -- filter 0 = None
  for dx = 1, tgtW do
    local rgb = png:get(xMap[dx], sy, false)
    row[#row + 1] = string.char((rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF)
  end
  scanlines[#scanlines + 1] = table.concat(row)
end
local filtered = table.concat(scanlines)
print(#filtered .. " bytes filtered")

-- Build a zlib stream of uncompressed (stored) DEFLATE blocks
local function u16_le(n) return string.char(n & 0xFF, (n >> 8) & 0xFF) end
local function u32_be(n)
  return string.char((n >> 24) & 0xFF, (n >> 16) & 0xFF, (n >> 8) & 0xFF, n & 0xFF)
end

io.write("packing zlib (stored)... "); io.flush()
local parts = {"\x78\x01"} -- zlib header, "fastest" compression
local MAXBLK = 65535
local pos = 1
while pos <= #filtered do
  local remaining = #filtered - pos + 1
  local len = math.min(MAXBLK, remaining)
  local isLast = (pos + len - 1) >= #filtered
  parts[#parts + 1] = string.char(isLast and 1 or 0) -- BFINAL | BTYPE(00)
  parts[#parts + 1] = u16_le(len)
  parts[#parts + 1] = u16_le((~len) & 0xFFFF)
  parts[#parts + 1] = filtered:sub(pos, pos + len - 1)
  pos = pos + len
end

-- Adler-32 of the filtered payload
local s1, s2 = 1, 0
for i = 1, #filtered do
  s1 = (s1 + filtered:byte(i)) % 65521
  s2 = (s2 + s1) % 65521
end
parts[#parts + 1] = u32_be((s2 * 65536 + s1) & 0xFFFFFFFF)

local idatData = table.concat(parts)
print(#idatData .. " bytes")

-- Emit PNG
io.write("writing " .. outpath .. "... "); io.flush()
local out = io.open(outpath, "wb")

-- Signature
out:write("\x89PNG\r\n\x1A\n")

-- Helper: write a chunk (4-byte length + type + data + CRC32 over type+data)
local function chunk(typ, data)
  out:write(u32_be(#data))
  out:write(typ)
  out:write(data)
  out:write(u32_be(crc32.crc32(typ .. data) & 0xFFFFFFFF))
end

-- IHDR: width(4) height(4) bitdepth(1=8) colortype(1=2:RGB) comp(1=0) filter(1=0) interlace(1=0)
chunk("IHDR", u32_be(tgtW) .. u32_be(tgtH) .. "\x08\x02\x00\x00\x00")
chunk("IDAT", idatData)
chunk("IEND", "")
out:close()

local fs = require("filesystem")
print("done, " .. fs.size(outpath) .. " bytes total")

-- Budget hint
local idatBytes = #idatData
local invCost = 6 + idatBytes * 0.1
print(string.format("  IDAT=%d, inflate cost~=%.0f energy (this image will need that much to display)",
  idatBytes, invCost))
