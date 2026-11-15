-- gcal.lua: read-only Google Calendar API client. The login runs once through
-- the built-in oauth.lua.
--
--   local gcal = require("gcal")
--   local cal = gcal.new{ client_id = "...", client_secret = "...",
--                         on_login = function(waiting) ... end }
--   task(function()
--     local cals = cal:calendars()     -- { { id, name, primary, defaults } } or nil, err
--     local evs = cal:events(cals[1], t_min, t_max)   -- agenda.normalize()d events
--   end)
--
-- Needs a Google Cloud "Desktop app" OAuth client: any loopback redirect works,
-- and Google wants its client secret with token requests. The login is kept in
-- the secret "gcal". api_url / authorize_url / token_url override Google's
-- addresses (tests).

local http, json, oauth = require('http'), require('json'), require('oauth')
local agenda = require('agenda')

local M = {}
local Cal = {}
Cal.__index = Cal

M.SCOPE = 'https://www.googleapis.com/auth/calendar.readonly'

function M.new(o)
  assert(o.client_id and o.client_id ~= '', 'gcal.new: client_id is required')
  local self = setmetatable({ api = o.api_url or 'https://www.googleapis.com/calendar/v3' }, Cal)
  self.login = oauth.new{
    name = 'gcal', title = 'Google Calendar', client_id = o.client_id, client_secret = o.client_secret,
    scope = M.SCOPE,
    authorize_url = o.authorize_url or 'https://accounts.google.com/o/oauth2/v2/auth',
    token_url = o.token_url or 'https://oauth2.googleapis.com/token',
    redirect = o.redirect or 'http://127.0.0.1:8890/callback',
    params = { access_type = 'offline', prompt = 'consent' },
    on_login = o.on_login, login_timeout = o.login_timeout,
  }
  return self
end

-- GET a path with a query; the decoded JSON, or nil, message.
function Cal:_get(path, query)
  local st, body = self.login:request{ url = self.api .. path .. '?' .. http.form(query) }
  if not st then return nil, body end
  if st ~= 200 then
    local t = json.decode(body)
    local msg = type(t) == 'table' and type(t.error) == 'table' and t.error.message
    return nil, 'HTTP ' .. st .. (msg and (': ' .. tostring(msg)) or '')
  end
  local t = json.decode(body)
  if type(t) ~= 'table' then return nil, 'bad answer from Google' end
  return t
end

-- The user's calendars: { id, name (ASCII), primary, defaults = { popup minutes } }.
function Cal:calendars()
  local t, err = self:_get('/users/me/calendarList', { fields = 'items(id,summary,primary,defaultReminders)' })
  if not t then return nil, err end
  local out = {}
  for _, c in ipairs(type(t.items) == 'table' and t.items or {}) do
    local defaults = {}
    for _, r in ipairs(type(c.defaultReminders) == 'table' and c.defaultReminders or {}) do
      if r.method == 'popup' and tonumber(r.minutes) then defaults[#defaults + 1] = math.tointeger(r.minutes) or r.minutes end
    end
    out[#out + 1] = { id = c.id, name = tostring(c.summary or c.id), primary = c.primary == true,
                      defaults = defaults }
  end
  return out
end

local function rfc3339(t)
  local d = sys.date(t, 'UTC')
  return string.format('%04d-%02d-%02dT%02d:%02d:%02dZ', d.year, d.month, d.day, d.hour, d.min, d.sec)
end

-- Events of one calendar (an entry of calendars()) between two UTC times,
-- recurring ones expanded, through agenda.normalize().
function Cal:events(calendar, t_min, t_max)
  local t, err = self:_get('/calendars/' .. http.urlencode(calendar.id) .. '/events', {
    singleEvents = 'true', orderBy = 'startTime', maxResults = '50',
    maxAttendees = '1',                 -- only our own entry (declined?), not a 2000-person all-hands
    timeMin = rfc3339(t_min), timeMax = rfc3339(t_max),
    fields = 'items(id,summary,status,start,end,transparency,attendees(self,responseStatus),reminders)',
  })
  if not t then return nil, err end
  return agenda.normalize(t.items, calendar.id, calendar.defaults)
end

function Cal:logged_in() return self.login:logged_in() end
function Cal:logout() self.login:logout() end

return M
