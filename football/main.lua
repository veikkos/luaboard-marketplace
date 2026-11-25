-- football: live scores, today's games and the latest results from
-- football-data.org, for the leagues and teams set in the secrets. Games in
-- progress first, your teams first in each group. Asks every 30 s while a
-- game is on, every minute before a kickoff, every 15 minutes otherwise.
-- A / C = previous / next game, B = refresh now. Needs Wi-Fi and your own
-- football-data.org key in the secret `key`.

local games, pics, web = require("games"), require("pics"), require("web")

local API = "https://api.football-data.org/v4/"
local RETRY_MS = 60 * 1000
local IDLE_MS = 60 * 1000              -- untouched this long: back to the top

local W, H = disp.W, disp.H
local BG, FG = disp.rgb(10, 14, 20), disp.WHITE
local DIM, DIMMER = disp.rgb(140, 150, 165), disp.rgb(70, 80, 95)
local GRID, HDR = disp.rgb(32, 40, 52), disp.rgb(20, 26, 38)
local ACCENT, LIVE = disp.rgb(255, 176, 32), disp.rgb(46, 204, 113)
local BADGE = disp.rgb(40, 52, 70)
local COLOR = { live = LIVE, dim = DIM, done = DIM }

local TOP = 14
local VIEW_H = H - TOP
local ROW_H = 36
local CREST = 20

local KEY = secrets.get("key")
local CFG = games.config(secrets.get("leagues"), secrets.get("teams"))
local TZ = sys.timezone()

UI = {
  status = "loading",                  -- "loading", "ok" or what went wrong
  fetches = 0,
  games = {},
  next = nil,                          -- the next week's first games, when today has none
  view = "list",
  scroll = 0,
  upd = nil,                           -- when the scores last came (UTC seconds)
  crests = {},                         -- team id -> 20 px pixels, or false when it has none
  crests64 = {},                       -- the same at 64 px, for the detail
  venues = {},                         -- match id -> venue, or false when it has none
}

---------------------------------------------------------------- helpers

local function now() return sys.time() end

local cut = games.cut

local function score(g)
  if g.ft.h and g.ft.a then return g.ft.h .. "-" .. g.ft.a end
  return "-"
end

local function shown() return #UI.games > 0 and UI.games or (UI.next or {}) end

---------------------------------------------------------------- header

local function draw_header()
  disp.rect(0, 0, W, TOP, HDR, true)
  disp.text(4, 3, "Football", DIM)
  local right = W - 4
  local t = now()
  if t then right = right - disp.text(right, 3, sys.date("%H:%M", t, TZ), DIM, 1, nil, "right") end
  local note, color
  if UI.status ~= "ok" and UI.status ~= "loading" then note, color = UI.status, ACCENT
  elseif UI.upd then note, color = "upd " .. sys.date("%H:%M", UI.upd, TZ), DIMMER end
  if note then disp.text(right - 6, 3, note, color, 1, nil, "right") end
end

---------------------------------------------------------------- list

local function list_top()                -- the strip's first row starts here
  return #UI.games == 0 and UI.next and 16 or 0
end

local function strip_h() return list_top() + #shown() * ROW_H end
local function max_scroll() return math.max(0, strip_h() - VIEW_H) end

local function draw_crest(team, x, y)
  local px = team.id and UI.crests[team.id]
  if px then disp.image(x, y, CREST, CREST, px)
  else pics.badge(x, y, CREST, team.tla, BADGE) end
end

local function draw_row(g, y)
  local t = now() or g.utc
  disp.rect(0, y, W, 1, GRID, true)
  if g.fav then disp.rect(0, y + 1, 3, ROW_H - 1, ACCENT, true) end
  local st, key = games.status(g, t, TZ)
  disp.text(6, y + 7, st, COLOR[key])
  local sub = g.comp                     -- today: the competition; other days: the weekday
  if g.group == 4 or g.group == 5 or #UI.games == 0 then sub = sys.date("%a", g.utc, TZ) end
  disp.text(6, y + 21, sub, DIMMER)
  draw_crest(g.home, 44, y + 8)
  local hn = cut(g.home.short, 13)
  disp.text(146, y + 14, hn, FG, 1, nil, "right")
  local sc = score(g)
  disp.text(182, y + 11, sc, key == "live" and LIVE or FG, 2, nil, "center")
  disp.text(218, y + 14, cut(g.away.short, 12), FG)
  draw_crest(g.away, 294, y + 8)
end

local function draw_empty()
  if UI.status == "loading" then
    disp.text(W // 2, 110, "Loading...", DIM, 2, nil, "center")
  elseif UI.status == "ok" then
    disp.text(W // 2, 110, "No games", DIM, 2, nil, "center")
  else
    disp.text(W // 2, 96, "The scores didn't load", FG, 2, nil, "center")
    disp.text(W // 2, 124, UI.status, ACCENT, 2, nil, "center")
    disp.text(W // 2, 150, "Trying again in a minute", DIM, 1, nil, "center")
  end
end

local function draw_list()
  disp.rect(0, TOP, W, VIEW_H, BG, true)
  local list = shown()
  if #list == 0 then
    draw_empty()
  else
    UI.scroll = math.min(UI.scroll, max_scroll())
    local base = TOP - UI.scroll
    if #UI.games == 0 then disp.text(6, base + 4, "No games today. Next:", DIM) end
    for i, g in ipairs(list) do
      local y = base + list_top() + (i - 1) * ROW_H
      if y + ROW_H > TOP and y < H then draw_row(g, y) end
    end
    local total = strip_h()
    if total > VIEW_H then
      local bh = math.max(12, VIEW_H * VIEW_H // total)
      disp.rect(W - 3, TOP + (VIEW_H - bh) * UI.scroll // max_scroll(), 2, bh, DIMMER, true)
    end
  end
  draw_header()
end

---------------------------------------------------------------- detail
-- One game: both crests big, the score, the half-time score, the
-- competition, the kickoff and the venue (asked for once, on opening).

local BIG = 64

-- Up to two lines of `n` characters, broken at spaces.
local function two_lines(s, n)
  local l = disp.wrap(s, 6 * n - 1)
  return l[1] or "", cut(table.concat(l, " ", 2), n)
end

local function draw_big_crest(team, x, y)
  local px = team.id and UI.crests64[team.id]
  if px then disp.image(x, y, BIG, BIG, px)
  else pics.badge(x, y, BIG, team.tla, BADGE) end
end

local function draw_detail()
  local g = UI.sel_game
  local t = now() or g.utc
  disp.clear(BG)
  draw_big_crest(g.home, 24, 20)
  draw_big_crest(g.away, W - 24 - BIG, 20)
  for i, team in ipairs({ g.home, g.away }) do
    local a, b = two_lines(team.name, 16)
    local cx = i == 1 and 24 + BIG // 2 or W - 24 - BIG // 2
    disp.text(cx, 90, a, FG, 1, nil, "center")
    disp.text(cx, 100, b, FG, 1, nil, "center")
  end
  local st, key = games.status(g, t, TZ)
  disp.text(W // 2, 34, score(g), key == "live" and LIVE or FG, 4, nil, "center")
  disp.text(W // 2, 70, st, COLOR[key], 2, nil, "center")
  local y = 124
  local function line(s, color) disp.text(W // 2, y, s, color or DIM, 1, nil, "center"); y = y + 16 end
  if g.ht.h and g.ht.a and key ~= "dim" then line("Half time " .. g.ht.h .. "-" .. g.ht.a, FG) end
  if g.pens then line("Penalties " .. g.pens.h .. "-" .. g.pens.a, FG) end
  line((g.comp_name or g.comp) .. (g.matchday and ("  Matchday " .. g.matchday) or ""))
  line(sys.date("%a %-d.%-m. %H:%M", g.utc, TZ))
  if UI.venue then line(UI.venue) end
end

local function draw()
  if UI.view == "detail" then draw_detail() else draw_list() end
end
UI.draw = draw                           -- for the checks and the showcase

local function open(i)
  local g = shown()[i]
  if not g then return end
  if UI.view == "list" then UI.list_scroll = UI.scroll end
  UI.view, UI.sel, UI.sel_id, UI.sel_game = "detail", i, g.id, g
  UI.venue = g.id and UI.venues[g.id] or nil
  draw()
end

local function close()
  UI.view, UI.sel, UI.sel_id, UI.sel_game, UI.venue = "list", nil, nil, nil, nil
  UI.scroll = UI.list_scroll or 0
  draw()
end

---------------------------------------------------------------- fetching

local HEADERS = { ["X-Auth-Token"] = KEY }
-- A crest failure that may pass (Wi-Fi, a timeout) pauses the crests until
-- the next good fetch; one that won't (not an image, HTTP 4xx) leaves the badge.
local crests_paused = false
local next_ms, force, last_force = 0, false, -1e9
local paused_until = 0                   -- after a rate limit, nothing before this (sys.millis)

-- What a refused request means for the user.
local REFUSED = { ["HTTP 400"] = "check leagues", ["HTTP 401"] = "key refused", ["HTTP 403"] = "key refused" }
local REFUSED_MS = 15 * 60 * 1000      -- asking again soon won't help

local function get(path)
  local body, note, final, wait = web.get(API .. path, nil, HEADERS)
  if wait then
    paused_until = sys.millis() + wait * 1000
    UI.status = "rate limit"             -- whichever request ran into it
  end
  return body, note, final
end

local function fetch()
  local t = now()
  if not t then UI.status = "no clock"; next_ms = sys.millis() + 2000; draw(); return end
  local body, err, final = get(games.query(CFG, t, TZ))
  local list
  if body then
    list, err = games.parse(body, CFG)
    body = nil
    yield()                              -- a big answer takes a while on the chip
  end
  if list then
    games.sort(list, t, TZ)
    UI.games, UI.status, UI.upd = list, "ok", t
    crests_paused = false
    UI.next = nil
    if #list == 0 then
      local nb = get(games.next_query(CFG, t, TZ))
      local nl = nb and games.parse(nb, CFG)
      nb = nil
      yield()
      if nl then
        games.sort(nl, t, TZ)
        UI.next = { table.unpack(nl, 1, math.min(6, #nl)) }
      end
    end
    next_ms = sys.millis() + games.next_delay(list, t)
  else
    UI.status = final and REFUSED[err] or err
    if err == "rate limit" then next_ms = paused_until
    elseif final then next_ms = sys.millis() + REFUSED_MS
    else next_ms = sys.millis() + RETRY_MS end
  end
  UI.fetches = UI.fetches + 1
  if UI.view == "detail" then              -- the open game, with its new score
    for _, g in ipairs(shown()) do
      if g.id == UI.sel_id then UI.sel_game = g; break end
    end
  end
  draw()
end

local function crest_into(cache, team, size)
  if not team.crest then cache[team.id] = false; return end
  local data, note, final = web.get(team.crest)
  local px = data and pics.crest(data, size, BG)
  data = nil
  if px then cache[team.id] = px
  elseif note and not final then crests_paused = true
  else cache[team.id] = false end
end

-- The open game's big crests and venue first, then one missing small crest,
-- in the order of the list.
local function load_crest()
  if crests_paused then return false end
  local g = UI.view == "detail" and UI.sel_game
  if g then
    for _, team in ipairs({ g.home, g.away }) do
      if team.id and UI.crests64[team.id] == nil then
        crest_into(UI.crests64, team, BIG)
        if UI.sel_game == g then draw() end
        return true
      end
    end
    if UI.venues[g.id] == nil and g.id and sys.millis() >= paused_until then
      local body, note, final = get("matches/" .. g.id)
      if body or final then              -- a venue never changes: asked once per game
        local ok, d = pcall(require("json").decode, body or "")
        UI.venues[g.id] = ok and type(d) == "table" and type(d.venue) == "string" and d.venue or false
      end
      if UI.sel_game == g then UI.venue = UI.venues[g.id]; draw() end
      return true
    end
  end
  for _, g in ipairs(shown()) do
    for _, team in ipairs({ g.home, g.away }) do
      if team.id and UI.crests[team.id] == nil then
        crest_into(UI.crests, team, CREST)
        if UI.view == "list" then draw() end
        return true
      end
    end
  end
  return false
end

---------------------------------------------------------------- setup

local function draw_setup()
  disp.clear(BG)
  disp.text(10, 10, "Football", FG, 3)
  local lines = {                          -- 51 characters fit from x 10
    { "This app needs your own free football-data.org", FG },
    { "key (football-data.org, Register).", DIM },
    { "", DIM },
    { "Give it to the app from a computer:", DIM },
    { "luaboard secrets set football key <key>", FG },
    { "then open the app again.", DIM },
    { "", DIM },
    { "Steps: github.com/veikkos/luaboard-marketplace", DIM },
  }
  for i, l in ipairs(lines) do disp.text(10, 50 + (i - 1) * 16, l[1], l[2], 1) end
end

---------------------------------------------------------------- main

if not (KEY and KEY ~= "") then
  UI = nil
  draw_setup()
  print("football: no key: luaboard secrets set football key <key>")
  return
end

UI.refresh = function() force = true end    -- for the checks

local last_touch = sys.millis()
local drag_base

local function top_row()                 -- the list row at the top of the view
  return math.max(1, (UI.scroll - list_top()) // ROW_H + 1)
end

local function scroll_list(to)
  UI.scroll = math.max(0, math.min(to, max_scroll()))
  draw()
end

local function button(b)
  last_touch = sys.millis()
  if b == "B" then
    if UI.view == "detail" then close()
    elseif sys.millis() - last_force >= 5000 then force, last_force = true, sys.millis() end
    return
  end
  local step = b == "A" and -1 or 1
  if UI.view == "detail" then              -- the previous / next game, found by id after any refresh
    local at = UI.sel
    for k, g in ipairs(shown()) do
      if g.id == UI.sel_id then at = k; break end
    end
    if shown()[at + step] then open(at + step) end
  elseif #shown() > 0 then
    local i = top_row()
    local at = list_top() + (i - 1) * ROW_H
    if step > 0 then scroll_list(at + ROW_H)
    elseif UI.scroll > at then scroll_list(at)
    else scroll_list(at - ROW_H) end
  end
end
touch.on("press", button)

touch.on("tap", function(x, y)
  last_touch = sys.millis()
  if UI.view == "detail" then close(); return end
  if y < TOP then return end
  local sy = y - TOP + UI.scroll - list_top()
  if sy >= 0 then open(sy // ROW_H + 1) end
end)

local pulled                             -- the drag began in the list at its top
touch.on("drag", function(x, y, x0, y0, ended)
  last_touch = sys.millis()
  if UI.view ~= "list" then return end
  if not drag_base then pulled = UI.scroll == 0 end
  drag_base = drag_base or UI.scroll
  scroll_list(drag_base - (y - y0))
  if ended then drag_base = nil end
end)

-- The buttons by touch, for a board without them: in a game's details a
-- swipe to the side is the next or the previous game, and the list pulled
-- down at its top fetches now.
touch.on("swipe", function(dir)
  if UI.view == "detail" then
    if dir == "left" then button("C") elseif dir == "right" then button("A") end
  elseif dir == "down" and pulled then
    button("B")
  end
end)

timer.every(1000, function()             -- untouched for a while: back to the top
  if sys.millis() - last_touch < IDLE_MS then return end
  if UI.view == "detail" then UI.list_scroll = 0; close()
  elseif UI.scroll ~= 0 then scroll_list(0) end
end)

local drawn_minute
timer.every(1000, function()             -- the clock, and the estimated minutes
  local t = now()
  if t and t // 60 ~= drawn_minute then
    drawn_minute = t // 60
    draw()
  end
end)

draw()
task(function()
  while true do
    if sys.millis() >= paused_until and (force or sys.millis() >= next_ms) then
      force = false
      fetch()
    else
      load_crest()
    end
    sleep(250)
  end
end)
