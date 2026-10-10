-- Port of lib/game/pack_generator.dart.
local util = require("src.core.util")

local P = {}

P.defaultPackCardCount = 10

-- setCards: list of CardDefinition; packSettings: list of {tag, count};
-- rng: optional function(n) -> [1, n]. Never repeats a definition, never pads.
function P.selectPackCards(setCards, packSettings, rng)
  packSettings = packSettings or {}
  local picked, pickedIds = {}, {}

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

  if #packSettings == 0 then
    takeRandom(setCards, P.defaultPackCardCount)
    return picked
  end

  for _, setting in ipairs(packSettings) do
    local pool = util.filter(setCards, function(c)
      return not pickedIds[c.id] and util.contains(c.types, setting.tag)
    end)
    takeRandom(pool, setting.count)
  end
  return picked
end

return P
