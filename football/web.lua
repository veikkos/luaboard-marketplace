-- web: the app's GETs. Never raises: an odd URL comes back as nil, note.
-- Resolves relative URLs; http follows redirects and lets go of kept
-- connections when the board is out of sockets.
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
  if err:find("url") then return "bad url", true end
  if err:find("redirect") then return "too many redirects", true end
  if err:find("resolve") then return "no such host", false end
  if err:find("timeout") or err:find("timed out") then return "timed out", false end
  if err:find("tls") or err:find("ssl") or err:find("certificate") or err:find("handshake") then
    return "TLS error", false
  end
  return "offline", false
end

function M.get(url, base, extra)
  local headers = { ["User-Agent"] = AGENT, ["Accept"] = "*/*" }
  for k, v in pairs(extra or {}) do headers[k] = v end
  url = M.resolve(url, base)
  if not url then return nil, "bad url", true end
  local ok, status, body, rh = pcall(M.http.get, url, headers)
  if not ok or not status then return nil, describe(ok and body or status) end
  if status == 429 then
    return nil, "rate limit", false, math.max(5, tonumber(rh and rh["x-requestcounter-reset"]) or 60)
  end
  if status ~= 200 then return nil, "HTTP " .. status, status >= 400 and status < 500 end
  return body
end

return M
