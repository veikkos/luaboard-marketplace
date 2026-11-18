-- feed: RSS 2.0 (and RDF) and Atom feeds into plain tables, with string
-- patterns. Enough of XML for feeds: elements, attributes, CDATA and
-- entities; not a general XML parser.
--
--   feed.parse(text, [max]) -> { title = s, items = { item, ... } } or nil, err
--   item = { id, title, link, summary, time (UTC seconds or nil), image (URL or nil) }

local M = {}

local ENT = {
  amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = " ",
  hellip = "…", ndash = "–", mdash = "—", lsquo = "‘", rsquo = "’",
  ldquo = "“", rdquo = "”", laquo = "«", raquo = "»", euro = "€", copy = "©",
}

local function decode(s)
  return (s:gsub("&(#?[xX]?)(%w+);", function(p, v)
    local n
    if p == "" then return ENT[v]
    elseif p == "#" then n = tonumber(v)
    elseif p == "#x" or p == "#X" then n = tonumber(v, 16)
    end
    if n and n > 0 and n <= 0x10FFFF then return utf8.char(n) end
  end))
end

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
local function uncdata(s) return (s:gsub("<!%[CDATA%[(.-)%]%]>", "%1")) end

-- An attribute value or a link: CDATA unwrapped, entities decoded, trimmed.
local function plain(s) return s and trim(decode(uncdata(s))) end

-- Text for the screen: CDATA unwrapped, the HTML in it dropped, entities
-- decoded, whitespace collapsed.
function M.text(s)
  if not s then return "" end
  s = decode(uncdata(s))
  s = s:gsub("<%s*/?%s*[pP]%f[%s>/][^>]*>", " "):gsub("<%s*[bB][rR]%f[%s>/][^>]*>", " ")
       :gsub("<%s*/%s*[dD][iI][vV]%s*>", " "):gsub("<%s*/%s*[lL][iI]%s*>", " ")
       :gsub("<!%-%-.-%-%->", ""):gsub("</?%a[^>]*>", "")
  s = decode(s):gsub("\u{A0}", " "):gsub("%s+", " ")
  return trim(s)
end

-- The content of the first <name ...>...</name> in `b`, raw.
local function tag(b, name)
  return b:match("<" .. name .. "%f[%s>][^>]*>(.-)</" .. name .. "%s*>")
end

local function first(b, ...)
  for _, name in ipairs({ ... }) do
    local v = tag(b, name)
    if v then return v end
  end
end

local function attr(t, name)
  local _, v = t:match("%s" .. name .. "%s*=%s*([\"'])(.-)%1")
  return v and plain(v)
end

-- UTC seconds of a feed's date: ISO 8601 (Atom) or RFC 822 (RSS), as
-- sys.time reads them.
function M.date(s)
  s = s and plain(s)
  if not s or s == "" then return nil end
  return (sys.time(s))
end

local function is_image(t, url)
  local ty = attr(t, "type") or ""
  local path = (url or ""):gsub("[?#].*", ""):lower()
  return attr(t, "medium") == "image" or ty:sub(1, 6) == "image/"
      or path:match("%.jpe?g$") ~= nil or path:match("%.png$") ~= nil
end

-- The picture for an item: the narrowest candidate at least 320 px wide,
-- else the widest, else the first without a width.
local function image(b)
  local cands = {}
  for name, t in b:gmatch("<([%w:]+)(%f[%s/>][^>]*)>") do
    local url, ok
    if name == "media:content" then
      url = attr(t, "url"); ok = url and is_image(t, url)
    elseif name == "media:thumbnail" then
      url = attr(t, "url"); ok = url ~= nil
    elseif name == "enclosure" then
      url = attr(t, "url"); ok = url and (attr(t, "type") or ""):sub(1, 6) == "image/"
    elseif name == "link" and attr(t, "rel") == "enclosure" then
      url = attr(t, "href"); ok = url and (attr(t, "type") or ""):sub(1, 6) == "image/"
    end
    if ok then cands[#cands + 1] = { url = url, w = tonumber(attr(t, "width")) or 0 } end
  end
  local narrow, wide
  for _, c in ipairs(cands) do
    if c.w >= 320 and (not narrow or c.w < narrow.w) then narrow = c end
    if c.w > 0 and (not wide or c.w > wide.w) then wide = c end
  end
  local c = narrow or wide or cands[1]
  return c and c.url
end

local function cut(s, n)
  local len = utf8.len(s)
  if len and len > n then return s:sub(1, utf8.offset(s, n + 1) - 1) end
  if not len and #s > n then return s:sub(1, n) end
  return s
end

local function rss_item(b)
  local link = plain(tag(b, "link"))
  if link == "" then link = nil end
  local title = M.text(tag(b, "title"))
  local guid = plain(tag(b, "guid"))
  return {
    id = (guid and guid ~= "" and guid) or link or title,
    title = title,
    link = link,
    summary = cut(M.text(first(b, "description", "content:encoded", "summary")), 1000),
    time = M.date(first(b, "pubDate", "dc:date", "published", "updated")),
    image = image(b),
  }
end

local function atom_item(b)
  local link
  for t in b:gmatch("<link(%f[%s/>][^>]*)>") do
    local rel = attr(t, "rel")
    if rel == nil or rel == "alternate" then link = attr(t, "href"); break end
  end
  local title = M.text(tag(b, "title"))
  local id = plain(tag(b, "id"))
  return {
    id = (id and id ~= "" and id) or link or title,
    title = title,
    link = link,
    summary = cut(M.text(first(b, "summary", "content", "media:description")), 1000),
    time = M.date(first(b, "published", "updated")),
    image = image(b),
  }
end

local function latin1(s)
  return (s:gsub("[\128-\255]", function(c) return utf8.char(c:byte()) end))
end

function M.parse(text, max)
  max = max or 20
  local enc = (text:match("^%s*<%?xml[^>]-encoding%s*=%s*[\"']([^\"']+)") or ""):lower()
  if enc == "iso-8859-1" or enc == "latin-1" or enc == "latin1" or enc == "windows-1252" then
    text = latin1(text)
  end
  local open, close, one
  if text:find("<rss%f[%s>]") or text:find("<rdf:RDF%f[%s>]") then
    open, close, one = "<item%f[%s>]", "</item%s*>", rss_item
  elseif text:find("<feed%f[%s>]") then
    open, close, one = "<entry%f[%s>]", "</entry%s*>", atom_item
  else
    return nil, "not a feed"
  end
  local start = text:find(open) or #text + 1
  local doc = { title = M.text(tag(text:sub(1, start - 1), "title")), items = {} }
  local pos, yielding = start, in_task()
  while #doc.items < max do
    local s = text:find(open, pos)
    if not s then break end
    local _, e = text:find(close, s)
    if not e then break end
    doc.items[#doc.items + 1] = one(text:sub(s, e))
    pos = e + 1
    if yielding and #doc.items % 4 == 0 then yield() end   -- a big feed is slow on the chip
  end
  return doc
end

return M
