-- di2: gear position and battery of a Shimano Di2 groupset (12-speed road,
-- e.g. 105 Di2 R7100) over Bluetooth LE, from the rear derailleur.
--
-- It only reads: battery level (the standard battery service) and the gear
-- position Shimano's service 18ef notifies (characteristic 2ac1: a message
-- starting 00, bytes 4..7 front gear and count, rear gear and count, rear 1
-- = biggest cog). Nothing is ever written to the bike.
--
-- The derailleur advertises while it's awake: shift once if it isn't found.
-- The first one found (a name starting "RD") is remembered; tap the screen
-- to forget it and look again.
--
-- Not affiliated with or endorsed by Shimano; Shimano and Di2 are its
-- trademarks.

local SHIMANO = "-5348-494d-414e-4f5f424c4500"
local GEAR_SVC, GEAR_CHR = "000018ef" .. SHIMANO, "00002ac1" .. SHIMANO

local W = disp.W
local BG = disp.rgb(8, 10, 16)
local ON = disp.rgb(255, 196, 40)      -- the gear in use
local OFF = disp.rgb(46, 52, 66)
local DIM = disp.rgb(120, 126, 140)

local st = { phase = "search" }        -- search | connect | live
local dirty = true
local function set(k, v)
  if st[k] ~= v then st[k] = v; dirty = true end
end

-------------------------------------------------------------- Bluetooth

-- Scan until the derailleur is heard: the remembered one, else the
-- strongest whose name starts with "RD" (after a moment to hear them all).
local function find()
  local saved = store.get("addr")
  local best, first_at
  ble.scan(function(a)
    local mine = saved and a.addr == saved
    if mine or (not saved and a.name and a.name:match("^RD")) then
      if not best or mine or a.rssi > best.rssi then best = a end
      first_at = first_at or sys.millis()
    end
  end)
  while not (best and (best.addr == saved or sys.millis() - first_at > 1500)) do sleep(100) end
  ble.stop_scan()
  return best
end

local function session(dev)
  set("name", dev.name or dev.addr)
  set("phase", "connect")
  local c, err = ble.connect(dev.addr)
  if not c then return err end
  local ok
  ok, err = ble.wait_connected(c)
  if ok then
    store.set("addr", dev.addr)
    local b = c:read("180f", "2a19")
    if b then set("battery", b:byte()) end
    c:subscribe("180f", "2a19", function(d) set("battery", d:byte()) end)
    ok, err = c:subscribe(GEAR_SVC, GEAR_CHR, function(d)
      -- The first byte is the kind of message: 00 is the gear position.
      -- Others (01, 04, ...) come too, mostly ff bytes: not gears.
      local kind, front, fronts, rear, rears = d:byte(1), d:byte(4), d:byte(5), d:byte(6), d:byte(7)
      if kind ~= 0 or not rears or front < 1 or front > fronts or rear < 1 or rear > rears then return end
      set("front", front); set("fronts", fronts)
      set("rear", rear); set("rears", rears)
    end)
  end
  if ok then
    set("phase", "live")
    set("msg", nil)
    while c:status() == "connected" and not st.forget do sleep(200) end
    err = select(2, c:status())
  end
  c:close()
  return err
end

task(function()
  while true do
    set("phase", "search")
    if st.forget then store.set("addr", nil); st.forget = nil end
    local err = session(find())
    set("msg", err)
    sleep(500)
  end
end)

---------------------------------------------------------------- drawing

local function centered(y, s, color, scale)
  disp.text((W - disp.text_width(s, scale)) // 2, y, s, color, scale)
end

-- Grey while disconnected: the level may be out of date.
local function battery(x, y, pct, live)
  disp.rect(x, y, 40, 20, DIM)
  disp.rect(x + 40, y + 6, 4, 8, DIM, true)
  if pct then
    local color = not live and DIM or pct > 40 and disp.rgb(70, 200, 90) or pct > 20 and disp.ORANGE or disp.RED
    disp.rect(x + 2, y + 2, math.max(1, 36 * pct // 100), 16, color, true)
    disp.text(x + 52, y + 3, pct .. "%", live and disp.WHITE or DIM, 2)
  else
    disp.text(x + 52, y + 3, "--", DIM, 2)
  end
end

-- "7/12", big number first, centred on x.
local function gear_number(x, y, gear, count, on)
  if not gear then return end
  local big, small = tostring(gear), "/" .. count
  local bw, sw = disp.text_width(big, 4), disp.text_width(small, 2)
  local left = x - (bw + 2 + sw) // 2
  disp.text(left, y, big, on, 4)
  disp.text(left + bw + 2, y + 14, small, DIM, 2)
end

-- Chainrings, seen from the side: big outside, small inside. `on` is the
-- colour of the one in use (dimmed while the position may be out of date).
local function rings(cx, cy, front, fronts, on)
  local radius = { 30, 50 }             -- 1 = small, 2 = big
  for g = 1, math.min(fronts or 2, 2) do
    local color = front == g and on or OFF
    for t = 0, front == g and 4 or 1 do disp.circle(cx, cy, radius[g] - t, color) end
  end
  disp.circle(cx, cy, 6, OFF, true)
  gear_number(cx, cy + 58, front, fronts or 2, on)
end

-- Cassette: biggest cog (gear 1) on the left, bars centred like cogs.
local function cassette(x, cy, rear, rears, on)
  local n = rears or 12
  local step = math.min(9, 176 // n)    -- packed close, centred in the 176 px area
  x = x + (176 - n * step) // 2
  for g = 1, n do                       -- thin, like cogs seen edge-on
    local h = 104 - (g - 1) * 64 // math.max(n - 1, 1)
    local w = rear == g and 6 or 4
    disp.rect(x + (g - 1) * step + (step - w) // 2, cy - h // 2, w, h, rear == g and on or OFF, true)
  end
  gear_number(x + n * step // 2, cy + 58, rear, n, on)
end

local function draw()
  disp.clear(BG)
  local live = st.phase == "live"
  battery(10, 8, st.battery, live)
  local dot = st.phase == "live" and disp.rgb(70, 200, 90) or st.phase == "connect" and disp.ORANGE or OFF
  local name = st.name or "Di2"
  disp.circle(W - 16 - disp.text_width(name) - 10, 17, 4, dot, true)
  disp.text(W - 16 - disp.text_width(name), 14, name, DIM)

  rings(70, 100, st.front, st.fronts, live and ON or DIM)
  cassette(134, 100, st.rear, st.rears, live and ON or DIM)

  if not live then
    centered(204, st.phase == "connect" and "Connecting..." or "Looking for Di2...", disp.WHITE, 2)
    centered(226, st.msg or (st.phase == "search" and "shift once to wake it" or ""), DIM)
  end
end

local function forget() if st.phase == "live" then st.forget = true end end
touch.on("tap", forget)
touch.on("hold", forget)

function loop()
  if dirty then dirty = false; draw() end
end
