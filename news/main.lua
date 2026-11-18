-- news: the top stories of an RSS or Atom feed, with pictures. The feed's
-- first story is big, the next ones are rows under it; drag to scroll, tap
-- a story for its summary. It refreshes itself every 5 minutes.
-- A / C = previous / next story, B = refresh now (in a summary: back). Needs Wi-Fi and the feed's
-- address in the secret `feed`.

local feed, pics, wrap, web = require("feed"), require("pics"), require("wrap"), require("web")

local REFRESH_MS = 5 * 60 * 1000
local RETRY_MS = 60 * 1000
local IDLE_MS = 60 * 1000             -- untouched this long: back to the top
local NEW_MS = 60 * 60 * 1000         -- a story is NEW this long after it first came
local MAX_STORIES = 20

local W, H = disp.W, disp.H
local BG, FG = disp.rgb(10, 14, 20), disp.WHITE
local DIM, DIMMER = disp.rgb(140, 150, 165), disp.rgb(70, 80, 95)
local GRID, HDR = disp.rgb(32, 40, 52), disp.rgb(20, 26, 38)
local ACCENT = disp.rgb(255, 176, 32)

-- The list is a strip scrolled under the header: the first story 140 px
-- (a 320x92 picture, the band with its age and headline), the others 43 px.
local TOP = 14                         -- the header's height
local VIEW_H = H - TOP
local HERO_H, PIC_H, ROW_H = 140, 92, 43
local THUMB_W, THUMB_H = 56, 32

local FEED = secrets.get("feed")

UI = {
  status = "loading",                  -- "loading", "ok" or what went wrong
  fetches = 0,
  stories = {},
  title = "",
  view = "list",
  scroll = 0,
}

---------------------------------------------------------------- helpers

local function now() return sys.time() end

local function age(t)
  local n = now()
  if not (t and n) then return "" end
  local s = math.max(0, n - t)
  if s < 60 then return "now"
  elseif s < 3600 then return string.format("%d min", s // 60)
  elseif s < 86400 then return string.format("%d h", s // 3600)
  else return string.format("%d d", s // 86400) end
end

local function is_new(st) return st.seen_ms and sys.millis() - st.seen_ms < NEW_MS end

-- The panel's word: the feed's first word ("Daily Planet" -> DAILY).
local function feed_word() return UI.title:match("[^%s|:%-]+") or "" end

---------------------------------------------------------------- header

local function draw_header()
  disp.rect(0, 0, W, TOP, HDR, true)
  local right = W - 4
  local t = now()
  if t then right = right - disp.text(right, 3, sys.date("%H:%M", t), DIM, 1, nil, "right") end
  if UI.status ~= "ok" and UI.status ~= "loading" then
    right = right - 6 - disp.text(right - 6, 3, UI.status, ACCENT, 1, nil, "right")
  end
  local cols = (right - 4 - 6) // 6
  local title = wrap(UI.title, cols, 1)[1]
  if title then disp.text(4, 3, title, DIM) end
end

---------------------------------------------------------------- list

local function strip_y(i)                -- where story i starts on the strip
  return i == 1 and 0 or HERO_H + (i - 2) * ROW_H
end

local function strip_h()
  local n = #UI.stories
  return n == 0 and 0 or strip_y(n) + (n == 1 and HERO_H or ROW_H)
end

local function max_scroll() return math.max(0, strip_h() - VIEW_H) end

local function draw_hero(st, y)
  if st.px then disp.image(0, y, W, PIC_H, st.px)
  else pics.panel(0, y, W, PIC_H, feed_word()) end
  disp.rect(0, y + PIC_H, W, HERO_H - PIC_H, BG, true)
  local a = age(st.time)
  local x = 4
  if a ~= "" then x = x + disp.text(4, y + PIC_H + 3, a, ACCENT) + 6 end
  if is_new(st) then disp.text(x, y + PIC_H + 3, " NEW ", BG, 1, ACCENT) end
  for i, l in ipairs(wrap(st.title, 26, 2)) do
    disp.text(4, y + PIC_H + 14 + (i - 1) * 16, l, FG, 2)
  end
end

local function draw_row(st, y)
  disp.rect(0, y, W, 1, GRID, true)
  if st.thumb then disp.image(4, y + 6, THUMB_W, THUMB_H, st.thumb)
  else pics.panel(4, y + 6, THUMB_W, THUMB_H, feed_word()) end
  if is_new(st) then disp.rect(0, y + 6, 3, THUMB_H, ACCENT, true) end
  for i, l in ipairs(wrap(st.title, 41, 3)) do      -- small letters: 3 lines of 41
    disp.text(66, y + 7 + (i - 1) * 11, l, FG)
  end
end

local function draw_empty()
  if UI.status == "loading" then
    disp.text(W // 2, 110, "Loading...", DIM, 2, nil, "center")
  elseif UI.status == "ok" then
    disp.text(W // 2, 110, "No stories in the feed", DIM, 2, nil, "center")
  else
    disp.text(W // 2, 96, "The feed didn't load", FG, 2, nil, "center")
    disp.text(W // 2, 124, UI.status, ACCENT, 2, nil, "center")
    disp.text(W // 2, 150, "Trying again in a minute", DIM, 1, nil, "center")
  end
end

local function draw_list()
  disp.rect(0, TOP, W, VIEW_H, BG, true)
  local n = #UI.stories
  if n == 0 then
    draw_empty()
  else
    UI.scroll = math.min(UI.scroll, max_scroll())
    for i, st in ipairs(UI.stories) do
      local y = TOP + strip_y(i) - UI.scroll
      local h = i == 1 and HERO_H or ROW_H
      if y + h > TOP and y < H then
        if i == 1 then draw_hero(st, y) else draw_row(st, y) end
      end
    end
    local total = strip_h()
    if total > VIEW_H then
      local bh = math.max(12, VIEW_H * VIEW_H // total)
      local by = TOP + (VIEW_H - bh) * UI.scroll // max_scroll()
      disp.rect(W - 3, by, 2, bh, DIMMER, true)
    end
  end
  draw_header()
end

---------------------------------------------------------------- summary
-- Its own strip, from the top of the screen: a 320x120 picture, the feed
-- and the age, the whole headline, the description.

local SUM_PIC_H = 120

local function summary_layout(st)
  local head = wrap(st.title, 26)
  local desc = wrap(st.summary or "", 52)
  local desc_y = SUM_PIC_H + 20 + #head * 16 + 6
  return head, desc, desc_y, desc_y + #desc * 10 + 8
end

local function summary_max(st)
  local _, _, _, h = summary_layout(st)
  return math.max(0, h - H)
end

local function draw_summary()
  local st = UI.sel_story
  disp.rect(0, 0, W, H, BG, true)
  local head, desc, desc_y, total = summary_layout(st)
  UI.sscroll = math.min(UI.sscroll, math.max(0, total - H))
  local o = -UI.sscroll
  if o + SUM_PIC_H > 0 then
    if UI.sel_px then disp.image(0, o, W, SUM_PIC_H, UI.sel_px)
    else pics.panel(0, o, W, SUM_PIC_H, feed_word()) end
  end
  local a = age(st.time)
  local meta = UI.title .. (a ~= "" and (" · " .. a .. (a == "now" and "" or " ago")) or "")
  disp.text(4, o + SUM_PIC_H + 6, wrap(meta, 52, 1)[1] or "", ACCENT)
  for i, l in ipairs(head) do
    local y = o + SUM_PIC_H + 20 + (i - 1) * 16
    if y > -16 and y < H then disp.text(4, y, l, FG, 2) end
  end
  for i, l in ipairs(desc) do
    local y = o + desc_y + (i - 1) * 10
    if y > -10 and y < H then disp.text(4, y, l, DIM) end
  end
  if total > H then
    local bh = math.max(12, H * H // total)
    disp.rect(W - 3, (H - bh) * UI.sscroll // (total - H), 2, bh, DIMMER, true)
  end
end

local function draw()
  if UI.view == "summary" then draw_summary() else draw_list() end
end
UI.draw = draw                           -- for the checks and the showcase

local function open(i)
  local st = UI.stories[i]
  if not st then return end
  if UI.view == "list" then UI.list_scroll = UI.scroll end
  UI.view, UI.sel, UI.sel_id, UI.sel_story = "summary", i, st.id, st
  UI.sel_px, UI.sscroll = nil, 0
  draw()
end

local function close()
  UI.view, UI.sel, UI.sel_id, UI.sel_story, UI.sel_px = "list", nil, nil, nil, nil
  UI.scroll = UI.list_scroll or 0
  draw()
end

---------------------------------------------------------------- fetching

local first_load = true
local next_ms, force, last_force = 0, false, -1e9
-- After a picture download failed for a reason that may pass (Wi-Fi, a
-- timeout), no more pictures until the next good fetch of the feed.
local pictures_paused = false

local function fetch()
  local body, err = web.get(FEED)
  local doc
  if body then
    doc = feed.parse(body, MAX_STORIES)
    body = nil
    if not doc then err = "bad feed" end
    yield()                                -- the parse can take a while on the chip
  end
  if doc then
    local old = {}
    for _, st in ipairs(UI.stories) do old[st.id] = st end
    local list = {}
    for i, it in ipairs(doc.items) do
      local o = old[it.id]
      if o then
        it.seen_ms, it.px, it.thumb, it.nopic = o.seen_ms, o.px, o.thumb, o.nopic
      else
        it.seen_ms = first_load and -NEW_MS or sys.millis()
      end
      list[i] = it
    end
    UI.stories, UI.title, UI.status = list, doc.title, "ok"
    first_load, pictures_paused = false, false
    next_ms = sys.millis() + REFRESH_MS
  else
    UI.status = err
    next_ms = sys.millis() + RETRY_MS
  end
  UI.fetches = UI.fetches + 1
  if UI.view == "list" then draw() end
end

-- One missing picture: the first story's big one, then the rows' in order.
local function next_picture()
  for i, st in ipairs(UI.stories) do
    if st.image and not st.nopic then
      if i == 1 and not st.px then return st, "px", W, PIC_H, "contain" end
      if i > 1 and not st.thumb then return st, "thumb", THUMB_W, THUMB_H end
    end
  end
end

-- A picture for a box, or nil. A failure that won't pass (not an image,
-- HTTP 4xx, too big) marks the story as having none; one that may pass
-- pauses the pictures until the next good fetch.
local function picture(st, w, h, mode)
  local data, note, final = web.get(st.image, FEED)
  local px = data and pics.fit(data, w, h, mode)
  data = nil
  if not px then
    if note and not final then pictures_paused = true else st.nopic = true end
  end
  return px
end

local function load_picture()
  if pictures_paused then return false end
  local open_st = UI.view == "summary" and UI.sel_story
  if open_st and not UI.sel_px and open_st.image and not open_st.nopic then
    local px = picture(open_st, W, SUM_PIC_H, "contain")
    if px and UI.sel_story == open_st then UI.sel_px = px; draw() end
    return true
  end
  local st, key, w, h, mode = next_picture()
  if not st then return false end
  st[key] = picture(st, w, h, mode)
  if UI.view == "list" then draw() end
  return true
end

---------------------------------------------------------------- setup

local function draw_setup()
  disp.clear(BG)
  disp.text(10, 10, "News", FG, 3)
  local lines = {                          -- 51 characters fit from x 10
    { "This app needs an RSS or Atom feed to show.", FG },
    { "", DIM },
    { "Give it the feed's address from a computer:", DIM },
    { "luaboard secrets set news feed <url>", FG },
    { "then open the app again.", DIM },
    { "", DIM },
    { "Steps: github.com/veikkos/luaboard-marketplace", DIM },
  }
  for i, l in ipairs(lines) do disp.text(10, 50 + (i - 1) * 16, l[1], l[2], 1) end
end

---------------------------------------------------------------- main

if not (FEED and FEED ~= "") then
  draw_setup()
  print("news: no feed: luaboard secrets set news feed <url>")
  return
end

UI.refresh = function() force = true end    -- for the checks

local last_touch = sys.millis()
local drag_base                           -- the scroll when the drag began

-- The story at the top of the list's view.
local function top_story()
  local i = 1
  while UI.stories[i + 1] and strip_y(i + 1) <= UI.scroll do i = i + 1 end
  return i
end

local function scroll_list(to)
  UI.scroll = math.max(0, math.min(to, max_scroll()))
  draw()
end

touch.on("press", function(b)
  last_touch = sys.millis()
  if b == "B" and UI.view == "summary" then
    close()
  elseif b == "B" then
    if sys.millis() - last_force >= 5000 then force, last_force = true, sys.millis() end
  elseif UI.view == "summary" then         -- the previous / next story's summary
    local at = UI.sel                     -- where the open story is now, after any refresh
    for k, st in ipairs(UI.stories) do
      if st.id == UI.sel_id then at = k; break end
    end
    local i = at + (b == "A" and -1 or 1)
    if UI.stories[i] then open(i) end
  elseif #UI.stories > 0 then
    local i = top_story()
    if b == "C" then
      if UI.stories[i + 1] then scroll_list(strip_y(i + 1)) end
    elseif UI.scroll > strip_y(i) then
      scroll_list(strip_y(i))
    elseif i > 1 then
      scroll_list(strip_y(i - 1))
    end
  end
end)

touch.on("tap", function(x, y)
  last_touch = sys.millis()
  if UI.view == "summary" then close(); return end
  if y < TOP or #UI.stories == 0 then return end
  local sy = y - TOP + UI.scroll
  open(sy < HERO_H and 1 or 2 + (sy - HERO_H) // ROW_H)
end)

touch.on("drag", function(x, y, x0, y0, ended)
  last_touch = sys.millis()
  local summary = UI.view == "summary"
  drag_base = drag_base or (summary and UI.sscroll or UI.scroll)
  local to = drag_base - (y - y0)
  if summary then
    UI.sscroll = math.max(0, math.min(to, summary_max(UI.sel_story)))
    draw()
  else
    scroll_list(to)
  end
  if ended then drag_base = nil end
end)

timer.every(1000, function()              -- untouched for a while: back to the top
  if sys.millis() - last_touch < IDLE_MS then return end
  if UI.view == "summary" then UI.list_scroll = 0; close()
  elseif UI.scroll ~= 0 then scroll_list(0) end
end)

local drawn_minute
timer.every(1000, function()              -- the clock in the header
  local t = now()
  if t and t // 60 ~= drawn_minute and UI.view == "list" then
    drawn_minute = t // 60
    draw_header()
  end
end)

draw()
task(function()
  while true do
    if force or sys.millis() >= next_ms then
      force = false
      fetch()
    else
      load_picture()
    end
    sleep(250)
  end
end)
