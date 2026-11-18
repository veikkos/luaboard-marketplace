-- clock: the time and date, digital or analog, in the device's time zone
-- (`luaboard tz`). A = digital, C = analog, B = seconds on/off. The button
-- hints go after a few seconds; a touch anywhere brings them back.

local W, H = disp.W, disp.H
local BG = disp.rgb(8, 10, 16)
local FG = disp.WHITE
local DIM = disp.rgb(120, 130, 150)
local DIMMER = disp.rgb(50, 58, 72)
local ACCENT = disp.rgb(90, 180, 255)
local RED = disp.rgb(240, 70, 60)

local HINTS_MS = 5000                           -- the hints stay this long after a touch

local face = "digital"
local seconds = true
local drawn                                     -- the second (or state) on the screen
local touched = sys.millis()                    -- the last touch (starting counts as one)
local hinted                                    -- whether the screen shows the hints

local function hints()
  hinted = sys.millis() - touched < HINTS_MS
  if not hinted then return end
  disp.text(8, H - 14, "<< digital", face == "digital" and ACCENT or DIMMER, 1)
  disp.text(W // 2, H - 14, seconds and "o seconds off" or "o seconds on", DIMMER, 1, nil, "center")
  disp.text(W - 8, H - 14, "analog >>", face == "analog" and ACCENT or DIMMER, 1, nil, "right")
end

---------------------------------------------------------------- faces

local function draw_waiting()
  disp.clear(BG)
  disp.text(W // 2, 70, "Waiting for the time", FG, 2, nil, "center")
  local y = 110
  for _, l in ipairs({
    "The device sets its clock from the network",
    "once it's on Wi-Fi:",
    "  luaboard wifi set \"My network\" \"password\"",
    "",
    "After a reset it also keeps the time",
    "in the board's clock chip.",
  }) do
    disp.text(20, y, l, DIM, 1); y = y + 12
  end
  hints()
end

-- The time, the weekday and the date, as one block in the middle of the
-- screen. The date is a line of its own: with the weekday the longest one,
-- "Wednesday 30 September 2026", is wider than the screen at this size.
local TIME_H, LINE_H = 56, 14                    -- glyphs at scale 8 and 2
local DIGITAL_Y = (H - (TIME_H + 18 + LINE_H + 8 + LINE_H)) // 2

local function draw_digital(t)
  disp.clear(BG)
  local hm = sys.date("%H:%M", t)
  local scale = 8                                -- 48 x 56 px per character
  local w = disp.text_width(hm, scale)
  local sw = seconds and disp.text_width("00", 3) + 8 or 0
  local x, y = (W - w - sw) // 2, DIGITAL_Y
  disp.text(x, y, hm, FG, scale)
  if seconds then disp.text(x + w + 8, y + TIME_H - 21, sys.date("%S", t), ACCENT, 3) end
  y = y + TIME_H + 18
  disp.text(W // 2, y, sys.date("%A", t), DIM, 2, nil, "center")
  disp.text(W // 2, y + LINE_H + 8, sys.date("%-d %B %Y", t), DIM, 2, nil, "center")
  hints()
end

-- A hand from the centre: angle in turns (0 = 12 o'clock), length, width.
local function hand(cx, cy, turns, len, width, col)
  local a = turns * 2 * math.pi
  local dx, dy = math.sin(a), -math.cos(a)
  local x0, y0 = math.floor(cx + 0.5), math.floor(cy + 0.5)
  local x1, y1 = math.floor(cx + dx * len + 0.5), math.floor(cy + dy * len + 0.5)
  local r = width // 2                           -- thickness: the same line shifted
  for i = -r, r do                               -- to every point of a small disc,
    for j = -r, r do                             -- so diagonals have no gaps
      if i * i + j * j <= r * r + r then disp.line(x0 + i, y0 + j, x1 + i, y1 + j, col) end
    end
  end
end

local function draw_analog(t)
  local d = sys.date(t)
  disp.clear(BG)
  local cx, cy, r = W // 2, 104, 92
  disp.circle(cx, cy, r + 4, DIMMER)
  for i = 0, 59 do                               -- minute ticks, longer every 5
    local a = i / 60 * 2 * math.pi
    local s, c = math.sin(a), -math.cos(a)
    local r0 = i % 5 == 0 and r - 12 or r - 4
    disp.line(math.floor(cx + s * r0 + 0.5), math.floor(cy + c * r0 + 0.5),
              math.floor(cx + s * r + 0.5), math.floor(cy + c * r + 0.5), i % 5 == 0 and FG or DIMMER)
  end
  local m = d.min + d.sec / 60
  hand(cx, cy, (d.hour % 12 + m / 60) / 12, r * 0.55, 5, FG)
  hand(cx, cy, m / 60, r * 0.82, 3, FG)
  if seconds then hand(cx, cy, d.sec / 60, r * 0.88, 1, RED) end
  disp.circle(cx, cy, 4, seconds and RED or FG, true)
  disp.text(W // 2, 206, sys.date("%A %-d %B %Y", t), DIM, 1, nil, "center")
  hints()
end

---------------------------------------------------------------- run

local function redraw()
  local t = sys.time()
  if not t then
    if drawn ~= "waiting" then draw_waiting(); drawn = "waiting" end
    return
  end
  if face == "digital" then draw_digital(t) else draw_analog(t) end
  drawn = t
end

local function wake()
  touched = sys.millis()
  if not hinted then drawn = nil end
end

local function button(b)
  wake()
  if b == "A" then face = "digital"
  elseif b == "C" then face = "analog"
  else seconds = not seconds end
  drawn = nil
end
touch.on("press", button)
touch.on("long", button)                        -- a slow press of A or C counts too
-- On the screen a touch only brings the hints back.
for _, ev in ipairs({ "tap", "hold", "drag" }) do touch.on(ev, wake) end

function loop()
  -- A finger down counts at once, before it's let go.
  if touch.read() or touch.button() then wake() end
  if hinted and sys.millis() - touched >= HINTS_MS then drawn = nil end
  local t = sys.time()
  if not drawn or (t and t ~= drawn) or (not t and drawn ~= "waiting") then redraw() end
end

sys.rate(10)                                    -- enough to catch each new second
redraw()
