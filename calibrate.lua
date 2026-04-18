-- Multi-screen calibration: paints each screen with a unique color + big
-- digit so you can tell me which grid position maps to which screen.
--
-- Usage: calibrate
-- Then look at the screens in-world and note: top-left=?, top-mid=?, ...
-- Tell me "top-left=3, top-mid=7, ..." and I'll build the row-major addr list.

local component = require("component")
local gpu = component.gpu

-- 5x7 digit font (MSB = leftmost pixel, 5 pixels wide rows)
local DIGITS = {
  [1] = {0x04, 0x0C, 0x04, 0x04, 0x04, 0x04, 0x0E},
  [2] = {0x0E, 0x11, 0x01, 0x02, 0x04, 0x08, 0x1F},
  [3] = {0x0E, 0x11, 0x01, 0x06, 0x01, 0x11, 0x0E},
  [4] = {0x02, 0x06, 0x0A, 0x12, 0x1F, 0x02, 0x02},
  [5] = {0x1F, 0x10, 0x1E, 0x01, 0x01, 0x11, 0x0E},
  [6] = {0x0E, 0x10, 0x1E, 0x11, 0x11, 0x11, 0x0E},
  [7] = {0x1F, 0x01, 0x02, 0x04, 0x08, 0x08, 0x08},
  [8] = {0x0E, 0x11, 0x11, 0x0E, 0x11, 0x11, 0x0E},
  [9] = {0x0E, 0x11, 0x11, 0x0F, 0x01, 0x01, 0x0E},
  [0] = {0x0E, 0x11, 0x13, 0x15, 0x19, 0x11, 0x0E},
}

-- Distinct high-contrast colors (RGB)
local COLORS = {
  0xFF0000, -- red
  0x00FF00, -- green
  0x0060FF, -- blue
  0xFFFF00, -- yellow
  0x00FFFF, -- cyan
  0xFF00FF, -- magenta
  0xFF8000, -- orange
  0x8000FF, -- purple
  0xFFFFFF, -- white
  0xFF0080, -- pink
  0x00FF80, -- mint
  0x8080FF, -- light blue
}

local SCALE = 5 -- each font pixel = SCALE x SCALE chars
local DIG_W, DIG_H = 5 * SCALE, 7 * SCALE

local screens = {}
for addr in component.list("screen") do screens[#screens + 1] = addr end

print("=== calibration ===")
print("found " .. #screens .. " screens")
for i, a in ipairs(screens) do
  print(string.format("  #%d -> %s", i, a))
end

local origScreen = gpu.getScreen()

for i, addr in ipairs(screens) do
  gpu.bind(addr, false)
  local SW, SH = gpu.maxResolution()
  gpu.setResolution(SW, SH)
  gpu.setDepth(gpu.maxDepth())

  local bg = COLORS[((i - 1) % #COLORS) + 1]
  local fg = (bg == 0xFFFF00 or bg == 0x00FF00 or bg == 0x00FFFF or bg == 0xFFFFFF) and 0x000000 or 0xFFFFFF

  gpu.setBackground(bg)
  gpu.setForeground(fg)
  gpu.fill(1, 1, SW, SH, " ")

  -- Center the digit glyph
  local x0 = math.floor((SW - DIG_W) / 2) + 1
  local y0 = math.floor((SH - DIG_H) / 2) + 1

  local glyph = DIGITS[i] or DIGITS[0]
  -- For i >= 10, also draw a second digit to the left/right. Simple: only
  -- handle up to 12 with two-digit rendering if needed.
  if i >= 10 and i <= 99 then
    local d1 = math.floor(i / 10)
    local d2 = i % 10
    local g1, g2 = DIGITS[d1], DIGITS[d2]
    x0 = math.floor((SW - (DIG_W * 2 + SCALE)) / 2) + 1
    for row = 1, 7 do
      for col = 1, 5 do
        local m = 1 << (5 - col)
        if (g1[row] & m) ~= 0 then
          gpu.setBackground(fg)
          gpu.fill(x0 + (col - 1) * SCALE, y0 + (row - 1) * SCALE, SCALE, SCALE, " ")
        end
        if (g2[row] & m) ~= 0 then
          gpu.setBackground(fg)
          gpu.fill(x0 + DIG_W + SCALE + (col - 1) * SCALE, y0 + (row - 1) * SCALE, SCALE, SCALE, " ")
        end
      end
    end
  else
    for row = 1, 7 do
      for col = 1, 5 do
        local m = 1 << (5 - col)
        if (glyph[row] & m) ~= 0 then
          gpu.setBackground(fg)
          gpu.fill(x0 + (col - 1) * SCALE, y0 + (row - 1) * SCALE, SCALE, SCALE, " ")
        end
      end
    end
  end

  -- Small label at bottom: first 8 chars of address
  gpu.setBackground(bg)
  gpu.setForeground(fg)
  local label = addr:sub(1, 8)
  gpu.set(math.floor((SW - #label) / 2) + 1, SH - 1, label)
end

gpu.bind(origScreen, false)
gpu.setResolution(gpu.maxResolution())
gpu.setBackground(0x000000)
gpu.setForeground(0xFFFFFF)
require("term").clear()
print("calibration done.")
print("look at the screens in-game. tell me which grid position shows which number.")
print("example for a 3x3:  'top-left=3, top-mid=7, top-right=1, mid-left=9, ...'")
