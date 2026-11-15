-- timer: a countdown. Set the hours, minutes and seconds with the + and -
-- above and below them (hold to repeat), with A and C (a minute less or
-- more, 5 when held), or by tapping a recent time; B starts it. While it
-- runs B or a tap pauses, A resets and C adds a minute. When it's up it
-- beeps for a minute and counts the time since, until any button or touch
-- says seen: back to the set screen, at the time it was started with.
--
-- The time set and the last few started are kept (store), and so is a
-- running or paused timer: leave the app or restart the board and it's still
-- there when you come back. A running one needs the clock (sys.time()) for
-- that, a paused one doesn't.
--
-- On battery it saves power: the screen may go off while it runs (the
-- Screen off setting), and asleep with a minute or more to go it turns the
-- device off until just before the end. It rings on time either way.

local json = require("json")

local W, H = disp.W, disp.H
local BG, FG = disp.rgb(10, 12, 18), disp.WHITE
local DIM, DIMMER = disp.rgb(140, 148, 162), disp.rgb(70, 78, 92)
local CHIP, CHIP_ON = disp.rgb(28, 34, 46), disp.rgb(50, 62, 84)
local ACCENT = disp.rgb(90, 180, 255)
local PAUSED = disp.rgb(255, 200, 60)
local ALERT = disp.rgb(240, 70, 60)
local FLASH = disp.rgb(110, 22, 18)

local MAX = 9 * 3600 + 59 * 60 + 59             -- 9:59:59, what the set screen shows
local ALARM_MS = 60000                          -- how long it beeps
local RECENT_N = 4
local REPEAT_AFTER, REPEAT_EVERY = 800, 100     -- holding a + or -
local OFF_MIN = 60                              -- s left that are worth turning the device off for

local function clamp(s) return math.max(0, math.min(MAX, s)) end

local function int(v, lo, hi)                   -- a stored number, or nil if it's off
  v = math.tointeger(v)
  if v and v >= lo and v <= hi then return v end
end

local function load_json(key)
  local v = json.decode(store.get(key) or "null")
  return type(v) == "table" and v or nil
end

-- Global so tests (and `luaboard eval`) can look in.
TIMER = {
  mode = "set",           -- set | run | pause | done
  set = int(store.get("last"), 1, MAX) or 300,  -- the time on the set screen, s
  total = 0,              -- the running timer's whole length, s (for the bar)
  ends = nil,             -- run: sys.millis() when it's up
  left = nil,             -- pause: ms left
  done_at = nil,          -- done: sys.millis() when it was up
  recent = {},            -- times started, newest first
  zones = {},             -- what can be tapped on the screen: id -> { x, y, w, h }
}
local T = TIMER

for _, s in ipairs(load_json("recent") or {}) do
  s = int(s, 1, MAX)
  if s and #T.recent < RECENT_N then T.recent[#T.recent + 1] = s end
end

-- 5:00, 25:00, 1:30:00
local function fmt(s)
  local h, m = s // 3600, s // 60 % 60
  if h > 0 then return string.format("%d:%02d:%02d", h, m, s % 60) end
  return string.format("%d:%02d", m, s % 60)
end

function T.remaining()                          -- ms
  if T.mode == "run" then return math.max(0, T.ends - sys.millis()) end
  if T.mode == "pause" then return T.left end
  return 0
end

---------------------------------------------------------------- keeping it

-- The running or paused timer, or nothing. A running one is kept as the
-- clock time it ends (sys.millis() starts over with each boot).
local function save_run()
  local v
  if T.mode == "pause" then
    v = { total = T.total, left = T.left }
  elseif T.mode == "run" or T.mode == "done" then
    local now = sys.time()
    local at = T.mode == "run" and T.ends or T.done_at
    if now then v = { total = T.total, ends = now + math.floor((at - sys.millis()) / 1000 + 0.5) } end
  end
  store.set("run", v and json.encode(v) or nil)
end

-- Picks up a kept timer. False while it needs the clock and the clock isn't
-- known yet (it comes from the network a moment after Wi-Fi is up).
local function restore()
  local v = load_json("run")
  if not v then return true end
  local total = int(v.total, 1, MAX)
  local left = int(v.left, 1, MAX * 1000)
  local ends = int(v.ends, 0, math.maxinteger)
  if total and left then
    T.mode, T.total, T.left = "pause", total, left
  elseif total and ends then
    local now = sys.time()
    if not now then return false end
    T.total = total
    if ends > now then
      T.mode, T.ends = "run", sys.millis() + (ends - now) * 1000
    else
      T.mode, T.done_at = "done", sys.millis() - (now - ends) * 1000
    end
  else
    store.set("run", nil)
  end
  return true
end
local restored = restore()

---------------------------------------------------------------- actions

local function set_to(s)
  s = clamp(s)
  if s ~= T.set then T.set = s; store.set("last", s) end
end

local function remember(s)
  for i = #T.recent, 1, -1 do if T.recent[i] == s then table.remove(T.recent, i) end end
  table.insert(T.recent, 1, s)
  while #T.recent > RECENT_N do table.remove(T.recent) end
  store.set("recent", json.encode(T.recent))
end

local function start()
  local s = T.set
  if s < 1 then return end
  remember(s)
  restored = true                               -- a new one replaces a kept one still waiting for the clock
  T.mode, T.total, T.ends = "run", s, sys.millis() + s * 1000
  save_run()
end

local function pause()
  T.left = T.remaining()
  T.mode = "pause"
  save_run()
end

local function resume()
  T.mode, T.ends = "run", sys.millis() + T.left
  save_run()
end

-- Back to the set screen. The time set doesn't change while a timer runs,
-- so that's the time it was started with.
local function reset()
  sound.stop()
  T.mode = "set"
  save_run()
end

local function add_minute()
  local left = math.min(T.remaining() + 60000, MAX * 1000)
  T.total = math.max(T.total, (left + 999) // 1000)
  if T.mode == "pause" then T.left = left else T.ends = sys.millis() + left end
  save_run()
end

local function finish()
  T.mode, T.done_at = "done", T.ends
  save_run()
  disp.sleep(false)                             -- the alarm is to be seen
end

-- One field of the set time (3600, 60 or 1 s) up or down, wrapping within
-- the field: the others stay as they are.
local function step(unit, d)
  local range = unit == 3600 and 10 or 60
  local v = T.set // unit % range
  set_to(T.set + (((v + d) % range) - v) * unit)
end

---------------------------------------------------------------- drawing

local function center(y, s, col, scale, bg)
  disp.text((W - disp.text_width(s, scale)) // 2, y, s, col, scale, bg)
end

local function hints(a, b, c, bg)
  disp.text(8, H - 14, "<< " .. a, DIM, 1, bg)
  center(H - 14, "o " .. b, DIM, 1, bg)
  local r = c .. " >>"
  disp.text(W - 8 - disp.text_width(r), H - 14, r, DIM, 1, bg)
end

local function chip(id, x, y, w, h, label, scale, col, on)
  T.zones[id] = { x = x, y = y, w = w, h = h }
  disp.rect(x, y, w, h, on and CHIP_ON or CHIP, true)
  disp.text(x + (w - disp.text_width(label, scale)) // 2, y + (h - 7 * scale) // 2, label, col, scale)
end

local SET_SCALE = 6                             -- 36 x 42 px per character
local held                                      -- { id, at }: a + or - held down

local function draw_set()
  disp.clear(BG)
  disp.text(10, 10, "Timer", DIM, 2)
  local s = string.format("%d:%02d:%02d", T.set // 3600, T.set // 60 % 60, T.set % 60)
  local x0 = (W - disp.text_width(s, SET_SCALE)) // 2
  local y = 88
  disp.text(x0, y, s, T.set > 0 and FG or DIMMER, SET_SCALE)
  for _, f in ipairs({ { "h", 3600, "" }, { "m", 60, "0:" }, { "s", 1, "0:00:" } }) do
    local x = x0 + (f[3] == "" and 0 or disp.text_width(f[3], SET_SCALE) + SET_SCALE)
    local w = disp.text_width(f[1] == "h" and "0" or "00", SET_SCALE)
    local up, down = f[1] .. "+", f[1] .. "-"
    chip(up, x - 4, 40, w + 8, 38, "+", 3, ACCENT, held and held.id == up)
    chip(down, x - 4, 140, w + 8, 38, "-", 3, ACCENT, held and held.id == down)
  end
  -- The recent times, each as wide as its label: as many as fit.
  local gap, ws, sum = 6, {}, -6
  for i, r in ipairs(T.recent) do
    local w = math.max(disp.text_width(fmt(r), 2) + 14, 56)
    if sum + gap + w > W - 16 then break end
    ws[i], sum = w, sum + gap + w
  end
  local x = (W - sum) // 2
  for i, w in ipairs(ws) do
    local r = T.recent[i]
    chip("r" .. i, x, 188, w, 26, fmt(r), 2, r == T.set and FG or DIM)
    x = x + w + gap
  end
  hints("-1 min", "start", "+1 min")
end

local function draw_running()
  disp.clear(BG)
  local ms = T.remaining()
  local s = (ms + 999) // 1000
  local col = T.mode == "pause" and PAUSED or FG
  disp.text(10, 10, "Timer " .. fmt(T.total), DIM, 2)
  if s >= 3600 then
    center(67, fmt(s), col, 6)
  else
    center(60, string.format("%02d:%02d", s // 60, s % 60), col, 8)
  end
  local bx, by, bw, bh = 30, 136, W - 60, 10
  disp.rect(bx, by, bw, bh, DIMMER)
  local fill = math.floor((bw - 2) * ms / (T.total * 1000) + 0.5)
  if fill > 0 then
    disp.rect(bx + 1, by + 1, math.min(fill, bw - 2), bh - 2, T.mode == "pause" and PAUSED or ACCENT, true)
  end
  if T.mode == "pause" then
    center(164, "Paused", PAUSED, 2)
  else
    local now = sys.time()
    if now then
      local d = sys.date(now + s)
      center(164, string.format("ends %02d:%02d", d.hour, d.min), DIM, 2)
    end
  end
  hints("reset", T.mode == "pause" and "resume" or "pause", "+1 min")
end

local function alarming() return T.mode == "done" and sys.millis() - T.done_at < ALARM_MS end
local function flash_on() return alarming() and (sys.millis() - T.done_at) % 1000 < 500 end

local function draw_done()
  local bg = flash_on() and FLASH or BG
  disp.clear(bg)
  center(50, "Time's up", flash_on() and FG or ALERT, 4)
  center(100, "+" .. fmt((sys.millis() - T.done_at) // 1000), FG, 6)
  center(164, fmt(T.total) .. " timer", DIM, 2)
  center(H - 14, "any button or touch: done", DIM, 1)
end

local drawn                                     -- what the screen shows, as a key

local function key()
  if T.mode == "set" then
    return "set " .. T.set .. " " .. #T.recent .. " " .. (held and held.id or "")
  elseif T.mode == "done" then
    return "done " .. (sys.millis() - T.done_at) // 1000 .. tostring(flash_on())
  end
  local ends = sys.time() and "t" or ""          -- the end time shows once the clock is known
  return T.mode .. " " .. (T.remaining() + 999) // 1000 .. " " .. T.total .. ends
end

local function redraw()
  T.zones = {}
  if T.mode == "set" then draw_set()
  elseif T.mode == "done" then draw_done()
  else draw_running() end
  drawn = key()
end

---------------------------------------------------------------- input

local function zone_at(x, y)
  for id, z in pairs(T.zones) do
    if x >= z.x and x < z.x + z.w and y >= z.y and y < z.y + z.h then return id end
  end
end

local FIELDS = { h = 3600, m = 60, s = 1 }

local function tap_zone(id)
  local f, sign = id:match("^([hms])([+-])$")
  if f then step(FIELDS[f], sign == "+" and 1 or -1); return end
  local i = tonumber(id:match("^r(%d)$"))
  if i and T.recent[i] then set_to(T.recent[i]) end
end

-- Done, and the user saw it: any button or touch. A finger still down then
-- (a hold) is let go of before the set screen takes touches again, so it
-- doesn't go on to change the time.
local settle = false
local function seen()
  reset()
  settle = true
end

local function button(b, long)
  local m = T.mode
  if m == "set" then
    if b == "A" then set_to(T.set - (long and 300 or 60))
    elseif b == "C" then set_to(T.set + (long and 300 or 60))
    else start() end
  elseif m == "run" or m == "pause" then
    if b == "A" then reset()
    elseif b == "C" then add_minute()
    elseif m == "run" then pause()
    else resume() end
  else
    seen()                                      -- done: any button
  end
end
touch.on("press", function(b) button(b, false) end)
touch.on("long", function(b) button(b, true) end)

touch.on("tap", function(x, y)
  local m = T.mode
  if m == "set" then
    local id = zone_at(x, y)
    if id then tap_zone(id) end
  elseif m == "run" then pause()
  elseif m == "pause" then resume()
  else seen() end
end)
touch.on("hold", function() if T.mode == "done" then seen() end end)
touch.on("swipe", function() if T.mode == "done" then seen() end end)

---------------------------------------------------------------- run

local beeped                                    -- the alarm's last second that beeped
local awake, kept_on = false, false
local usb, usb_at = true, nil                   -- USB power, looked at once a second
local off_failed                                -- sys.off refused the wait once

function loop()
  if not restored then restored = restore() end
  local now = sys.millis()

  -- A + or - held: it repeats after a moment. (A shorter touch is a tap.)
  local x, y = touch.read()
  if settle then
    if x then x = nil else settle = false end
  end
  local id = T.mode == "set" and x and zone_at(x, y)
  if id and id:match("[+-]$") then
    if not held or held.id ~= id then
      held = { id = id, at = now + REPEAT_AFTER }
    elseif now >= held.at then
      tap_zone(id)
      held.at = now + REPEAT_EVERY
    end
  else
    held = nil
  end

  if T.mode == "run" and now >= T.ends then finish() end
  if alarming() then
    local sec = (now - T.done_at) // 1000
    if sec ~= beeped then
      beeped = sec
      for i = 1, 3 do
        sound.tone(988, 90)
        if i < 3 then sound.tone(0, 60) end
      end
    end
  else
    beeped = nil
  end

  -- A timer at work keeps the screen on while USB powers the device. On
  -- battery the screen may sleep (the Screen off setting), but the device
  -- isn't to turn off under the timer...
  if not usb_at or now - usb_at >= 1000 then
    usb_at, usb = now, select(3, sys.battery())
  end
  local busy = T.mode == "run" or alarming()
  local want = busy and usb
  if want ~= awake then awake = want; disp.keep_awake(want) end
  if busy ~= kept_on then kept_on = busy; sys.keep_on(busy) end
  -- ...unless the timer does it itself: asleep with a while to go, it turns
  -- the device off until the end. The device starts this app again in
  -- time, and the kept timer goes on from there. (That takes the clock.)
  -- A wait the device can't honor is an error; then the timer simply runs
  -- on awake, and doesn't ask again.
  if T.mode == "run" and not usb and disp.sleep() and sys.time() and not off_failed then
    local left = T.remaining() // 1000
    if left >= OFF_MIN then
      save_run()
      local ok, err = pcall(sys.off, left)
      if not ok then off_failed = true; print(err) end
    end
  end

  if key() ~= drawn then redraw() end
end

sys.rate(20)
redraw()
