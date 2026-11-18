-- hello: a greeting and a counter. Tap the screen to change color.

local colors = { disp.CYAN, disp.ORANGE, disp.GREEN, disp.MAGENTA, disp.YELLOW }
local color, count = 1, 0

local function draw_count()
  disp.rect(0, 80, disp.W, 80, disp.BLACK, true)          -- erase old number
  disp.text(disp.W // 2, 92, count, colors[color], 8, nil, "center")   -- 8x scale
end

disp.clear(disp.BLACK)
disp.text(12, 12, "Hello, CoreS3!", disp.WHITE, 3)
disp.line(12, 44, disp.W - 12, 44, disp.GRAY)
disp.text(12, disp.H - 20, "tap the screen to change color", disp.GRAY)
print("hello script started on " .. sys.info().board)
draw_count()

timer.every(1000, function()
  count = count + 1
  draw_count()
end)

local function next_color()
  color = color % #colors + 1
  draw_count()
end
touch.on("tap", next_color)
touch.on("hold", next_color)
