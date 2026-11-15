-- cardata.lua: BMW CarData's REST API (with a daily budget) and its stream.
--
--   local cardata = require("cardata")
--   local C = cardata.new{ api_url, stream_url, ca, cap }   -- all optional
--   task(function()
--     local vin = C:vin(access)
--     local client = C:stream(tokens, vin, function(data) ... end)
--   end)
--
-- BMW allows 50 REST calls a day per account; this app makes at most `cap`
-- (default 10) and counts them in `store` ("rest_budget"). What it learns
-- once is kept in `store` too: "vin", "model", "container".

local http, json, mqtt = require("http"), require("json"), require("mqtt")
local car = require("car")

local M = {}
local C = {}
C.__index = C

function M.new(o)
  o = o or {}
  return setmetatable({
    api = o.api_url or "https://api-cardata.bmwgroup.com",
    stream_url = o.stream_url or "mqtts://customer.streaming-cardata.bmwgroup.com:9000",
    ca = o.ca, cap = o.cap or 10,
  }, C)
end

-- May a call be made today? Returns the budget record to keep once BMW has
-- answered (a call that never reached BMW isn't counted), or nil.
local function budget(cap)
  local rec = json.decode(store.get("rest_budget") or "")
  local allowed, new = car.budget_take(rec, sys.time(), cap)
  return allowed and new or nil
end

-- One REST call. Returns status, decoded body (or nil; with `raw` the body
-- as it came), or nil, err.
function C:rest(access, method, path, body, raw)
  local rec = budget(self.cap)
  if not rec then return nil, "daily limit" end
  local headers = { Authorization = "Bearer " .. tostring(access), ["x-version"] = "v1",
                    Accept = raw and "*/*" or "application/json" }
  if body then headers["Content-Type"] = "application/json" end
  local st, text = http.request{ method = method, url = self.api .. path, headers = headers,
                                 body = body and json.encode(body) or nil }
  if not st then return nil, text end
  store.set("rest_budget", json.encode(rec))
  if raw then return st, text end
  return st, (json.decode(text or ""))
end

local function failed(st, v)
  if not st then return v end
  return "BMW answered HTTP " .. st
end

-- The car's VIN: the first PRIMARY one on the account.
function C:vin(access)
  local vin = store.get("vin")
  if vin then return vin end
  local st, v = self:rest(access, "GET", "/customers/vehicles/mappings")
  if st ~= 200 or type(v) ~= "table" then return nil, failed(st, v) end
  local pick
  for _, m in ipairs(v) do
    if type(m) == "table" and type(m.vin) == "string" then
      if m.mappingType == "PRIMARY" then pick = m.vin break end
      pick = pick or m.vin
    end
  end
  if not pick then return nil, "no car on this BMW account" end
  store.set("vin", pick)
  return pick
end

function C:model(access, vin)
  local name = store.get("model")
  if name then return name end
  local st, v = self:rest(access, "GET", "/customers/vehicles/" .. vin .. "/basicData")
  if st == 200 and type(v) == "table" and type(v.modelName) == "string" then
    store.set("model", v.modelName)
    return v.modelName
  end
end

-- The data container listing the descriptors REST answers with: this app's
-- own, named after its list of descriptors (car.container_name()), made
-- once and reused (also after Clear data). When the list changes, the new
-- one is made and the app's older ones are deleted: BMW allows 10.
function C:container(access)
  local name = car.container_name()
  local id = store.get("container")
  if id and store.get("container_name") == name then return id end
  local st, v = self:rest(access, "GET", "/customers/containers")
  if st ~= 200 or type(v) ~= "table" or type(v.containers) ~= "table" then return nil, failed(st, v) end
  local old = {}
  id = nil
  for _, c in ipairs(v.containers) do
    if type(c) == "table" and type(c.containerId) == "string" and type(c.name) == "string" then
      if c.name == name then id = c.containerId
      elseif c.name == "luaboard" or c.name:match("^luaboard%-%x+$") then old[#old + 1] = c.containerId end
    end
  end
  if not id then
    local descriptors = {}
    for i, d in ipairs(car.DESCRIPTORS) do descriptors[i] = d end
    st, v = self:rest(access, "POST", "/customers/containers",
      { name = name, purpose = "luaboard display", technicalDescriptors = json.array(descriptors) })
    if not ((st == 200 or st == 201) and type(v) == "table" and type(v.containerId) == "string") then
      if st and st >= 400 and st < 500 then return nil, "BMW refused a new data container (HTTP " .. st .. ")" end
      return nil, failed(st, v)
    end
    id = v.containerId
  end
  store.set("container", id)
  store.set("container_name", name)
  for _, o in ipairs(old) do
    local dst = self:rest(access, "DELETE", "/customers/containers/" .. o)
    if dst ~= 200 and dst ~= 204 then print("bmw: an old data container wasn't deleted: " .. tostring(dst)) end
  end
  return id
end

-- The container's current values: { descriptor = { value = "...", unit, timestamp } }.
function C:snapshot(access, vin, id)
  local st, v = self:rest(access, "GET", "/customers/vehicles/" .. vin .. "/telematicData?containerId=" .. http.urlencode(id))
  if st == 200 and type(v) == "table" and type(v.telematicData) == "table" then return v.telematicData end
  return nil, failed(st, v)
end

-- The car's picture, as the My BMW app shows it: a PNG (BMW labels it
-- image/jpeg), or nil, err.
function C:picture(access, vin)
  local st, body = self:rest(access, "GET", "/customers/vehicles/" .. vin .. "/image", nil, true)
  if st ~= 200 then return nil, failed(st, body) end
  if type(body) ~= "string" or body:sub(1, 8) ~= "\137PNG\r\n\26\n" then return nil, "not a PNG" end
  return body
end

-- The stream: values as the car reports them. on_data(data) per message for
-- our car. Returns the mqtt client, or nil, err. The client doesn't
-- reconnect by itself: the caller does, with the current id token and its
-- own back-off (BMW refuses a stale password, and a second connection).
function C:stream(tok, vin, on_data)
  local c, err = mqtt.connect(self.stream_url, {
    client_id = tok.gcid, username = tok.gcid, password = tok.id,
    keepalive = 30, queue = 0, ca = self.ca, reconnect = false,
  })
  if not c then return nil, err end
  local ok, serr = c:subscribe(tok.gcid .. "/" .. vin, function(_, message)
    local msg = json.decode(message)
    if type(msg) ~= "table" then
      print("bmw: a message that isn't JSON (" .. #message .. " bytes)")
    elseif msg.vin ~= nil and msg.vin ~= vin then
      print("bmw: a message for another car")
    elseif type(msg.data) ~= "table" then
      print("bmw: a message without data")
    else
      on_data(msg.data)
    end
  end, 1)
  if not ok then c:close() return nil, serr end
  return c
end

return M
