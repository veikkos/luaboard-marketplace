-- web: the app's GETs. Never raises: a feed's odd URL or a full socket table
-- comes back as nil, note. Follows redirects, resolves relative URLs, and
-- keeps at most one host's connections open (the board has room for four
-- TLS connections, and a feed's pictures can come from many hosts).
--
--   web.get(url, [base], [headers]) -> body or nil, note, final, wait_s
--     note: a short reason for the screen ("offline", "HTTP 404", ...);
--     final: true when trying again won't help (HTTP 4xx, a bad URL, too big);
--     wait_s: after "rate limit" (HTTP 429), the seconds until asking again
--   web.resolve(url, [base]) -> an absolute http(s) URL or nil

local M = { http = require("http") }

local AGENT = "luaboard-football/1.0"

function M.resolve(url, base)
  if not url or url == "" then return nil end
  if url:match("^https?://[^/?#]") then return url end
  if url:match("^%a[%w+.-]*:") then return nil end           -- data:, ftp:// and the like
  if not base then return nil end
  local scheme, root = base:match("^(https?):(//[^/?#]+)")
  if not scheme then return nil end
  if url:sub(1, 2) == "//" then return scheme .. ":" .. url end
  if url:sub(1, 1) == "/" then return scheme .. ":" .. root .. url end
  return (base:gsub("[?#].*", ""):gsub("[^/]*$", "")) .. url
end

-- A short note for what http.get said, and whether it's final.
local function describe(err)
  err = tostring(err):lower()
  if err:find("too big") then return "too big", true end
  if err:find("resolve") then return "no such host", false end
  if err:find("timeout") or err:find("timed out") then return "timed out", false end
  if err:find("tls") or err:find("ssl") or err:find("certificate") or err:find("handshake") then
    return "TLS error", false
  end
  return "offline", false
end

local last_host

function M.get(url, base, extra)
  local headers = { ["User-Agent"] = AGENT, ["Accept"] = "*/*" }
  for k, v in pairs(extra or {}) do headers[k] = v end
  url = M.resolve(url, base)
  for _ = 1, 4 do
    if not url then return nil, "bad url", true end
    local host = url:match("^https?://([^/?#]+)")
    if host ~= last_host then
      pcall(M.http.close_idle)
      last_host = host
    end
    local ok, status, body, rh = pcall(M.http.get, url, headers)
    if not ok or not status then return nil, describe(ok and body or status) end
    if status == 429 then
      return nil, "rate limit", false, math.max(5, tonumber(rh and rh["x-requestcounter-reset"]) or 60)
    end
    local loc = rh and rh.location
    if status >= 300 and status < 400 and loc then
      url = M.resolve(loc, url)
    elseif status ~= 200 then
      return nil, "HTTP " .. status, status >= 400 and status < 500
    else
      return body
    end
  end
  return nil, "too many redirects", true
end

return M
