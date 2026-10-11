-- Pure helpers for table box selection and keeping moved items on the
-- table (no love.* calls, so they are unit-tested directly).
local geometry = require("src.core.geometry")

local S = {}

local WW, WH = geometry.worldWidth, geometry.worldHeight
local M = geometry.tablePanMarginFraction
S.EDGE_MARGIN = 10

-- Normalized screen rect between two corner points.
function S.rectFromPoints(x1, y1, x2, y2)
  return { x = math.min(x1, x2), y = math.min(y1, y2), w = math.abs(x2 - x1), h = math.abs(y2 - y1) }
end

local function rectsOverlap(ax, ay, aw, ah, b)
  return ax < b.x + b.w and ax + aw > b.x and ay < b.y + b.h and ay + ah > b.y
end

-- Does a hit item (see table_view.lua addItem) touch the rect? Rotated
-- items use the bounding box of the rotated rect, circles test the closest
-- point, and everything else its x/y/w/h box.
function S.boxHits(rect, item)
  if item.circle then
    local nx = math.max(rect.x, math.min(item.cx, rect.x + rect.w))
    local ny = math.max(rect.y, math.min(item.cy, rect.y + rect.h))
    local dx, dy = item.cx - nx, item.cy - ny
    return dx * dx + dy * dy <= item.circle * item.circle
  end
  if item.angle and item.angle ~= 0 and item.hw then
    local c, s = math.abs(math.cos(item.angle)), math.abs(math.sin(item.angle))
    local ex = item.hw * c + item.hh * s
    local ey = item.hw * s + item.hh * c
    return rectsOverlap(item.cx - ex, item.cy - ey, 2 * ex, 2 * ey, rect)
  end
  return rectsOverlap(item.x, item.y, item.w, item.h, rect)
end

-- Half extents of a card-sized item turned by `turns` (full turns); odd
-- quarter turns swap width and height.
function S.halfExtents(w, h, turns)
  local q = math.floor((turns or 0) * 4 + 0.5) % 2
  if q == 1 then return h / 2, w / 2 end
  return w / 2, h / 2
end

-- Clamps a world-pixel center so an item with the given half extents lies
-- fully inside the reachable table (the world plus its pan margin).
function S.clampWorldCenter(wx, wy, halfW, halfH)
  local function clamp(v, size, half)
    local lo = -M * size + S.EDGE_MARGIN + half
    local hi = size * (1 + M) - S.EDGE_MARGIN - half
    if lo > hi then return size / 2 end
    return math.max(lo, math.min(hi, v))
  end
  return clamp(wx, WW, halfW), clamp(wy, WH, halfH)
end

return S
