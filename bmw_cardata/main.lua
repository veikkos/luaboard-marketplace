-- bmw_cardata: the car from BMW CarData's stream. Setup in README.md.

local login, cardata, car = require("bmw_login"), require("cardata"), require("car")

-- BMW's servers (nil: the defaults in bmw_login.lua and cardata.lua). Tests
-- replace this line to point the app at fakes.
CONFIG = { auth_url = nil, api_url = nil, stream_url = nil, ca = nil }

-- Colours: black, BMW's blue for what is active, red for what needs a look.
local BG, TEXT, SUB, LINE = 0x000000, 0xF2F2F2, 0x8A9099, 0x2A2E35
local PANEL = 0x16181C
local BLUE, WARN = 0x2E7FE8, 0xE5484D
local function rgb565(c) return ((c >> 19) << 11) | (((c >> 10) & 63) << 5) | ((c >> 3) & 31) end
local BG565 = rgb565(BG)
local PAGES = 2
local RETRY_MIN, RETRY_MAX = 30 * 1000, 5 * 60 * 1000
local REFUSED_MSG = "BMW refuses the stream. Is another app using this account?"
local REFUSED_LOGIN_MSG = "BMW refuses the stream login. Is CarData Stream on for this client ID?"
local PIC_W, PIC_H = 250, 86           -- the most the picture takes on page 1
local FOOTER_Y = 212                   -- the bottom line: the page dots, or a problem
local PIC_STORE_MAX = 48 * 1024        -- bytes of picture kept in `store`
local IDLE_MS = 60 * 1000              -- back to page 1 after this long untouched

-- What the screen shows; UI and redraw() are globals for tests and the console.
UI = { mode = "starting", page = 1, live = false, code = nil, uri = nil, code_until = nil, status = "",
       soc = nil, model = nil, picture = "none", connects = 0, refreshes = 0, refusals = 0, wait = 0 }

local CLIENT = secrets.get("bmw_client")
if CLIENT == "" then CLIENT = nil end

local state = car.decode(store.get("state"))
local dirty = false                    -- state changed since it was saved
local vin = store.get("vin")
UI.model = store.get("model")
UI.soc = car.view(state, sys.time()).soc
if CLIENT and secrets.get("bmw_refresh") then UI.mode = "car" end

-- The car's picture, cropped, as disp.image takes it: { px, w, h }.
local pic
do
  local px, w, h = store.get("picture"), store.get("picture_w"), store.get("picture_h")
  if type(px) == "string" and math.type(w) == "integer" and math.type(h) == "integer" and #px == w * h * 2 then
    pic = { px = px, w = w, h = h }
    UI.picture = "stored"
  end
end

---------------------------------------------------------------- drawing

local function title(s)
  disp.text(12, 12, s, TEXT, 2)
end

local function draw_setup()
  title("BMW CarData")
  disp.text(12, 56, "It needs your own CarData client ID (the", TEXT, 1)
  disp.text(12, 70, "README says where it comes from).", TEXT, 1)
  disp.text(12, 98, "Give it to the app from a computer:", TEXT, 1)
  disp.text(12, 116, "luaboard secrets set bmw_cardata bmw_client <id>", BLUE, 1)
  disp.text(12, 134, "then open the app again.", TEXT, 1)
  disp.text(12, 186, "Steps: github.com/veikkos/luaboard-marketplace", SUB, 1)
end

local function draw_login()
  title("Log in to My BMW")
  disp.text(12, 46, "On your phone, open", TEXT, 1)
  local uri = (UI.uri or ""):gsub("^https?://", "")
  local y = 60
  while #uri > 24 do                    -- 24 characters at double size: break before a "/"
    local cut = uri:sub(2, 25):match("^.*()/") or 24
    disp.text(12, y, uri:sub(1, cut), BLUE, 2)
    uri, y = uri:sub(cut + 1), y + 18
  end
  disp.text(12, y, uri, BLUE, 2)
  disp.text(12, y + 22, "and enter the code:", TEXT, 1)
  disp.rect(12, 124, 296, 54, PANEL, true)
  disp.rect(12, 124, 296, 54, LINE)
  disp.text(disp.W // 2, 134, UI.code or "", TEXT, 5, nil, "center")
  if UI.code_until then
    local min = math.max(0, (UI.code_until - sys.millis() + 59999) // 60000)
    disp.text(disp.W // 2, 190, "The code is valid for " .. min .. " min.", TEXT, 1, nil, "center")
  end
  if UI.status ~= "" then disp.text(disp.W // 2, 210, UI.status, WARN, 1, nil, "center") end
end

local function draw_message(head, lines, color)
  title("BMW CarData")
  disp.text(12, 56, head, color, 2)
  local y = 88
  for _, s in ipairs(lines) do
    for _, l in ipairs(disp.wrap(s, disp.W - 24)) do disp.text(12, y, l, SUB, 1) y = y + 14 end
    y = y + 6
  end
end

local function name()
  if UI.model then return UI.model end
  if vin then return "..." .. vin:sub(-7) end
  return "BMW CarData"
end

-- A warning triangle with "!" in it, `size` px high and wide, its top at
-- (x, y). Its middle is the two columns cx - 1 and cx, as is the "!".
local function warn_icon(x, y, size)
  local cx = x + size // 2
  for i = 0, size - 1 do
    local half = (2 * i * (size // 2 - 1) + size - 1) // (2 * (size - 1))
    local cut = i == size - 1 and 1 or 0             -- rounded bottom corners
    disp.line(cx - 1 - half + cut, y + i, cx + half - cut, y + i, TEXT)
  end
  disp.rect(cx - 1, y + size // 3, 2, size // 3, BG, true)
  disp.rect(cx - 1, y + size - 4, 2, 2, BG, true)
end

-- What needs a look, for the mark on every page.
local function warnings(v)
  local tyres = v.tyres_low == true
  return tyres or (v.openings and #v.openings > 0) or v.lock == "unlocked", tyres
end

-- The top line: the car's name (cut to fit), a warning mark, and how old the
-- values are, after a dot: blue while the stream is connected, a ring if not.
local function header(v)
  local warn, tyres = warnings(v)
  UI.warning, UI.tyre_alarm = warn and true or false, tyres
  local age = v.age or (UI.live and "connected" or "offline")
  UI.header = age
  local x = 308 - disp.text(308, 15, age, v.stale and WARN or SUB, 1, nil, "right")
  disp.circle(x - 9, 18, 3, UI.live and BLUE or SUB, UI.live)
  if warn then warn_icon(x - 34, 9, 16) end
  local s, room = name(), (warn and x - 34 or x - 12) - 6 - 12
  while disp.text_width(s, 2) > room do s = s:sub(1, (utf8.offset(s, -1) or #s) - 1) end
  disp.text(12, 12, s, TEXT, 2)
  UI.name = s
end

-- The bottom line: the page dots, or a problem in red.
local function footer()
  disp.rect(0, FOOTER_Y, disp.W, disp.H - FOOTER_Y, BG, true)
  if UI.status ~= "" then
    local lines = disp.wrap(UI.status, disp.W - 24)
    local y = #lines > 1 and 214 or 224
    for i = 1, math.min(2, #lines) do disp.text(disp.W // 2, y + (i - 1) * 12, lines[i], WARN, 1, nil, "center") end
    return
  end
  for p = 1, PAGES do disp.circle(160 - (PAGES - 1) * 6 + (p - 1) * 12, 230, 3, p == UI.page and TEXT or LINE, true) end
end

-- The battery bar, with the charging target as a mark.
local function bar(v, x0, y, w, h)
  disp.rect(x0, y, w, h, LINE, true)
  if v.soc then
    local fill = math.max(0, math.min(w, math.floor(w * v.soc / 100 + 0.5)))
    disp.rect(x0, y, fill, h, v.is_charging and BLUE or TEXT, true)
  end
  if v.target then
    local tx = x0 + math.floor(w * v.target / 100 + 0.5)
    disp.rect(math.min(tx, x0 + w - 2), y - 3, 2, h + 6, SUB, true)
  end
end

-- Page 1: the car, battery, range, charging.
local function page1(v, main)
  local y = 40
  if pic then
    local h = math.min(pic.h, PIC_H)            -- taller only if still so at 1/8
    disp.image((disp.W - pic.w) // 2, y, pic.w, h, h < pic.h and pic.px:sub(1, pic.w * h * 2) or pic.px)
    y = y + h + 4
  else
    y = 54
  end
  local big = pic and 6 or 7
  local soc = v.soc and tostring(math.floor(v.soc + 0.5)) or "-"
  disp.text(12, y, soc, main, big)
  disp.text(12 + disp.text_width(soc, big) + 4, y + 7 * big - 21, "%", SUB, 3)
  disp.text(308, y + 7 * big - 21, v.range_km and car.fmt_km(v.range_km) or "- km", main, 3, nil, "right")
  y = y + 7 * big + 4
  bar(v, 12, y, 296, 6)
  y = y + 12
  disp.text(12, y, v.charging or "-", v.is_charging and main or SUB, 2)
  if v.power_kw then
    local kw = string.format("%.1f kW", v.power_kw) .. (v.method and (" " .. v.method) or "")
    disp.text(308, y, kw, BLUE, 2, nil, "right")
  end
  y = y + 17
  local left = v.is_charging and v.left or v.plug
  local target = v.target and ("target " .. math.floor(v.target + 0.5) .. " %")
  if left then disp.text(12, y, left, SUB, 1) end
  if target then disp.text(308, y, target, SUB, 1, nil, "right") end
  UI.line1 = (left or "") .. " | " .. (target or "")
end

-- Page 2: the car from above. What is open shows red; each tyre's pressure
-- by its wheel, red with a warning mark when low; the lock in the middle.
local CAR = { x = 125, y = 44, w = 70, h = 124 }
local function page2(v, main)
  local o = v.open or {}
  local function col(id, off) return (o[id] == "open" or o[id] == "half") and WARN or off end
  local x, y, w, h = CAR.x, CAR.y, CAR.w, CAR.h
  local wheels = { { x - 7, y + 20 }, { x + w + 1, y + 20 }, { x - 7, y + h - 46 }, { x + w + 1, y + h - 46 } }
  for i, wh in ipairs(wheels) do
    local low = v.tyre_low and v.tyre_low[i]
    disp.rect(wh[1], wh[2], 6, 26, low and WARN or SUB, true)
    if v.tyres then
      local text, ty = v.tyres[i], wh[2] + 6
      if i % 2 == 1 then
        disp.text(x - 16, ty, text, low and WARN or main, 2, nil, "right")
        if low then warn_icon(x - 16 - disp.text_width(text, 2) - 20, ty - 1, 16) end
      else
        disp.text(x + w + 16, ty, text, low and WARN or main, 2)
        if low then warn_icon(x + w + 16 + disp.text_width(text, 2) + 4, ty - 1, 16) end
      end
    end
  end
  if v.tyres then
    local targets = { v.target_front, v.target_rear }
    UI.targets = (targets[1] or "-") .. "|" .. (targets[2] or "-")
    if targets[1] or targets[2] then
      for i = 1, 2 do
        if targets[i] then
          disp.text(x - 16, wheels[i * 2 - 1][2] + 24, "target " .. targets[i] .. " bar", SUB, 1, nil, "right")
        end
      end
    else
      disp.text(x - 16, y + h // 2 - 4, "bar", SUB, 1, nil, "right")
    end
  end
  disp.rect(x, y, w, h, LINE, true)
  disp.rect(x, y, w, h, SUB)
  disp.rect(x + 4, y + 3, w - 8, 22, col("hood", PANEL), true)
  disp.rect(x + 4, y + h - 23, w - 8, 20, col("trunk", PANEL), true)
  disp.rect(x + 9, y + 30, w - 18, h - 58, PANEL, true)
  if o.sunroof == "open" or o.sunroof == "half" then disp.rect(x + 22, y + 46, w - 44, 18, WARN, true) end
  local doors = { { "door_fl", "window_fl", x, y + 30 }, { "door_fr", "window_fr", x + w - 3, y + 30 },
                  { "door_rl", "window_rl", x, y + 66 }, { "door_rr", "window_rr", x + w - 3, y + 66 } }
  for _, d in ipairs(doors) do
    disp.rect(d[3], d[4], 3, 34, col(d[1], SUB), true)
    local wx = d[3] == x and x + 5 or x + w - 7
    disp.rect(wx, d[4] + 4, 2, 26, col(d[2], LINE), true)
  end
  local lx, ly = x + w // 2, y + h // 2 + 6
  if v.lock then
    local c = v.lock == "unlocked" and WARN or main
    disp.rect(lx - 7, ly, 14, 11, c, true)
    disp.circle(lx, ly, 5, c)
    disp.rect(lx - 7, ly + 1, 14, 2, c, true)
    if v.lock == "unlocked" then disp.rect(lx - 7, ly - 6, 4, 6, PANEL, true) end
  end
  -- below the car: the lock and what is open; odometer and service; climate
  local dot = "  \xc2\xb7  "
  local lines = {}
  local line = v.lock and (v.lock:sub(1, 1):upper() .. v.lock:sub(2)) or nil
  if v.openings then
    local n = #v.openings
    local open = n == 0 and "all closed" or n == 1 and v.openings[1]:lower() or (v.openings[1]:lower() .. " +" .. (n - 1))
    line = line and (line .. dot .. open) or (open:sub(1, 1):upper() .. open:sub(2))
  end
  if line then lines[#lines + 1] = { line, (v.openings and #v.openings > 0 or v.lock == "unlocked") and WARN or main } end
  local odo = v.odometer_km and car.fmt_km(v.odometer_km)
  local service = v.service_km and ("service in " .. car.fmt_km(v.service_km))
  if odo or service then lines[#lines + 1] = { odo and service and (odo .. dot .. service) or odo or service, SUB } end
  if v.climate then lines[#lines + 1] = { v.climate, BLUE } end
  UI.below = {}
  for i, l in ipairs(lines) do
    local ly = 176 + (i - 1) * 12
    UI.below[i] = l[1]
    disp.text(disp.W // 2, ly, l[1], l[2], 1, nil, "center")
  end
end

local function draw_car()
  local v = car.view(state, sys.time())
  local main = UI.live and TEXT or SUB
  header(v)
  if UI.page == 2 then page2(v, main) else page1(v, main) end
  footer()
end

function redraw()
  disp.clear(BG)
  if UI.confirm_at and UI.mode ~= "car" and UI.mode ~= "error" then UI.confirm_at = nil end
  if UI.confirm_at then
    draw_message("Log out?", { "Hold again or press o to log out.", "A tap cancels." }, TEXT)
  elseif UI.mode == "setup" then draw_setup()
  elseif UI.mode == "login" then draw_login()
  elseif UI.mode == "code_expired" then
    draw_message("Not logged in", { UI.status:gsub("^%l", string.upper) .. ".", "Tap or press o for a new code." }, TEXT)
  elseif UI.mode == "error" then draw_message("Can't go on", { UI.status }, WARN)
  elseif UI.mode == "car" then draw_car()
  else draw_message("Starting", {}, SUB) end
end

---------------------------------------------------------------- data

-- The state goes to `store` at most once a minute: the picture shares the
-- file, and every save rewrites it.
local function save_state()
  if dirty then
    store.set("state", car.encode(state))
    dirty = false
  end
end

-- Each value is logged: where it came from, and how long ago the car
-- recorded it. "(not used)" marks one the app doesn't know, the first time.
local function on_data(data, src)
  local unused, keys, now = {}, {}, sys.time()
  for _, key in ipairs(car.merge(state, data)) do unused[key] = true end
  for key, e in pairs(data) do
    if type(key) == "string" and type(e) == "table" then keys[#keys + 1] = key end
  end
  table.sort(keys)
  for _, key in ipairs(keys) do
    local e = data[key]
    local ts = car.parse_time(e.timestamp)
    print(string.format("bmw: %s %s = %s%s%s", src or "stream", (key:gsub("^vehicle%.", "")), tostring(e.value),
      ts and now and string.format(", %d s old", math.floor(now - ts)) or "", unused[key] and " (not used)" or ""))
  end
  dirty = true
  UI.soc = car.view(state, sys.time()).soc
  redraw()
end

---------------------------------------------------------------- touch

local new_code = false
local last_touch = sys.millis()
local logout_req = false               -- confirmed: the main task logs out
local CONFIRM_MS = 10 * 1000

local function set_page(p)
  last_touch = sys.millis()
  if UI.page ~= p then
    UI.page = p
    if UI.mode == "car" then redraw() end
  end
end

-- Holding the screen asks to log out: o logs out, anything else cancels.
local function cancel()
  last_touch, UI.confirm_at = sys.millis(), nil
  redraw()
end

touch.on("press", function(b)
  if UI.confirm_at then
    if b == "B" then UI.confirm_at, logout_req = nil, true redraw() else cancel() end
  elseif b == "B" and UI.mode == "code_expired" then new_code = true
  elseif b == "A" then set_page(math.max(1, UI.page - 1))
  elseif b == "C" then set_page(math.min(PAGES, UI.page + 1)) end
end)
touch.on("swipe", function(dir)
  if UI.confirm_at then cancel()
  elseif dir == "left" then set_page(math.min(PAGES, UI.page + 1))
  elseif dir == "right" then set_page(math.max(1, UI.page - 1))
  else last_touch = sys.millis() end
end)
-- By touch what o does too, for a board without the buttons: a tap asks for
-- a new code, and a second hold logs out.
touch.on("tap", function()
  if UI.confirm_at then cancel()
  elseif UI.mode == "code_expired" then new_code = true
  else last_touch = sys.millis() end
end)
touch.on("hold", function()
  last_touch = sys.millis()
  if UI.confirm_at then
    UI.confirm_at, logout_req = nil, true
    redraw()
  elseif UI.mode == "car" or UI.mode == "error" then
    UI.confirm_at = sys.millis()
    redraw()
  end
end)
timer.every(1000, function()
  if UI.confirm_at and sys.millis() - UI.confirm_at >= CONFIRM_MS then cancel() end
  if UI.page ~= 1 and sys.millis() - last_touch >= IDLE_MS then set_page(1) end
end)

if not CLIENT then
  UI.mode = "setup"
  redraw()
  return
end

local L = login.new{
  client_id = CLIENT, auth_url = CONFIG.auth_url,
  on_code = function(c)
    if c then
      UI.mode, UI.code, UI.uri, UI.code_until, UI.status = "login", c.user_code, c.uri, c.expires_at, ""
      UI.live = false
    else
      UI.code = nil
    end
    redraw()
  end,
}
local C = cardata.new{ api_url = CONFIG.api_url, stream_url = CONFIG.stream_url, ca = CONFIG.ca }

local client, client_tok          -- the stream and the tokens it logged in with
local rest_done = false           -- the start's REST call for fresh values
local model_tried = false         -- basicData asked once per run, not at every refresh
local picture_tried = false       -- /image asked at most once per run
local refused_since, refused_msg  -- the stream refuses us since then, and why
local stream_delay = 3000         -- the wait before the next connect after a failed one
local up_at = 0                   -- when the stream last connected

local function close_stream()
  if client then
    client.on_close = nil
    client:close()
  end
  client, client_tok = nil, nil
  UI.live = false
end

-- One try at the stream. Returns the client, or nil and how long to wait
-- before the next try. A refusal ("not authorized": BMW allows one
-- connection per account and remembers ours for a few seconds after it
-- ends) waits 3 s, doubling to 60 s; after 5 minutes of refusals the screen
-- says why. A refused password with a token over a minute old asks for a
-- refresh first; with a fresh token it is a refusal like the other. The
-- wait goes back to 3 s once a connection has lasted a minute.
local function connect(tok)
  local c, err = C:stream(tok, vin, on_data)
  if c then
    UI.connects, UI.live, UI.status = UI.connects + 1, true, ""
    refused_since, refused_msg, up_at = nil, nil, sys.millis()
    c.on_close = function() UI.live = false redraw() end
    redraw()
    return c
  end
  err = tostring(err)
  local bad_pw = err:find("bad user name or password", 1, true) ~= nil
  if bad_pw and sys.millis() - (tok.at or 0) > 60000 then
    L.refresh_at = 0                    -- an old id token: refresh, then try again
    return nil, 0
  end
  UI.live = false
  if bad_pw or err:find("not authorized", 1, true) then
    UI.refusals = UI.refusals + 1
    refused_since = refused_since or sys.millis()
    refused_msg = bad_pw and REFUSED_LOGIN_MSG or REFUSED_MSG
    if sys.millis() - refused_since >= 5 * 60 * 1000 then UI.status = refused_msg end
  else
    UI.status = "offline"
    print("bmw: stream: " .. err)
  end
  redraw()
  local wait = stream_delay
  stream_delay = math.min(stream_delay * 2, 60000)
  return nil, wait
end

-- The picture drawn shrunk by `scale` onto the background, read back and
-- cropped to the car: pixels, width, height, or nil and why.
local function render(png, pw, ph, scale)
  local w, h = (pw + scale - 1) // scale, (ph + scale - 1) // scale
  disp.rect(0, 0, w, h, BG, true)
  local ok, err = disp.png(0, 0, png, scale)
  if not ok then return nil, err end
  local px, cw, ch = car.crop(disp.grab(0, 0, w, h), w, h, BG565, 4)
  if not px then return nil, "the picture is empty" end
  return px, cw, ch
end

-- The car's picture from BMW, shrunk to fit page 1 and kept in `store`. A
-- failure is tried again the next UTC day. No wait in between drawing and
-- reading back, so the screen never shows it.
local function fetch_picture(tok)
  local now = sys.time()
  local today = now and car.utc_day(now)
  if today and store.get("picture_day") == today then return end
  if today then store.set("picture_day", today) end
  local png, err = C:picture(tok.access, vin)
  if not png then print("bmw: no picture: " .. tostring(err)) return end
  local pw, ph = disp.png_size(png)
  if not pw then print("bmw: the picture can't be read") return end
  local scale = 1
  while scale < 8 and (pw + scale - 1) // scale > PIC_W do scale = scale * 2 end
  local px, w, h = render(png, pw, ph, scale)
  while px and h > PIC_H and scale < 8 do
    scale = scale * 2
    px, w, h = render(png, pw, ph, scale)
  end
  if not px then print("bmw: no picture: " .. tostring(w)) redraw() return end   -- w: why
  pic = { px = px, w = w, h = h }
  if #px < PIC_STORE_MAX then
    store.set("picture", px)
    store.set("picture_w", w)
    store.set("picture_h", h)
  end
  UI.picture = "fetched"
  redraw()
end

-- What the start needs once: the car, its name, and fresh values if the
-- saved ones are old. Returns false and the reason when there is no car yet.
local function first_steps(tok)
  if not vin then
    local err
    vin, err = C:vin(tok.access)
    if not vin then return false, err end
  end
  if not UI.model and not model_tried then
    model_tried = true
    UI.model = C:model(tok.access, vin)
  end
  if not rest_done then
    rest_done = true
    if car.needs_rest(state, sys.time()) then
      local id, err = C:container(tok.access)
      local snap
      if id then snap, err = C:snapshot(tok.access, vin, id) end
      if snap then
        on_data(snap, "rest")
        save_state()
      else
        print("bmw: no values from REST: " .. tostring(err))
      end
    end
  end
  if not pic and not picture_tried then
    picture_tried = true
    fetch_picture(tok)
  end
  return true
end

-- A reason short enough for the status line.
local function short(why)
  why = tostring(why)
  if why == "daily limit" then return "BMW's daily API limit reached" end
  if why:find("cannot", 1, true) or why:find("timeout", 1, true) then return "offline" end
  return why:sub(1, 36)
end

-- Sleep `ms`, or until a log out is asked for.
local function pause(ms)
  local stop = sys.millis() + ms
  while sys.millis() < stop and not logout_req do sleep(250) end
end

-- Forget the login and the car, keep the day's API count.
local function log_out()
  logout_req = false
  close_stream()
  L:logout()
  for _, k in ipairs(store.keys()) do
    if k ~= "rest_budget" then store.set(k, nil) end
  end
  state, dirty, vin, pic = {}, false, nil, nil
  rest_done, model_tried, picture_tried = false, false, false
  UI.mode, UI.status, UI.model, UI.soc, UI.picture, UI.page = "starting", "", nil, nil, "none", 1
  print("bmw: logged out")
  redraw()
end

local function main()
  local retry = RETRY_MIN
  while true do
    if logout_req then log_out() end
    local tok, err, kind = L:tokens()
    if tok then
      if UI.mode ~= "car" then UI.mode = "car" redraw() end
      local ok, why = first_steps(tok)
      if not ok then
        if why == "no car on this BMW account" then
          UI.mode, UI.status = "error", "No car on this BMW account. The car's primary user has to log in."
          redraw()
          pause(math.huge)
        else
          UI.status = short(why)
          print("bmw: " .. tostring(why))
          redraw()
          pause(retry)
          retry = math.min(retry * 2, RETRY_MAX)
        end
      else
        retry = RETRY_MIN
        if client and client_tok ~= tok then             -- refreshed: log in again with the new id token
          close_stream()
          UI.refreshes = UI.refreshes + 1
        end
        local wait = 0
        if client and not client.connected then          -- dropped: wait before the next connect
          client, client_tok = nil, nil
          if sys.millis() - up_at >= 60000 then stream_delay = 3000 end
          wait = stream_delay
          stream_delay = math.min(stream_delay * 2, 60000)
        elseif not client then
          client, wait = connect(tok)
          client_tok = client and tok or nil
        end
        UI.wait = wait or 0
        -- until the refresh is due, the stream drops, or the next try
        local stop = client and L.refresh_at or math.min(L.refresh_at, sys.millis() + (wait or 0))
        while sys.millis() < stop and not (client and not client.connected) and not logout_req do sleep(250) end
      end
    elseif kind == "code" then
      close_stream()
      UI.mode, UI.status = "code_expired", tostring(err)
      redraw()
      new_code = false
      while not new_code do sleep(100) end
    elseif kind == "network" then
      UI.status = "offline"
      print("bmw: login: " .. tostring(err))
      redraw()
      pause(retry)
      retry = math.min(retry * 2, RETRY_MAX)
    else
      close_stream()
      UI.mode, UI.status = "error", tostring(err)
      redraw()
      pause(math.huge)
    end
  end
end

redraw()
timer.every(30000, redraw)              -- the age at the top right moves on
timer.every(60000, save_state)
task(main)
