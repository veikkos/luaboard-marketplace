-- paint: finger painting. Pick a color from the palette at the top,
-- touch button A clears the canvas, B toggles a big brush.

local SW = 32                                   -- swatch size
local colors = { disp.WHITE, disp.RED, disp.ORANGE, disp.YELLOW, disp.GREEN,
                 disp.CYAN, disp.BLUE, disp.MAGENTA, disp.GRAY, disp.BLACK }
local color, brush = disp.WHITE, 3
local last_x, last_y

local function palette()
  for i, c in ipairs(colors) do
    local x = (i - 1) * SW
    disp.rect(x, 0, SW, SW, c, true)
    if c == color then disp.rect(x + 2, 2, SW - 4, SW - 4, c == disp.WHITE and disp.BLACK or disp.WHITE) end
  end
end

local function clear()
  disp.clear(disp.BLACK)
  palette()
  disp.text(4, disp.H - 10, "A: clear   B: brush size", disp.DARKGRAY)
end

clear()

local function button(b)
  if b == "A" then clear() end
  if b == "B" then brush = brush == 3 and 8 or 3 end
end
touch.on("press", button)
touch.on("long", button)

function loop(dt)
  local x, y = touch.read()
  if not x then last_x = nil return end
  if y < SW then                                 -- palette row
    color = colors[x // SW + 1] or color
    palette()
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
