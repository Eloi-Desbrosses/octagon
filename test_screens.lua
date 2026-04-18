-- test_screens: paint each screen with a distinctive pattern.
-- Shows: background color block + big index digit + full address + gradient.
-- Useful for verifying every screen on the network responds, and for
-- physically mapping each address to a grid position.
--
-- Usage:
--   test_screens          - paint all screens, hold until Ctrl+C
--   test_screens 10       - paint all, hold 10s then return

local component = require("component")
local gpu = component.gpu
local event = require("event")
local unicode = require("unicode")

local args = {...}
local delay = tonumber(args[1])

-- 5x7 hex font (used for the address at the top)
local FONT = {
  ["0"]={0x0E,0x11,0x13,0x15,0x19,0x11,0x0E}, ["1"]={0x04,0x0C,0x04,0x04,0x04,0x04,0x0E},
  ["2"]={0x0E,0x11,0x01,0x02,0x04,0x08,0x1F}, ["3"]={0x0E,0x11,0x01,0x06,0x01,0x11,0x0E},
  ["4"]={0x02,0x06,0x0A,0x12,0x1F,0x02,0x02}, ["5"]={0x1F,0x10,0x1E,0x01,0x01,0x11,0x0E},
  ["6"]={0x0E,0x10,0x1E,0x11,0x11,0x11,0x0E}, ["7"]={0x1F,0x01,0x02,0x04,0x08,0x08,0x08},
  ["8"]={0x0E,0x11,0x11,0x0E,0x11,0x11,0x0E}, ["9"]={0x0E,0x11,0x11,0x0F,0x01,0x01,0x0E},
  ["a"]={0x0E,0x11,0x11,0x1F,0x11,0x11,0x11}, ["b"]={0x1E,0x11,0x11,0x1E,0x11,0x11,0x1E},
  ["c"]={0x0E,0x11,0x10,0x10,0x10,0x11,0x0E}, ["d"]={0x1E,0x11,0x11,0x11,0x11,0x11,0x1E},
  ["e"]={0x1F,0x10,0x10,0x1E,0x10,0x10,0x1F}, ["f"]={0x1F,0x10,0x10,0x1E,0x10,0x10,0x10},
  ["-"]={0x00,0x00,0x00,0x0E,0x00,0x00,0x00}, ["#"]={0x0A,0x1F,0x0A,0x0A,0x1F,0x0A,0x00},
}

-- Nine distinctive high-saturation backgrounds
local COLORS = {
  0xE53935, 0xFB8C00, 0xFDD835, 0x7CB342, 0x1E88E5,
  0x3949AB, 0x8E24AA, 0xF06292, 0x00897B,
  0xD81B60, 0x00ACC1, 0x5E35B1,
}

local function drawText(gpu_, text, x0, y0, scale, fgColor, bgColor)
  for ci = 1, #text do
    local ch = text:sub(ci, ci)
    local glyph = FONT[ch]
    local cx = x0 + (ci - 1) * (5 * scale + scale)
    if glyph then
      for row = 1, 7 do
        for col = 1, 5 do
          local mask = 1 << (5 - col)
          if (glyph[row] & mask) ~= 0 then
            gpu_.setBackground(fgColor)
            gpu_.fill(cx + (col - 1) * scale, y0 + (row - 1) * scale, scale, scale, " ")
          end
        end
      end
    end
  end
  gpu_.setBackground(bgColor)
end

local screens = {}
for addr in component.list("screen") do screens[#screens + 1] = addr end

print("=== test_screens ===")
print("screens found: " .. #screens)

local origScreen = gpu.getScreen()

for i, addr in ipairs(screens) do
  print(string.format("  #%d  %s", i, addr))
  gpu.bind(addr, false)
  local SW, SH = gpu.maxResolution()
  gpu.setResolution(SW, SH)
  gpu.setDepth(gpu.maxDepth())

  local bg = COLORS[((i - 1) % #COLORS) + 1]
  gpu.setBackground(bg); gpu.setForeground(0xFFFFFF)
  gpu.fill(1, 1, SW, SH, " ")

  -- Top: address (first 8 hex chars), small scale (2x)
  drawText(gpu, addr:sub(1, 8), 2, 2, 2, 0xFFFFFF, bg)

  -- Center: big index
  local label = "#" .. tostring(i)
  local sc = 6
  local lw = #label * (5 * sc + sc)
  drawText(gpu, label,
    math.floor((SW - lw) / 2) + 1,
    math.floor((SH - 7 * sc) / 2) + 1,
    sc, 0xFFFFFF, bg)

  -- Bottom: horizontal gradient bar
  local gradH = 3
  for x = 1, SW do
    local t = (x - 1) / (SW - 1)
    local r = math.floor(0xFF * (1 - t))
    local g = math.floor(0xFF * t)
    local b = math.floor(0x80 + 0x7F * math.sin(t * 3.14159))
    gpu.setBackground((r << 16) | (g << 8) | b)
    gpu.fill(x, SH - gradH + 1, 1, gradH, " ")
  end
end

gpu.bind(origScreen, false)
gpu.setResolution(gpu.maxResolution())
gpu.setBackground(0x000000); gpu.setForeground(0xFFFFFF)
require("term").clear()
print("done. painted " .. #screens .. " screen(s).")

if delay then
  os.sleep(delay)
  -- Clean up each screen back to black so it's not a distraction
  for _, addr in ipairs(screens) do
    gpu.bind(addr, false)
    gpu.setBackground(0x000000)
    gpu.fill(1, 1, gpu.maxResolution(), " ")
  end
  gpu.bind(origScreen, false)
end
