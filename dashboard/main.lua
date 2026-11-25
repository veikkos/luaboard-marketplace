-- dashboard: multi-file example, uses widgets.lua via require().

local ui = require("widgets")

sys.rate(15)
local start = sys.millis()
local blink = false
timer.every(500, function() blink = not blink end)

local pressed = {}                                 -- button -> lit until (ms)
local function button(b) pressed[b] = sys.millis() + 300 end
touch.on("press", button)
touch.on("long", button)

function loop(dt)
  local knob = adc.read(adc.PORTB_IN) / adc.MAX
  local pct, charging, usb = sys.battery()
  local up = (sys.millis() - start) // 1000
  local btn = touch.button()                       -- A or C while held
  local tx, ty = touch.read()                      -- or a finger on a button's box on the screen
  if tx and ty >= 190 then btn = ({ "A", "B", "C" })[tx * 3 // disp.W + 1] end

  disp.clear(disp.rgb(8, 12, 20))
  ui.gauge(80, 110, 70, knob, "KNOB", string.format("%d%%", math.floor(knob * 100)))
  ui.gauge(240, 110, 70, (pct or 0) / 100, "BATTERY", pct and (pct .. "%") or "none")

  disp.line(0, 150, disp.W, 150, disp.DARKGRAY)
  ui.led(10, 162, usb, "USB 5V", disp.CYAN)
  ui.led(100, 162, charging and blink, "CHARGING", disp.ORANGE)
  disp.text(220, 160, string.format("%02d:%02d", up // 60, up % 60), disp.WHITE, 2)

  for i, name in ipairs({ "A", "B", "C" }) do      -- mirror the touch buttons
    local x = (i - 1) * disp.W // 3
    local lit = btn == name or (pressed[name] or 0) > sys.millis()
    disp.rect(x + 8, 196, disp.W // 3 - 16, 36, lit and disp.BLUE or disp.DARKGRAY, true)
    disp.text(x + disp.W // 6 - 6, 207, name, disp.WHITE, 2)
  end
  local heap_used, _, heap_limit = sys.heap()
  ui.bar(0, 186, disp.W, 6, heap_used / heap_limit, disp.MAGENTA)
end
