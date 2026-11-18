-- wrap(s, cols, [max_lines]) -> { line, ... }: text broken at spaces into
-- lines of at most `cols` font cells (disp.wrap). Text cut off by
-- `max_lines` ends its last line with "…", after the last word that fits.

local ELLIPSIS = "…"

return function(s, cols, max_lines)
  local width = 6 * cols - 1                     -- cols cells, in pixels
  local function fits(l) return disp.text_width(l) <= width end
  local lines = disp.wrap((s:gsub("%s", " ")), width)
  if not max_lines or #lines <= max_lines then return lines end
  local last = lines[max_lines]
  while not fits(last .. ELLIPSIS) and last:find(" ") do last = last:match("^(.*) ") end
  while not fits(last .. ELLIPSIS) and #last > 0 do last = last:sub(1, (utf8.offset(last, -1) or #last) - 1) end
  lines = table.move(lines, 1, max_lines - 1, 1, {})
  lines[max_lines] = last .. ELLIPSIS
  return lines
end
