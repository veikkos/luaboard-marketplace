-- wrap(s, cols, [max_lines]) -> { line, ... }: text broken at spaces into
-- lines of at most `cols` font cells. A character is one cell, except "…",
-- which the font draws as "..." (three). A word longer than a line is
-- split. Text cut off by `max_lines` ends its last line with "…", after
-- the last word that fits.

local ELLIPSIS = "…"

local function chars(s)                      -- UTF-8 characters, or bytes if it isn't UTF-8
  local t = {}
  if utf8.len(s) then
    for _, c in utf8.codes(s) do t[#t + 1] = utf8.char(c) end
  else
    for i = 1, #s do t[i] = s:sub(i, i) end
  end
  return t
end

local function cells(s)
  local n = 0
  for _, c in ipairs(chars(s)) do n = n + (c == ELLIPSIS and 3 or 1) end
  return n
end

-- The longest start of s within n cells, and the rest.
local function split(s, n)
  local t, used = chars(s), 0
  for i, c in ipairs(t) do
    local w = c == ELLIPSIS and 3 or 1
    if used + w > n then return table.concat(t, "", 1, i - 1), table.concat(t, "", i) end
    used = used + w
  end
  return s, ""
end

return function(s, cols, max_lines)
  local words = {}
  for w in s:gmatch("%S+") do words[#words + 1] = w end
  local out, line, i = {}, {}, 1
  local function width(l) return cells(table.concat(l, " ")) end
  while i <= #words and not (max_lines and #out >= max_lines) do
    local w = words[i]
    if #line == 0 and cells(w) > cols then         -- a word too long for any line
      local a, b = split(w, cols)
      out[#out + 1] = { a }
      words[i] = b
    elseif #line == 0 or width(line) + 1 + cells(w) <= cols then
      line[#line + 1] = w
      i = i + 1
    else
      out[#out + 1] = line
      line = {}
    end
  end
  if #line > 0 and not (max_lines and #out >= max_lines) then out[#out + 1] = line end
  local cut = max_lines and #out >= max_lines and (i <= #words or #line > 0 and out[#out] ~= line)
  if cut then
    local last = out[max_lines]
    while #last > 1 and width(last) + 3 > cols do table.remove(last) end
    local text = table.concat(last, " ")
    if cells(text) + 3 > cols then text = split(text, cols - 3) end
    out[max_lines] = { text .. ELLIPSIS }
  end
  for k, l in ipairs(out) do out[k] = table.concat(l, " ") end
  return out
end
