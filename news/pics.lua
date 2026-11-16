-- pics: a downloaded JPEG or PNG made into pixels of an exact size, for
-- disp.image. The decoders only shrink by 1, 2, 4 or 8, so the picture is
-- decoded at the step closest above the box, its middle grabbed off the
-- screen and resized in Lua. What the decode drew over is put back in the
-- same call, so nothing of it is ever shown.
--
--   pics.fit(data, w, h, [mode]) -> pixels (w*h*2 bytes, RGB565) or nil, err
--     mode "cover" (default) crops to the box, "contain" shows it all
--   pics.resample(pixels, sw, sh, dw, dh) -> pixels
--   pics.panel(x, y, w, h, word)    the stand-in for a missing picture

local M = {}

local SW, SH = disp.W, disp.H
local PANEL, PANEL_FG = disp.rgb(18, 58, 92), disp.rgb(47, 110, 158)

-- Each output pixel is the average of the source pixels it covers (at least
-- one, so enlarging repeats pixels). Inside a task it lets other things run
-- every 16 rows.
function M.resample(px, sw, sh, dw, dh)
  local byte, char = string.byte, string.char
  local yielding = in_task()
  local xs0, xs1 = {}, {}
  for ox = 0, dw - 1 do
    local x0 = ox * sw // dw
    xs0[ox] = x0
    xs1[ox] = math.max(x0, (ox + 1) * sw // dw - 1)
  end
  local out = {}
  for oy = 0, dh - 1 do
    local y0 = oy * sh // dh
    local y1 = math.max(y0, (oy + 1) * sh // dh - 1)
    local row = {}
    for ox = 0, dw - 1 do
      local r, g, b, n = 0, 0, 0, 0
      for y = y0, y1 do
        local base = y * sw * 2 + 1
        for x = xs0[ox], xs1[ox] do
          local hi, lo = byte(px, base + x * 2, base + x * 2 + 1)
          local v = hi << 8 | lo
          r, g, b, n = r + (v >> 11), g + ((v >> 5) & 63), b + (v & 31), n + 1
        end
      end
      local h = n // 2
      local v = ((r + h) // n) << 11 | ((g + h) // n) << 5 | ((b + h) // n)
      row[ox + 1] = char(v >> 8, v & 255)
    end
    out[oy + 1] = table.concat(row)
    if yielding and oy % 16 == 15 then yield() end
  end
  return table.concat(out)
end

-- The middle of a dw x dh picture with the box's shape, at most the screen
-- (a wider picture is cropped closer rather than decoded smaller): w, h and
-- offsets.
local function crop(dw, dh, w, h)
  local cw = math.min(dw, dh * w // h, SW, SH * w // h)
  local ch = math.min(dh, cw * h // w)
  return cw, ch, (dw - cw) // 2, (dh - ch) // 2
end

local function ceil_div(a, b) return -(-a // b) end

-- The shrink step and the crop: the most shrink whose crop still covers the
-- box, else none (the crop enlarged afterwards). Returns s, cw, ch.
function M.plan(iw, ih, w, h)
  for _, s in ipairs({ 8, 4, 2, 1 }) do
    local cw, ch = crop(ceil_div(iw, s), ceil_div(ih, s), w, h)
    if (cw >= w and ch >= h) or s == 1 then return s, cw, ch end
  end
end

-- The cx,cy cw x ch part of a picture decoded at 1/s, as pixels. Decodes it
-- onto the screen and puts back what was there, in one go.
local function grab_decoded(decode, data, s, dw, dh, cx, cy, cw, ch)
  local uw, uh = math.min(dw - cx, SW), math.min(dh - cy, SH)
  local saved = disp.grab(0, 0, uw, uh)
  if decode == disp.png then disp.rect(0, 0, uw, uh, 0, true) end   -- PNGs blend over it
  local rw, rh = decode(-cx, -cy, data, s)
  local px
  if rw then
    -- the decoder's own rounding of an odd size can be a pixel short
    cw, ch = math.min(cw, rw - cx), math.min(ch, rh - cy)
    if cw >= 1 and ch >= 1 then px = disp.grab(0, 0, cw, ch) end
  end
  disp.image(0, 0, uw, uh, saved)
  if not rw then return nil, rh end
  if not px then return nil, "pics: too small" end
  return px, cw, ch
end

-- Rows y..y+h-1, columns x..x+w-1 of a pw-wide picture.
local function cut(px, pw, x, y, w, h)
  local rows = {}
  for r = 0, h - 1 do
    local i = ((y + r) * pw + x) * 2 + 1
    rows[r + 1] = px:sub(i, i + w * 2 - 1)
  end
  return table.concat(rows)
end

-- Darker and enlarged smoothly (bilinear): the fill around a whole picture.
local function backdrop(px, sw, sh, dw, dh)
  local byte, char = string.byte, string.char
  local function at(x, y)
    local i = (y * sw + x) * 2 + 1
    local hi, lo = byte(px, i, i + 1)
    local v = hi << 8 | lo
    return v >> 11, (v >> 5) & 63, v & 31
  end
  local yielding = in_task()
  local out = {}
  for oy = 0, dh - 1 do
    local fy = math.max(0, (oy + 0.5) * sh / dh - 0.5)
    local y0 = math.min(sh - 1, math.floor(fy)); local y1 = math.min(sh - 1, y0 + 1); local ty = fy - y0
    local row = {}
    for ox = 0, dw - 1 do
      local fx = math.max(0, (ox + 0.5) * sw / dw - 0.5)
      local x0 = math.min(sw - 1, math.floor(fx)); local x1 = math.min(sw - 1, x0 + 1); local tx = fx - x0
      local r00, g00, b00 = at(x0, y0); local r10, g10, b10 = at(x1, y0)
      local r01, g01, b01 = at(x0, y1); local r11, g11, b11 = at(x1, y1)
      local function mix(a, b, c, d) return ((a * (1 - tx) + b * tx) * (1 - ty) + (c * (1 - tx) + d * tx) * ty) * 0.5 end
      local r = math.floor(mix(r00, r10, r01, r11) + 0.5)
      local g = math.floor(mix(g00, g10, g01, g11) + 0.5)
      local b = math.floor(mix(b00, b10, b01, b11) + 0.5)
      local v = r << 11 | g << 5 | b
      row[ox + 1] = char(v >> 8, v & 255)
    end
    out[oy + 1] = table.concat(row)
    if yielding and oy % 16 == 15 then yield() end
  end
  return table.concat(out)
end

-- The whole picture, as large as fits the box, over a dimmed, blurred copy
-- of it filling the rest. A picture close to the box's shape just fills it.
local function contain(decode, data, iw, ih, w, h)
  local tw, th = w, ih * w // iw
  if th > h then tw, th = iw * h // ih, h end
  if tw * 100 >= w * 85 and th * 100 >= h * 85 then return nil end   -- near the box's shape
  if tw < 1 or th < 1 then return nil, "pics: too small" end
  local pick
  for _, s in ipairs({ 8, 4, 2, 1 }) do
    local dw, dh = ceil_div(iw, s), ceil_div(ih, s)
    if dw >= tw and dh >= th and dw <= SW and dh <= SH then pick = s; break end
  end
  if not pick then
    for _, s in ipairs({ 1, 2, 4, 8 }) do
      if ceil_div(iw, s) <= SW and ceil_div(ih, s) <= SH then pick = s; break end
    end
  end
  if not pick then return nil end                       -- too big to decode whole: crop instead
  local dw, dh = ceil_div(iw, pick), ceil_div(ih, pick)
  local px, gw, gh = grab_decoded(decode, data, pick, dw, dh, 0, 0, dw, dh)
  if not px then return nil, gw end
  local fg = M.resample(px, gw, gh, tw, th)
  local cw, ch, cx, cy = crop(gw, gh, w, h)
  local bw, bh = math.max(1, w // 10), math.max(1, h // 10)
  local bg = backdrop(M.resample(cut(px, gw, cx, cy, cw, ch), cw, ch, bw, bh), bw, bh, w, h)
  px = nil
  local x0, y0 = (w - tw) // 2, (h - th) // 2
  local rows = {}
  for y = 0, h - 1 do
    local b = y * w * 2
    if y < y0 or y >= y0 + th then
      rows[y + 1] = bg:sub(b + 1, b + w * 2)
    else
      local f = (y - y0) * tw * 2
      rows[y + 1] = bg:sub(b + 1, b + x0 * 2) .. fg:sub(f + 1, f + tw * 2) .. bg:sub(b + (x0 + tw) * 2 + 1, b + w * 2)
    end
  end
  return table.concat(rows)
end

-- mode "cover" (default): the middle of the picture fills the box.
-- mode "contain": the whole picture, the rest of the box a dimmed copy.
function M.fit(data, w, h, mode)
  local decode = disp.jpeg
  local iw, ih = disp.jpeg_size(data)
  if not iw then
    decode = disp.png
    iw, ih = disp.png_size(data)
  end
  if not iw then return nil, "pics: not an image" end
  if iw < 8 or ih < 8 then return nil, "pics: too small" end   -- a spacer, not a picture
  if mode == "contain" then
    local px, err = contain(decode, data, iw, ih, w, h)
    if px or err then return px, err end
  end
  local s = M.plan(iw, ih, w, h)
  local dw, dh = ceil_div(iw, s), ceil_div(ih, s)
  local cw, ch, cx, cy = crop(dw, dh, w, h)
  if cw < 1 or ch < 1 then return nil, "pics: too small" end
  local px, gw, gh = grab_decoded(decode, data, s, dw, dh, cx, cy, cw, ch)
  if not px then return nil, gw end
  return M.resample(px, gw, gh, w, h)
end

function M.panel(x, y, w, h, word)
  disp.rect(x, y, w, h, PANEL, true)
  word = (word or ""):upper()
  local n = utf8.len(word) or #word
  if n > 8 then word, n = word:sub(1, (utf8.offset(word, 9) or 9) - 1), 8 end
  if n == 0 then return end
  for scale = 4, 1, -1 do
    local tw, th = 6 * n * scale, 7 * scale
    if tw <= w - 8 and th <= h - 4 then
      disp.text(x + (w - tw) // 2, y + (h - th) // 2, word, PANEL_FG, scale)
      return
    end
  end
end

return M
