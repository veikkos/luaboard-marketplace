-- agenda.lua: the calendar app's logic without drawing or network: times,
-- which events count, what the screen shows, which alert is due.
-- Times are UTC seconds; local time comes from the device's time zone.
local M = {}

local MIN, HOUR = 60, 3600

---------------------------------------------------------------- time

-- RFC 3339 ("2026-11-06T17:30:00+02:00", "...Z", "...00.250Z") -> UTC seconds.
-- nil for a date without a time (all-day events) or anything else.
function M.parse_time(s)
  if type(s) ~= "string" or not s:find("T", 1, true) then return nil end
  return (sys.time(s))
end

-- Local midnight (UTC seconds) of the day of t, plus `days` days.
function M.day_start(t, days)
  local d = sys.date(t)
  return sys.time({ year = d.year, month = d.month, day = d.day + (days or 0) })
end

function M.hhmm(t)
  local d = sys.date(t)
  return string.format("%02d:%02d", d.hour, d.min)
end

local WEEKDAYS = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }
function M.day_name(t)
  local d = sys.date(t)
  return string.format("%s %d.%d.", WEEKDAYS[d.wday], d.day, d.month)
end

-- "in 18 min", "in 1 h 20 min", "in 2 h"; minutes rounded up. "now" once t has come.
function M.until_text(now, t)
  if t <= now then return "now" end
  local m = math.max(1, (t - now + 59) // 60)
  if m < 60 then return "in " .. m .. " min" end
  local h, r = m // 60, m % 60
  return r == 0 and ("in " .. h .. " h") or ("in " .. h .. " h " .. r .. " min")
end

---------------------------------------------------------------- text

-- At most max_chars characters (UTF-8); a cut text ends with "..".
function M.fit(s, max_chars)
  local n = utf8.len(s)
  if (n or #s) <= max_chars then return s end
  local head = n and s:sub(1, utf8.offset(s, max_chars - 1) - 1) or s:sub(1, max_chars - 2)
  return (head:gsub("%s+$", "")) .. ".."
end

---------------------------------------------------------------- events

local function declined(item)
  for _, a in ipairs(type(item.attendees) == "table" and item.attendees or {}) do
    if a.self == true and a.responseStatus == "declined" then return true end
  end
  return false
end

local function popup_minutes(list)
  local out = {}
  for _, r in ipairs(type(list) == "table" and list or {}) do
    if r.method == "popup" and tonumber(r.minutes) then out[#out + 1] = math.tointeger(r.minutes) or r.minutes end
  end
  return out
end

-- Google events.list items -> { id, title, start, stop, reminders = { minutes } }.
-- Skips cancelled, all-day, "free" and declined events.
function M.normalize(items, cal_id, default_minutes)
  local out = {}
  for _, it in ipairs(type(items) == "table" and items or {}) do
    local s = type(it.start) == "table" and M.parse_time(it.start.dateTime)
    local e = type(it["end"]) == "table" and M.parse_time(it["end"].dateTime)
    if s and e and it.status ~= "cancelled" and it.transparency ~= "transparent" and not declined(it) then
      local r = type(it.reminders) == "table" and it.reminders or { useDefault = true }
      local rem
      if r.useDefault == true then
        rem = {}
        for i, m in ipairs(default_minutes or {}) do rem[i] = m end
      else
        rem = popup_minutes(r.overrides)
      end
      local title = type(it.summary) == "string" and it.summary ~= "" and it.summary or "(no title)"
      out[#out + 1] = { id = cal_id .. "/" .. tostring(it.id), title = title, start = s, stop = e, reminders = rem }
    end
  end
  return out
end

-- Several lists of events -> one, by start time (then title).
function M.merge(lists)
  local out = {}
  for _, l in ipairs(lists) do
    for _, e in ipairs(l) do out[#out + 1] = e end
  end
  table.sort(out, function(a, b)
    if a.start ~= b.start then return a.start < b.start end
    return a.title < b.title
  end)
  return out
end

---------------------------------------------------------------- views

-- What the screen shows for `page` (0 = today, 1 = tomorrow):
-- { main = { kind, event, label }, list = { events }, list_label }
function M.view(events, now, page)
  local s1, s2 = M.day_start(now, 1), M.day_start(now, 2)
  local main, list, list_label = nil, {}, nil
  if page == 1 then
    for _, e in ipairs(events) do
      if e.start >= s1 and e.start < s2 then
        if not main then main = { kind = "first", event = e, label = "tomorrow - " .. M.hhmm(e.start) }
        else list[#list + 1] = e end
      end
    end
    return { main = main or { kind = "none", label = "nothing tomorrow" }, list = list }
  end

  for _, e in ipairs(events) do               -- in progress: the one that started last
    if e.start <= now and now < e.stop and (not main or e.start >= main.event.start) then
      main = { kind = "now", event = e, label = "now - until " .. M.hhmm(e.stop) }
    end
  end
  if not main then
    for _, e in ipairs(events) do
      if e.start > now and e.start < s1 then
        main = { kind = "next", event = e, label = "next - " .. M.until_text(now, e.start) }
        break
      end
    end
  end
  if main then
    for _, e in ipairs(events) do
      if e ~= main.event and e.stop > now and e.start < s1 then list[#list + 1] = e end
    end
  else
    main = { kind = "none", label = "nothing more today" }
    for _, e in ipairs(events) do
      if e.start >= s1 and e.start < s2 then list[#list + 1] = e end
    end
    list_label = "tomorrow"
  end
  return { main = main, list = list, list_label = list_label }
end

---------------------------------------------------------------- alerts

M.AT_START_S = 5 * MIN       -- how long an "at time of event" (0 min) reminder stays up

-- The alert to show now, or nil: { key, event, minutes }. Per event the
-- active reminder is the smallest one whose time has come, until the meeting
-- starts (a 0 min reminder: for AT_START_S after). dismissed = { [key] = the
-- event's start when it was dismissed }: a moved meeting alerts again. The
-- meeting that starts first wins.
function M.alert_due(events, now, dismissed)
  local best
  for _, e in ipairs(events) do
    local m
    for _, r in ipairs(e.reminders or {}) do
      local live = now < e.start or (r == 0 and now < e.start + M.AT_START_S)
      if live and now >= e.start - r * 60 and (not m or r < m) then m = r end
    end
    if m then
      local key = e.id .. "@" .. m
      if not (dismissed and dismissed[key] == e.start) and (not best or e.start < best.event.start) then
        best = { key = key, event = e, minutes = m }
      end
    end
  end
  return best
end

-- Seconds to wait before the next fetch after `failures` failed ones in a row:
-- a network failure (30 s doubling up to 5 min) or a login nobody did
-- (15 min doubling up to 4 h, so an unattended studio doesn't fill with tabs).
function M.retry_delay(failures) return math.min(300, 30 * 2 ^ (failures - 1) // 1 | 0) end
function M.login_retry_delay(failures) return math.min(4 * HOUR, 900 * 2 ^ (failures - 1) // 1 | 0) end

return M
