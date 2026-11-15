-- spotify.lua: Spotify Web API client on the built-in http/json. The login runs
-- once through the built-in oauth.lua.
--
--   local spotify = require("spotify")
--   local sp = spotify.new{ client_id = "<your app's Client ID>",
--                           on_login = function(waiting) ... end }
--   task(function()
--     local p = sp:player()      -- table, false (nothing playing) or nil, err
--     sp:next()  sp:previous()  sp:play()  sp:pause()
--     local jpeg = sp:cover(p.cover)
--   end)
--
-- The app needs the redirect URI http://127.0.0.1:8888/callback (or pass
-- `redirect`). The login is kept in the secret "spotify" (`name`).
-- api_url / accounts_url override Spotify's addresses (tests, proxies).

local http, json, oauth = require('http'), require('json'), require('oauth')

local M = {}
local Sp = {}
Sp.__index = Sp

M.SCOPES = 'user-read-playback-state user-modify-playback-state user-read-currently-playing'

function M.new(o)
  assert(o.client_id and o.client_id ~= '', 'spotify.new: client_id is required')
  local self = setmetatable({ retry_at = 0, api = o.api_url or 'https://api.spotify.com/v1' }, Sp)
  local accounts = o.accounts_url or 'https://accounts.spotify.com'
  self.login = oauth.new{
    name = o.name or 'spotify', title = 'Spotify', client_id = o.client_id, scope = M.SCOPES,
    authorize_url = accounts .. '/authorize',
    token_url = accounts .. '/api/token',
    redirect = o.redirect or 'http://127.0.0.1:8888/callback',
    on_login = o.on_login,
  }
  return self
end

-- One API call. Returns status, body or nil, message, status.
function Sp:_call(method, path, body)
  if sys.millis() < self.retry_at then
    return nil, 'rate limited, retrying in ' .. (self.retry_at - sys.millis()) // 1000 + 1 .. ' s'
  end
  local st, b, h = self.login:request{ method = method, url = self.api .. path, body = body,
    headers = body and { ['Content-Type'] = 'application/json' } or nil }
  if not st then return nil, b end
  if st >= 200 and st < 300 then return st, b end
  if st == 429 then
    local wait = tonumber(h['retry-after']) or 5
    self.retry_at = sys.millis() + wait * 1000
    return nil, 'rate limited, retrying in ' .. wait .. ' s', st
  end
  local t = json.decode(b)
  local msg = type(t) == 'table' and type(t.error) == 'table' and t.error.message or ('HTTP ' .. st)
  if st == 403 then msg = msg .. ' (playback control needs Spotify Premium)' end
  if st == 404 then msg = 'no active Spotify device: start playing somewhere first' end
  return nil, msg, st
end

-- Current playback: { playing, title, artist, album, progress, duration,
-- device, cover (URL of the ~300 px image), id }, false if nothing is
-- playing, or nil, err.
function Sp:player()
  local st, b = self:_call('GET', '/me/player?additional_types=episode')
  if not st then return nil, b end
  if st == 204 or b == '' then return false end
  local p = json.decode(b)
  if type(p) ~= 'table' then return nil, 'bad answer from Spotify' end
  local it = p.item
  if not it or it == json.null then return false end
  local artist, album, images
  if it.type == 'episode' then
    artist = it.show and it.show.name or ''
    album, images = 'podcast', it.images or (it.show and it.show.images) or {}
  else
    local names = {}
    for _, a in ipairs(it.artists or {}) do names[#names + 1] = a.name end
    artist = table.concat(names, ', ')
    album, images = it.album and it.album.name or '', it.album and it.album.images or {}
  end
  -- the smallest image that is at least 300 px (Spotify sends 640, 300, 64)
  local cover, best
  for _, im in ipairs(images) do
    local w = tonumber(im.width) or 0
    if w >= 300 and (not best or w < best) then cover, best = im.url, w end
  end
  if not cover and images[1] then cover = images[1].url end
  return {
    playing = p.is_playing == true, title = it.name or '', artist = artist, album = album,
    progress = tonumber(p.progress_ms) or 0, duration = tonumber(it.duration_ms) or 0,
    device = p.device and p.device ~= json.null and p.device.name or '', cover = cover, id = it.id,
  }
end

function Sp:play() return self:_call('PUT', '/me/player/play') end
function Sp:pause() return self:_call('PUT', '/me/player/pause') end
function Sp:next() return self:_call('POST', '/me/player/next') end
function Sp:previous() return self:_call('POST', '/me/player/previous') end

-- Cover art JPEG (for disp.jpeg).
function Sp:cover(url)
  local st, b = http.get(url)
  if st == 200 then return b end
  return nil, st and ('cover: HTTP ' .. st) or b
end

function Sp:logout() self.login:logout() end

return M
