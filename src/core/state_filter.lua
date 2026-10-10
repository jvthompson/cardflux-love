-- Port of lib/networking/state_filter.dart: hides other players' hands and
-- private-zone cards before a state is sent to a client.
local models = require("src.core.models")
local util = require("src.core.util")

local F = {}

-- visibleZoneIds: set {zoneId -> true} of zones marked visibleToAll.
function F.filterForRecipient(trueState, recipientId, visibleZoneIds)
  local cards = util.map(trueState.cards, function(card)
    local isPrivateZoneCard = card.zone == "zone" and not visibleZoneIds[card.zoneId or ""]
    local isOpponentPrivate = card.ownerId ~= nil and card.ownerId ~= recipientId
      and (card.zone == "hand" or isPrivateZoneCard)
    if not isOpponentPrivate then return card end
    return util.copyWith(card, { faceUp = false, definitionId = models.hiddenDefinitionId })
  end)
  return util.copyWith(trueState, { cards = cards })
end

return F
