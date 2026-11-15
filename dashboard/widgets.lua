-- widgets.lua: drawing helpers.
local M = {}

local function clamp01(v) return math.max(0, math.min(1, v)) end

-- Horizontal bar, frac in 0..1
function M.bar(x, y, w, h, frac, color)
  disp.rect(x, y, w, h, disp.GRAY)
  disp.rect(x + 2, y + 2, math.floor((w - 4) * clamp01(frac)), h - 4, color or disp.GREEN, true)
end

-- Semicircular gauge with colored scale and a needle, frac in 0..1
function M.gauge(cx, cy, r, frac, label, value_text)
  for i = 0, 20 do                                   -- tick marks, green -> red
    local f = i / 20
    local a = math.pi * (1 - f)
    local c, s = math.cos(a), math.sin(a)
    local inner = (i % 5 == 0) and r - 10 or r - 5
    disp.line(cx + math.floor(c * inner), cy - math.floor(s * inner),
              cx + math.floor(c * r), cy - math.floor(s * r),
              disp.rgb(math.floor(255 * f), math.floor(220 * (1 - f)), 60))
  end
  local a = math.pi * (1 - clamp01(frac))
  disp.line(cx, cy, cx + math.floor(math.cos(a) * (r - 14)), cy - math.floor(math.sin(a) * (r - 14)), disp.WHITE)
  disp.circle(cx, cy, 4, disp.WHITE, true)
  if label then disp.text(cx - disp.text_width(label, 2) // 2, cy + 10, label, disp.GRAY, 2) end
  if value_text then disp.text(cx - disp.text_width(value_text, 2) // 2, cy - r // 2, value_text, disp.WHITE, 2) end
end

-- Indicator light with a label
function M.led(x, y, on, label, color)
  disp.circle(x + 6, y + 6, 6, on and (color or disp.GREEN) or disp.DARKGRAY, true)
  if label then disp.text(x + 18, y + 2, label, on and disp.WHITE or disp.GRAY, 1) end
end

return M
