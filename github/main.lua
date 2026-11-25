-- github: a desk board for your GitHub repos. Each row is a repo: a dot for
-- the latest workflow run on its default branch (green passed, red failed,
-- yellow running, grey cancelled or skipped, a ring for none yet), its open
-- pull requests and how long ago that run started. At the top, the pull
-- requests waiting for your review. A chime when a run fails, another when
-- it passes again.
--
-- Setup: a GitHub App of your own (see README.md), its Client ID and a client
-- secret in secrets.env (see secrets.env.example). The first run asks for a
-- login in luaboard studio (or `luaboard browser`); the device keeps it in
-- the secret "github". The repos are the ones you install the app on, or the
-- `repos` line of secrets.env.
--
-- B refreshes, A / C (or a swipe) scroll, a tap on a row shows its run.

local github = require("github")

local POLL_MS = 2 * 60 * 1000
local REPOS_MS = 30 * 60 * 1000       -- how often the list of repos is fetched again

local W, H = disp.W, disp.H
local BG, FG = disp.rgb(13, 17, 23), disp.WHITE             -- GitHub's dark theme
local DIM, DIMMER = disp.rgb(139, 148, 158), disp.rgb(72, 79, 88)
local LINE = disp.rgb(33, 38, 45)
local ACCENT = disp.rgb(88, 166, 255)
local PASS, FAIL = disp.rgb(63, 185, 80), disp.rgb(248, 81, 73)
local RUNNING, NEUTRAL = disp.rgb(210, 153, 34), disp.rgb(110, 118, 129)
local BADGE = disp.rgb(219, 109, 40)

local ROW_Y, ROW_H, ROWS = 24, 23, 8

-- Global so tests (and `luaboard eval`) can look in.
UI = { status = "starting...", polls = 0, user = nil, reviews = nil, rows = {}, top = 1 }

local gh
local logging_in = false
local picked, picked_until            -- a tapped row, its run shown at the bottom
local polling = false
local last_poll_ms = -POLL_MS

---------------------------------------------------------------- drawing

local function fit(s, n)                       -- at most n characters (UTF-8)
  local len = utf8.len(s)
  if (len or #s) <= n then return s end
  return s:sub(1, len and utf8.offset(s, n - 1) - 1 or n - 2) .. ".."
end

local function age(t)
  local now = sys.time()
  if not t or not now then return "" end
  local s = math.max(0, now - t)
  if s < 3600 then return (s // 60) .. "m" end
  if s < 86400 then return (s // 3600) .. "h" end
  return (s // 86400) .. "d"
end

local function run_color(run)
  if run == nil then return DIMMER end           -- not fetched yet
  if run == false then return nil end            -- no runs: a ring
  if run.status ~= "completed" then return RUNNING end
  if run.conclusion == "success" then return PASS end
  if run.conclusion == "failure" or run.conclusion == "timed_out" or run.conclusion == "startup_failure" then
    return FAIL
  end
  return NEUTRAL
end

local function draw_header()
  disp.rect(0, 0, W, ROW_Y - 2, BG, true)
  local w = disp.text(8, 6, "GitHub", FG, 1)
  if UI.user then disp.text(8 + w + 6, 6, "@" .. UI.user, DIM, 1) end
  local n = UI.reviews
  if n and n > 0 then
    local s = n .. " to review"
    local bw = disp.text_width(s) + 12
    disp.rect(312 - bw, 3, bw, 14, BADGE, true)
    disp.text(312 - bw + 6, 6, s, FG, 1)
  elseif n then
    disp.text(312, 6, "no reviews waiting", DIMMER, 1, nil, "right")
  end
  disp.line(0, ROW_Y - 2, W, ROW_Y - 2, LINE)
end

local function draw_row(i, r)
  local y = ROW_Y + (i - UI.top) * ROW_H
  disp.rect(0, y, W, ROW_H - 1, BG, true)
  local col = run_color(r.run)
  if col then disp.circle(14, y + 10, 5, col, true)
  else disp.circle(14, y + 10, 5, NEUTRAL); disp.circle(14, y + 10, 4, NEUTRAL) end
  local name = fit(r.name, 16)
  disp.text(28, y + 4, name, picked == r and ACCENT or FG, 2)
  if r.prs and r.prs > 0 then disp.text(276, y + 8, r.prs .. " PR", ACCENT, 1, nil, "right") end
  if r.run then disp.text(312, y + 8, age(r.run.at), DIM, 1, nil, "right") end
  disp.line(8, y + ROW_H - 1, 312, y + ROW_H - 1, LINE)
end

local function draw_rows()
  disp.rect(0, ROW_Y, W, ROWS * ROW_H, BG, true)
  local rows = UI.rows
  if #rows == 0 then
    disp.text(16, 100, UI.status == "ok" and "No repos: install the GitHub App" or "", DIM, 1)
    disp.text(16, 114, UI.status == "ok" and "on some, or set repos (see the README)." or "", DIM, 1)
  end
  for i = UI.top, math.min(#rows, UI.top + ROWS - 1) do draw_row(i, rows[i]) end
  if #rows > ROWS then                            -- where we are in the list
    local h = ROWS * ROW_H
    local bh = math.max(8, h * ROWS // #rows)
    local by = ROW_Y + (h - bh) * (UI.top - 1) // (#rows - ROWS)
    disp.rect(316, ROW_Y, 3, h, LINE, true)
    disp.rect(316, by, 3, bh, DIM, true)
  end
end

local function draw_footer()
  disp.rect(0, 210, W, H - 210, BG, true)
  disp.line(0, 211, W, 211, LINE)
  local line, col
  if picked and sys.millis() < picked_until then
    local run = picked.run
    if run then
      line = string.format("%s on %s: %s%s", run.name, run.branch or "?",
                           run.status == "completed" and (run.conclusion or "?") or run.status:gsub("_", " "),
                           run.actor and (", " .. run.actor) or "")
    else
      line = picked.full_name .. ": no workflow runs"
    end
    disp.text(8, 216, fit(picked.full_name, 52), ACCENT, 1)
    disp.text(8, 228, fit(line, 52), FG, 1)
    return
  end
  picked = nil
  if UI.status == "ok" then
    line, col = "updated " .. (UI.updated or ""), DIMMER
  else
    line, col = UI.status, polling and DIM or disp.ORANGE
  end
  disp.text(8, 216, fit(line, 52), col, 1)
  local hint = #UI.rows > ROWS and "<< up   o refresh   down >>" or "o refresh   tap a repo for its run"
  disp.text(8, 228, hint, DIMMER, 1)
end

local function draw_all()
  disp.clear(BG)
  draw_header(); draw_rows(); draw_footer()
end

local function draw_setup()
  disp.clear(BG)
  disp.text(16, 24, "GitHub board: setup", FG, 2)
  local y = 60
  for _, l in ipairs({                     -- 51 characters fit from x 10
    { "It needs your own GitHub App: the README says", DIM },
    { "how to make one. Then, from a computer:", DIM },
    { "", DIM },
    { "luaboard secrets set github github_client <id>", FG },
    { "luaboard secrets set github github_secret <secret>", FG },
    { "", DIM },
    { "then open the app again.", DIM },
  }) do
    disp.text(10, y, l[1], l[2], 1); y = y + 16
  end
  disp.text(10, 196, "Steps: github.com/veikkos/luaboard-marketplace", ACCENT, 1)
end

local function draw_login()
  disp.clear(BG)
  disp.text(16, 30, "Log in to GitHub", FG, 2)
  local y = 70
  for _, l in ipairs({
    "Open luaboard studio on your computer",
    "(connected to this device) and click",
    "'Open browser and log in'.",
    "",
    "Or run on the computer:",
    "  luaboard browser",
  }) do
    disp.text(16, y, l, DIM, 1); y = y + 12
  end
  disp.text(16, 200, "The device keeps the login.", DIMMER, 1)
end

---------------------------------------------------------------- sounds

local function chime(up)
  local notes = up and { 660, 880, 1320 } or { 880, 660, 440 }
  for i, hz in ipairs(notes) do
    sound.tone(hz, i == 3 and 220 or 110, 70)
    sound.tone(0, 30)
  end
end

local function failed(run)
  return run and run.status == "completed" and run_color(run) == FAIL
end
local function passed(run)
  return run and run.status == "completed" and run.conclusion == "success"
end

---------------------------------------------------------------- fetching

local repos_at = -REPOS_MS

-- The rows to show: the `repos` secret (owner/name, comma separated) in its
-- order, else the repos the app is installed on. Rows keep what was fetched
-- for them before.
local function load_repos()
  local old = {}
  for _, r in ipairs(UI.rows) do old[r.full_name] = r end
  local list, err
  local wanted = secrets.get("repos")
  if wanted and wanted:find("%S") then
    list = {}
    for name in wanted:gmatch("[^,%s]+") do
      local r
      r, err = gh:repo(name)
      if r then list[#list + 1] = r
      elseif err ~= "Not Found" then return nil, err
      else print("github: no repo " .. name .. " (or no access)") end
    end
  else
    list, err = gh:repos(20)
    if not list then return nil, err end
  end
  for i, r in ipairs(list) do
    local o = old[r.full_name]
    if o then r.run, r.prs = o.run, o.prs end
    list[i] = r
  end
  UI.rows = list
  UI.top = math.max(1, math.min(UI.top, #list - ROWS + 1))
  repos_at = sys.millis()
  return true
end

local function hhmm() return sys.date("%H:%M") or "" end

local function poll()
  if polling then return end
  polling = true
  last_poll_ms = sys.millis()
  UI.status = "updating..."
  draw_footer()
  local ok, err = true, nil
  if not UI.user then UI.user, err = gh:user(); ok = UI.user ~= nil end
  if ok and sys.millis() - repos_at >= REPOS_MS then ok, err = load_repos() end
  if ok then draw_all() end
  for i, r in ipairs(ok and UI.rows or {}) do
    local run, e = gh:last_run(r.full_name, r.default_branch)
    if run == nil then ok, err = false, e; break end
    if r.run ~= nil then                          -- not the first look: news?
      if failed(run) and not failed(r.run) then chime(false)
      elseif passed(run) and failed(r.run) then chime(true) end
    end
    r.run = run
    r.prs = gh:open_prs(r.full_name) or r.prs
    if i >= UI.top and i < UI.top + ROWS then draw_row(i, r) end
  end
  if ok then
    UI.reviews = gh:review_requests() or UI.reviews
    UI.updated = hhmm()
  end
  UI.status = ok and "ok" or (err or "failed")
  UI.polls = UI.polls + 1
  polling = false
  if not logging_in then draw_all() end
end

---------------------------------------------------------------- input

local function scroll(by)
  local top = math.max(1, math.min(UI.top + by, #UI.rows - ROWS + 1))
  if top ~= UI.top then UI.top = top; draw_rows() end
end

local function button(b)
  if not gh or logging_in then return end
  if b == "A" then scroll(-ROWS + 1)
  elseif b == "C" then scroll(ROWS - 1)
  elseif b == "B" and not polling and sys.millis() - last_poll_ms > 5000 then
    repos_at = -REPOS_MS                          -- the list of repos too
    task(poll)
  end
end
touch.on("press", button)
touch.on("long", button)
-- By touch, for a board without the buttons: a swipe scrolls, and a swipe
-- down at the top, or a tap on the lines at the bottom, refreshes.
touch.on("swipe", function(dir)
  if dir == "up" then scroll(3)
  elseif dir == "down" then
    if UI.top == 1 then button("B") else scroll(-3) end
  end
end)
touch.on("tap", function(x, y)
  if not gh or logging_in then return end
  if y >= 212 then button("B"); return end
  local i = UI.top + (y - ROW_Y) // ROW_H
  local r = y >= ROW_Y and (y - ROW_Y) // ROW_H < ROWS and UI.rows[i]
  if r then
    picked, picked_until = r, sys.millis() + 6000
    draw_rows(); draw_footer()
  end
end)

-- The tapped run goes away after a while.
timer.every(1000, function()
  if picked and sys.millis() >= picked_until then draw_rows(); draw_footer() end
end)

---------------------------------------------------------------- start

disp.keep_awake(true)

local CLIENT_ID, CLIENT_SECRET = secrets.get("github_client"), secrets.get("github_secret")
if not CLIENT_ID or CLIENT_ID == "" or not CLIENT_SECRET or CLIENT_SECRET == "" then
  draw_setup()
  print("github: no keys: luaboard secrets set github github_client <id> (and github_secret)")
  return
end

gh = github.new{
  client_id = CLIENT_ID, client_secret = CLIENT_SECRET,
  on_login = function(waiting)
    logging_in = waiting
    if waiting then draw_login() else draw_all() end
  end,
}
draw_all()

task(function()
  poll()
  while true do
    local mark = last_poll_ms
    local wait = UI.status == "ok" and POLL_MS or 60 * 1000
    while sys.millis() - mark < wait and last_poll_ms == mark do sleep(1000) end
    if last_poll_ms == mark then poll() end         -- else B polled: wait again from there
  end
end)
