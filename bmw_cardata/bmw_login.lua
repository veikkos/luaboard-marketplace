-- bmw_login.lua: logging in to BMW CarData the way a TV app logs in (the
-- OAuth 2.0 device authorization grant, RFC 8628, with PKCE). The board
-- shows a code, the user approves it on their phone, and from then on the
-- board renews the login by itself.
--
--   local login = require("bmw_login")
--   local L = login.new{
--     client_id = "...",                 -- made in the My BMW CarData portal
--     auth_url = nil,                    -- default: BMW's login server
--     on_code = function(c) end,         -- c = { user_code, uri, expires_at
--                                        --   (sys.millis()) }: show it; nil: the
--                                        --   wait is over
--   }
--   task(function()
--     local t, err, kind = L:tokens()    -- t = { access, id, gcid }
--   end)
--
-- kind, when there are no tokens: "network" (BMW unreachable; the login is
-- kept), "code" (the code expired or was declined: ask the user before a new
-- one), "refused" (BMW refused the login itself, e.g. a wrong client ID),
-- "too_big" (the refresh token doesn't fit in a secret).
--
-- The refresh token is the secret `bmw_refresh`, the GCID is `gcid` in
-- `store`. The access and id tokens stay in RAM.

local http, json = require("http"), require("json")

local M = {}
local Login = {}
Login.__index = Login

local NAME = "bmw_refresh"
local SCOPE = "authenticate_user openid cardata:streaming:read cardata:api:read"
local MAX_SECRET = 2048
local REFRESH_S = 45 * 60

function M.new(o)
  assert(type(o.client_id) == "string" and o.client_id ~= "", "bmw_login.new: client_id is required")
  return setmetatable({
    o = o, auth = o.auth_url or "https://customer.bmwgroup.com/gcdm/oauth",
    tok = nil, refresh_at = 0, busy = false,
  }, Login)
end

local function b64url(s) return crypto.base64(s, true) end

-- POST a form. Returns status, decoded table (or {}), or nil, nil, err.
local function post(url, fields)
  local st, body = http.post(url, http.form(fields), {
    ['Content-Type'] = 'application/x-www-form-urlencoded', Accept = 'application/json' })
  if not st then return nil, nil, body end
  local ok, t = pcall(json.decode, body)
  if not ok or type(t) ~= 'table' then t = {} end
  return st, t
end

local function str(v) return type(v) == 'string' and v or nil end

function Login:_save(t)
  local rt = str(t.refresh_token)
  if rt then
    if #rt > MAX_SECRET then
      return nil, "BMW's login key is too big to keep (" .. #rt .. " bytes)", "too_big"
    end
    secrets.set(NAME, rt)
  end
  local gcid = str(t.gcid)
  if gcid then store.set("gcid", gcid) end
  self.tok = { access = str(t.access_token), id = str(t.id_token), gcid = gcid or store.get("gcid"),
               at = sys.millis() }
  local life = tonumber(t.expires_in) or 3600
  self.refresh_at = sys.millis() + math.floor(math.min(REFRESH_S, life * 3 / 4) * 1000)
  return self.tok
end

local function why(t, st)
  return str(t.error_description) or str(t.error) or ("HTTP " .. tostring(st))
end

function Login:_refresh(rt)
  local st, t, err = post(self.auth .. "/token",
    { grant_type = "refresh_token", refresh_token = rt, client_id = self.o.client_id })
  if not st then return nil, err, "network" end
  if st == 200 and str(t.access_token) then return self:_save(t) end
  if st >= 500 or st == 429 then return nil, "BMW login: " .. why(t, st), "network" end
  return nil, why(t, st), "refused"
end

function Login:_code_over(msg)
  if self.o.on_code then self.o.on_code(nil) end
  return nil, msg, "code"
end

function Login:_device()
  local verifier = b64url(crypto.random(48))
  local st, t, err = post(self.auth .. "/device/code", {
    client_id = self.o.client_id, response_type = "device_code", scope = SCOPE,
    code_challenge = b64url(crypto.sha256(verifier)), code_challenge_method = "S256" })
  if not st then return nil, err, "network" end
  if st >= 500 or st == 429 then return nil, "BMW login: " .. why(t, st), "network" end
  if st ~= 200 or not str(t.device_code) then
    return nil, "BMW refused the login: " .. why(t, st), "refused"
  end
  local interval = tonumber(t.interval) or 5
  local deadline = sys.millis() + (tonumber(t.expires_in) or 300) * 1000
  print("bmw: log in at " .. tostring(t.verification_uri) .. " with the code " .. tostring(t.user_code))
  if self.o.on_code then
    self.o.on_code({ user_code = str(t.user_code), uri = str(t.verification_uri), expires_at = deadline })
  end
  while true do
    sleep(interval * 1000)
    if sys.millis() >= deadline then return self:_code_over("the code expired") end
    local pst, r = post(self.auth .. "/token", {
      client_id = self.o.client_id, device_code = t.device_code,
      grant_type = "urn:ietf:params:oauth:grant-type:device_code", code_verifier = verifier })
    local e = r and str(r.error)
    if pst == 200 and r and str(r.access_token) then
      if self.o.on_code then self.o.on_code(nil) end
      print("bmw: logged in")
      return self:_save(r)
    elseif e == "authorization_pending" then                   -- keep waiting
    elseif e == "slow_down" then interval = interval + 5
    elseif not pst or pst >= 500 then                            -- network trouble: keep polling
    elseif e == "access_denied" then return self:_code_over("the login was declined")
    elseif e == "expired_token" then return self:_code_over("the code expired")
    else return self:_code_over("BMW login: " .. why(r or {}, pst)) end
  end
end

function Login:_obtain()
  local rt = secrets.get(NAME)
  if rt then
    local t, err, kind = self:_refresh(rt)
    if t or kind ~= "refused" then return t, err, kind end
    print("bmw: the stored login no longer works (" .. tostring(err) .. "), logging in again")
    secrets.set(NAME, nil)
    self.tok = nil
  end
  return self:_device()
end

-- Tokens that are good for a while yet: the ones in RAM, a refresh, or a
-- new login. Inside task().
function Login:tokens()
  assert(in_task(), 'bmw_login: call inside task()')
  while self.busy do sleep(100) end
  if self.tok and sys.millis() < self.refresh_at then return self.tok end
  self.busy = true
  local ok, a, b, c = pcall(self._obtain, self)
  self.busy = false
  if not ok then error(a, 0) end
  return a, b, c
end

function Login:logout()
  secrets.set(NAME, nil)
  self.tok, self.refresh_at = nil, 0
end

return M
