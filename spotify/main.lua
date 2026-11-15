-- spotify: now playing with cover art and previous / play-pause / next, talking
-- to the Spotify Web API directly over HTTPS.
--
-- Setup: put your app's Client ID in secrets.env (see secrets.env.example) and
-- add http://127.0.0.1:8888/callback to its redirect URIs. The first run asks
-- for a login in luaboard studio (or `luaboard browser`); the device keeps it in
-- the secret "spotify". Log out: `luaboard secrets rm spotify spotify`.
-- Playback control needs Premium.

local CLIENT_ID = secrets.get("spotify_client") or ""  -- from secrets.env

local spotify = require("spotify")

local W, H = disp.W, disp.H
-- Spotify's dark theme: near-black, white text, grey secondary text, green accents
local BG, FG = disp.rgb(18, 18, 18), disp.WHITE
local DIM, DIMMER = disp.rgb(179, 179, 179), disp.rgb(106, 106, 106)
local ACCENT = disp.rgb(30, 215, 96)
local TRACK = disp.rgb(77, 77, 77)                  -- progress bar background
local CARD = disp.rgb(40, 40, 40)
local WARN = disp.rgb(241, 94, 108)
local COVER = 150                                   -- 300 px cover decoded at 1/2
local CX, CY = 8, 8
local TX = CX + COVER + 8                           -- text column
local BAR_Y, BTN_Y, BTN_H = 166, 186, 48

local sp
local status = "connecting to Spotify..."           -- shown when not "ok"
local now = { state = "idle", artist = "", title = "", album = "", progress = 0, duration = 0, device = "" }
local now_at = sys.millis()
local cover_url                                     -- the cover on the screen
local pressed
local logging_in = false

----------------------------------------------------------------- drawing
-- Titles are UTF-8: lengths in characters, not bytes.
local function len(s) return utf8.len(s) or #s end
local function cut(s, n)                            -- the first n characters
  if not utf8.len(s) then return s:sub(1, n) end
  return s:sub(1, (utf8.offset(s, n + 1) or #s + 1) - 1)
end

-- Word-wrap `s` to lines of at most `n` characters, at most `max` lines.
local function wrap(s, n, max)
  local lines, line = {}, ""
  for word in s:gmatch("%S+") do
    while len(word) > n do                          -- very long words are cut
      if #line > 0 then lines[#lines + 1] = line; line = "" end
      local head = cut(word, n)
      lines[#lines + 1] = head; word = word:sub(#head + 1)
    end
    if #line == 0 then line = word
    elseif len(line) + 1 + len(word) <= n then line = line .. " " .. word
    else lines[#lines + 1] = line; line = word end
  end
  if #line > 0 then lines[#lines + 1] = line end
  if #lines > max then
    lines = { table.unpack(lines, 1, max) }
    lines[max] = cut(lines[max], n - 2) .. ".."
  end
  return lines
end

local function mmss(ms)
  local s = ms // 1000
  return string.format("%d:%02d", s // 60, s % 60)
end

local function triangle(x, y, h, dir, col)          -- dir 1 = pointing right, -1 = left
  for i = 0, h // 2 do
    local len = (h // 2 - i) * 2 * 2 // 3
    local x0 = dir > 0 and x or x - len
    disp.line(x0, y + h // 2 - i, x0 + len, y + h // 2 - i, col)
    disp.line(x0, y + h // 2 + i, x0 + len, y + h // 2 + i, col)
  end
end

local function draw_cover_placeholder()            -- grey card with a music note
  local mx, my, col = CX + COVER // 2, CY + COVER // 2, disp.rgb(120, 120, 120)
  disp.rect(CX, CY, COVER, COVER, CARD, true)
  disp.circle(mx - 8, my + 18, 9, col, true)
  disp.rect(mx, my - 26, 3, 44, col, true)
  disp.rect(mx, my - 26, 18, 3, col, true)
  disp.rect(mx + 15, my - 26, 3, 12, col, true)
end

-- A pill (rounded ends), filled. Use an odd height: a disc is 2r+1 pixels
-- tall, so only then do the ends line up with the middle.
local function pill(x, y, w, h, col)
  local r = (h - 1) // 2
  disp.rect(x + r, y, w - 2 * r, h, col, true)
  disp.circle(x + r, y + r, r, col, true)
  disp.circle(x + w - r - 1, y + r, r, col, true)
end

local function draw_info()
  disp.rect(TX, 0, W - TX, BAR_Y - 4, BG, true)
  local y = CY
  local cols = (W - TX - 4) // 6                     -- characters per line at scale 1
  if now.state == "idle" then
    disp.text(TX, y, "Nothing playing", DIM, 1)
  else
    for _, l in ipairs(wrap(now.title, cols // 2, 3)) do
      disp.text(TX, y, l, FG, 2); y = y + 18
    end
    y = y + 4
    for _, l in ipairs(wrap(now.artist, cols, 2)) do
      disp.text(TX, y, l, DIM); y = y + 10
    end
    y = y + 2
    for _, l in ipairs(wrap(now.album, cols, 2)) do
      disp.text(TX, y, l, DIMMER); y = y + 10
    end
  end
  -- the device it's playing on, in green like Spotify's "Listening on ..."
  local line = status ~= "ok" and status or (now.device ~= "" and ("Playing on " .. now.device) or "")
  local lines = wrap(line, cols, 2)
  for i, l in ipairs(lines) do
    disp.text(TX, CY + COVER - 18 + (i - 1) * 10 + (#lines == 1 and 10 or 0), l,
              status ~= "ok" and WARN or ACCENT)
  end
end

local function progress_ms()
  local p = now.progress
  if now.state == "playing" then p = p + (sys.millis() - now_at) end
  return math.min(p, now.duration)
end

-- Thin rounded bar: grey track, white fill, a white knob at the position.
local function draw_progress()
  local x, w = CX + 4, W - 2 * CX - 8
  disp.rect(x - 6, BAR_Y - 5, w + 12, 13, BG, true)  -- clear the old knob
  pill(x, BAR_Y, w, 5, TRACK)
  if now.duration > 0 then
    local fw = w * progress_ms() // now.duration
    if fw >= 5 then pill(x, BAR_Y, fw, 5, FG) end
    disp.circle(x + fw, BAR_Y + 2, 5, FG, true)
    disp.text(CX, BAR_Y + 9, mmss(progress_ms()) .. "  ", DIM, 1, BG)
    local d = mmss(now.duration)
    disp.text(CX + (W - 2 * CX) - disp.text_width(d), BAR_Y + 9, d, DIM, 1, BG)
  else
    disp.rect(CX, BAR_Y + 9, W - 2 * CX, 8, BG, true)
  end
end

local function button_rect(i)                        -- 3 buttons across the bottom
  local bw = (W - 2 * CX - 2 * 8) // 3
  return CX + (i - 1) * (bw + 8), BTN_Y, bw, BTN_H
end

-- Like Spotify's player bar: previous/next are bare grey icons (white while
-- pressed), play/pause is a white disc with a black icon (shrinks a little
-- while pressed). The touch zones are still the three thirds.
local function draw_buttons()
  for i = 1, 3 do
    local x, y, w, h = button_rect(i)
    disp.rect(x, y, w, h, BG, true)
    local cx, cy = x + w // 2, y + h // 2
    if i == 2 then
      local r = pressed == 2 and 20 or 22
      disp.circle(cx, cy, r, pressed == 2 and DIM or FG, true)
      local s = 18
      if now.state == "playing" then               -- ||
        disp.rect(cx - 7, cy - s // 2, 5, s, BG, true)
        disp.rect(cx + 2, cy - s // 2, 5, s, BG, true)
      else                                         -- >  (nudged right to look centred)
        triangle(cx - 5, cy - s // 2, s, 1, BG)
      end
    else
      local col = pressed == i and FG or DIM
      local s = 18
      if i == 1 then                               -- |<
        disp.rect(cx - 10, cy - s // 2, 3, s, col, true)
        triangle(cx + 8, cy - s // 2, s, -1, col)
      else                                         -- >|
        triangle(cx - 8, cy - s // 2, s, 1, col)
        disp.rect(cx + 8, cy - s // 2, 3, s, col, true)
      end
    end
  end
end

local function draw_all()
  disp.clear(BG)
  draw_cover_placeholder(); cover_url = nil
  draw_info(); draw_progress(); draw_buttons()
end

local function draw_login()
  disp.clear(BG)
  disp.text(16, 30, "Log in to Spotify", FG, 2)
  local y = 70
  for _, l in ipairs({
    "Open luaboard studio on your computer",
    "(connected to this device) and click",
    "'Open browser and log in'.",
    "",
    "Or run on the computer:",
    "  luaboard browser",
  }) do
    disp.text(16, y, l, DIM); y = y + 12
  end
  pill(16, H - 40, 252, 25, ACCENT)                -- a Spotify-style green pill
  disp.text(28, H - 32, "The device keeps the login", disp.BLACK)
end

local function draw_setup()
  disp.clear(BG)
  disp.text(16, 30, "Spotify: setup needed", FG, 2)
  local y = 70
  for _, l in ipairs({
    "It needs your own Spotify app (developer.",
    "spotify.com > Dashboard), with the redirect URI",
    "http://127.0.0.1:8888/callback.",
    "",
    "Give it the Client ID from a computer:",
    "luaboard secrets set spotify spotify_client <id>",
    "then open the app again.",
    "",
    "Steps: github.com/veikkos/luaboard-marketplace",
  }) do
    disp.text(16, y, l, DIM); y = y + 12
  end
end

---------------------------------------------------------------- Spotify

local function show_cover(url)
  if url == cover_url then return end
  cover_url = url
  if not url then draw_cover_placeholder() return end
  local jpeg, err = sp:cover(url)
  if not jpeg or url ~= cover_url then
    if err then print("spotify: " .. err) end
    return
  end
  local w, h = disp.jpeg_size(jpeg)
  if not w then print("spotify: " .. h) return end
  local scale = 1
  while w // scale > COVER and scale < 8 do scale = scale * 2 end
  if w // scale < COVER or h // scale < COVER then draw_cover_placeholder() end
  disp.jpeg(CX + (COVER - w // scale) // 2, CY + (COVER - h // scale) // 2, jpeg, scale)
end

local function refresh()
  local p, err = sp:player()
  if p == nil then
    status = err
    draw_info()
    return
  end
  status = "ok"
  if p then
    now = { state = p.playing and "playing" or "paused", title = p.title, artist = p.artist, album = p.album,
            progress = p.progress, duration = p.duration, device = p.device }
  else
    now = { state = "idle", artist = "", title = "", album = "", progress = 0, duration = 0, device = "" }
  end
  now_at = sys.millis()
  draw_info(); draw_progress(); draw_buttons()
  show_cover(p and p.cover)
end


local function poll_soon()                          -- after a command: look again
  task(function()
    sleep(500)
    refresh()
  end)
end

local function send(cmd)
  if not sp or logging_in then return end
  if cmd == "toggle" then
    if now.state == "idle" then return end
    now.progress = progress_ms(); now_at = sys.millis()
    now.state = now.state == "playing" and "paused" or "playing"   -- show it right away
    draw_buttons()
    cmd = now.state == "playing" and "play" or "pause"
  end
  task(function()
    local ok, err = sp[cmd](sp)
    if not ok then status = err; draw_info() end
    poll_soon()
  end)
end

------------------------------------------------------------------ input

local CMDS = { "previous", "toggle", "next" }
local KEYS = { A = 1, B = 2, C = 3 }

local function button(b) send(CMDS[KEYS[b]]) end
touch.on("press", button)                                  -- the buttons under the screen
touch.on("long", button)                                   -- a slow press of A or C counts too

local touched   -- the on-screen button under the finger

function loop()
  local hit
  local x, y = touch.read()
  if x then
    for i = 1, 3 do
      local bx, by, bw, bh = button_rect(i)
      if x >= bx and x < bx + bw and y >= by and y < by + bh then hit = i end
    end
  end
  if hit ~= touched then
    if touched and not hit then send(CMDS[touched]) end     -- act on release
    touched = hit
  end
  local shown = hit or KEYS[touch.button() or ""]          -- the strip's buttons show pressed too
  if shown ~= pressed then
    pressed = shown
    if not logging_in then draw_buttons() end
  end
end

timer.every(500, function()
  if now.state == "playing" and not logging_in then draw_progress() end
end)

------------------------------------------------------------------- main

if CLIENT_ID == "" then
  draw_setup()
  print("spotify: no Client ID: luaboard secrets set spotify spotify_client <id>")
  return
end

sp = spotify.new{
  client_id = CLIENT_ID,
  on_login = function(waiting)
    logging_in = waiting
    if waiting then draw_login() else status = "logged in"; draw_all() end
  end,
}
draw_all()

task(function()
  while true do
    refresh()
    sleep(2000)
  end
end)
