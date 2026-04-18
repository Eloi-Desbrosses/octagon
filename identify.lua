-- identify.lua: paint each screen with the first 8 chars of its address
-- in big block-letter font, so you can physically walk to each screen
-- and read its ID.

local component = require("component")
local gpu = component.gpu

-- 5x7 hex font (0-9, a-f)
local FONT = {
  ["0"] = {0x0E,0x11,0x13,0x15,0x19,0x11,0x0E},
  ["1"] = {0x04,0x0C,0x04,0x04,0x04,0x04,0x0E},
  ["2"] = {0x0E,0x11,0x01,0x02,0x04,0x08,0x1F},
  ["3"] = {0x0E,0x11,0x01,0x06,0x01,0x11,0x0E},
  ["4"] = {0x02,0x06,0x0A,0x12,0x1F,0x02,0x02},
  ["5"] = {0x1F,0x10,0x1E,0x01,0x01,0x11,0x0E},
  ["6"] = {0x0E,0x10,0x1E,0x11,0x11,0x11,0x0E},
  ["7"] = {0x1F,0x01,0x02,0x04,0x08,0x08,0x08},
  ["8"] = {0x0E,0x11,0x11,0x0E,0x11,0x11,0x0E},
  ["9"] = {0x0E,0x11,0x11,0x0F,0x01,0x01,0x0E},
  ["a"] = {0x0E,0x11,0x11,0x1F,0x11,0x11,0x11},
  ["b"] = {0x1E,0x11,0x11,0x1E,0x11,0x11,0x1E},
  ["c"] = {0x0E,0x11,0x10,0x10,0x10,0x11,0x0E},
  ["d"] = {0x1E,0x11,0x11,0x11,0x11,0x11,0x1E},
  ["e"] = {0x1F,0x10,0x10,0x1E,0x10,0x10,0x1F},
  ["f"] = {0x1F,0x10,0x10,0x1E,0x10,0x10,0x10},
  ["-"] = {0x00,0x00,0x00,0x0E,0x00,0x00,0x00},
}

local COLORS = {
  0xE53935, 0xFB8C00, 0xFDD835, 0x7CB342, 0x00897B,
  0x1E88E5, 0x3949AB, 0x8E24AA, 0xF06292,
}

local SCALE = 4
local CH_W, CH_H = 5 * SCALE, 7 * SCALE
local SPACING = SCALE

local origScreen = gpu.getScreen()
local screens = {}
for a in component.list("screen") do screens[#screens + 1] = a end

print("=== identify ===")
print("screens: " .. #screens)
for i, addr in ipairs(screens) do
  print(string.format("  #%d  %s", i, addr))
end

for i, addr in ipairs(screens) do
  gpu.bind(addr, false)
  local SW, SH = gpu.maxResolution()
  gpu.setResolution(SW, SH)
  gpu.setDepth(gpu.maxDepth())

  local bg = COLORS[((i - 1) % #COLORS) + 1]
  local fg = 0xFFFFFF
  gpu.setBackground(bg); gpu.setForeground(fg)
  gpu.fill(1, 1, SW, SH, " ")

  -- First 8 hex chars of the address
  local text = addr:sub(1, 8)
  local total_w = #text * CH_W + (#text - 1) * SPACING
  local x0 = math.floor((SW - total_w) / 2) + 1
  local y0 = math.floor((SH - CH_H) / 2) + 1

  for ci = 1, #text do
    local ch = text:sub(ci, ci)
    local g = FONT[ch]
    local cx = x0 + (ci - 1) * (CH_W + SPACING)
    if g then
      for row = 1, 7 do
        for col = 1, 5 do
          local m = 1 << (5 - col)
          if (g[row] & m) ~= 0 then
            gpu.setBackground(fg)
            gpu.fill(cx + (col - 1) * SCALE, y0 + (row - 1) * SCALE, SCALE, SCALE, " ")
          end
        end
      end
    end
  end

  -- Index #N in the top-left corner
  gpu.setBackground(bg)
  gpu.setForeground(fg)
  gpu.set(2, 2, "#" .. i)
end

gpu.bind(origScreen, false)
gpu.setResolution(gpu.maxResolution())
gpu.setBackground(0x000000); gpu.setForeground(0xFFFFFF)
require("term").clear()
print("identify done - each screen shows its 8-char address.")
