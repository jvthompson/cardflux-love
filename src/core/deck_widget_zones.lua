-- Port of lib/game/deck_widget_zones.dart: synthetic zone ids for the cards
-- held inside a Deck Widget, "deckWidget:<widgetInstanceId>:<realZoneId>".
local D = {}

local PREFIX = "deckWidget:"

function D.build(widgetInstanceId, realZoneId)
  return PREFIX .. widgetInstanceId .. ":" .. realZoneId
end

function D.isDeckWidgetZoneId(zoneId)
  return zoneId ~= nil and zoneId:sub(1, #PREFIX) == PREFIX
end

-- Returns {widgetInstanceId=, realZoneId=} or nil when malformed.
function D.parse(zoneId)
  if not D.isDeckWidgetZoneId(zoneId) then return nil end
  local rest = zoneId:sub(#PREFIX + 1)
  local sep = rest:find(":", 1, true)
  if not sep or sep <= 1 then return nil end
  local realZoneId = rest:sub(sep + 1)
  if realZoneId == "" then return nil end
  return { widgetInstanceId = rest:sub(1, sep - 1), realZoneId = realZoneId }
end

return D
