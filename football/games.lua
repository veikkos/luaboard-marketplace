-- games: football-data.org's matches as the app shows them. Pure: no
-- drawing, no network.
--
--   games.config(leagues, teams) -> cfg        from the secrets
--   games.query(cfg, now, tz) -> path         yesterday to tomorrow
--   games.next_query(cfg, now, tz) -> path    the next week
--   games.parse(text, cfg) -> list or nil, "bad answer"
--   games.sort(list, now, tz)                 in place, sets g.group
--   games.status(g, now, tz) -> text, "live" | "dim" | "done"
--   games.next_delay(list, now) -> ms         when to ask again
--   games.fav(team, cfg) -> bool
--   games.cut(s, n) -> s                      at most n characters, "." when cut

local json = require("json")

local M = {}

local LIVE_MS, SOON_MS, IDLE_MS = 30000, 60000, 900000
local SOON_S = 10 * 60                    -- from this long before a kickoff, ask every minute

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

local function split(s)
  local t = {}
  for part in (s or ""):gmatch("[^,]+") do
    part = trim(part)
    if part ~= "" then t[#t + 1] = part end
  end
  return t
end

function M.config(leagues, teams)
  local l = split(leagues)
  for i, c in ipairs(l) do l[i] = c:upper() end
  local t = split(teams)
  for i, n in ipairs(t) do t[i] = n:lower() end
  return { leagues = #l > 0 and l or nil, teams = t }
end

local function day(t, tz)                 -- "YYYY-MM-DD" of a time in tz
  local d = sys.date(t, tz)
  return string.format("%04d-%02d-%02d", d.year, d.month, d.day)
end

local function window(cfg, from, to)
  local q = "matches?dateFrom=" .. from .. "&dateTo=" .. to
  if cfg.leagues then q = q .. "&competitions=" .. table.concat(cfg.leagues, ",") end
  return q
end

function M.query(cfg, now, tz)
  return window(cfg, day(now - 86400, tz), day(now + 86400, tz))
end

function M.next_query(cfg, now, tz)
  return window(cfg, day(now, tz), day(now + 7 * 86400, tz))
end

function M.fav(team, cfg)
  for _, part in ipairs(cfg.teams) do
    for _, s in ipairs({ team.name, team.short, team.tla }) do
      if s and s:lower():find(part, 1, true) then return true end
    end
  end
  return false
end

local function num(v) return type(v) == "number" and v or nil end

local function team(t)
  t = type(t) == "table" and t or {}
  local name = type(t.name) == "string" and t.name or nil
  local short = type(t.shortName) == "string" and t.shortName ~= "" and t.shortName or nil
  local tla = type(t.tla) == "string" and t.tla ~= "" and t.tla or nil
  return {
    id = num(t.id),
    name = name or short or tla or "?",
    short = short or name or tla or "?",
    tla = tla or (short or name or "?"):sub(1, 3):upper(),
    crest = type(t.crest) == "string" and t.crest or nil,
  }
end

local function pair(p)
  p = type(p) == "table" and p or {}
  return { h = num(p.home), a = num(p.away) }
end

function M.parse(text, cfg)
  local ok, d = pcall(json.decode, text)
  if not ok or type(d) ~= "table" or type(d.matches) ~= "table" then return nil, "bad answer" end
  local list = {}
  for _, x in ipairs(d.matches) do
    local utc = type(x.utcDate) == "string" and sys.time(x.utcDate) or nil
    if utc then
      local score = type(x.score) == "table" and x.score or {}
      local comp = type(x.competition) == "table" and x.competition or {}
      local g = {
        id = num(x.id), utc = utc, status = tostring(x.status or ""), minute = num(x.minute),
        comp = type(comp.code) == "string" and comp.code or "",
        comp_name = type(comp.name) == "string" and comp.name or nil,
        matchday = num(x.matchday),
        home = team(x.homeTeam), away = team(x.awayTeam),
        ft = pair(score.fullTime), ht = pair(score.halfTime),
      }
      -- fullTime counts a shootout's goals: the score is without them, the
      -- shootout on its own.
      local pens = pair(score.penalties)
      if pens.h and pens.a then
        g.pens = pens
        if g.ft.h and g.ft.a then g.ft = { h = g.ft.h - pens.h, a = g.ft.a - pens.a } end
      end
      g.fav = M.fav(g.home, cfg) or M.fav(g.away, cfg)
      list[#list + 1] = g
    end
  end
  return list
end

local LIVE = { IN_PLAY = true, PAUSED = true, LIVE = true, EXTRA_TIME = true, PENALTY_SHOOTOUT = true }
local function is_live(g) return LIVE[g.status] == true end
local function is_upcoming(g) return g.status == "TIMED" or g.status == "SCHEDULED" end

-- 1 in progress, 2 still to come today, 3 the rest of today, 4 before today, 5 after today.
local function group(g, today, tz)
  if is_live(g) then return 1 end
  local d = day(g.utc, tz)
  if d < today then return 4 end
  if d > today then return 5 end
  return is_upcoming(g) and 2 or 3
end

function M.sort(list, now, tz)
  local today = day(now, tz)
  for _, g in ipairs(list) do g.group = group(g, today, tz) end
  table.sort(list, function(a, b)
    if a.group ~= b.group then return a.group < b.group end
    if a.fav ~= b.fav then return a.fav end
    if a.utc ~= b.utc then
      if a.group == 4 then return a.utc > b.utc end      -- latest results first
      return a.utc < b.utc
    end
    if a.comp ~= b.comp then return a.comp < b.comp end
    return (a.id or 0) < (b.id or 0)
  end)
end

local SHORT = { FINISHED = "FT", AWARDED = "AWD", POSTPONED = "PST", SUSPENDED = "SUS", CANCELLED = "CAN" }

function M.status(g, now, tz)
  if g.status == "PAUSED" then return "HT", "live" end
  if g.status == "EXTRA_TIME" then return "ET", "live" end
  if g.status == "PENALTY_SHOOTOUT" then return "PEN", "live" end
  if is_live(g) then
    if g.minute then return g.minute .. "'", "live" end
    -- Not given: estimated from the kickoff, about 17 minutes of break and
    -- stoppage between the halves.
    local e = (now - g.utc) // 60
    if e <= 45 then return "~" .. math.max(1, e) .. "'", "live" end
    local m = math.max(46, e - 17)
    if m >= 90 then return "90+'", "live" end
    return "~" .. m .. "'", "live"
  end
  if g.status == "FINISHED" and g.pens then return "PEN", "done" end
  if g.status == "FINISHED" or g.status == "AWARDED" then return SHORT[g.status], "done" end
  if SHORT[g.status] then return SHORT[g.status], "dim" end
  local d = sys.date(g.utc, tz)
  return string.format("%02d:%02d", d.hour, d.min), "dim"
end

function M.next_delay(list, now)
  local next_kick
  for _, g in ipairs(list) do
    if is_live(g) then return LIVE_MS end
    if is_upcoming(g) and (not next_kick or g.utc < next_kick) then next_kick = g.utc end
  end
  if next_kick and next_kick - now <= SOON_S then return SOON_MS end
  if next_kick then return math.min(IDLE_MS, (next_kick - SOON_S - now) * 1000) end
  return IDLE_MS
end

function M.cut(s, n)
  if not utf8.len(s) then s = s:gsub("[\128-\255]", "?") end   -- not UTF-8: no surprises
  local chars = {}
  for _, c in utf8.codes(s) do chars[#chars + 1] = utf8.char(c) end
  if #chars <= n then return s end
  return table.concat(chars, "", 1, n - 1) .. "."
end

return M
