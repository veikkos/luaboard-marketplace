-- github.lua: a small GitHub REST API client on the built-in http/json, logged
-- in as you through a GitHub App (browser login, built-in oauth.lua).
--
--   local github = require("github")
--   local gh = github.new{ client_id = "...", client_secret = "...",
--                          on_login = function(waiting) ... end }
--   task(function()
--     local me = gh:user()                       -- "octocat"
--     local repos = gh:repos()                   -- the repos the app is installed on
--     local run = gh:last_run("octocat/hello", "main")
--     local n = gh:open_prs("octocat/hello")
--   end)
--
-- Each call returns its result, or nil, message, HTTP status. The login is
-- kept in the secret "github" (`name`). A GitHub App's user tokens last 8
-- hours and come with a refresh token (6 months), which oauth.lua uses by
-- itself. api_url / oauth_url / redirect override GitHub's addresses (tests).

local http, json, oauth = require("http"), require("json"), require("oauth")

local M = {}
local Gh = {}
Gh.__index = Gh

function M.new(o)
  assert(o.client_id and o.client_id ~= "", "github.new: client_id is required")
  local self = setmetatable({ api = o.api_url or "https://api.github.com", retry_at = {} }, Gh)
  local base = o.oauth_url or "https://github.com/login/oauth"
  self.login = oauth.new{
    name = o.name or "github", title = "GitHub",
    client_id = o.client_id, client_secret = o.client_secret,
    authorize_url = base .. "/authorize", token_url = base .. "/access_token",
    redirect = o.redirect or "http://127.0.0.1:8888/callback",
    login_timeout = o.login_timeout, on_login = o.on_login,
  }
  return self
end

-- "2026-11-10T18:22:01Z" -> UTC seconds
local function days_from_civil(y, m, d)
  if m <= 2 then y = y - 1 end
  local era = y // 400
  local yoe = y - era * 400
  local doy = (153 * ((m + 9) % 12) + 2) // 5 + d - 1
  return era * 146097 + yoe * 365 + yoe // 4 - yoe // 100 + doy - 719468
end
function M.time(s)
  local y, mo, d, h, mi, se = tostring(s):match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  if not y then return nil end
  return days_from_civil(tonumber(y), tonumber(mo), tonumber(d)) * 86400 + h * 3600 + mi * 60 + se
end

-- GET a path of the API, decoded. nil, message, status on errors. Search has
-- its own rate limit (30 a minute), apart from the rest of the API's.
function Gh:get(path)
  local limit = path:find("^/search/") and "search" or "core"
  local retry_at = self.retry_at[limit] or 0
  if sys.millis() < retry_at then
    return nil, "rate limited, waiting " .. (retry_at - sys.millis()) // 1000 + 1 .. " s"
  end
  local st, body, h = self.login:request{ url = self.api .. path, headers = {
    Accept = "application/vnd.github+json", ["X-GitHub-Api-Version"] = "2022-11-28" } }
  if not st then return nil, body end
  if st == 200 then
    local ok, t = pcall(json.decode, body)
    if ok and type(t) == "table" then return t end
    return nil, "bad reply", st
  end
  if (st == 403 or st == 429) and (h["x-ratelimit-remaining"] == "0" or h["retry-after"]) then
    local wait = tonumber(h["retry-after"]) or
      ((tonumber(h["x-ratelimit-reset"]) or 0) - (sys.time() or 0))
    wait = math.max(5, math.min(wait, 3600))
    self.retry_at[limit] = sys.millis() + wait * 1000
    return nil, "rate limited, waiting " .. wait .. " s", st
  end
  local ok, t = pcall(json.decode, body)
  local msg = ok and type(t) == "table" and t.message or ("HTTP " .. st)
  return nil, msg, st
end

function Gh:user()
  local t, err, st = self:get("/user")
  if not t then return nil, err, st end
  return t.login
end

-- One repo: { full_name, name, owner, default_branch, pushed_at }
local function repo_info(r)
  return { full_name = r.full_name, name = r.name, owner = r.owner and r.owner.login,
           default_branch = r.default_branch, pushed_at = M.time(r.pushed_at) or 0,
           private = r.private == true }
end

function Gh:repo(full_name)
  local t, err, st = self:get("/repos/" .. full_name)
  if not t then return nil, err, st end
  return repo_info(t)
end

-- The repos the GitHub App is installed on (that you can see), most recently
-- pushed first, at most `max` (default 20).
function Gh:repos(max)
  local inst, err, st = self:get("/user/installations?per_page=100")
  if not inst then return nil, err, st end
  local list = {}
  for _, i in ipairs(inst.installations or {}) do
    local t
    t, err, st = self:get("/user/installations/" .. i.id .. "/repositories?per_page=100")
    if not t then return nil, err, st end
    for _, r in ipairs(t.repositories or {}) do list[#list + 1] = repo_info(r) end
  end
  table.sort(list, function(a, b) return a.pushed_at > b.pushed_at end)
  while #list > (max or 20) do table.remove(list) end
  return list
end

-- The latest workflow run on `branch`: { name, status, conclusion, branch,
-- at, actor, url }, or false if there are none. status: queued, in_progress,
-- completed...; conclusion (when completed): success, failure, cancelled,
-- skipped, timed_out...
function Gh:last_run(full_name, branch)
  local q = "?per_page=1&exclude_pull_requests=true"
  if branch then q = q .. "&branch=" .. http.urlencode(branch) end
  local t, err, st = self:get("/repos/" .. full_name .. "/actions/runs" .. q)
  if not t then return nil, err, st end
  local r = type(t.workflow_runs) == "table" and t.workflow_runs[1]
  if not r then return false end
  local function s(v) return type(v) == "string" and v or nil end
  return { name = s(r.name) or "?", status = s(r.status) or "?", conclusion = s(r.conclusion),
           branch = s(r.head_branch), at = M.time(r.run_started_at or r.created_at),
           actor = type(r.actor) == "table" and s(r.actor.login) or nil, url = s(r.html_url) }
end

-- How many issues / PRs match a search (GitHub's search syntax).
function Gh:count(query)
  local t, err, st = self:get("/search/issues?per_page=1&q=" .. http.urlencode(query))
  if not t then return nil, err, st end
  return math.tointeger(t.total_count) or 0
end

function Gh:open_prs(full_name) return self:count("repo:" .. full_name .. " is:pr is:open") end
function Gh:review_requests() return self:count("is:pr is:open archived:false review-requested:@me") end

function Gh:logged_in() return self.login:logged_in() end
function Gh:logout() self.login:logout() end

return M
