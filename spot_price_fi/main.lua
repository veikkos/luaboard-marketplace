-- spot_price_fi: Finland's electricity spot price in 15-minute slots, today
-- and tomorrow. Data: porssisahko.net (c/kWh incl. VAT, Nord Pool FI area).
-- A = today, C = tomorrow, B = refresh, tap a bar for its price. Needs Wi-Fi.

local http, json = require("http"), require("json")

local API = "https://api.porssisahko.net/v2/"          -- latest-prices.json, price.json

local W, H = disp.W, disp.H
local BG, FG = disp.rgb(10, 14, 20), disp.WHITE
local DIM, DIMMER = disp.rgb(140, 150, 165), disp.rgb(70, 80, 95)
local GRID = disp.rgb(32, 40, 52)
local ACCENT = disp.rgb(90, 180, 255)

local CX0, CX1, CY0, CY1 = 30, 314, 80, 196

---------------------------------------------------------------- time
-- sys.time() once the clock is set, else the API reply's Date header plus
-- sys.millis(). Prices follow Finnish days, so Finnish time is used
-- regardless of the device's time zone. A local day is a day number (days
-- since 1970-01-01), to compare and step through.

local FI = "EET-2EEST,M3.5.0/3,M10.5.0/4"

local function iso_time(s) return type(s) == "string" and (sys.time(s)) or nil end  -- UTC seconds

local function local_day(t)
  local d = sys.date(t, FI)
  return sys.time({ year = d.year, month = d.month, day = d.day }, "UTC") // 86400
end

-- UTC start of a local day, and its length (23 or 25 h when the clocks change).
local function day_start(day)
  local d = sys.date(day * 86400, "UTC")
  return sys.time({ year = d.year, month = d.month, day = d.day }, FI)
end
local function day_len(day) return day_start(day + 1) - day_start(day) end

local function iso(t) return sys.date("%Y-%m-%dT%H:%M:%S.000Z", t, "UTC") end   -- "2026-11-05T22:00:00.000Z"
local function hhmm(t) return sys.date("%H:%M", t, FI) end
local function day_name(day) return sys.date("%a %-d.%-m.", day * 86400, "UTC") end

---------------------------------------------------------------- state

local slots = {}            -- { t = start (UTC s), p = c/kWh }, oldest first
local clock_t, clock_ms     -- UTC seconds at sys.millis() == clock_ms
local status = "Fetching prices..."
local view = 0              -- 0 = today, 1 = tomorrow
local picked, picked_until  -- a tapped slot, shown at the top for a while
local fetching = false
local last_fetch_ms = -60000
local drawn_slot            -- slot start the screen was drawn for

local function now()
  return sys.time() or (clock_t and clock_t + (sys.millis() - clock_ms) // 1000)
end

-- Slots of a local day, and their min / average / max.
local function day_slots(day)
  local list = {}
  for _, s in ipairs(slots) do
    if local_day(s.t) == day then list[#list + 1] = s end
  end
  return list
end

local function stats(list)
  local lo, hi, sum = list[1], list[1], 0
  for _, s in ipairs(list) do
    if s.p < lo.p then lo = s end
    if s.p > hi.p then hi = s end
    sum = sum + s.p
  end
  return lo, hi, sum / #list
end

local function slot_at(t)
  for _, s in ipairs(slots) do
    if t >= s.t and t < s.t + 900 then return s end
  end
end

---------------------------------------------------------------- drawing

-- Same idea as porssisahko.net's scale: green is cheap, red is expensive.
local function level(p)
  if p <= 0 then return disp.rgb(80, 170, 255) end
  if p < 5 then return disp.rgb(46, 204, 113) end
  if p < 10 then return disp.rgb(190, 214, 60) end
  if p < 15 then return disp.rgb(250, 176, 50) end
  if p < 25 then return disp.rgb(240, 100, 50) end
  return disp.rgb(214, 40, 70)
end

local function price_str(p) return string.format("%.2f", p) end

local function draw_top()
  disp.rect(0, 0, W, 60, BG, true)
  local s, label
  if picked and sys.millis() < picked_until then
    s, label = picked, "AT " .. hhmm(picked.t) .. "-" .. hhmm(picked.t + 900)
  else
    picked = nil
    local t = now()
    s = t and slot_at(t)
    label = s and ("NOW " .. hhmm(s.t) .. "-" .. hhmm(s.t + 900)) or "NOW"
  end
  disp.text(10, 6, label, DIM, 1)
  if s then
    local w = disp.text(10, 20, price_str(s.p), level(s.p), 4)
    disp.text(10 + w + 4, 42, "c/kWh", DIM, 1)
  else
    disp.text(10, 24, "--", DIMMER, 4)
  end

  -- min / avg / max of the day on the chart
  local list = now() and day_slots(local_day(now()) + view) or {}
  local rows = { { "min" }, { "avg" }, { "max" } }
  if #list > 0 then
    local lo, hi, avg = stats(list)
    rows = { { "min", lo.p, hhmm(lo.t) }, { "avg", avg }, { "max", hi.p, hhmm(hi.t) } }
  end
  for i, r in ipairs(rows) do
    local y = 4 + (i - 1) * 19
    disp.text(186, y + 4, r[1], DIM, 1)
    if r[3] then disp.text(208, y + 4, r[3], DIMMER, 1) end
    if r[2] then disp.text(312, y, price_str(r[2]), level(r[2]), 2, nil, "right")
    else disp.text(312, y, "-", DIMMER, 2, nil, "right") end
  end
end

-- A nice grid step for the price range.
local function grid_step(range)
  for _, s in ipairs({ 1, 2, 5, 10, 20, 50, 100 }) do
    if range / s <= 5 then return s end
  end
  return 200
end

-- The clock, Finnish time like the chart, top right of the chart's date row.
local drawn_minute
local function draw_clock()
  local t = now()
  disp.rect(270, 62, W - 270, 10, BG, true)
  if t then disp.text(312, 64, hhmm(t), FG, 1, nil, "right") end
  drawn_minute = t and t // 60
end

local function chart_body()
  disp.rect(0, 62, W, CY1 - 62 + 18, BG, true)
  local t = now()
  if not t then
    disp.text(CX0, 120, status, DIM, 1)
    return
  end
  local day = local_day(t) + view
  disp.text(CX0, 64, (view == 0 and "Today " or "Tomorrow ") .. day_name(day), ACCENT, 1)
  local list = day_slots(day)
  if #list == 0 then
    local msg = view == 1 and { "Tomorrow's prices come out", "around 14:00 Finnish time." } or { status }
    for i, l in ipairs(msg) do disp.text(CX0, 110 + (i - 1) * 14, l, DIM, 1) end
    return
  end
  if status ~= "ok" then disp.text(312 - 42, 64, status, disp.ORANGE, 1, nil, "right") end

  local lo, hi, avg = stats(list)
  local vmin, vmax = math.min(0, lo.p), math.max(hi.p, 1)
  local step = grid_step(vmax - vmin)
  vmin = math.floor(vmin / step) * step
  vmax = math.ceil(vmax / step) * step
  local function y_of(v) return CY1 - math.floor((v - vmin) * (CY1 - CY0) / (vmax - vmin) + 0.5) end

  for v = vmin, vmax, step do                      -- grid with labels
    local y = y_of(v)
    disp.line(CX0, y, CX1, y, v == 0 and DIMMER or GRID)
    disp.text(CX0 - 4, y - 3, tostring(v), DIMMER, 1, nil, "right")
  end

  local cur = slot_at(t)
  local zero = y_of(0)
  local d0, dl = day_start(day), day_len(day)
  local function x_of(ts) return CX0 + (ts - d0) * (CX1 - CX0) // dl end
  for h = 0, dl // 3600 - 1, 6 do                  -- hour labels: 00, 06, 12, 18
    local x = x_of(d0 + h * 3600)
    local hs = sys.date(d0 + h * 3600, FI).hour
    disp.line(x, CY1 + 1, x, CY1 + 3, DIMMER)
    disp.text(x, CY1 + 6, string.format("%02d", hs), DIMMER, 1)
  end
  for _, s in ipairs(list) do                      -- bars at their time of day
    local x = x_of(s.t)
    local w = math.max(1, x_of(s.t + 900) - x - 1)
    local y = y_of(s.p)
    local col = (s == cur or s == picked) and FG or level(s.p)
    if y < zero then disp.rect(x, y, w, zero - y, col, true)
    elseif y > zero then disp.rect(x, zero + 1, w, y - zero, col, true) end
    if s == cur then                              -- marker above "now"
      for k = 0, 3 do disp.line(x + w // 2 - k, CY0 - 4 - k, x + w // 2 + k, CY0 - 4 - k, FG) end
    end
  end

  local ya = y_of(avg)                             -- dashed average line
  for x = CX0, CX1, 6 do disp.line(x, ya, math.min(x + 2, CX1), ya, FG) end
end

local function draw_chart()
  chart_body()
  draw_clock()
end

local function draw_footer()
  disp.rect(0, 214, W, H - 214, BG, true)
  disp.line(0, 214, W, 214, GRID)
  disp.text(8, 218, "<< today", view == 0 and ACCENT or DIMMER, 1)
  disp.text(W // 2, 218, "o refresh", DIMMER, 1, nil, "center")
  disp.text(312, 218, "tomorrow >>", view == 1 and ACCENT or DIMMER, 1, nil, "right")
  disp.text(W // 2, 230, "prices: porssisahko.net - c/kWh incl. VAT", DIMMER, 1, nil, "center")
end

local function draw_all()
  disp.clear(BG)
  draw_top(); draw_chart(); draw_footer()
  local t = now()
  local s = t and slot_at(t)
  drawn_slot = s and s.t
end

---------------------------------------------------------------- fetching

-- Merge new prices into what we have; forget anything before yesterday.
local function merge(list)
  local by_t = {}
  for _, s in ipairs(slots) do by_t[s.t] = s end
  for _, s in ipairs(list) do by_t[s.t] = s end
  local t = now()
  local keep_from = t and day_start(local_day(t) - 1) or 0
  slots = {}
  for ts, s in pairs(by_t) do
    if ts >= keep_from then slots[#slots + 1] = s end
  end
  table.sort(slots, function(a, b) return a.t < b.t end)
end

-- latest-prices.json covers 48 h in Nord Pool's (Norwegian) days: after
-- 14:00 it starts at 01:00 Finnish time, so the first hour of today is
-- missing. Ask for those slots one by one (a handful of small requests).
local function fill_today()
  local t = now()
  if not t then return end
  local day = local_day(t)
  local have = {}
  for _, s in ipairs(slots) do have[s.t] = true end
  local added, asked = {}, 0
  for ts = day_start(day), day_start(day + 1) - 900, 900 do
    if not have[ts] and asked < 8 then
      asked = asked + 1
      local st, body = http.get(API .. "price.json?date=" .. iso(ts + 60), { ["Accept"] = "application/json" })
      local data = json.decode(body or "")
      if st == 200 and type(data) == "table" and type(data.price) == "number" then
        added[#added + 1] = { t = ts, p = data.price }
      end
    end
  end
  if #added > 0 then merge(added) end
end

local function fetch()
  if fetching then return end
  fetching = true
  last_fetch_ms = sys.millis()
  local st, body, headers = http.get(API .. "latest-prices.json", { ["Accept"] = "application/json" })
  if not st then
    status = "no connection"
  elseif st == 429 then
    status = "busy, retrying"
  elseif st ~= 200 then
    status = "HTTP " .. st
  else
    local data = json.decode(body)
    if type(data) ~= "table" or type(data.prices) ~= "table" then
      status = "bad reply"
    else
      local list = {}
      for _, e in ipairs(data.prices) do
        local t = type(e.startDate) == "string" and iso_time(e.startDate)
        if t and type(e.price) == "number" then list[#list + 1] = { t = t, p = e.price } end
      end
      local t = headers and headers["date"] and sys.time(headers["date"])
      if t then clock_t, clock_ms = t, sys.millis() end
      merge(list)
      fill_today()
      status = "ok"
    end
  end
  fetching = false
  draw_all()
end

local function has_tomorrow()
  local t = now()
  return t and #day_slots(local_day(t) + 1) > 0
end

-- How long until the next fetch. The API asks for at most one a minute.
local function next_wait()
  local t = now()
  if status ~= "ok" or not t then return 60 * 1000 end
  if not has_tomorrow() and sys.date(t, FI).hour >= 14 then
    return 10 * 60 * 1000                          -- tomorrow's are due
  end
  return 60 * 60 * 1000                            -- prices change once a day
end

task(function()
  fetch()
  while true do
    local mark = last_fetch_ms
    local wait = next_wait()
    while sys.millis() - mark < wait and last_fetch_ms == mark do sleep(1000) end
    if last_fetch_ms == mark then fetch() end      -- else B refreshed: wait again from there
  end
end)

---------------------------------------------------------------- input

-- A new slot (every 15 min), and the tapped price going away.
timer.every(1000, function()
  local t = now()
  local s = t and slot_at(t)
  if (s and s.t) ~= drawn_slot then draw_all()
  elseif picked and sys.millis() >= picked_until then draw_all()
  elseif t and t // 60 ~= drawn_minute then draw_clock() end
end)

local function button(b)
  if b == "A" and view ~= 0 then view = 0; draw_all()
  elseif b == "C" and view ~= 1 then view = 1; draw_all()
  elseif b == "B" and not fetching and sys.millis() - last_fetch_ms > 5000 then
    status = "refreshing..."
    draw_chart()
    task(fetch)
  end
end
touch.on("press", button)
touch.on("long", button)                        -- a slow press of A or C counts too

local function pick_bar(x, y)                   -- a bar: its price for a while
  if y >= CY0 - 8 and y <= CY1 + 12 and x >= CX0 and x < CX1 and now() then
    local day = local_day(now()) + view
    local s = slot_at(day_start(day) + (x - CX0) * day_len(day) // (CX1 - CX0))
    if s then
      picked, picked_until = s, sys.millis() + 5000
      draw_top(); draw_chart()
    end
  end
end
touch.on("hold", pick_bar)

-- The buttons by touch, for a board without them: a swipe to the side for
-- the other day, down to refresh, or a tap on a hint at the bottom.
touch.on("swipe", function(dir)
  button(dir == "right" and "A" or dir == "left" and "C" or dir == "down" and "B")
end)
touch.on("tap", function(x, y)
  if y >= 210 then button(x < W // 3 and "A" or x < 2 * W // 3 and "B" or "C") else pick_bar(x, y) end
end)

draw_all()
