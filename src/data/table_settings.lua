-- Table display settings (LÖVE port only). The selection color is stored
-- as an ARGB int under settings.json "selection_color"; the default is left
-- unsaved.
local settings = require("src.data.settings")

local T = {}

T.defaultSelectionColor = 0xFFFFEB3B -- Material yellow 500

local cached

function T.selectionColor()
  if cached == nil then
    local v = tonumber(settings.get(settings.keys.selectionColor))
    cached = v and math.floor(v) or T.defaultSelectionColor
  end
  return cached
end

function T.setSelectionColor(argb)
  if argb == T.selectionColor() then return end
  cached = argb
  if argb == T.defaultSelectionColor then
    settings.remove(settings.keys.selectionColor)
  else
    settings.set(settings.keys.selectionColor, argb)
  end
end

function T.isDefault() return T.selectionColor() == T.defaultSelectionColor end
function T.reset() T.setSelectionColor(T.defaultSelectionColor) end

return T
