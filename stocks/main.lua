-- stocks: US stock and ETF prices and the day's chart. SPY follows the S&P
-- 500, QQQ the Nasdaq 100, DIA the Dow and IWM the Russell 2000; secrets.env
-- can pick up to four others. Data: Alpaca's free market data (prices on the
-- IEX exchange), with your own free keys.
-- A / C = previous / next symbol, B = refresh, tap a tile to pick it.
-- Needs Wi-Fi.

local http, json = require("http"), require("json")

local API = "https://data.alpaca.markets/v2/"          -- stocks/snapshots, stocks/bars

local LIVE_MS = 15 * 1000            -- prices while the market is open
local BARS_MS = 5 * 60 * 1000        -- the chart's 5-minute bars while it's open
local IDLE_MS = 30 * 60 * 1000       -- while it's closed
local RETRY_MS = 60 * 1000

local W, H = disp.W, disp.H
local BG, FG = disp.rgb(10, 14, 20), disp.WHITE
local DIM, DIMMER = disp.rgb(140, 150, 165), disp.rgb(70, 80, 95)
local GRID = disp.rgb(32, 40, 52)
local TILE, TILE_SEL = disp.rgb(22, 28, 38), disp.rgb(30, 44, 62)
local ACCENT = disp.rgb(90, 180, 255)
local UP, UP_FILL = disp.rgb(46, 204, 113), disp.rgb(18, 64, 44)
local DOWN, DOWN_FILL = disp.rgb(240, 84, 84), disp.rgb(78, 28, 32)

local CX0, CX1, CY0, CY1 = 6, 268, 66, 164        -- the chart
local TY = 184                                     -- the tiles' top

local NAMES = { SPY = "S&P 500", VOO = "S&P 500", IVV = "S&P 500", QQQ = "Nasdaq 100",
                DIA = "Dow Jones", IWM = "Russell 2000", VTI = "US total market" }

local KEY, SECRET = secrets.get("alpaca_key"), secrets.get("alpaca_secret")
local SYMBOLS = {}
for s in (secrets.get("symbols") or "SPY,QQQ,DIA,IWM"):gmatch("[^,%s]+") do
  if #SYMBOLS == 4 then print("stocks: only the first four symbols are shown"); break end
  SYMBOLS[#SYMBOLS + 1] = s:upper()
end

---------------------------------------------------------------- time
-- sys.time() once the clock is set, else the API reply's Date header plus
-- sys.millis(). The market keeps New York time, computed here whatever the
-- device's time zone.

local function days_from_civil(y, m, d)          -- days since 1970-01-01
  if m <= 2 then y = y - 1 end
  local era = y // 400
  local yoe = y - era * 400
  local doy = (153 * ((m + 9) % 12) + 2) // 5 + d - 1
  local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
  return era * 146097 + doe - 719468
end

local function civil_from_days(z)                 -- -> y, m, d
  z = z + 719468
  local era = z // 146097
  local doe = z - era * 146097
  local yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
  local doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
  local mp = (5 * doy + 2) // 153
  local d = doy - (153 * mp + 2) // 5 + 1
  local m = mp < 10 and mp + 3 or mp - 9
  return yoe + era * 400 + (m <= 2 and 1 or 0), m, d
end

local function iso_day(s)                         -- "2026-11-05T05:00:00Z" -> days
  local y, mo, d = (s or ""):match("^(%d+)-(%d+)-(%d+)")
  return y and days_from_civil(tonumber(y), tonumber(mo), tonumber(d))
end

local function iso_time(s)                        -- "2026-11-05T14:30:00Z", UTC
  local h, mi, se = (s or ""):match("T(%d+):(%d+):(%d+)")
  local day = iso_day(s)
  return day and h and day * 86400 + h * 3600 + mi * 60 + se
end

local function iso(t)                             -- UTC seconds -> "2026-11-05T14:30:00Z"
  local y, m, d = civil_from_days(t // 86400)
  local s = t % 86400
  return string.format("%04d-%02d-%02dT%02d:%02d:%02dZ", y, m, d, s // 3600, s % 3600 // 60, s % 60)
end

local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }
local MONTH_NO = {}
for i, m in ipairs(MONTHS) do MONTH_NO[m] = i end

local function http_date(s)                       -- "Fri, 06 Nov 2026 13:27:00 GMT"
  local d, mon, y, h, mi, se = (s or ""):match("(%d+) (%a+) (%d+) (%d+):(%d+):(%d+)")
  if not d or not MONTH_NO[mon] then return nil end
  return days_from_civil(tonumber(y), MONTH_NO[mon], tonumber(d)) * 86400 + h * 3600 + mi * 60 + se
end

-- New York time: UTC-5, UTC-4 from the second Sunday of March to the first
-- Sunday of November (02:00 local both ways).
local function et_offset(t)
  local y = civil_from_days(t // 86400)
  local function sunday(m, n)                     -- the nth Sunday of month m, in days
    local first = days_from_civil(y, m, 1)
    return first + (3 - first) % 7 + (n - 1) * 7  -- day 3 (1970-01-04) was a Sunday
  end
  local from, to = sunday(3, 2) * 86400 + 7 * 3600, sunday(11, 1) * 86400 + 6 * 3600
  return (t >= from and t < to) and -4 * 3600 or -5 * 3600
end

local function et_day(t) return (t + et_offset(t)) // 86400 end

-- UTC seconds of `mins` past midnight New York time on an ET day.
local function at_et(day, mins)
  return day * 86400 + mins * 60 - et_offset(day * 86400 + 12 * 3600)
end
local OPEN, CLOSE = 9 * 60 + 30, 16 * 60          -- the regular session, 9:30 to 16:00

local function hhmm(t)
  local s = (t + et_offset(t)) % 86400
  return string.format("%02d:%02d", s // 3600, s % 3600 // 60)
end

local WEEKDAYS = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }
local function day_name(day)
  local _, m, d = civil_from_days(day)
  return string.format("%s %s %d", WEEKDAYS[(day + 4) % 7 + 1], MONTHS[m], d)
end

---------------------------------------------------------------- state

UI = { status = "Fetching...", fetches = 0, sel = 1 }   -- global: tests read it
-- UI.state: "open", "pre" (before the day's opening) or "closed", once known;
-- UI.top: the price and the after-hours line at the top, as drawn

local quotes = {}           -- [symbol] = { price, t (its trade), close (the day's so far), day, prev (its close), prev_day }
local bars = {}             -- [symbol] = { { t (start), o, c }, ... } 5-minute bars of the chart's day
local chart_day             -- the ET day (days since 1970) on the chart
local bars_ms = 0           -- sys.millis() of the last bars fetch
local clock_t, clock_ms     -- UTC seconds at sys.millis() == clock_ms
local next_ms, last_ms = 0, -60000
local force, fetching = false, false

local function now()
  return sys.time() or (clock_t and clock_t + (sys.millis() - clock_ms) // 1000)
end

---------------------------------------------------------------- Alpaca

local HEADERS = { ["APCA-API-KEY-ID"] = KEY, ["APCA-API-SECRET-KEY"] = SECRET }

-- json.null is a table too: only real objects.
local function obj(v) return type(v) == "table" and v ~= json.null and v or nil end

local function api(path, q)
  q.feed = "iex"                                  -- the free plan's real-time prices
  local st, body, hdr = http.get(API .. path .. "?" .. http.form(q), HEADERS)
  if not st then
    print("stocks: " .. path .. ": " .. tostring(body))
    return nil, "No connection"
  end
  if not sys.time() then
    local t = http_date(hdr.date)
    if t then clock_t, clock_ms = t, sys.millis() end
  end
  if st == 200 then
    local ok, v = pcall(json.decode, body)
    if ok and obj(v) then return v end
    return nil, "Bad reply"
  end
  print("stocks: " .. path .. " " .. st .. " " .. body:sub(1, 200))
  if st == 401 or st == 403 then return nil, "Keys refused" end
  if st == 429 then return nil, "Too many requests" end
  return nil, "HTTP " .. st
end

-- The latest trade and the last two days of each symbol.
local function fetch_quotes()
  local r, err = api("stocks/snapshots", { symbols = table.concat(SYMBOLS, ",") })
  if not r then return nil, err end
  local any
  for _, s in ipairs(SYMBOLS) do
    local v = obj(r[s])
    local trade, daily, prev = v and obj(v.latestTrade), v and obj(v.dailyBar), v and obj(v.prevDailyBar)
    if trade and daily then
      quotes[s] = { price = trade.p, t = iso_time(trade.t), close = daily.c, day = iso_day(daily.t),
                    prev = prev and prev.c, prev_day = prev and iso_day(prev.t) }
      any = true
    else
      quotes[s] = nil
      print("stocks: no prices for " .. s)
    end
  end
  return any, not any and "No prices" or nil
end

-- What the market is doing, and the day the chart shows: today's session
-- once it has opened, else the last one.
local function market()
  local t, q = now(), nil
  for _, s in ipairs(SYMBOLS) do q = q or quotes[s] end
  if not (t and q) then return nil end
  local today = et_day(t)
  if q.day == today and t < at_et(today, OPEN) then return "pre", q.prev_day end
  if q.day == today and t < at_et(today, CLOSE) then return "open", q.day end
  return "closed", q.day
end

-- How long until the next fetch.
local function next_delay(state)
  if state == "open" then return LIVE_MS end
  local t = now()
  if not t then return IDLE_MS end
  local today = et_day(t)
  local wd = (today + 4) % 7                      -- 0 = Sunday
  if wd ~= 0 and wd ~= 6 then
    local open_at = at_et(today, OPEN)
    if t < open_at then return math.min(IDLE_MS, (open_at - t) * 1000 + 5000) end
    if t < at_et(today, CLOSE) then return 5 * 60 * 1000 end  -- no trades yet, or a holiday
  end
  return IDLE_MS
end

-- The 5-minute bars of a day's regular session, all symbols.
local function fetch_bars(day)
  local t = now()
  if not t then return nil, "No clock" end
  local q = { symbols = table.concat(SYMBOLS, ","), timeframe = "5Min", limit = 10000,
              start = iso(at_et(day, OPEN)), ["end"] = iso(math.min(at_et(day, CLOSE), t)) }
  local got = {}
  repeat
    local r, err = api("stocks/bars", q)
    if not r then return nil, err end
    for s, list in pairs(obj(r.bars) or {}) do
      local pts = got[s] or {}
      for _, b in ipairs(list) do pts[#pts + 1] = { t = iso_time(b.t), o = b.o, c = b.c } end
      got[s] = pts
    end
    q.page_token = type(r.next_page_token) == "string" and r.next_page_token or nil
  until not q.page_token
  return got
end

---------------------------------------------------------------- drawing

local function text_right(x, y, s, col, scale)
  disp.text(x - disp.text_width(s, scale), y, s, col, scale)
end

local function centered(x0, w, y, s, col, scale)
  disp.text(x0 + (w - disp.text_width(s, scale)) // 2, y, s, col, scale)
end

-- The price at the top: the latest trade, or once the market has closed,
-- the closing price (the chart's last).
local function shown(q) return UI.state == "closed" and q.close or q.price end

-- A trade after the close that differs from it, or nil.
local function after_hours(q)
  if UI.state == "closed" and q.t and q.t >= at_et(q.day, CLOSE) and math.abs(q.price - q.close) >= 0.005 then
    return q.price
  end
end

-- The price change from the previous close: amount, percent (nil without it).
local function change(q)
  if not (q and q.prev and q.prev ~= 0) then return nil end
  local p = shown(q)
  return p - q.prev, (p - q.prev) * 100 / q.prev
end

local function signed(v, fmt) return (v >= 0 and "+" or "-") .. string.format(fmt, math.abs(v)) end

-- The chart's points: the opening, each bar's close at its end and the
-- latest trade, all within the session.
local function chart_points(s)
  local pts, list, q = {}, bars[s], quotes[s]
  if not (list and #list > 0 and chart_day) then return pts end
  local close = at_et(chart_day, CLOSE)
  pts[1] = { t = list[1].t, v = list[1].o }
  for _, b in ipairs(list) do pts[#pts + 1] = { t = math.min(b.t + 300, close), v = b.c } end
  if q and q.t and q.t > pts[#pts].t and q.t < close and et_day(q.t) == chart_day then
    pts[#pts + 1] = { t = q.t, v = q.price }
  end
  return pts
end

local function nice_step(x)
  local p = 10 ^ math.floor(math.log(x, 10))
  for _, m in ipairs({ 1, 2, 2.5, 5 }) do
    if m * p >= x then return m * p end
  end
  return 10 * p
end

local drawn_minute

local function draw_top()
  local s, t = SYMBOLS[UI.sel], now()
  local q = quotes[s]
  disp.rect(0, 0, W, 62, BG, true)
  disp.text(10, 5, s, FG, 3)
  if NAMES[s] then disp.text(10, 31, NAMES[s], DIM, 1) end

  local line, col
  if UI.status ~= "ok" then line, col = UI.status, disp.ORANGE
  elseif UI.state == "open" then line, col = "Open " .. hhmm(t) .. " ET", UP
  elseif UI.state == "pre" then line, col = "Pre-market " .. hhmm(t) .. " ET", DIM
  elseif UI.state == "closed" and chart_day then line, col = "Closed, " .. day_name(chart_day), DIM
  end
  if line then disp.text(10, 51, line, col, 1) end
  drawn_minute = t and t // 60

  UI.top = nil
  if not q then return end
  UI.top = { price = string.format("%.2f", shown(q)) }
  text_right(312, 4, UI.top.price, FG, 3)
  local d, pct = change(q)
  if d then
    text_right(312, 30, signed(d, "%.2f") .. " " .. signed(pct, "%.2f") .. "%", d >= 0 and UP or DOWN, 2)
  end
  local ah = after_hours(q)
  if ah then
    local p = (ah - q.close) * 100 / q.close
    UI.top.after = string.format("After hours %.2f %s%%", ah, signed(p, "%.2f"))
    text_right(312, 51, UI.top.after, DIM, 1)
  end
end

local function draw_chart()
  disp.rect(0, 62, W, TY - 62, BG, true)
  local s = SYMBOLS[UI.sel]
  local pts = chart_points(s)
  if #pts < 2 then
    disp.text(CX0 + 10, 110, UI.status == "ok" and "No trades on IEX yet" or UI.status, DIM, 1)
    return
  end
  -- Against the previous close, except before the opening: then it's the
  -- close before the chart's day, unknown here, and the chart's own opening.
  local q = quotes[s]
  local ref = UI.state ~= "pre" and q and q.prev or nil
  local base = ref or pts[1].v

  local lo, hi = base, base
  for _, p in ipairs(pts) do lo, hi = math.min(lo, p.v), math.max(hi, p.v) end
  if hi - lo < 0.02 then lo, hi = lo - 0.01, hi + 0.01 end
  local pad = (hi - lo) * 0.08
  lo, hi = lo - pad, hi + pad
  local function y_of(v) return CY1 - math.floor((v - lo) * (CY1 - CY0) / (hi - lo) + 0.5) end
  local d0, d1 = at_et(chart_day, OPEN), at_et(chart_day, CLOSE)
  local function x_of(t) return CX0 + (t - d0) * (CX1 - CX0) // (d1 - d0) end

  local step = nice_step((hi - lo) / 4)          -- price grid, labels on the right
  local function whole(v) return math.abs(v - math.floor(v + 0.5)) < 1e-6 end
  local fmt = whole(step) and "%.0f" or whole(step * 10) and "%.1f" or "%.2f"
  for k = math.ceil(lo / step), math.floor(hi / step) do
    local y = y_of(k * step)
    disp.line(CX0, y, CX1, y, GRID)
    disp.text(CX1 + 6, y - 3, string.format(fmt, k * step), DIMMER, 1)
  end
  for h = 10, 16 do                               -- hours, New York time
    local x = x_of(at_et(chart_day, h * 60))
    disp.line(x, CY1 + 1, x, CY1 + 3, DIMMER)
    centered(x - 10, 20, CY1 + 7, tostring(h), DIMMER, 1)
  end

  -- The area between the price and the base: green above, red below.
  local by = y_of(base)
  local seg = 1
  for x = x_of(pts[1].t), x_of(pts[#pts].t) do
    local t = d0 + (x - CX0) * (d1 - d0) / (CX1 - CX0)
    while seg < #pts - 1 and pts[seg + 1].t < t do seg = seg + 1 end
    local a, b = pts[seg], pts[seg + 1]
    local f = b.t > a.t and math.max(0, math.min(1, (t - a.t) / (b.t - a.t))) or 1
    local y = y_of(a.v + (b.v - a.v) * f)
    if y < by then disp.line(x, y, x, by - 1, UP_FILL)
    elseif y > by then disp.line(x, by + 1, x, y, DOWN_FILL) end
  end
  if ref then                                     -- the previous close, dashed
    for x = CX0, CX1, 6 do disp.line(x, by, math.min(x + 2, CX1), by, DIM) end
  end
  for i = 1, #pts - 1 do                          -- the price, 2 px thick
    local a, b = pts[i], pts[i + 1]
    local col = b.v >= base and UP or DOWN
    local xa, ya, xb, yb = x_of(a.t), y_of(a.v), x_of(b.t), y_of(b.v)
    disp.line(xa, ya, xb, yb, col)
    disp.line(xa, ya - 1, xb, yb - 1, col)
  end
  if UI.state == "open" then                      -- now
    local p = pts[#pts]
    disp.circle(x_of(p.t), y_of(p.v), 3, FG, true)
  end
end

local function draw_tiles()
  disp.rect(0, TY, W, H - TY, BG, true)
  local tw = W // #SYMBOLS
  for i, s in ipairs(SYMBOLS) do
    local x, sel = (i - 1) * tw, i == UI.sel
    disp.rect(x + 2, TY, tw - 4, H - TY - 2, sel and TILE_SEL or TILE, true)
    if sel then disp.rect(x + 2, TY, tw - 4, H - TY - 2, ACCENT) end
    centered(x, tw, TY + 5, s, FG, 2)
    local q = quotes[s]
    local _, pct = change(q)
    if pct then
      local p = signed(pct, "%.1f") .. "%"
      local scale = disp.text_width(p, 2) <= tw - 16 and 2 or 1
      centered(x, tw, TY + 24, p, pct >= 0 and UP or DOWN, scale)
    end
    if q then centered(x, tw, TY + 43, string.format("%.2f", shown(q)), DIM, 1) end
  end
end

local function draw()
  draw_top()
  draw_chart()
  draw_tiles()
end

local function draw_setup()
  disp.clear(BG)
  disp.text(10, 10, "Stocks", FG, 3)
  local lines = {                          -- 51 characters fit from x 10
    { "This app needs your own free Alpaca keys", FG },
    { "(alpaca.markets, Home > API Keys).", DIM },
    { "", DIM },
    { "Give them to it from a computer:", DIM },
    { "luaboard secrets set stocks alpaca_key <key>", FG },
    { "luaboard secrets set stocks alpaca_secret <secret>", FG },
    { "then open the app again.", DIM },
    { "", DIM },
    { "Steps: github.com/veikkos/luaboard-marketplace", DIM },
  }
  for i, l in ipairs(lines) do disp.text(10, 50 + (i - 1) * 16, l[1], l[2], 1) end
end

---------------------------------------------------------------- main

local function fetch()
  fetching, last_ms = true, sys.millis()
  local ok, err = fetch_quotes()
  if ok then
    local state, day = market()
    UI.state = state
    if day and (day ~= chart_day or force or (state == "open" and sys.millis() - bars_ms >= BARS_MS)) then
      local got
      got, err = fetch_bars(day)
      if got then bars, chart_day, bars_ms = got, day, sys.millis() end
    end
  end
  UI.status = err or "ok"
  UI.fetches = UI.fetches + 1
  force, fetching = false, false
  next_ms = sys.millis() + (err and RETRY_MS or next_delay(UI.state))
  draw()
end

if not (KEY and KEY ~= "" and SECRET and SECRET ~= "") then
  draw_setup()
  print("stocks: no keys: luaboard secrets set stocks alpaca_key <key> (and alpaca_secret)")
  return
end

disp.keep_awake(true)

local function pick(i)
  UI.sel = (i - 1) % #SYMBOLS + 1
  draw()
end

touch.on("press", function(b)
  if b == "A" then pick(UI.sel - 1)
  elseif b == "C" then pick(UI.sel + 1)
  elseif b == "B" and not fetching and sys.millis() - last_ms >= 5000 then force = true end
end)

touch.on("tap", function(x, y)
  if y >= TY then pick(math.min(x // (W // #SYMBOLS) + 1, #SYMBOLS)) end
end)

timer.every(1000, function()                      -- the clock in the status line
  local t = now()
  if t and t // 60 ~= drawn_minute then draw_top() end
end)

draw()
task(function()
  while true do
    if force or sys.millis() >= next_ms then fetch() end
    sleep(250)
  end
end)
