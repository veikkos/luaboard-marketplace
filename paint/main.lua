-- paint: finger painting. Pick a color from the palette at the top. Next to
-- the colors are the brush (tap: big or small) and clear, which the touch
-- buttons B and A do too.

local SW = 32                                   -- the palette's height
local CW = 26                                   -- a color's width: ten of them, then the brush and clear
local BRUSH_X, CLEAR_X = 10 * CW, 10 * CW + 30
local colors = { disp.WHITE, disp.RED, disp.ORANGE, disp.YELLOW, disp.GREEN,
                 disp.CYAN, disp.BLUE, disp.MAGENTA, disp.GRAY, disp.BLACK }
local color, brush = disp.WHITE, 3
local last_x, last_y

local function palette()
  for i, c in ipairs(colors) do
    local x = (i - 1) * CW
    disp.rect(x, 0, CW, SW, c, true)
    if c == color then disp.rect(x + 2, 2, CW - 4, SW - 4, c == disp.WHITE and disp.BLACK or disp.WHITE) end
  end
  disp.rect(BRUSH_X, 0, disp.W - BRUSH_X, SW, disp.DARKGRAY, true)
  disp.circle(BRUSH_X + 15, SW // 2, brush, disp.WHITE, true)       -- the brush, at its size
  local cx, cy = CLEAR_X + 15, SW // 2
  disp.line(cx - 6, cy - 6, cx + 6, cy + 6, disp.WHITE)             -- clear: a cross
  disp.line(cx - 6, cy + 6, cx + 6, cy - 6, disp.WHITE)
end

local function clear()
  disp.clear(disp.BLACK)
  palette()
  disp.text(4, disp.H - 10, "A: clear   B: brush size", disp.DARKGRAY)
end

clear()

local function button(b)
  if b == "A" then clear() end
  if b == "B" then brush = brush == 3 and 8 or 3; palette() end
end
touch.on("press", button)
touch.on("long", button)
touch.on("tap", function(x, y)                  -- the two at the end of the palette
  if y < SW and x >= BRUSH_X then button(x >= CLEAR_X and "A" or "B") end
end)

function loop(dt)
  local x, y = touch.read()
  if not x then last_x = nil return end
  if y < SW then                                 -- palette row
    if x < BRUSH_X then
      color = colors[x // CW + 1] or color
      palette()
    end
    last_x = nil
    return
  end
  if last_x then
    -- thick line: discs along the segment so fast strokes stay continuous
    local dx, dy = x - last_x, y - last_y
    local steps = math.max(1, math.floor(math.sqrt(dx * dx + dy * dy) / 2))
    for i = 0, steps do
      disp.circle(last_x + dx * i // steps, last_y + dy * i // steps, brush, color, true)
    end
  else
    disp.circle(x, y, brush, color, true)
  end
  last_x, last_y = x, y
end
