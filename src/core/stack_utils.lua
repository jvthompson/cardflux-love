-- Port of lib/game/stack_utils.dart. A "stack" (pile) on the table is a
-- chain of cards linked through stackParentId; its root is the bottom card.
local S = {}

local function indexById(cards)
  local idx = {}
  for _, c in ipairs(cards) do
    if idx[c.instanceId] == nil then idx[c.instanceId] = c end
  end
  return idx
end

local function rootIdWithIndex(idx, card)
  local current = card
  local visited = {}
  while current.stackParentId ~= nil and not visited[current.instanceId] do
    visited[current.instanceId] = true
    local parent = idx[current.stackParentId]
    if parent == nil then break end
    current = parent
  end
  return current.instanceId
end

function S.rootIdOf(cards, card)
  return rootIdWithIndex(indexById(cards), card)
end

function S.stackOf(cards, rootInstanceId)
  local idx = indexById(cards)
  local out = {}
  for _, c in ipairs(cards) do
    if c.instanceId == rootInstanceId or rootIdWithIndex(idx, c) == rootInstanceId then
      out[#out + 1] = c
    end
  end
  return out
end

-- Returns map rootId -> list of cards, plus an ordered list of root ids
-- (first-seen order, like Dart's LinkedHashMap).
function S.groupByStack(cards)
  local idx = indexById(cards)
  local groups, order = {}, {}
  for _, c in ipairs(cards) do
    local root = rootIdWithIndex(idx, c)
    local g = groups[root]
    if not g then
      g = {}
      groups[root] = g
      order[#order + 1] = root
    end
    g[#g + 1] = c
  end
  return groups, order
end

-- Highest zIndex; ties go to the earlier card (Dart's reduce with >=).
function S.topOf(stack)
  local best = stack[1]
  for i = 2, #stack do
    if not (best.zIndex >= stack[i].zIndex) then best = stack[i] end
  end
  return best
end

return S
