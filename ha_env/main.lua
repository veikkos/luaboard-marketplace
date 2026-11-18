-- ha_env: a room sensor for Home Assistant.
--
-- Reads temperature and humidity from an SHT40 (M5Stack ENV IV unit) on Grove
-- Port A, shows them, and publishes them over MQTT with Home Assistant's MQTT
-- discovery, so they appear in Home Assistant by themselves.
--
-- Settings come from secrets (secrets.env next to this file): mqtt_url
-- (mqtt:// or mqtts://), mqtt_user, mqtt_pass. The board's own id
-- (sys.info().id) names it, so Home Assistant sees the same device after
-- every restart.
--
-- Simulator: a broker on this computer (mosquitto -p 1883), a secrets.env with
-- mqtt_url=mqtt://127.0.0.1, and start the simulator with --set porta=env.

local mqtt = require("mqtt")
local json = require("json")

local EVERY_S = 30
local URL = secrets.get("mqtt_url")                  -- nil: show the readings only

local ID = sys.info().id
local BASE = "luaboard/" .. ID
local STATUS = BASE .. "/status"

local temp, hum, sensor_err = nil, nil, nil
local state, published = "connecting", 0

---------------------------------------------------------------- sensor

local function crc8(s)
  local c = 0xFF
  for i = 1, #s do
    c = c ~ s:byte(i)
    for _ = 1, 8 do c = (c & 0x80 ~= 0) and ((c << 1) ~ 0x31) & 0xFF or (c << 1) & 0xFF end
  end
  return c
end

-- One SHT40 measurement (inside a task): temperature (°C), humidity (%).
local function measure()
  local ok, err = i2c.write(0x44, "\xFD")           -- measure, high precision
  if not ok then return nil, err end
  sleep(10)                                          -- takes ~9 ms
  local d
  d, err = i2c.read(0x44, 6)
  if not d then return nil, err end
  if crc8(d:sub(1, 2)) ~= d:byte(3) or crc8(d:sub(4, 5)) ~= d:byte(6) then return nil, "bad CRC" end
  local t = -45 + 175 * string.unpack(">I2", d, 1) / 65535
  local h = -6 + 125 * string.unpack(">I2", d, 4) / 65535
  return t, math.max(0, math.min(100, h))
end

---------------------------------------------------------------- screen

local function draw()
  disp.clear(disp.rgb(10, 14, 22))
  disp.text(10, 8, "Room sensor", disp.WHITE, 2)
  if temp then
    disp.text(10, 50, string.format("%.1f C", temp), disp.ORANGE, 5)
    disp.text(10, 110, string.format("%.0f %% humidity", hum), disp.CYAN, 3)
  else
    disp.text(10, 50, "No sensor", disp.GRAY, 3)
    disp.text(10, 85, "Plug an ENV IV unit into Port A", disp.GRAY)
    if sensor_err then disp.text(10, 100, sensor_err, disp.DARKGRAY) end
  end
  local col = state == "connected" and disp.GREEN or disp.ORANGE
  disp.circle(16, 168, 6, col, true)
  disp.text(30, 161, state, col, 2)
  disp.text(10, 195, URL or "luaboard secrets set ha_env mqtt_url <url>", disp.GRAY)
  disp.text(10, 215, "id " .. ID .. ", sent " .. published, disp.DARKGRAY)
end

---------------------------------------------------------------- Home Assistant

-- MQTT discovery: one retained config message per sensor.
local function announce(c)
  local device = { identifiers = { "luaboard_" .. ID }, name = "luaboard " .. ID, model = "CoreS3" }
  for _, s in ipairs({
    { key = "temperature", name = "Temperature", class = "temperature", unit = "°C" },
    { key = "humidity", name = "Humidity", class = "humidity", unit = "%" },
  }) do
    c:publish("homeassistant/sensor/luaboard_" .. ID .. "_" .. s.key .. "/config", json.encode({
      name = s.name,
      unique_id = "luaboard_" .. ID .. "_" .. s.key,
      device_class = s.class,
      unit_of_measurement = s.unit,
      state_class = "measurement",
      state_topic = BASE .. "/state",
      value_template = "{{ value_json." .. s.key .. " }}",
      availability_topic = STATUS,
      device = device,
    }), { retain = true })
  end
  c:publish(STATUS, "online", { retain = true })
end

local client                                         -- set once the broker answered

local function publish_reading()
  if not (temp and client) then return end
  client:publish(BASE .. "/state", json.encode({
    temperature = math.floor(temp * 10 + 0.5) / 10, humidity = math.floor(hum + 0.5),
  }))
  published = published + 1
end

task(function()
  if not URL then state = "no broker set"; draw() return end
  local c, err
  repeat
    c, err = mqtt.connect(URL, {
      username = secrets.get("mqtt_user"), password = secrets.get("mqtt_pass"),
      will = { topic = STATUS, payload = "offline", retain = true },
      on_connect = function(cl) state = "connected"; announce(cl); draw() end,
      on_close = function() state = "offline"; draw() end,
    })
    if not c then
      state = "no broker, retrying"; draw()
      print("mqtt: " .. err)
      sleep(10000)
    end
  until c
  client = c
  publish_reading()                                  -- the reading taken while connecting
  draw()
end)

-- Measure now and every EVERY_S seconds. Once connected, publish each
-- reading; while the link is down, the client queues them.
task(function()
  while true do
    local t, h = measure()
    if t then temp, hum, sensor_err = t, h, nil else temp, sensor_err = nil, h end
    publish_reading()
    draw()
    sleep(EVERY_S * 1000)
  end
end)

draw()
