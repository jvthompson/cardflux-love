-- Hand display settings (LÖVE port only): how the fanned hand is laid out.
-- Values live in settings.json under "hand_<id>"; defaults are left unsaved.
local settings = require("src.data.settings")

local H = {}

-- Ordered for the settings dialog. step is the slider's snapping interval.
H.defs = {
  { id = "cardScale", label = "Card size", min = 1, max = 4, step = 0.05, default = 3,
    format = function(v) return string.format("%.2fx", v) end },
  { id = "spacing", label = "Card spacing", min = 0.2, max = 1.1, step = 0.05, default = 0.6,
    format = function(v) return math.floor(v * 100 + 0.5) .. "% of card width" end },
  { id = "tilt", label = "Tilt between cards", min = 0, max = 10, step = 0.5, default = 3,
    format = function(v) return string.format("%g°", v) end },
  { id = "maxSpread", label = "Maximum fan spread", min = 0, max = 90, step = 1, default = 24,
    format = function(v) return string.format("%g°", v) end },
  { id = "raise", label = "Resting height above hand area", min = 0, max = 200, step = 2, default = 50,
    format = function(v) return string.format("%dpx", v) end },
  { id = "reveal", label = "Card shown on hover", min = 0, max = 1, step = 0.05, default = 1,
    format = function(v) return math.floor(v * 100 + 0.5) .. "%" end },
}

local byId = {}
for _, d in ipairs(H.defs) do byId[d.id] = d end

local cache = {}

local function key(id) return "hand_" .. id end

function H.get(id)
  local v = cache[id]
  if v ~= nil then return v end
  local d = byId[id]
  v = tonumber(settings.get(key(id))) or d.default
  v = math.max(d.min, math.min(d.max, v))
  cache[id] = v
  return v
end

-- live = true only updates the in-memory value (while a slider is held);
-- the next non-live set writes it to settings.json.
function H.set(id, v, live)
  local d = byId[id]
  v = math.max(d.min, math.min(d.max, v))
  cache[id] = v
  if live then return end
  local stored = tonumber(settings.get(key(id)))
  if v == d.default then
    if stored ~= nil then settings.remove(key(id)) end
  elseif stored ~= v then
    settings.set(key(id), v)
  end
end

function H.isDefault()
  for _, d in ipairs(H.defs) do
    if H.get(d.id) ~= d.default then return false end
  end
  return true
end

function H.reset()
  for _, d in ipairs(H.defs) do H.set(d.id, d.default) end
end

return H
