-- car.lua: the car's state as BMW CarData reports it, and what the screen
-- shows of it. No network or drawing here.
--
-- The state is a table: descriptor -> { v = value, ts = UTC seconds or nil }.
-- Its `_seen` field remembers unknown descriptors already reported.

local json = require("json")

local M = {}

local SOC = {
  "vehicle.drivetrain.batteryManagement.header",
  "vehicle.drivetrain.electricEngine.charging.level",
  "vehicle.powertrain.electric.battery.stateOfCharge.displayed",
}
local RANGE = {
  "vehicle.drivetrain.electricEngine.kombiRemainingElectricRange",
  "vehicle.drivetrain.electricEngine.remainingElectricRange",
}
local TARGET = { "vehicle.powertrain.electric.battery.stateOfCharge.target" }
local STATUS = "vehicle.drivetrain.electricEngine.charging.status"
local HV = "vehicle.drivetrain.electricEngine.charging.hvStatus"
local POWER = { "vehicle.powertrain.electric.battery.charging.power" }
local LEFT = {
  "vehicle.drivetrain.electricEngine.charging.timeRemaining",
  "vehicle.drivetrain.electricEngine.charging.timeToFullyCharged",
}
local METHOD = { "vehicle.drivetrain.electricEngine.charging.method" }
local PORT = "vehicle.body.chargingPort.status"
local PLUGGED = "vehicle.powertrain.tractionBattery.charging.port.anyPosition.isPlugged"
local LOCK = "vehicle.cabin.door.lock.status"          -- REST only; the stream has the trunk's
local TRUNK_LOCK = "vehicle.body.trunk.isLocked"
local ODO = { "vehicle.vehicle.travelledDistance" }
local SERVICE = { "vehicle.status.serviceDistance.next" }
-- Doors, windows and lids: { descriptor, name, id }, in the order they are listed.
local OPENINGS = {
  { "vehicle.cabin.door.row1.driver.isOpen", "Front left door", "door_fl" },
  { "vehicle.cabin.door.row1.passenger.isOpen", "Front right door", "door_fr" },
  { "vehicle.cabin.door.row2.driver.isOpen", "Rear left door", "door_rl" },
  { "vehicle.cabin.door.row2.passenger.isOpen", "Rear right door", "door_rr" },
  { "vehicle.cabin.window.row1.driver.status", "Front left window", "window_fl" },
  { "vehicle.cabin.window.row1.passenger.status", "Front right window", "window_fr" },
  { "vehicle.cabin.window.row2.driver.status", "Rear left window", "window_rl" },
  { "vehicle.cabin.window.row2.passenger.status", "Rear right window", "window_rr" },
  { "vehicle.body.trunk.isOpen", "Trunk", "trunk" },
  { "vehicle.body.hood.isOpen", "Hood", "hood" },
  { "vehicle.cabin.sunroof.status", "Sunroof", "sunroof" },
}
-- Tyres front left, front right, rear left, rear right: pressure and target (kPa).
local TYRES = {}
for _, pos in ipairs({ "row1.wheel.left", "row1.wheel.right", "row2.wheel.left", "row2.wheel.right" }) do
  TYRES[#TYRES + 1] = { "vehicle.chassis.axle." .. pos .. ".tire.pressure", "vehicle.chassis.axle." .. pos .. ".tire.pressureTarget" }
end
-- Climate: the electric cars' preconditioning and the older one; the newest wins.
local CLIMATE_STATE = { "vehicle.cabin.hvac.preconditioning.status.comfortState", "vehicle.vehicle.preConditioning.activity" }
local CLIMATE_SECONDS = "vehicle.cabin.hvac.preconditioning.status.remainingRunningTime"
local CLIMATE_MINUTES = "vehicle.vehicle.preConditioning.remainingTime"

-- Every descriptor the app shows: the data container asks for these, and
-- only these are saved.
M.DESCRIPTORS = {}
local function add(d) M.DESCRIPTORS[#M.DESCRIPTORS + 1] = d end
for _, list in ipairs({ SOC, RANGE, TARGET, { STATUS, HV }, POWER, LEFT, METHOD, { PORT, PLUGGED },
                        { LOCK, TRUNK_LOCK }, ODO, SERVICE, CLIMATE_STATE, { CLIMATE_SECONDS, CLIMATE_MINUTES } }) do
  for _, d in ipairs(list) do add(d) end
end
for _, o in ipairs(OPENINGS) do add(o[1]) end
for _, t in ipairs(TYRES) do add(t[1]) add(t[2]) end
local KNOWN = {}
for _, d in ipairs(M.DESCRIPTORS) do KNOWN[d] = true end

local STATUS_TEXT = {
  CHARGINGACTIVE = "Charging", INITIALIZATION = "Starting", CHARGINGPAUSED = "Paused",
  NOCHARGING = "Not charging", CHARGINGENDED = "Charged", CHARGINGERROR = "Charging error",
}
local HV_TEXT = {
  CHARGING = "Charging", WAITING_FOR_CHARGING = "Waiting", NOT_CHARGING = "Not charging",
  FINISHED_FULLY_CHARGED = "Charged", FINISHED_NOT_FULL = "Stopped", ERROR = "Charging error",
}
local PORT_TEXT = { CONNECTED = "Plugged in", DISCONNECTED = "Unplugged" }
local TRUNK_LOCK_TEXT = { [true] = "locked", [false] = "unlocked" }
local TYRE_LOW = 0.9           -- under 90 % of the target pressure
-- Climate states that mean it is off (the rest mean on).
local CLIMATE_OFF = { INACTIVE = true, STANDBY = true, OFF = true, NO_ACTION = true, UNKNOWN = true,
                      COMFORT_STATE_INACTIVE = true, INVALID = true, [""] = true }
local PLUGGED_TEXT = { [true] = "Plugged in", [false] = "Unplugged" }
local LOCK_TEXT = { LOCKED = "locked", SECURED = "locked", SELECTIVELOCKED = "partly locked", UNLOCKED = "unlocked" }
local MAX_SEEN = 50
local LOCK_STALE = 5 * 60    -- s: a lock this much older than the newest value is hidden

-- "2025-07-28T05:16:53.000Z" -> UTC seconds, or nil.
function M.parse_time(s)
  if type(s) ~= "string" then return nil end
  return (sys.time(s))
end

-- REST gives every value as a string; the stream as numbers and booleans.
local function value(v)
  if type(v) ~= "string" then return v end
  if v == "true" then return true elseif v == "false" then return false end
  if v:match("^%s*-?%d+%.?%d*%s*$") then return tonumber(v) end
  return v
end

-- Merge a stream message's `data` or REST's `telematicData` into the state.
-- Returns the unknown descriptors seen for the first time.
function M.merge(state, data)
  local new = {}
  if type(data) ~= "table" then return new end
  state._seen = state._seen or {}
  for key, e in pairs(data) do
    if type(key) == "string" and type(e) == "table" and e.value ~= nil and e.value ~= json.null then
      state[key] = { v = value(e.value), ts = M.parse_time(e.timestamp) }
      if not KNOWN[key] and not state._seen[key] then
        local n = 0
        for _ in pairs(state._seen) do n = n + 1 end
        if n < MAX_SEEN then
          state._seen[key] = true
          new[#new + 1] = key
        end
      end
    end
  end
  table.sort(new)
  return new
end

-- The newest value among a row's descriptors (the car updates some and
-- leaves others behind); on a tie, or with no times, the first one listed.
-- `text`, if given, maps a descriptor's value to what is shown, and values it
-- doesn't know are passed over. Returns the value (or its text) and the entry.
local function pick(state, list, text)
  local best, be
  for _, d in ipairs(list) do
    local e = state[d]
    if type(e) == "table" and e.v ~= nil then
      local v = e.v
      if text then v = text[d] and text[d][v] end
      if v ~= nil and (not be or (e.ts or -1) > (be.ts or -1)) then best, be = v, e end
    end
  end
  return best, be
end

local function num(state, list)
  local v = pick(state, list)
  return type(v) == "number" and v or nil
end

local function newest(state)
  local t
  for _, d in ipairs(M.DESCRIPTORS) do
    local e = state[d]
    if type(e) == "table" and e.ts and (not t or e.ts > t) then t = e.ts end
  end
  return t
end

local function age_text(secs)
  if secs < 60 then return "just now" end
  if secs < 3600 then return secs // 60 .. " min ago" end
  if secs < 86400 then return secs // 3600 .. " h ago" end
  return secs // 86400 .. " d ago"
end

local function left_text(min)
  min = math.floor(min + 0.5)
  if min < 60 then return min .. " min left" end
  local h, m = min // 60, min % 60
  return m == 0 and (h .. " h left") or (h .. " h " .. m .. " min left")
end

-- What the screen shows. `now`: UTC seconds, or nil while the clock is unknown.
function M.view(state, now)
  local v = {
    soc = num(state, SOC), range_km = num(state, RANGE), target = num(state, TARGET),
    odometer_km = num(state, ODO),
  }
  local text = pick(state, { STATUS, HV }, { [STATUS] = STATUS_TEXT, [HV] = HV_TEXT })
  v.charging = text
  v.is_charging = text == "Charging"
  if v.is_charging then
    local w = num(state, POWER)
    if w then v.power_kw = math.floor(w / 100 + 0.5) / 10 end
    local min, e = pick(state, LEFT)
    if type(min) == "number" and min > 0 then
      local from = now and (e.ts or now)          -- the clock unknown: just the minutes
      if from then
        local d = sys.date(from + math.floor(min * 60 + 0.5))
        v.left = string.format("full at %d:%02d", d.hour, d.min)
      else
        v.left = left_text(min)
      end
    end
  end
  v.plug = pick(state, { PORT, PLUGGED }, { [PORT] = PORT_TEXT, [PLUGGED] = PLUGGED_TEXT })
  v.updated = newest(state)
  local lock, le = pick(state, { LOCK, TRUNK_LOCK }, { [LOCK] = LOCK_TEXT, [TRUNK_LOCK] = TRUNK_LOCK_TEXT })
  if lock and le.ts and v.updated and v.updated - le.ts > LOCK_STALE then lock = nil end
  v.lock = lock
  v.service_km = num(state, SERVICE)
  local m = pick(state, METHOD)
  if type(m) == "string" then v.method = m:match("^(DC)") or m:match("^(AC)") end

  -- doors, windows, lids: nil until one is known, then the open ones;
  -- v.open[id] = "open", "half" or "closed" for each one known
  v.open = {}
  for _, o in ipairs(OPENINGS) do
    local e = state[o[1]]
    if type(e) == "table" and e.v ~= nil then
      v.openings = v.openings or {}
      local val = e.v
      if val == true or val == "OPEN" then
        v.openings[#v.openings + 1] = o[2] .. " open"
        v.open[o[3]] = "open"
      elseif val == "INTERMEDIATE" then
        v.openings[#v.openings + 1] = o[2] .. " half open"
        v.open[o[3]] = "half"
      else
        v.open[o[3]] = "closed"
      end
    end
  end

  -- tyres: all four in bar once all are known
  local tyres, low, each = {}, false, {}
  for _, t in ipairs(TYRES) do
    local p, target = num(state, { t[1] }), num(state, { t[2] })
    if not p then tyres = nil break end
    tyres[#tyres + 1] = string.format("%.1f", p / 100)
    each[#each + 1] = target ~= nil and p < target * TYRE_LOW
    if each[#each] then low = true end
  end
  if tyres then v.tyres, v.tyres_low, v.tyre_low = tyres, low, each end
  local function axle(a, b)                       -- the axle's target, in bar
    local t = num(state, { TYRES[a][2], TYRES[b][2] })
    return t and string.format("%.1f", t / 100)
  end
  v.target_front, v.target_rear = axle(1, 2), axle(3, 4)

  -- climate: on while its newest state isn't an "off" one
  local cs = pick(state, CLIMATE_STATE)
  if type(cs) == "string" and not CLIMATE_OFF[cs:upper()] then
    local secs = pick(state, { CLIMATE_SECONDS })
    local mins, me = pick(state, { CLIMATE_MINUTES })
    local se = state[CLIMATE_SECONDS]
    local left
    if type(secs) == "number" and (not me or (se.ts or -1) >= (me.ts or -1)) then left = math.floor(secs / 60 + 0.5)
    elseif type(mins) == "number" then left = math.floor(mins + 0.5) end
    v.climate = left and left > 0 and ("Climate on, " .. left .. " min left") or "Climate on"
  end
  v.stale = false
  if now and v.updated then
    v.age = age_text(math.max(0, now - v.updated))
    v.stale = now - v.updated > 86400
  end
  return v
end

-- 12345 -> "12 345 km"
function M.fmt_km(n)
  local s = tostring(math.floor(n + 0.5))
  local out = s:reverse():gsub("(%d%d%d)", "%1 "):reverse()
  return (out:gsub("^ ", "")) .. " km"
end

-- Ask REST for the values? With nothing known, or the newest an hour old.
function M.needs_rest(state, now)
  local t = newest(state)
  local any = t ~= nil
  if not any then
    for _, d in ipairs(M.DESCRIPTORS) do if state[d] then any = true break end end
  end
  if not any then return true end
  return now ~= nil and t ~= nil and now - t > 3600
end

-- "YYYY-MM-DD", the UTC date of `now`.
function M.utc_day(now)
  local d = sys.date(now, "UTC")
  return string.format("%04d-%02d-%02d", d.year, d.month, d.day)
end

-- The daily REST budget: rec = { day = "YYYY-MM-DD" (UTC), n = calls }.
-- Returns whether a call may be made, and the record to keep.
function M.budget_take(rec, now, cap)
  rec = type(rec) == "table" and rec or { n = 0 }
  local day = rec.day
  if now then day = M.utc_day(now) end
  local n = (day == rec.day) and (tonumber(rec.n) or 0) or 0
  if n >= cap then return false, { day = day, n = n } end
  return true, { day = day, n = n + 1 }
end

-- Cut a picture (big-endian RGB565 as disp.grab gives) down to what isn't
-- the background `bg` (RGB565), keeping `margin` pixels around it. Returns
-- the pixels, width and height, or nil when it is all background.
function M.crop(px, w, h, bg, margin)
  local bgp = string.char(bg >> 8, bg & 255)
  local empty = bgp:rep(w)
  local x0, x1, y0, y1 = w, -1, nil, nil
  for y = 0, h - 1 do
    local row = px:sub(y * w * 2 + 1, (y + 1) * w * 2)
    if row ~= empty then
      y0 = y0 or y
      y1 = y
      for x = 0, x0 - 1 do
        if row:sub(x * 2 + 1, x * 2 + 2) ~= bgp then x0 = x break end
      end
      for x = w - 1, x1 + 1, -1 do
        if row:sub(x * 2 + 1, x * 2 + 2) ~= bgp then x1 = x break end
      end
    end
  end
  if not y0 then return nil end
  x0, y0 = math.max(0, x0 - margin), math.max(0, y0 - margin)
  x1, y1 = math.min(w - 1, x1 + margin), math.min(h - 1, y1 + margin)
  local cw, out = x1 - x0 + 1, {}
  for y = y0, y1 do out[#out + 1] = px:sub((y * w + x0) * 2 + 1, (y * w + x1) * 2 + 2) end
  return table.concat(out), cw, y1 - y0 + 1
end

-- The data container's name: "luaboard-" and 8 hex digits of the list of
-- descriptors, so a new list gets a new container.
function M.container_name()
  return "luaboard-" .. crypto.hex(crypto.sha256(table.concat(M.DESCRIPTORS, ","))):sub(1, 8)
end

-- The shown descriptors as JSON, for `store`.
function M.encode(state)
  local t = {}
  for _, d in ipairs(M.DESCRIPTORS) do
    local e = state[d]
    if type(e) == "table" then t[d] = { v = e.v, ts = e.ts } end
  end
  return json.encode(t)
end

function M.decode(text)
  local t = json.decode(text or "")
  local state = {}
  if type(t) ~= "table" then return state end
  for _, d in ipairs(M.DESCRIPTORS) do
    local e = t[d]
    if type(e) == "table" and e.v ~= nil and e.v ~= json.null then
      state[d] = { v = e.v, ts = tonumber(e.ts) }
    end
  end
  return state
end

return M
