-- heart_rate: heart rate from a Bluetooth LE chest strap (or any sensor with
-- the standard Heart Rate service, 180d), coloured by zone, with the last two
-- minutes as a chart and the strap's battery.
--
-- The strongest sensor heard advertising the Heart Rate service is used and
-- remembered; it's looked for again whenever the link drops.
--
-- B starts a new session (time, average, max). Holding the screen opens the
-- settings: the max heart rate the zones come from, and forgetting the strap.

local HR_SVC, HR_MEAS = "180d", "2a37"

local W, H = disp.W, disp.H
local BG, FG = disp.rgb(10, 12, 18), disp.WHITE
local DIM, DIMMER = disp.rgb(140, 148, 162), disp.rgb(70, 78, 92)
local GRID = disp.rgb(32, 38, 50)
local ACCENT = disp.rgb(90, 180, 255)

-- Zones as % of max heart rate, the usual five.
local ZONES = {
  { from = 0,  name = "Rest",      col = disp.rgb(110, 118, 132) },
  { from = 50, name = "Z1 Easy",   col = disp.rgb(150, 170, 200) },
  { from = 60, name = "Z2 Base",   col = disp.rgb(70, 150, 255) },
  { from = 70, name = "Z3 Tempo",  col = disp.rgb(70, 205, 95) },
  { from = 80, name = "Z4 Hard",   col = disp.rgb(255, 165, 40) },
  { from = 90, name = "Z5 Peak",   col = disp.rgb(240, 60, 60) },
}

local CHART_S = 120                           -- seconds in the chart
local CX0, CX1, CY0, CY1 = 30, 314, 124, 204

-- Global so tests (and `luaboard eval`) can look in.
HR = {
  phase = "search",        -- search | connect | live
  bpm = nil,               -- the last reading
  at = 0,                  -- sys.millis() of it
  contact = true,          -- false: the strap says it isn't on the skin
  rr = nil,                -- the last beat-to-beat interval, ms
  max_hr = store.get("max_hr") or 190,
  settings = false,
}

local history = {}         -- one reading a second, newest last
local session = { start = nil, sum = 0, n = 0, max = 0 }
local dirty = true
local function set(k, v)
  if HR[k] ~= v then HR[k] = v; dirty = true end
end

local function zone(bpm)
  local pct = bpm * 100 / HR.max_hr
  local z = 1
  for i, zz in ipairs(ZONES) do if pct >= zz.from then z = i end end
  return z, ZONES[z]
end

local function fresh() return HR.bpm and sys.millis() - HR.at < 5000 end

---------------------------------------------------------------- Bluetooth

-- Heart Rate Measurement (2a37): flags, then the rate (8 or 16 bits), then
-- optionally energy expended (16 bits) and RR intervals (16 bits each, in
-- 1/1024 s).
local function on_measurement(d)
  if #d < 2 then return end
  local flags = d:byte(1)
  local bpm, pos
  if flags & 1 == 1 then bpm, pos = string.unpack("<I2", d, 2) else bpm, pos = d:byte(2), 3 end
  if flags & 4 ~= 0 then set("contact", flags & 2 ~= 0) else set("contact", true) end
  if flags & 8 ~= 0 then pos = pos + 2 end
  if flags & 16 ~= 0 and #d >= pos + 1 then
    local last
    while #d >= pos + 1 do last, pos = string.unpack("<I2", d, pos) end
    HR.rr = last * 1000 // 1024
  end
  HR.at = sys.millis()
  if bpm > 0 then set("bpm", bpm) end
  dirty = true
end

-- Scan until a heart rate sensor is heard: the remembered one, else the
-- strongest advertising the service (after a moment to hear them all).
local function find()
  local saved = store.get("addr")
  local best, first_at
  ble.scan(function(a)
    local mine = saved and a.addr == saved
    local hr = false
    for _, u in ipairs(a.uuids or {}) do if u == HR_SVC then hr = true end end
    if mine or (not saved and hr) then
      if not best or mine or a.rssi > best.rssi then best = a end
      first_at = first_at or sys.millis()
    end
  end, { active = true })                     -- some straps list the service only in the scan response
  while not (best and (best.addr == saved or sys.millis() - first_at > 1500)) do
    if HR.forget then best = nil; break end      -- forgotten while looking for it
    sleep(100)
  end
  ble.stop_scan()
  return best
end

local function connect(dev)
  set("name", dev.name or dev.addr)
  set("phase", "connect")
  local c, err = ble.connect(dev.addr)
  if not c then return err end
  local ok
  ok, err = c:wait_connected()
  if ok then
    store.set("addr", dev.addr)
    local b = c:read("180f", "2a19")         -- battery: optional
    if b then set("battery", b:byte()) end
    c:subscribe("180f", "2a19", function(d) set("battery", d:byte()) end)
    ok, err = c:subscribe(HR_SVC, HR_MEAS, on_measurement)
  end
  if ok then
    set("phase", "live")
    set("msg", nil)
    session.start = session.start or sys.millis()
    while c:status() == "connected" and not HR.forget do sleep(200) end
    err = select(2, c:status())
  end
  c:close()
  return err
end

task(function()
  while true do
    set("phase", "search")
    if HR.forget then store.set("addr", nil); HR.forget = nil; set("battery", nil) end
    local dev = find()
    if dev then set("msg", connect(dev)) end
    sleep(500)
  end
end)

-- Once a second: the chart and the session.
timer.every(1000, function()
  local v = fresh() and HR.contact and HR.bpm or false
  history[#history + 1] = v
  if #history > CHART_S then table.remove(history, 1) end
  if v then
    session.start = session.start or sys.millis()
    session.sum, session.n = session.sum + v, session.n + 1
    session.max = math.max(session.max, v)
  end
  dirty = true
end)

---------------------------------------------------------------- drawing

local function centered(y, s, col, scale)
  disp.text((W - disp.text_width(s, scale)) // 2, y, s, col, scale)
end
local function text_right(x, y, s, col, scale)
  disp.text(x - disp.text_width(s, scale), y, s, col, scale)
end

local function battery(x, y, pct, live)
  disp.rect(x, y, 28, 14, DIM)
  disp.rect(x + 28, y + 4, 3, 6, DIM, true)
  if pct then
    local col = not live and DIM or pct > 40 and disp.rgb(70, 200, 90) or pct > 20 and disp.ORANGE or disp.RED
    disp.rect(x + 2, y + 2, math.max(1, 24 * pct // 100), 10, col, true)
    disp.text(x + 36, y + 4, pct .. "%", live and FG or DIM, 1)
  end
end

-- A heart, about 2r wide, centred on (cx, cy).
local function heart(cx, cy, r, col)
  local h = r // 2
  disp.circle(cx - h, cy - h // 2, h, col, true)
  disp.circle(cx + h, cy - h // 2, h, col, true)
  for i = 0, r do
    local w = r - i
    disp.line(cx - w, cy + i - h // 2 + 1, cx + w, cy + i - h // 2 + 1, col)
  end
end

local function mmss(ms)
  local s = ms // 1000
  if s >= 3600 then return string.format("%d:%02d:%02d", s // 3600, s % 3600 // 60, s % 60) end
  return string.format("%d:%02d", s // 60, s % 60)
end

local function draw_top()
  local live = HR.phase == "live"
  battery(8, 6, HR.battery, live)
  local dot = live and disp.rgb(70, 200, 90) or HR.phase == "connect" and disp.ORANGE or DIMMER
  local name = HR.name or "Heart rate"
  text_right(312, 9, name, DIM, 1)
  disp.circle(312 - disp.text_width(name) - 8, 12, 3, dot, true)
end

local function draw_reading()
  local on = HR.phase == "live" and fresh() and HR.contact
  if HR.bpm then
    local _, z = zone(HR.bpm)
    local col = on and z.col or DIMMER
    local s = tostring(HR.bpm)
    local w = disp.text(16, 34, s, col, 8)
    heart(16 + w + 22, 44, 12, on and disp.rgb(240, 60, 60) or DIMMER)
    disp.text(16 + w + 10, 64, "bpm", DIM, 2)
    disp.text(16, 96, on and z.name or (HR.contact and "--" or "no skin contact"), col, 2)
  else
    disp.text(16, 34, "--", DIMMER, 8)
  end

  -- the zones as a bar, the current one tall
  local cur = HR.bpm and on and zone(HR.bpm)
  for i = 2, #ZONES do
    local x = 212 + (i - 2) * 20
    local tall = cur == i
    disp.rect(x, tall and 36 or 50, 16, tall and 40 or 26, cur == i and ZONES[i].col or GRID, true)
  end
  disp.text(212, 82, "HRmax " .. HR.max_hr, DIMMER, 1)

  -- the session: time, average, max
  if session.start and session.n > 0 then
    local line = string.format("%s  avg %d  max %d", mmss(sys.millis() - session.start),
                               session.sum // session.n, session.max)
    text_right(312, 100, line, DIM, 1)
  end
end

local function draw_chart()
  local lo, hi = HR.max_hr * 0.5, HR.max_hr
  for _, v in ipairs(history) do
    if v then lo = math.min(lo, v - 5); hi = math.max(hi, v + 5) end
  end
  local function y_of(v) return CY1 - math.floor((v - lo) * (CY1 - CY0) / (hi - lo) + 0.5) end
  for i = 2, #ZONES do                          -- zone boundaries
    local v = ZONES[i].from * HR.max_hr // 100
    if v >= lo then
      local y = y_of(v)
      for x = CX0, CX1, 4 do disp.pixel(x, y, GRID) end
      text_right(CX0 - 4, y - 3, tostring(v), DIMMER, 1)
    end
  end
  disp.line(CX0, CY1, CX1, CY1, GRID)
  disp.text(CX0, CY1 + 4, "-2 min", DIMMER, 1)
  text_right(CX1, CY1 + 4, "now", DIMMER, 1)
  local n = #history
  local function x_of(i) return CX1 - (n - i) * (CX1 - CX0) // (CHART_S - 1) end
  for i = 2, n do
    local a, b = history[i - 1], history[i]
    if a and b then
      local _, z = zone(b)
      local x0, y0, x1, y1 = x_of(i - 1), y_of(a), x_of(i), y_of(b)
      disp.line(x0, y0, x1, y1, z.col); disp.line(x0, y0 - 1, x1, y1 - 1, z.col)
    end
  end
end

local function draw_status()
  if HR.phase == "live" then
    if not fresh() then centered(224, "waiting for a reading...", DIM, 1) end
    return
  end
  centered(214, HR.phase == "connect" and "Connecting..." or "Looking for a heart rate strap...", FG, 1)
  centered(228, HR.msg or (HR.phase == "search" and "put it on: it wakes when it feels a heartbeat" or ""), DIM, 1)
end

-- Settings: A / C change the max heart rate (held: by 5), B is done, the
-- button at the bottom forgets the strap.
local FORGET = { x = 60, y = 168, w = 200, h = 36 }

local function draw_settings()
  centered(20, "Max heart rate", FG, 2)
  centered(56, tostring(HR.max_hr), ACCENT, 6)
  centered(110, "<< -1      o done      +1 >>", DIM, 1)
  centered(124, "hold << or >> for 5", DIMMER, 1)
  disp.rect(FORGET.x, FORGET.y, FORGET.w, FORGET.h, GRID, true)
  centered(FORGET.y + 14, store.get("addr") and "Forget this strap" or "No strap remembered", FG, 1)
  centered(220, "zones: 50 60 70 80 90 % of max", DIMMER, 1)
end

local function draw()
  disp.clear(BG)
  if HR.settings then draw_settings(); return end
  draw_top(); draw_reading(); draw_chart(); draw_status()
end

function loop()
  if dirty then dirty = false; draw() end
end

---------------------------------------------------------------- input

local function change_max(d)
  HR.max_hr = math.max(100, math.min(230, HR.max_hr + d))
  store.set("max_hr", HR.max_hr)
  dirty = true
end

touch.on("press", function(b)
  if HR.settings then
    if b == "A" then change_max(-1) elseif b == "C" then change_max(1)
    else HR.settings = false; dirty = true end
  elseif b == "B" then                         -- a new session
    session = { start = HR.phase == "live" and sys.millis() or nil, sum = 0, n = 0, max = 0 }
    history = {}
    dirty = true
  end
end)
touch.on("long", function(b)
  if HR.settings then change_max(b == "A" and -5 or 5) end
end)
touch.on("hold", function()
  if not HR.settings then HR.settings = true; dirty = true end
end)
touch.on("tap", function(x, y)
  if not HR.settings then return end
  if x >= FORGET.x and x < FORGET.x + FORGET.w and y >= FORGET.y and y < FORGET.y + FORGET.h then
    HR.forget = true
    HR.bpm, history = nil, {}
  end
  HR.settings = false
  dirty = true
end)

disp.keep_awake(true)
