-- pics: team crests (PNG or JPEG) made into square pixels for disp.image,
-- the picture as large as fits, over the row's own color (PNG transparency
-- blends over it). The decoders only shrink by 1, 2, 4 or 8, so a crest is
-- decoded at the step closest above the box, grabbed off the screen and
-- resized in Lua; what the decode drew over is put back in the same call.
-- (resample comes from the news app's pics.lua.)
--
--   pics.crest(data, size, bg) -> pixels (size*size*2 bytes, RGB565) or nil, err
--   pics.badge(x, y, size, tla, color)   the stand-in for a missing crest
--   pics.resample(pixels, sw, sh, dw, dh) -> pixels

local M = {}

local SW, SH = disp.W, disp.H

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

local function ceil_div(a, b) return -(-a // b) end

function M.crest(data, size, bg)
  local decode = disp.jpeg
  local iw, ih = disp.jpeg_size(data)
  if not iw then
    decode = disp.png
    iw, ih = disp.png_size(data)
  end
  if not iw then return nil, "pics: not an image" end
  if iw < 8 or ih < 8 then return nil, "pics: too small" end
  -- the most shrink that keeps the longer side at least the box, on the screen
  local s
  for _, k in ipairs({ 8, 4, 2, 1 }) do
    local dw, dh = ceil_div(iw, k), ceil_div(ih, k)
    if math.max(dw, dh) >= size and dw <= SW and dh <= SH then s = k; break end
  end
  if not s then
    for _, k in ipairs({ 1, 2, 4, 8 }) do
      if ceil_div(iw, k) <= SW and ceil_div(ih, k) <= SH then s = k; break end
    end
  end
  if not s then return nil, "pics: too big" end
  local dw, dh = ceil_div(iw, s), ceil_div(ih, s)
  local saved = disp.grab(0, 0, dw, dh)
  disp.rect(0, 0, dw, dh, bg, true)                -- PNGs blend over the row's color
  local rw, rh = decode(0, 0, data, s)
  local px
  if rw then
    dw, dh = math.min(dw, rw), math.min(dh, rh)
    px = disp.grab(0, 0, dw, dh)
  end
  disp.image(0, 0, ceil_div(iw, s), ceil_div(ih, s), saved)
  if not rw then return nil, rh end
  -- as large as fits, centred on bg
  local tw, th = size, math.max(1, dh * size // dw)
  if dh > dw then tw, th = math.max(1, dw * size // dh), size end
  local fg = M.resample(px, dw, dh, tw, th)
  px = nil
  local b = string.pack(">I2", (bg >> 19 & 31) << 11 | (bg >> 10 & 63) << 5 | (bg >> 3 & 31))
  local x0, y0 = (size - tw) // 2, (size - th) // 2
  local rows = {}
  for y = 0, size - 1 do
    if y < y0 or y >= y0 + th then
      rows[y + 1] = b:rep(size)
    else
      local f = (y - y0) * tw * 2
      rows[y + 1] = b:rep(x0) .. fg:sub(f + 1, f + tw * 2) .. b:rep(size - x0 - tw)
    end
  end
  return table.concat(rows)
end

function M.badge(x, y, size, tla, color)
  disp.rect(x, y, size, size, color, true)
  tla = (tla or "?"):sub(1, 3)
  for scale = 4, 1, -1 do
    local tw, th = disp.text_width(tla, scale), 7 * scale
    if tw <= size - 2 and th <= size - 2 then
      disp.text(x + (size - tw) // 2, y + (size - th) // 2, tla, disp.WHITE, scale)
      return
    end
  end
end

return M
