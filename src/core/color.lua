-- ARGB integer color helpers. Port of lib/models/color_palette.dart.
local color = {}

color.boardWidgetColorPalette = {
  0xFF455A64, -- blueGrey (default background)
  0xFFFFFFFF, -- white (default text)
  0xFF000000, -- black
  0xFFD32F2F, -- red
  0xFFF57C00, -- orange
  0xFFFBC02D, -- yellow
  0xFF388E3C, -- green
  0xFF1976D2, -- blue
  0xFF7B1FA2, -- purple
  0xFF5D4037, -- brown
  0xFF9E9E9E, -- grey
  0xFFEC407A, -- pink
}

-- 6-char uppercase RGB hex for an ARGB int.
function color.hexFromColor(argb)
  return string.format("%06X", argb % 0x1000000)
end

-- Parses "#RRGGBB"/"RRGGBB" to opaque ARGB; returns fallback otherwise.
function color.colorFromHex(input, fallback)
  local cleaned = input:gsub("^%s+", ""):gsub("%s+$", ""):gsub("#", "", 1)
  if #cleaned ~= 6 or cleaned:find("[^%x]") then return fallback end
  return 0xFF000000 + tonumber(cleaned, 16)
end

-- ARGB int -> r, g, b, a floats in 0..1 (for love.graphics.setColor).
function color.toRgba(argb, alphaMul)
  local a = math.floor(argb / 0x1000000) % 0x100
  local r = math.floor(argb / 0x10000) % 0x100
  local g = math.floor(argb / 0x100) % 0x100
  local b = argb % 0x100
  return r / 255, g / 255, b / 255, (a / 255) * (alphaMul or 1)
end

function color.fromRgba(r, g, b, a)
  local function c(x) return math.floor(math.max(0, math.min(1, x)) * 255 + 0.5) end
  return c(a or 1) * 0x1000000 + c(r) * 0x10000 + c(g) * 0x100 + c(b)
end

-- "#D32F2F" -> r, g, b (0..1) or nil.
function color.parseHexRgb(hex)
  if not hex then return nil end
  local argb = color.colorFromHex(hex, nil)
  if not argb then return nil end
  local r, g, b = color.toRgba(argb)
  return r, g, b
end

-- RGB <-> HSL helpers (all components 0..1), used for the player tint
-- (lightness - 0.30) and the color picker.
function color.rgbToHsl(r, g, b)
  local max, min = math.max(r, g, b), math.min(r, g, b)
  local l = (max + min) / 2
  if max == min then return 0, 0, l end
  local d = max - min
  local s = l > 0.5 and d / (2 - max - min) or d / (max + min)
  local h
  if max == r then
    h = (g - b) / d + (g < b and 6 or 0)
  elseif max == g then
    h = (b - r) / d + 2
  else
    h = (r - g) / d + 4
  end
  return h / 6, s, l
end

local function hue2rgb(p, q, t)
  if t < 0 then t = t + 1 end
  if t > 1 then t = t - 1 end
  if t < 1 / 6 then return p + (q - p) * 6 * t end
  if t < 1 / 2 then return q end
  if t < 2 / 3 then return p + (q - p) * (2 / 3 - t) * 6 end
  return p
end

function color.hslToRgb(h, s, l)
  if s == 0 then return l, l, l end
  local q = l < 0.5 and l * (1 + s) or l + s - l * s
  local p = 2 * l - q
  return hue2rgb(p, q, h + 1 / 3), hue2rgb(p, q, h), hue2rgb(p, q, h - 1 / 3)
end

function color.hsvToRgb(h, s, v)
  local i = math.floor(h * 6)
  local f = h * 6 - i
  local p, q, t = v * (1 - s), v * (1 - f * s), v * (1 - (1 - f) * s)
  i = i % 6
  if i == 0 then return v, t, p
  elseif i == 1 then return q, v, p
  elseif i == 2 then return p, v, t
  elseif i == 3 then return p, q, v
  elseif i == 4 then return t, p, v
  else return v, p, q end
end

function color.rgbToHsv(r, g, b)
  local max, min = math.max(r, g, b), math.min(r, g, b)
  local d = max - min
  local h = 0
  if d ~= 0 then
    if max == r then h = ((g - b) / d) % 6
    elseif max == g then h = (b - r) / d + 2
    else h = (r - g) / d + 4 end
    h = h / 6
  end
  return h, (max == 0 and 0 or d / max), max
end

return color
