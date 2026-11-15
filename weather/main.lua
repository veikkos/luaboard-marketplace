-- weather: the weather now and the next 24 hours, or the next 7 days, for one
-- place. Data: Open-Meteo (open-meteo.com), free and without an API key.
-- A = now, C = 7 days, B = refresh. Needs Wi-Fi.
--
-- The place comes from secrets.env (see secrets.env.example): `place` alone is
-- looked up by name (Open-Meteo's geocoding), `lat` and `lon` give it exactly
-- (`place` is then only its label). Without either it's Helsinki.

local http, json = require("http"), require("json")

local API = "https://api.open-meteo.com/v1/"            -- forecast
local GEO = "https://geocoding-api.open-meteo.com/v1/"  -- search

local REFRESH_MS = 15 * 60 * 1000    -- Open-Meteo's current values change every 15 min

local W, H = disp.W, disp.H
local BG, FG = disp.rgb(12, 16, 24), disp.WHITE
local DIM, DIMMER = disp.rgb(150, 160, 175), disp.rgb(75, 85, 100)
local GRID = disp.rgb(34, 42, 56)
local ACCENT = disp.rgb(90, 180, 255)
local WARM = disp.rgb(255, 170, 60)               -- the temperature line
local RAIN = disp.rgb(70, 140, 255)
local SUN = disp.rgb(255, 205, 50)
local CLOUD, DARK_CLOUD = disp.rgb(205, 212, 222), disp.rgb(130, 138, 150)
local MOON = disp.rgb(230, 225, 190)

local CX0, CX1, CY0, CY1 = 30, 314, 128, 196       -- the 24 h chart

UI = { status = "Fetching...", fetches = 0, view = "now" }   -- global: tests read it

local wx                 -- the last forecast (Open-Meteo's reply)
local place              -- { name, lat, lon }
local fetching = false
local last_fetch_ms = -60000

---------------------------------------------------------------- helpers

local function round(x) return math.floor(x + 0.5) end

local function text_right(x, y, s, col, scale)
  disp.text(x - disp.text_width(s, scale), y, s, col, scale)
end

local function centered(y, s, col, scale)
  disp.text((W - disp.text_width(s, scale)) // 2, y, s, col, scale)
end

-- Local time of the place (Open-Meteo gives its UTC offset).
local function local_secs(t) return t + (wx and wx.utc_offset_seconds or 0) end
local function hhmm(t)
  local s = local_secs(t) % 86400
  return string.format("%02d:%02d", s // 3600, s % 3600 // 60)
end
local WEEKDAYS = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }

-- "6", "-12", "0" (never "-0")
local function deg(v)
  local r = round(v)
  return tostring(r == 0 and 0 or r)
end

local COMPASS = { "N", "NE", "E", "SE", "S", "SW", "W", "NW" }
local function compass(d) return COMPASS[round(d / 45) % 8 + 1] end

---------------------------------------------------------------- weather codes
-- WMO codes as Open-Meteo uses them: a description and the icon to draw.

local CODES = {
  [0] = { "Clear", "clear" }, [1] = { "Mostly clear", "clear" },
  [2] = { "Partly cloudy", "partly" }, [3] = { "Overcast", "cloud" },
  [45] = { "Fog", "fog" }, [48] = { "Rime fog", "fog" },
  [51] = { "Light drizzle", "drizzle" }, [53] = { "Drizzle", "drizzle" },
  [55] = { "Heavy drizzle", "drizzle" }, [56] = { "Freezing drizzle", "drizzle" },
  [57] = { "Freezing drizzle", "drizzle" },
  [61] = { "Light rain", "rain" }, [63] = { "Rain", "rain" }, [65] = { "Heavy rain", "rain" },
  [66] = { "Freezing rain", "rain" }, [67] = { "Freezing rain", "rain" },
  [71] = { "Light snow", "snow" }, [73] = { "Snow", "snow" }, [75] = { "Heavy snow", "snow" },
  [77] = { "Snow grains", "snow" },
  [80] = { "Light showers", "rain" }, [81] = { "Showers", "rain" }, [82] = { "Heavy showers", "rain" },
  [85] = { "Snow showers", "snow" }, [86] = { "Snow showers", "snow" },
  [95] = { "Thunderstorm", "thunder" }, [96] = { "Thunder, hail", "thunder" },
  [99] = { "Thunder, hail", "thunder" },
}
local function code_info(c) return CODES[c] or { "?", "cloud" } end

---------------------------------------------------------------- icons
-- Drawn from circles and lines, centred on (cx, cy), about 2r wide.

local function sun(cx, cy, r)
  for i = 0, 7 do
    local a = i * math.pi / 4
    local c, s = math.cos(a), math.sin(a)
    disp.line(round(cx + c * r * 0.95), round(cy + s * r * 0.95),
              round(cx + c * r * 1.35), round(cy + s * r * 1.35), SUN)
  end
  disp.circle(cx, cy, round(r * 0.7), SUN, true)
end

local function moon(cx, cy, r, bg)
  disp.circle(cx, cy, round(r * 0.8), MOON, true)
  disp.circle(round(cx + r * 0.4), round(cy - r * 0.3), round(r * 0.65), bg, true)
end

local function cloud(cx, cy, r, col)
  disp.circle(round(cx - r * 0.5), round(cy + r * 0.15), round(r * 0.42), col, true)
  disp.circle(round(cx + r * 0.05), round(cy - r * 0.15), round(r * 0.58), col, true)
  disp.circle(round(cx + r * 0.55), round(cy + r * 0.18), round(r * 0.4), col, true)
  disp.rect(round(cx - r * 0.5), round(cy + r * 0.15), round(r * 1.05), round(r * 0.43), col, true)
end

-- What falls from a cloud: `kind` rain, drizzle, snow or thunder, in the
-- band from y0 down to y0 + h.
local function falling(kind, cx, y0, r, h)
  for i = -1, 1 do
    local x = round(cx + i * r * 0.5)
    if kind == "snow" then
      local y = y0 + round(h * (i == 0 and 0.6 or 0.3))
      local a = math.max(1, round(r * 0.12))
      disp.line(x - a, y, x + a, y, FG); disp.line(x, y - a, x, y + a, FG)
      disp.line(x - a, y - a, x + a, y + a, FG); disp.line(x - a, y + a, x + a, y - a, FG)
    elseif kind == "drizzle" then
      for k = 0, 1 do disp.circle(x - k * round(r * 0.15), y0 + round(h * (0.25 + k * 0.5)), math.max(1, round(r * 0.06)), RAIN, true) end
    elseif kind == "rain" then
      local dx = round(r * 0.2)
      disp.line(x, y0, x - dx, y0 + h, RAIN); disp.line(x + 1, y0, x + 1 - dx, y0 + h, RAIN)
    end
  end
  if kind == "thunder" then
    local s = r / 10
    local pts = { { 1, 0 }, { -2, 5 }, { 1, 5 }, { -1, 10 } }
    for i = 1, #pts - 1 do
      for o = 0, 1 do
        disp.line(round(cx + pts[i][1] * s) + o, y0 + round(pts[i][2] * s),
                  round(cx + pts[i + 1][1] * s) + o, y0 + round(pts[i + 1][2] * s), SUN)
      end
    end
  end
end

local function icon(code, cx, cy, r, day, bg)
  local kind = code_info(code)[2]
  if kind == "clear" then
    if day then sun(cx, cy, r) else moon(cx, cy, r, bg) end
  elseif kind == "partly" then
    if day then sun(round(cx - r * 0.3), round(cy - r * 0.3), r * 0.7)
    else moon(round(cx - r * 0.3), round(cy - r * 0.35), r * 0.75, bg) end
    cloud(round(cx + r * 0.15), round(cy + r * 0.2), r * 0.85, CLOUD)
  elseif kind == "cloud" then
    cloud(cx, cy, r, CLOUD)
  elseif kind == "fog" then
    cloud(cx, round(cy - r * 0.25), r * 0.85, DARK_CLOUD)
    for i = 0, 2 do
      local y = round(cy + r * (0.35 + i * 0.25))
      disp.line(round(cx - r * (0.8 - i * 0.15)), y, round(cx + r * (0.8 - i * 0.1)), y, CLOUD)
    end
  else                                             -- rain, drizzle, snow, thunder
    cloud(cx, round(cy - r * 0.3), r * 0.9, kind == "thunder" and DARK_CLOUD or CLOUD)
    falling(kind, cx, round(cy + r * 0.32), r, round(r * 0.6))
  end
end

---------------------------------------------------------------- drawing

local function draw_header(title)
  disp.text(8, 6, title, FG, 1)
  local right = UI.status ~= "ok" and UI.status or (wx and ("updated " .. hhmm(wx.current.time)) or "")
  text_right(312, 6, right, UI.status ~= "ok" and disp.ORANGE or DIMMER, 1)
end

local function draw_footer()
  disp.line(0, 214, W, 214, GRID)
  disp.text(8, 218, "<< now", UI.view == "now" and ACCENT or DIMMER, 1)
  local mid = "o refresh"
  disp.text((W - disp.text_width(mid)) // 2, 218, mid, DIMMER, 1)
  text_right(312, 218, "7 days >>", UI.view == "days" and ACCENT or DIMMER, 1)
  centered(230, "weather: open-meteo.com", DIMMER, 1)
end

-- A nice grid step for a temperature range.
local function grid_step(range)
  for _, s in ipairs({ 1, 2, 5, 10 }) do
    if range / s <= 4 then return s end
  end
  return 20
end

local function draw_chart()
  local hr = wx.hourly
  local n = #hr.time
  if n < 2 then return end
  local lo, hi, rain_max = math.huge, -math.huge, 2
  for i = 1, n do
    lo = math.min(lo, hr.temperature_2m[i]); hi = math.max(hi, hr.temperature_2m[i])
    rain_max = math.max(rain_max, hr.precipitation[i] or 0)
  end
  local step = grid_step(math.max(hi - lo, 1))
  local vmin, vmax = math.floor(lo / step) * step, math.ceil(hi / step) * step
  if vmax == vmin then vmax = vmin + step end
  local function y_of(v) return CY1 - round((v - vmin) * (CY1 - CY0) / (vmax - vmin)) end
  local function x_of(i) return CX0 + (i - 1) * (CX1 - CX0) // (n - 1) end

  for v = vmin, vmax, step do                       -- grid with labels
    local y = y_of(v)
    disp.line(CX0, y, CX1, y, GRID)
    text_right(CX0 - 4, y - 3, deg(v), DIMMER, 1)
  end
  local bw = math.max(2, (CX1 - CX0) // (n - 1) - 3)
  for i = 1, n do                                   -- rain: blue bars from the bottom
    local mm = hr.precipitation[i] or 0
    if mm > 0 then
      local h = math.max(2, round(mm * (CY1 - CY0) / rain_max * 0.6))
      local x = math.min(x_of(i) - bw // 2, CX1 - bw)
      disp.rect(math.max(x, CX0), CY1 - h, bw, h, RAIN, true)
    end
    local s = local_secs(hr.time[i]) % 86400 // 3600
    if s % 6 == 0 then                              -- hour labels: 00, 06, 12, 18
      disp.line(x_of(i), CY1 + 1, x_of(i), CY1 + 3, DIMMER)
      disp.text(x_of(i) - 5, CY1 + 6, string.format("%02d", s), DIMMER, 1)
    end
  end
  for i = 1, n - 1 do                               -- temperature: a thick line
    local x0, y0 = x_of(i), y_of(hr.temperature_2m[i])
    local x1, y1 = x_of(i + 1), y_of(hr.temperature_2m[i + 1])
    disp.line(x0, y0, x1, y1, WARM); disp.line(x0, y0 - 1, x1, y1 - 1, WARM)
  end
  disp.circle(x_of(1), y_of(hr.temperature_2m[1]), 3, FG, true)   -- now
  disp.text(CX0, CY0 - 12, "next 24 h", ACCENT, 1)
  local sum = 0
  for i = 1, n do sum = sum + (hr.precipitation[i] or 0) end
  if sum >= 0.1 then text_right(CX1, CY0 - 12, string.format("rain %.1f mm", sum), RAIN, 1) end
end

local function draw_now()
  local c = wx.current
  local info = code_info(c.weather_code)
  icon(c.weather_code, 54, 64, 30, c.is_day == 1, BG)

  local t = deg(c.temperature_2m)
  local x = 112
  local w = disp.text(x, 26, t, FG, 6)
  disp.circle(x + w + 6, 30, 5, FG); disp.circle(x + w + 6, 30, 4, FG)
  disp.text(x + w + 16, 26, "C", DIM, 3)
  disp.text(x, 78, info[1], FG, 2)
  disp.text(x, 100, string.format("feels %s   wind %d m/s %s", deg(c.apparent_temperature),
                                  round(c.wind_speed_10m), compass(c.wind_direction_10m)), DIM, 1)
  draw_chart()
end

local function draw_days()
  local d = wx.daily
  local today = local_secs(wx.current.time) // 86400
  for i = 1, math.min(#d.time, 7) do
    local y = 22 + (i - 1) * 27
    local day = local_secs(d.time[i]) // 86400
    local name = day == today and "Today" or WEEKDAYS[(day + 4) % 7 + 1]
    if i > 1 then disp.line(8, y - 2, 312, y - 2, GRID) end
    disp.text(8, y + 6, name, day == today and ACCENT or FG, 2)
    icon(d.weather_code[i], 92, y + 11, 10, true, BG)
    disp.text(112, y + 9, code_info(d.weather_code[i])[1], DIM, 1)
    local mm = d.precipitation_sum[i] or 0
    if mm >= 0.1 then text_right(238, y + 9, string.format("%.1f mm", mm), RAIN, 1) end
    text_right(268, y + 6, deg(d.temperature_2m_min[i]), DIM, 2)
    text_right(312, y + 6, deg(d.temperature_2m_max[i]), FG, 2)
  end
end

local function draw()
  disp.clear(BG)
  local name = place and place.name or "Weather"
  draw_header(UI.view == "days" and ("7 days, " .. name) or name)
  if not wx then
    centered(110, UI.status == "ok" and "" or UI.status, DIM, 2)
  elseif UI.view == "days" then
    draw_days()
  else
    draw_now()
  end
  draw_footer()
end

---------------------------------------------------------------- fetching

local function get_json(url)
  local st, body = http.get(url, { Accept = "application/json" })
  if not st then return nil, "no connection" end
  if st ~= 200 then return nil, "HTTP " .. st end
  local ok, t = pcall(json.decode, body)
  if not ok or type(t) ~= "table" then return nil, "bad reply" end
  return t
end

-- Where to show the weather for: lat/lon from secrets, or `place` looked up
-- once (and kept in store until the name changes), or Helsinki.
local function find_place()
  local name = secrets.get("place")
  local lat, lon = tonumber(secrets.get("lat") or ""), tonumber(secrets.get("lon") or "")
  if lat and lon then return { name = name or string.format("%.2f, %.2f", lat, lon), lat = lat, lon = lon } end
  if not name or name == "" then return { name = "Helsinki", lat = 60.1699, lon = 24.9384 } end
  local saved = store.get("geo")
  saved = saved and json.decode(saved)
  if saved and saved.q == name then return saved end
  local t, err = get_json(GEO .. "search?count=1&name=" .. http.urlencode(name))
  if not t then return nil, err end
  local r = type(t.results) == "table" and t.results[1]
  if not r then return nil, "place not found" end
  local p = { q = name, name = type(r.name) == "string" and r.name or name, lat = r.latitude, lon = r.longitude }
  store.set("geo", json.encode(p))
  return p
end

local function fetch()
  if fetching then return end
  fetching = true
  last_fetch_ms = sys.millis()
  local err
  if not place then place, err = find_place() end
  if place then
    local url = API .. "forecast?latitude=" .. place.lat .. "&longitude=" .. place.lon ..
      "&current=temperature_2m,apparent_temperature,weather_code,wind_speed_10m,wind_direction_10m,is_day" ..
      "&hourly=temperature_2m,precipitation&forecast_hours=24" ..
      "&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_sum&forecast_days=7" ..
      "&timezone=auto&wind_speed_unit=ms&timeformat=unixtime"
    local t
    t, err = get_json(url)
    if t and (type(t.current) ~= "table" or type(t.hourly) ~= "table" or type(t.daily) ~= "table") then
      t, err = nil, t.reason or "bad reply"
    end
    if t then wx = t end
  end
  UI.status = err or "ok"
  UI.fetches = UI.fetches + 1
  fetching = false
  draw()
end

task(function()
  fetch()
  while true do
    local mark = last_fetch_ms
    local wait = UI.status == "ok" and REFRESH_MS or 60 * 1000
    while sys.millis() - mark < wait and last_fetch_ms == mark do sleep(1000) end
    if last_fetch_ms == mark then fetch() end      -- else B refreshed: wait again from there
  end
end)

---------------------------------------------------------------- input

local function button(b)
  if b == "A" and UI.view ~= "now" then UI.view = "now"; draw()
  elseif b == "C" and UI.view ~= "days" then UI.view = "days"; draw()
  elseif b == "B" and not fetching and sys.millis() - last_fetch_ms > 5000 then
    UI.status = "refreshing..."
    draw()
    task(fetch)
  end
end
touch.on("press", button)
touch.on("long", button)                          -- a slow press of A or C counts too

disp.keep_awake(true)
draw()
