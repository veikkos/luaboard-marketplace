-- gcal: the next meetings from Google Calendar. Setup in README.md.
--
-- Alerts follow the events' popup reminders: a chime, and the top of the
-- screen pulses red until B or a tap dismisses it, or the meeting starts.
-- A = today, C = tomorrow, B = dismiss the alert, else the calendar picker
-- (A/C move, B ticks, "Done" saves).

local gcal, agenda, json = require("gcal"), require("agenda"), require("json")

local CLIENT_ID = secrets.get("gcal_client")
local CLIENT_SECRET = secrets.get("gcal_secret")
if CLIENT_ID == "" then CLIENT_ID = nil end

local DIM, MID, HI, LINE = 0x5a5a5a, 0x8a8a8a, 0xd8d8d8, 0x1c1c1c
local BANNER, BANNER_DARK, WHITE = 0xff3b30, 0x5a0f0b, 0xffffff
local BANNER_H = 120
local REFRESH_MS = 5 * 60 * 1000
local LOGIN_RETRY_MS = 15 * 60 * 1000
local PAGE_BACK_MS = 60 * 1000

-- What the screen shows. UI, cal and refresh() are globals for tests and the console.
UI = { mode = "calm", main = "", title = nil, status = "", alert = nil, fetches = 0, cursor = 1, logins = 0 }

local events = {}                 -- merged, agenda.normalize()d
local fetched_at                  -- UTC time of the last good fetch
local fetch_err                   -- message of the last failed fetch, or nil
local logging_in = false          -- the studio is showing our login right now
local login_failed = false        -- a login was asked for and nobody did it
local notice                      -- a one-off problem to show in the status line
local want_fetch = true
local page, last_input = 0, sys.millis()
local drawn_key, drawn_phase
local alert                       -- agenda.alert_due() result showing now, or nil

-- Dismissed alerts, kept across restarts: { [key] = event start }.
local dismissed = {}
do
  local ok, t = pcall(json.decode, secrets.get("gcal_dismissed") or "{}")
  if ok and type(t) == "table" then
    for k, v in pairs(t) do if type(k) == "string" then dismissed[k] = tonumber(v) or 0 end end
  end
end

local function dismiss()
  if not alert then return end
  dismissed[alert.key] = alert.event.start
  local now, keep = sys.time() or 0, {}
  for k, start in pairs(dismissed) do
    if start >= now then keep[k] = start end       -- past meetings can't alert again
  end
  dismissed = keep
  if not pcall(secrets.set, "gcal_dismissed", next(keep) and json.encode(keep) or nil) then
    pcall(secrets.set, "gcal_dismissed", json.encode({ [alert.key] = alert.event.start }))   -- too big: this one
  end
  alert, UI.alert = nil, nil
end

cal = gcal.new{
  client_id = CLIENT_ID or "missing", client_secret = CLIENT_SECRET,
  on_login = function(waiting)
    logging_in = waiting
    if waiting then UI.logins = UI.logins + 1 end
  end,
}

-- Ask the fetch task to fetch now.
function refresh() want_fetch = true end

---------------------------------------------------------------- data

-- The calendars to show: the ones in the secret gcal_calendars (a JSON list
-- of ids) that still exist, else the primary one.
local function chosen(cals)
  local ok, ids = pcall(json.decode, secrets.get("gcal_calendars") or "[]")
  local want = {}
  for _, id in ipairs(ok and type(ids) == "table" and ids or {}) do want[id] = true end
  local out = {}
  for _, c in ipairs(cals) do if want[c.id] then out[#out + 1] = c end end
  if #out == 0 then
    for _, c in ipairs(cals) do if c.primary then out[#out + 1] = c end end
  end
  return out
end

local function fetch()
  local cals, err = cal:calendars()
  if not cals then return nil, err end
  local now, lists = sys.time(), {}
  for _, c in ipairs(chosen(cals)) do
    local evs, e = cal:events(c, agenda.day_start(now, 0), agenda.day_start(now, 2))
    if not evs then return nil, e end
    lists[#lists + 1] = evs
  end
  events, fetched_at = agenda.merge(lists), now
  UI.calendars = cals
  UI.fetches = UI.fetches + 1
  return true
end

task(function()
  local next_at, failures, login_failures = 0, 0, 0
  while true do
    if CLIENT_ID and sys.time() and (want_fetch or sys.millis() >= next_at) then
      want_fetch = false
      local logins = UI.logins
      local ok, err = fetch()
      if ok then
        login_failed, fetch_err, failures, login_failures = false, nil, 0, 0
        next_at = sys.millis() + REFRESH_MS
      else
        fetch_err = err
        print("gcal: " .. tostring(err))
        if UI.logins > logins and not cal:logged_in() then
          -- asked for a login and nobody came: wait longer each time (o retries now)
          login_failed, login_failures = true, login_failures + 1
          next_at = sys.millis() + agenda.login_retry_delay(login_failures) * 1000
        else
          failures = failures + 1                    -- network: soon, then less often
          next_at = sys.millis() + agenda.retry_delay(failures) * 1000
        end
      end
    end
    sleep(200)
  end
end)

---------------------------------------------------------------- drawing

local function status_text()
  if not CLIENT_ID then return "set gcal_client, gcal_secret: luaboard secrets set" end
  if not sys.time() then
    local wifi = net.wifi()
    if wifi == "off" then return "no Wi-Fi: set it up in luaboard studio (Wi-Fi...)" end
    if wifi == "connecting" then return "connecting to Wi-Fi..." end
    return "waiting for the clock..."
  end
  if logging_in then return "log in from luaboard studio or run luaboard browser" end
  if login_failed then return "not logged in - press o to log in" end
  if notice then return notice end
  if fetch_err then
    return fetched_at and ("offline - data from " .. agenda.hhmm(fetched_at)) or agenda.fit("error: " .. fetch_err, 52)
  end
  return ""
end

local function text_right(x, y, s, color, scale)
  disp.text(x - disp.text_width(s, scale), y, s, color, scale)
end

local function text_center(y, s, color, scale)
  disp.text(160 - disp.text_width(s, scale) // 2, y, s, color, scale)
end

local function draw_buttons(a, b, c)
  disp.text(8, 230, a, DIM)
  text_center(230, b, DIM)
  text_right(312, 230, c, DIM)
end

-- The calm view from the top down to the list; returns nothing.
local function draw_calm(now)
  local day = agenda.day_start(now, page) + 12 * 3600
  disp.text(8, 8, agenda.day_name(day), DIM, 2)
  text_right(312, 8, agenda.hhmm(now), MID, 2)
  if not fetched_at then
    UI.main, UI.title = "Google Calendar", nil
    disp.text(8, 44, UI.main, DIM, 2)
    return
  end
  local v = agenda.view(events, now, page)
  UI.main, UI.title = v.main.label, v.main.event and v.main.event.title
  disp.text(8, 44, v.main.label, DIM, 2)
  local y = 70
  if v.main.event then
    local e = v.main.event
    disp.text(8, 66, agenda.fit(e.title, 17), HI, 3)
    disp.text(8, 94, agenda.hhmm(e.start) .. "-" .. agenda.hhmm(e.stop), MID, 2)
    y = 118
  end
  disp.line(8, y, 312, y, LINE)
  y = y + 8
  if v.list_label then
    disp.text(8, y, v.list_label, DIM)
    y = y + 12
  end
  for i, e in ipairs(v.list) do
    if y > 196 then break end
    disp.text(8, y, agenda.hhmm(e.start) .. " " .. agenda.fit(e.title, 20), DIM, 2)
    y = y + 20
  end
end

-- The calendar picker: ticked calendars and a "Done" row.
local picks = {}                  -- calendar id -> ticked, while the picker is open

local function open_picker()
  if not UI.calendars then return end            -- not fetched yet: nothing to pick
  picks, notice = {}, nil
  for _, c in ipairs(chosen(UI.calendars)) do picks[c.id] = true end
  UI.mode, UI.cursor = "picker", 1
end

local function picker_press(b)
  local n = #UI.calendars + 1                     -- the last row is "Done"
  if b == "A" then UI.cursor = (UI.cursor - 2) % n + 1
  elseif b == "C" then UI.cursor = UI.cursor % n + 1
  elseif UI.cursor < n then
    local id = UI.calendars[UI.cursor].id
    picks[id] = not picks[id] or nil
  else
    local ids = {}
    for _, c in ipairs(UI.calendars) do if picks[c.id] then ids[#ids + 1] = c.id end end
    -- none ticked: the primary one. A secret holds 2 KB, about 25 calendars.
    if not pcall(secrets.set, "gcal_calendars", #ids > 0 and json.encode(ids) or nil) then
      notice = "too many calendars to save, untick some"
    end
    UI.mode = "calm"
    refresh()
  end
end

local function picker_key()
  local t = { UI.cursor }
  for _, c in ipairs(UI.calendars or {}) do t[#t + 1] = picks[c.id] and "x" or "-" end
  return table.concat(t)
end

local function draw_picker()
  disp.clear()
  disp.text(8, 8, "Calendars", DIM, 2)
  local rows = {}
  for _, c in ipairs(UI.calendars) do rows[#rows + 1] = (picks[c.id] and "[x] " or "[ ] ") .. agenda.fit(c.name, 20) end
  rows[#rows + 1] = "Done"
  local first = math.max(1, UI.cursor - 6)        -- 7 rows fit
  for i = first, math.min(#rows, first + 6) do
    local y = 36 + (i - first) * 24
    if i == UI.cursor then disp.rect(4, y - 4, 312, 22, 0x2a2a2a, true) end
    disp.text(8, y, rows[i], i == UI.cursor and HI or MID, 2)
  end
  draw_buttons("<< up", "o tick", "down >>")
end

-- The alert banner over the top of the screen; phase 0/1 = bright/dark.
local function draw_banner(now, phase)
  disp.rect(0, 0, 320, BANNER_H, phase == 0 and BANNER or BANNER_DARK, true)
  local e = alert.event
  disp.text(12, 16, agenda.until_text(now, e.start) .. " - " .. agenda.hhmm(e.start), WHITE, 2)
  disp.text(12, 48, agenda.fit(e.title, 16), WHITE, 3)
  disp.text(12, 84, agenda.hhmm(e.start) .. "-" .. agenda.hhmm(e.stop), WHITE, 2)
end

local function phase() return sys.millis() // 500 % 2 end

-- No client ID or secret yet: how to give them, instead of an empty agenda.
local function draw_setup()
  disp.clear()
  disp.text(8, 12, "Google Calendar", HI, 2)
  local lines = {                          -- 52 characters fit from x 8
    { "It needs your own Google Cloud client: the README", MID },
    { "says how to make one. Then, from a computer:", MID },
    { "", MID },
    { "luaboard secrets set gcal gcal_client <id>", HI },
    { "luaboard secrets set gcal gcal_secret <secret>", HI },
    { "", MID },
    { "then open the app again and log in from the", MID },
    { "studio (or luaboard browser).", MID },
    { "", MID },
    { "Steps: github.com/veikkos/luaboard-marketplace", MID },
  }
  for i, l in ipairs(lines) do disp.text(8, 50 + (i - 1) * 16, l[1], l[2], 1) end
end

local function draw(now)
  if UI.mode == "picker" then return draw_picker() end
  if not CLIENT_ID or not CLIENT_SECRET or CLIENT_SECRET == "" then UI.status = status_text(); return draw_setup() end
  disp.clear()
  UI.status = status_text()
  if now then draw_calm(now) else UI.main, UI.title = "Google Calendar", nil; disp.text(8, 44, UI.main, DIM, 2) end
  disp.text(8, 216, UI.status, DIM)
  if alert then
    draw_banner(now, phase())
    draw_buttons("", "o dismiss", "")
  else
    draw_buttons(page == 1 and "<< today" or "", UI.calendars and "o calendars" or "", page == 0 and "tomorrow >>" or "")
  end
end

-- A new alert chimes once: three notes going up, not too loud.
local function chime()
  for _, hz in ipairs({ 659, 784, 1047 }) do
    sound.tone(hz, 140, 70)
    sound.tone(0, 30)
  end
end

-- Redraw when anything visible changed (the minute, the page, the data, the
-- status, the alert); while an alert shows, the banner pulses on its own.
timer.every(100, function()
  local now = sys.time()
  if page ~= 0 and sys.millis() - last_input > PAGE_BACK_MS then page = 0 end
  local a = now and fetched_at and agenda.alert_due(events, now, dismissed) or nil
  if a and (not alert or a.key ~= alert.key) then page, UI.mode = 0, "calm"; chime() end   -- a new alert: back to today
  alert, UI.alert = a, a and a.key
  local key = table.concat({ now and now // 60 or "-", page, UI.fetches, status_text(), alert and alert.key or "",
                            UI.mode, UI.mode == "picker" and picker_key() or "" }, "|")
  if key ~= drawn_key then
    drawn_key, drawn_phase = key, phase()
    draw(now)
  elseif alert and phase() ~= drawn_phase then
    drawn_phase = phase()
    draw_banner(now, drawn_phase)
  end
end)

---------------------------------------------------------------- input

local function button(b)
  last_input = sys.millis()
  if alert then
    if b == "B" then dismiss() end
  elseif UI.mode == "picker" then picker_press(b)
  elseif b == "A" then page = 0 elseif b == "C" then page = 1
  elseif b == "B" then
    if login_failed and not logging_in then login_failed = false; refresh() else open_picker() end
  end
end
touch.on("press", button)
touch.on("long", button)                       -- a slow press of A or C counts too

touch.on("tap", function() dismiss() end)      -- a tap on the screen dismisses too
touch.on("hold", function() dismiss() end)

draw(sys.time())
