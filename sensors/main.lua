-- sensors: what the board's own sensors measure, a page each: motion (a
-- level), the compass, light and proximity, and the camera's live picture
-- with a button that saves a photo on the SD card. A swipe to the side
-- changes the page, as the buttons A and C do where there are any.
-- CoreS3 and CoreS3 Lite have the sensors; on an SE every page says so.

local W, H = disp.W, disp.H
local TOP = 20                                  -- the header's height
local PAGES = { "Motion", "Compass", "Light", "Camera" }
local page = 1

local function clamp(v, lo, hi) return v < lo and lo or v > hi and hi or v end

local function header()
  disp.rect(0, 0, W, TOP, disp.NAVY, true)
  disp.text(6, 6, PAGES[page], disp.WHITE)
  for i = 1, #PAGES do                          -- a dot a page, this one filled
    disp.circle(W - 12 * (#PAGES - i + 1), TOP // 2, 3, i == page and disp.WHITE or disp.GRAY, i == page)
  end
end

local function hint(text) disp.text(W // 2, H - 10, text, disp.GRAY, 1, nil, "center") end

-- A sensor that didn't answer: why, in the middle of the page.
local function missing(err)
  disp.text(W // 2, H // 2 - 4, err or "no reading", disp.ORANGE, 1, nil, "center")
end

-- Three numbers under a title, at x.
local function triple(x, y, title, a, b, c, fmt)
  disp.text(x, y, title, disp.GRAY)
  for i, v in ipairs({ a, b, c }) do
    disp.text(x, y + 2 + i * 14, ("xyz"):sub(i, i), disp.GRAY)
    disp.text(x + 78, y + 2 + i * 14, fmt:format(v), disp.WHITE, 1, nil, "right")
  end
end

-- A bar filled to part (0..1) of its length.
local function bar(x, y, w, part, color)
  disp.rect(x, y, w, 14, disp.DARKGRAY)
  disp.rect(x + 1, y + 1, math.floor((w - 2) * clamp(part, 0, 1)), 12, color, true)
end

------------------------------------------------------------------ motion

-- A level: the bubble goes where down is, and sits in the middle with the
-- board flat.
local function motion()
  local ax, ay, az = imu.accel()
  if not ax then return missing(ay) end
  local gx, gy, gz = imu.gyro()
  local cx, cy, r = 100, 125, 85
  disp.circle(cx, cy, r, disp.GRAY)
  disp.circle(cx, cy, 14, disp.DARKGRAY)
  disp.line(cx - r, cy, cx + r, cy, disp.DARKGRAY)
  disp.line(cx, cy - r, cx, cy + r, disp.DARKGRAY)
  local bx, by = clamp(ax, -1, 1) * (r - 12), clamp(ay, -1, 1) * (r - 12)
  local flat = math.abs(ax) < 0.03 and math.abs(ay) < 0.03
  disp.circle(math.floor(cx + bx), math.floor(cy + by), 11, flat and disp.GREEN or disp.YELLOW, true)
  triple(214, 34, "accel, g", ax, ay, az, "%+.2f")
  if gx then triple(214, 122, "gyro, deg/s", gx, gy, gz, "%+.0f") end
end

----------------------------------------------------------------- compass

-- The compass measures the board's own iron and magnets along with the
-- earth's field. Those turn with the board, the earth's doesn't: so the
-- middle of what each axis has read, once the board has been turned
-- around, is the board's own part, and the rest points north.
local lo, hi

local function compass_reset() lo, hi = { 1e9, 1e9, 1e9 }, { -1e9, -1e9, -1e9 } end
compass_reset()

local function compass()
  local x, y, z = imu.mag()
  if not x then
    missing(y)
    if y and y:find("too strong") then
      disp.text(W // 2, H // 2 + 14, "A magnet is next to the compass.", disp.GRAY, 1, nil, "center")
      disp.text(W // 2, H // 2 + 28, "On a CoreS3 Lite: the back cover's.", disp.GRAY, 1, nil, "center")
    end
    return
  end
  local m = { x, y, z }
  for i = 1, 3 do lo[i], hi[i] = math.min(lo[i], m[i]), math.max(hi[i], m[i]) end
  local hx, hy = x - (lo[1] + hi[1]) / 2, y - (lo[2] + hi[2]) / 2
  local turned = hi[1] - lo[1] > 25 and hi[2] - lo[2] > 25       -- seen from enough sides
  local cx, cy, r = 100, 125, 85
  disp.circle(cx, cy, r, disp.GRAY)
  disp.text(cx, cy - r + 6, "N", turned and disp.DARKGRAY or disp.BLACK, 1, nil, "center")
  if turned then
    local len = math.sqrt(hx * hx + hy * hy)
    if len > 1 then
      local nx, ny = hx / len, hy / len                           -- towards north, in the screen's plane
      local tx, ty = math.floor(cx + nx * (r - 10)), math.floor(cy + ny * (r - 10))
      disp.line(cx, cy, tx, ty, disp.RED)
      disp.line(cx, cy, math.floor(cx - nx * (r - 10)), math.floor(cy - ny * (r - 10)), disp.GRAY)
      disp.circle(tx, ty, 5, disp.RED, true)
    end
    hint("held flat, the red end points north.  Tap: start over")
  else
    disp.text(cx, cy - 12, "Turn the board", disp.WHITE, 1, nil, "center")
    disp.text(cx, cy + 2, "around once, flat", disp.WHITE, 1, nil, "center")
  end
  disp.circle(cx, cy, 3, disp.WHITE, true)
  triple(214, 34, "field, uT", x, y, z, "%+.1f")
  disp.text(214, 122, "in all", disp.GRAY)
  disp.text(292, 138, ("%.1f"):format(math.sqrt(x * x + y * y + z * z)), disp.WHITE, 1, nil, "right")
end

------------------------------------------------------------------- light

local function light_page()
  local lux, err = light.lux()
  if not lux then return missing(err) end
  local near = light.proximity() or 0
  disp.text(20, 44, "Light", disp.GRAY)
  disp.text(20, 60, ("%.0f lux"):format(lux), disp.WHITE, 3)
  -- The bar by powers of ten: a dim room, a lit one and sunlight are each a step apart.
  bar(20, 92, W - 40, math.log(lux + 1, 10) / 5, disp.YELLOW)
  disp.text(20, 110, "dark", disp.GRAY)
  disp.text(W - 20, 110, "sunlight", disp.GRAY, 1, nil, "right")
  disp.text(20, 140, "Proximity", disp.GRAY)
  disp.text(20, 156, tostring(near), disp.WHITE, 3)
  bar(20, 188, W - 40, near / 2047, disp.CYAN)
  disp.text(20, 206, "nothing near", disp.GRAY)
  disp.text(W - 20, 206, "touching", disp.GRAY, 1, nil, "right")
end

------------------------------------------------------------------ camera

-- The live picture with a button on it: a tap on the button (or B) saves
-- a photo on the SD card, a tap on the picture mirrors it. Without a card the page says so, in red, from
-- the moment it opens.
local BTN_X, BTN_Y, BTN_R = W // 2, H - 34, 22
local card_err                                  -- why photos can't be saved, nil if they can
local saved, saved_until = nil, 0               -- the line about the last photo, for a while
local photo_n = 1
local mirrored = false                          -- a tap on the picture: as in a mirror, or as others see it

local function card_check()
  local there, err = sd.exists("photo_1.jpg")
  card_err = there == nil and err or nil
end

local function banner(text, color)
  disp.rect(0, 0, W, TOP, color, true)
  disp.text(W // 2, 6, text, disp.WHITE, 1, nil, "center")
end

local function card_text()
  if card_err == "no card" then return "No SD card in the slot: photos can't be saved" end
  return "SD card: " .. tostring(card_err)
end

local function camera_page()
  local w, err = camera.draw()
  if not w then
    disp.clear(disp.BLACK)
    header()
    return missing(err)
  end
  if card_err then banner(card_text(), disp.RED)
  elseif saved and sys.millis() < saved_until then banner(saved, 0x007000)
  else disp.text(6, 6, mirrored and "Camera, mirrored" or "Camera", disp.WHITE) end
  disp.circle(BTN_X, BTN_Y, BTN_R, disp.WHITE)                    -- the button: a ring around a disc,
  disp.circle(BTN_X, BTN_Y, BTN_R - 1, disp.WHITE)
  disp.circle(BTN_X, BTN_Y, BTN_R - 5, card_err and disp.GRAY or disp.WHITE, true)   -- grey while it can't save
end

local function photo()
  local data, err = camera.jpeg(90)
  if not data then
    saved, saved_until = nil, 0
    card_err = err
    return
  end
  local name
  repeat                                         -- the first number not on the card yet
    name = ("photo_%d.jpg"):format(photo_n)
    local there, e = sd.exists(name)
    if there == nil then card_err = e return end
    if there then photo_n = photo_n + 1 end
  until not there
  local ok, e = sd.write(name, data)
  if not ok then card_err = e return end
  card_err = nil
  saved, saved_until = ("Saved %s, %d KB"):format(name, (#data + 512) // 1024), sys.millis() + 3000
end

------------------------------------------------------------------- pages

local draw = { motion, compass, light_page, camera_page }

local function go(step)
  if PAGES[page] == "Camera" then camera.stop() end              -- it draws a good part of the board's power
  page = (page - 1 + step) % #PAGES + 1
  if PAGES[page] == "Camera" then card_check() end
end

touch.on("swipe", function(dir)
  if dir == "left" then go(1) elseif dir == "right" then go(-1) end
end)
touch.on("press", function(b)
  if b == "C" then go(1) elseif b == "A" then go(-1) end
  if b == "B" and PAGES[page] == "Camera" then photo() end
end)
touch.on("tap", function(x, y)
  if PAGES[page] == "Compass" then compass_reset() end
  if PAGES[page] == "Camera" then
    if math.abs(x - BTN_X) <= BTN_R + 12 and math.abs(y - BTN_Y) <= BTN_R + 12 then photo()
    else
      mirrored = not mirrored
      camera.mirror(mirrored)
    end
  end
end)

function loop()
  if PAGES[page] ~= "Camera" then               -- the camera's picture is the whole screen
    disp.clear(disp.BLACK)
    header()
  end
  draw[page]()
end
