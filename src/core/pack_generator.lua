-- Port of lib/game/pack_generator.dart.
local util = require("src.core.util")
local tagMatch = require("src.core.tag_match")

local P = {}

P.defaultPackCardCount = 10

-- Resolution used to turn a fractional chance into an rng(n) -> [1, n] roll.
local ROLL_RESOLUTION = 1000000

-- setCards: list of CardDefinition; packSettings: list of {tag, count};
-- rng: optional function(n) -> [1, n]. Never repeats a definition, never pads.
--
-- Each setting's count >= 1 guarantees that many cards of its tag (the
-- integer part); any fractional remainder is the probability of one more
-- card of that tag, on top of whatever the pack would otherwise contain.
function P.selectPackCards(setCards, packSettings, rng)
  packSettings = packSettings or {}
  local picked, pickedIds = {}, {}
  local rollRng = rng or math.random

  local function takeRandom(pool, count)
    local shuffled = util.shuffle(util.shallowCopy(pool), rng)
    for i = 1, math.min(count, #shuffled) do
      local card = shuffled[i]
      if not pickedIds[card.id] then
        pickedIds[card.id] = true
        picked[#picked + 1] = card
      end
    end
  end

  local function poolFor(tag)
    return util.filter(setCards, function(c)
      if pickedIds[c.id] then return false end
      for _, entry in ipairs(c.types) do
        local _, t = tagMatch.parse(entry)
        if t == tag then return true end
      end
      return false
    end)
  end

  -- Phase 1: the normal pack -- guaranteed per-tag counts (the integer part
  -- of each setting), or the default random fill when none are configured.
  local anyGuaranteed = false
  for _, setting in ipairs(packSettings) do
    if math.floor(setting.count) >= 1 then anyGuaranteed = true end
  end
  if not anyGuaranteed then
    takeRandom(setCards, P.defaultPackCardCount)
  else
    for _, setting in ipairs(packSettings) do
      local floorCount = math.floor(setting.count)
      if floorCount >= 1 then takeRandom(poolFor(setting.tag), floorCount) end
    end
  end

  -- Phase 2: bonus chance -- each setting's fractional remainder is the
  -- probability of one additional card of that tag.
  for _, setting in ipairs(packSettings) do
    local remainder = setting.count - math.floor(setting.count)
    if remainder > 0 and rollRng(ROLL_RESOLUTION) <= math.floor(remainder * ROLL_RESOLUTION) then
      takeRandom(poolFor(setting.tag), 1)
    end
  end

  return picked
end

return P
