-- samsung_tv: a remote for a Samsung TV (Tizen: 2016 and later) on the same
-- network. Power, volume and mute, the arrows, home and back, playback, and
-- the TV's apps. It talks to the TV the way Samsung's own phone app does:
-- the keys go over the TV's remote-control channel (a WebSocket, TLS), and
-- what the TV is doing is asked over its plain HTTP interface.
--
-- The first time, the TV asks on its screen whether to allow "luaboard":
-- choose Allow there. The token it then gives is kept as a secret. Needs
-- firmware with Lua API 2 (ws, cert_name, net.udp).
--
-- By touch: tap a key, hold one to repeat it. A swipe to the side, or the
-- key at the bottom right, changes between the remote and the apps. On a
-- board with buttons, A and C are volume down and up, B is mute.
--
-- `host` in secrets.env names the TV's address, for a network where it
-- isn't found by itself.

local http, json = require("http"), require("json")
local ws = require("ws")

-- The TV's certificate is issued by Samsung's own authority ("SmartViewSDK
-- Root CA G2", below as the TVs send it), to this name and not to the TV's
-- address: both are given to the connection to check.
local CERT_NAME = "Samsung SmartViewSDK Cert. G2"
local CA = [[
-----BEGIN CERTIFICATE-----
MIIDsDCCApigAwIBAgIUMJRaXn1A8EKOpYBPUKKcBZs84dAwDQYJKoZIhvcNAQEN
BQAwbzELMAkGA1UEBhMCS1IxHDAaBgNVBAoME1NhbXN1bmcgRWxlY3Ryb25pY3Mx
IDAeBgNVBAsMF1Zpc3VhbCBEaXNwbGF5IEJ1c2luZXNzMSAwHgYDVQQDDBdTbWFy
dFZpZXdTREsgUm9vdCBDQSBHMjAgFw0yMjA0MDcwMTMwMTlaGA8yMDcyMDMyNTAx
MzAxOVowbzELMAkGA1UEBhMCS1IxHDAaBgNVBAoME1NhbXN1bmcgRWxlY3Ryb25p
Y3MxIDAeBgNVBAsMF1Zpc3VhbCBEaXNwbGF5IEJ1c2luZXNzMSAwHgYDVQQDDBdT
bWFydFZpZXdTREsgUm9vdCBDQSBHMjCCASIwDQYJKoZIhvcNAQEBBQADggEPADCC
AQoCggEBAK6fAHwocr4JdCupjzkfR35Yc7vjXkNWlgULN2wlEq+rK3DDdEkj3GWZ
X6zk9sTLyLP3ESQqWiQgU8Ph+IRPbchEi7safr+X+VdvNWb6cyayedVA2aL8pnxS
OrlCrT7+0sWMkk9Mlc8aSVDW1hwQY7H205b77qG+N/u5F2YBevcYYi/V5RkGc67q
RQ3pX+TpiiCpmuSIlNYae0mQT/NM2+x2mVJtszOlIJn1qWlpdsd/DyEWpTHeknoz
OaFtc4vTeT0LD3FPK6TQDBU3xDmkItavtVEd1eQAwApQcjRDef8XyzvMFVLhYKyJ
0WLMhWXjB1az14w6fZ9kdb4kmPpf9skCAwEAAaNCMEAwDwYDVR0TAQH/BAUwAwEB
/zAOBgNVHQ8BAf8EBAMCAQYwHQYDVR0OBBYEFMetCgEe7JwvWp/J1O6cRw4Bx9OA
MA0GCSqGSIb3DQEBDQUAA4IBAQCfR6LsaDacG4RczhNlL9L2dy+AKS1/MEtZQXuD
EooAQG69vIoO6j3hvFMJP+YsrrOhS3WrjOhKAX2T6DmI/WwNqZiJMoDbTDhPaF51
+npYX9Q4ZA7fhKADro988IF0e9kTKgOG7FeXg2VPyJFwxRgHTE5P0hUPfng9eyLl
hQX2aa14VsB+IvauGctHPqPiMsVTAhbnT6twe+q7GDjKpweceuw5s/zYby/gH0wH
WZTNCmk54BB+BEtYEzjW1jeyLoAHh4D00h0gauNTHUrN/Dy3QMYOAcfxLLVvZTNi
/9+yY10pPCpi5L/W13klJP28BQZBG1vQvr0k0NkKsZSpQClI
-----END CERTIFICATE-----
]]

local NAME = "luaboard"                          -- what the TV's Allow prompt calls this device
local INFO_MS = 4000                             -- how often the TV is asked how it is
local KEY_REPEAT_MS = 180                        -- a held key, again this often

-- Apps by the id Samsung's store gives them. Only those the TV has are shown.
local APPS = {
  { "Netflix", "3201907018807" }, { "YouTube", "111299001912" }, { "Prime Video", "3201910019365" },
  { "Disney+", "3201901017640" }, { "Apple TV", "3201807016597" }, { "HBO Max", "3202301029760" },
  { "Spotify", "3201606009684" }, { "Viaplay", "11111300404" }, { "Twitch", "3202203026841" },
  { "Plex", "3201512006963" },
}

local W, H = disp.W, disp.H
local BG, FG = disp.rgb(10, 14, 24), disp.WHITE
local DIM, DIMMER = disp.rgb(150, 160, 175), disp.rgb(90, 100, 116)
local LINE = disp.rgb(60, 72, 92)
local KEY, KEY_DOWN, KEY_OFF = disp.rgb(34, 44, 62), disp.rgb(70, 120, 190), disp.rgb(22, 28, 40)
local ON, STANDBY, OFF = disp.rgb(70, 210, 120), disp.rgb(255, 180, 60), disp.rgb(120, 128, 140)
local ACCENT, WARN, RED = disp.rgb(90, 180, 255), disp.rgb(255, 150, 60), disp.rgb(235, 90, 80)

UI = { page = "remote", note = nil, sent = 0 }   -- global: tests read it
local tv = { ip = nil, name = nil, mac = nil, power = nil }   -- power: "on", "standby", "off", nil (not asked yet)
local chan                                       -- the remote-control channel, when it's open
local chan_state = "closed"                      -- "closed", "connecting", "allow" (the TV is asking), "ready", "refused"
local installed = {}                             -- of APPS, those the TV has: { name, id, visible }
local showing                                    -- the app on the screen, by name

---------------------------------------------------------------- the TV

local function unescape(s)
  return (tostring(s):gsub("&quot;", '"'):gsub("&amp;", "&"):gsub("&#39;", "'"):gsub("&lt;", "<"):gsub("&gt;", ">"))
end

local function remember()
  store.set("tv", json.encode({ ip = tv.ip, name = tv.name, mac = tv.mac }))
end

-- The TV's own account of itself, or nil when it doesn't answer.
local function describe(ip)
  local st, body = http.get("http://" .. ip .. ":8001/api/v2/", nil, { timeout = 2500 })
  local d = st == 200 and json.decode(body)
  local dev = type(d) == "table" and d.device
  if type(dev) ~= "table" or dev.type ~= "Samsung SmartTV" then return nil end
  return dev
end

-- Find a TV: ask the network who is there (SSDP) and take the first that
-- says it's a Samsung TV.
local function discover()
  local u = net.udp()
  if not u then return nil end
  local ask = table.concat({
    "M-SEARCH * HTTP/1.1", "HOST: 239.255.255.250:1900", 'MAN: "ssdp:discover"', "MX: 1", "ST: ssdp:all", "", "",
  }, "\r\n")
  local found
  if u:send(ask, "239.255.255.250", 1900) then
    local tried = {}
    local deadline = sys.millis() + 2500
    while not found and sys.millis() < deadline do
      local data, ip = u:wait(deadline - sys.millis())
      if data and data:find("Samsung", 1, true) and not tried[ip] then
        tried[ip] = true
        if describe(ip) then found = ip end
      end
    end
  end
  u:close()
  return found
end

local function locate()
  local host = secrets.get("host")
  if host and host ~= "" then tv.ip = host return end
  if not tv.ip then
    local k = json.decode(store.get("tv") or "null")
    if type(k) == "table" and type(k.ip) == "string" then tv.ip, tv.name, tv.mac = k.ip, k.name, k.mac end
  end
  if not tv.ip then tv.ip = discover() end
end

local misses = 0
local function ask_tv()
  local dev = describe(tv.ip)
  if dev then
    misses = 0
    local name, mac = unescape(dev.name or "TV"), dev.wifiMac
    if name ~= tv.name or mac ~= tv.mac then tv.name, tv.mac = name, mac; remember() end
    tv.power = dev.PowerState == "standby" and "standby" or "on"   -- (older TVs don't say: they answer only when on)
  else
    misses = misses + 1
    if misses >= 2 then tv.power = "off" end
  end
end

task(function()
  local looked = -30000
  while true do
    if not tv.ip then locate() end
    if tv.ip then
      ask_tv()
      -- Off for a while: its address may have changed. Look again now and then.
      local host = secrets.get("host")
      if tv.power == "off" and (not host or host == "") and sys.millis() - looked > 30000 then
        looked = sys.millis()
        local ip = discover()
        if ip and ip ~= tv.ip then tv.ip = ip; remember() end
      end
    end
    sleep(tv.ip and INFO_MS or 3000)
  end
end)

-- Which of the apps the TV has, and which one is on the screen: one asked a second.
task(function()
  local i = 0
  while true do
    if tv.ip and tv.power == "on" then
      i = i % #APPS + 1
      local name, id = APPS[i][1], APPS[i][2]
      local st, body = http.get("http://" .. tv.ip .. ":8001/api/v2/applications/" .. id, nil, { timeout = 2500 })
      local d = st == 200 and json.decode(body)
      local at
      for k, a in ipairs(installed) do if a.id == id then at = k end end
      if type(d) == "table" then
        if not at then
          installed[#installed + 1] = { name = name, id = id }
          at = #installed
        end
        installed[at].visible = d.visible == true
        if d.visible == true then showing = name elseif showing == name then showing = nil end
      elseif st == 404 and at then
        table.remove(installed, at)
      end
      sleep(1000)
    else
      showing = nil
      sleep(1000)
    end
  end
end)

---------------------------------------------------------------- the remote-control channel

local function channel_path()
  local token = secrets.get("token")
  return "/api/v2/channels/samsung.remote.control?name=" .. crypto.base64(NAME) ..
         (token and token ~= "" and "&token=" .. token or "")
end

task(function()
  while true do
    if tv.ip and tv.power == "on" and chan_state ~= "refused" then
      chan_state = secrets.get("token") and "connecting" or "allow"
      local w, err = ws.connect("wss://" .. tv.ip .. ":8002" .. channel_path(), { ca = CA, cert_name = CERT_NAME })
      if not w then
        -- A TV whose certificate isn't Samsung's G2 one (an older model, it may be) can't be checked.
        UI.note = tostring(err):find("not trusted") and "this TV's certificate isn't one the app knows" or err
        chan_state = "closed"
        sleep(3000)
      else
        UI.note = nil
        -- Its first word: "connect" (with a token, the first time), or that
        -- nobody allowed it. Then it stays open for the keys.
        local deadline = sys.millis() + 60000
        while w do
          local msg, e = w:recv(1000)
          local m = msg and json.decode(msg)
          local ev = type(m) == "table" and m.event
          if ev == "ms.channel.connect" then
            local token = type(m.data) == "table" and m.data.token
            if token then secrets.set("token", tostring(token)) end
            chan, chan_state = w, "ready"
          elseif ev == "ms.channel.unauthorized" or ev == "ms.channel.timeOut" then
            -- Not allowed (or nobody answered): the token it had, if any, is no good.
            secrets.set("token", nil)
            chan_state = "refused"
            w:close()
            w = nil
          elseif not msg and e ~= "timeout" then  -- the TV closed it (turned off, most likely)
            w = nil
          elseif tv.power ~= "on" then             -- gone without closing it (unplugged): don't keep a dead one
            w:close()
            w = nil
          elseif chan_state ~= "ready" and sys.millis() > deadline then
            w:close()
            w = nil
          end
        end
        chan = nil
        if chan_state ~= "refused" then chan_state = "closed" end
        sleep(1000)
      end
    else
      sleep(500)
    end
  end
end)

local function send_key(key)
  if not chan then return false end
  local ok = chan:send(json.encode({
    method = "ms.remote.control",
    params = { Cmd = "Click", DataOfCmd = key, Option = "false", TypeOfRemote = "SendRemoteKey" },
  }))
  if ok then UI.sent = UI.sent + 1 end
  return ok
end

-- Wake a TV that is off: the "magic packet" its network chip listens for
-- (six bytes of 255, then its address sixteen times), to everyone.
local function wake()
  local mac = tv.mac and tv.mac:gsub("[^%x]", "")
  if not mac or #mac ~= 12 then return false end
  local bytes = mac:gsub("%x%x", function(h) return string.char(tonumber(h, 16)) end)
  local u = net.udp()
  if not u then return false end
  local ok = u:send(string.rep("\255", 6) .. string.rep(bytes, 16), "255.255.255.255", 9)
  u:close()
  return ok
end

local function power()
  if tv.power == "on" and chan then return send_key("KEY_POWER") end
  if tv.power == "on" then UI.note = "not connected to the TV yet" return false end
  if chan then send_key("KEY_POWER") end         -- (in standby the channel may still be open)
  return wake()
end

local function launch(app)
  task(function()
    local st = http.post("http://" .. tv.ip .. ":8001/api/v2/applications/" .. app.id, "", nil, { timeout = 5000 })
    UI.note = st ~= 200 and ("couldn't start " .. app.name) or nil
  end)
end

---------------------------------------------------------------- the keys on the screen

-- { x, y, w, h, label, what it does (a key's name, or a function), repeat when held, its colour }
local REMOTE = {
  { 8, 26, 71, 34, "POWER", power, false, RED },
  { 85, 26, 71, 34, "SOURCE", "KEY_SOURCE" },
  { 162, 26, 71, 34, "HOME", "KEY_HOME" },
  { 239, 26, 73, 34, "BACK", "KEY_RETURN" },
  { 73, 68, 60, 36, "up", "KEY_UP", true },
  { 8, 109, 60, 36, "left", "KEY_LEFT", true },
  { 73, 109, 60, 36, "OK", "KEY_ENTER" },
  { 138, 109, 60, 36, "right", "KEY_RIGHT", true },
  { 73, 150, 60, 36, "down", "KEY_DOWN", true },
  { 212, 68, 100, 36, "VOL +", "KEY_VOLUP", true },
  { 212, 109, 100, 36, "MUTE", "KEY_MUTE" },
  { 212, 150, 100, 36, "VOL -", "KEY_VOLDOWN", true },
  { 8, 194, 60, 30, "<<", "KEY_REWIND" },
  { 73, 194, 60, 30, "PLAY", "KEY_PLAY_BACK" },
  { 138, 194, 60, 30, ">>", "KEY_FF" },
  { 212, 194, 100, 30, "APPS >", function() UI.page = "apps" end },
}

local function app_keys()
  local keys = {}
  for i, a in ipairs(installed) do
    if i > 10 then break end
    local col, row = (i - 1) % 2, (i - 1) // 2
    keys[i] = { 8 + col * 154, 26 + row * 34, 150, 30, a.name, function() launch(a) end, false, a.visible and ACCENT or nil }
  end
  keys[#keys + 1] = { 8, 198, 100, 26, "< REMOTE", function() UI.page = "remote" end }
  return keys
end

local function keys()
  return UI.page == "apps" and app_keys() or REMOTE
end

local function key_at(x, y)
  for i, k in ipairs(keys()) do
    if x >= k[1] and x < k[1] + k[3] and y >= k[2] and y < k[2] + k[4] then return i, k end
  end
end

local function press(k)
  if type(k[6]) == "function" then return k[6]() end
  if not send_key(k[6]) then UI.note = tv.power == "on" and "not connected to the TV yet" or "the TV is off" end
end

local held, held_at                              -- the key a finger holds (after a hold), and when it was last sent

touch.on("tap", function(x, y)
  if y >= H - 16 and chan_state == "refused" then chan_state = "closed" return end   -- the hint: ask the TV again
  local _, k = key_at(x, y)
  if k then press(k) end
end)
touch.on("hold", function(x, y)
  local i, k = key_at(x, y)
  if not k then return end
  press(k)
  if k[7] then held, held_at = i, sys.millis() end
end)
touch.on("swipe", function(dir)
  if dir == "left" then UI.page = "apps" elseif dir == "right" then UI.page = "remote" end
end)
touch.on("press", function(b)
  send_key(b == "A" and "KEY_VOLDOWN" or b == "C" and "KEY_VOLUP" or "KEY_MUTE")
end)

---------------------------------------------------------------- drawing

-- An arrow head in a key: a filled triangle, drawn as lines.
local function arrow(cx, cy, dir, col)
  for i = 0, 7 do
    if dir == "up" then disp.line(cx - i, cy - 4 + i, cx + i, cy - 4 + i, col)
    elseif dir == "down" then disp.line(cx - i, cy + 4 - i, cx + i, cy + 4 - i, col)
    elseif dir == "left" then disp.line(cx - 4 + i, cy - i, cx - 4 + i, cy + i, col)
    else disp.line(cx + 4 - i, cy - i, cx + 4 - i, cy + i, col) end
  end
end

local ARROWS = { up = true, down = true, left = true, right = true }

local function draw_key(k, down, usable)
  local x, y, w, h = k[1], k[2], k[3], k[4]
  disp.rect(x, y, w, h, down and KEY_DOWN or usable and KEY or KEY_OFF, true)
  if k[8] then disp.rect(x, y, w, 2, k[8], true) end
  local cx, cy = x + w // 2, y + h // 2
  local col = usable and FG or DIMMER
  if ARROWS[k[5]] then arrow(cx, cy, k[5], col)
  else disp.text(cx, cy - 3, k[5], col, 1, nil, "center") end
end

local function status()
  if not tv.ip then return "Looking for the TV...", DIM end
  if tv.power == "off" then return "Off", OFF end
  if tv.power == "standby" then return "Standby", STANDBY end
  if tv.power == nil then return "", DIM end
  return showing and ("On: " .. showing) or "On", ON
end

local function hint()
  if net.wifi() ~= "connected" then return "Needs Wi-Fi", WARN end
  if not tv.ip then return "No Samsung TV has answered on this network yet", DIM end
  if tv.power == "on" then
    if chan_state == "allow" then return "Choose Allow on the TV, for \"" .. NAME .. "\"", WARN end
    if chan_state == "refused" then return "The TV didn't allow it. Tap here to ask again", WARN end
  end
  if UI.note then return UI.note, WARN end
  if tv.power == "off" then return "POWER turns the TV on", DIMMER end
  return nil
end

local function draw()
  disp.clear(BG)
  disp.text(8, 6, tv.name or "Samsung TV", FG, 1)
  local text, col = status()
  disp.text(W - 8, 6, text, col, 1, nil, "right")
  disp.line(0, 18, W, 18, LINE)
  local finger_x, finger_y = touch.read()
  local down = finger_x and key_at(finger_x, finger_y)
  local live = chan ~= nil
  for i, k in ipairs(keys()) do
    -- Keys that need the TV listening are dim until it does: POWER and the page keys always work.
    draw_key(k, i == down or i == held, live or type(k[6]) == "function")
  end
  if UI.page == "apps" and #installed == 0 then
    disp.text(W // 2, 100, tv.power == "on" and "Asking the TV for its apps..." or "The TV is off", DIM, 1, nil, "center")
  end
  local h, hcol = hint()
  if h then disp.text(W // 2, H - 10, h, hcol, 1, nil, "center") end
end

-- What the screen shows: drawn again only when this changes.
local function key()
  local x, y = touch.read()
  local t = { UI.page, tv.name or "", (status()), chan_state, tostring(chan ~= nil), tostring(hint()),
              tostring(x and key_at(x, y)), tostring(held), net.wifi() }
  for _, a in ipairs(installed) do t[#t + 1] = a.name .. (a.visible and "*" or "") end
  return table.concat(t, "|")
end

local drawn
function loop()
  if held then                                   -- a held key repeats until the finger lifts
    if not touch.read() then held = nil
    elseif sys.millis() - held_at >= KEY_REPEAT_MS then
      held_at = sys.millis()
      press(keys()[held])
    end
  end
  if UI.note and UI.note_at ~= UI.note then UI.note_at, UI.note_until = UI.note, sys.millis() + 4000 end
  if UI.note and sys.millis() > (UI.note_until or 0) then UI.note, UI.note_at = nil, nil end
  local k = key()
  if k ~= drawn then drawn = k; draw() end
end

sys.rate(20)
