-- Port of the filter/sort logic in lib/ui/widgets/card_sort_menu.dart,
-- shared by the Deck Editor, the Card View tab and the in-game Card Library.
local util = require("src.core.util")

local F = {}

F.sortBySet = "set"
F.sortByName = "name"

-- Returns a new sorted list (or the original list when sortKey is nil).
function F.sortCardDefinitions(cards, sortKey, sets, tagGroups)
  if sortKey == nil then return cards end
  local rank
  if sortKey == F.sortBySet then
    local order = {}
    for i, s in ipairs(sets) do order[s.id] = i - 1 end
    rank = function(c)
      if c.setId == nil then return #sets end
      return order[c.setId] or #sets
    end
  elseif sortKey == F.sortByName then
    rank = function() return 0 end
  else
    local group = util.find(tagGroups, function(g) return g.id == sortKey end)
    local tags = group and group.tags or {}
    local order = {}
    for i, t in ipairs(tags) do order[t] = i - 1 end
    rank = function(c)
      local best = #tags
      for _, tag in ipairs(c.types) do
        local idx = order[tag]
        if idx ~= nil and idx < best then best = idx end
      end
      return best
    end
  end
  local indexed = {}
  for i, c in ipairs(cards) do
    indexed[i] = { c = c, r = rank(c), t = c.cardTitle:lower(), i = i }
  end
  table.sort(indexed, function(a, b)
    if a.r ~= b.r then return a.r < b.r end
    if a.t ~= b.t then return a.t < b.t end
    return a.i < b.i
  end)
  return util.map(indexed, function(e) return e.c end)
end

-- selectedTagsByGroup / excludedTagsByGroup: { groupId -> {tag -> true} };
-- selectedSetIds: {setId -> true}.
function F.cardMatchesFilters(card, tagGroups, selectedTagsByGroup, excludedTagsByGroup, selectedSetIds, searchQuery)
  for _, set in pairs(excludedTagsByGroup or {}) do
    for _, tag in ipairs(card.types) do
      if set[tag] then return false end
    end
  end
  for _, group in ipairs(tagGroups) do
    local selected = selectedTagsByGroup and selectedTagsByGroup[group.id]
    if selected ~= nil and next(selected) ~= nil then
      local ok = false
      for _, tag in ipairs(card.types) do
        if selected[tag] then ok = true break end
      end
      if not ok then return false end
    end
  end
  if selectedSetIds and next(selectedSetIds) ~= nil and card.setId ~= nil and not selectedSetIds[card.setId] then
    return false
  end
  local query = util.trim(searchQuery or ""):lower()
  if query == "" then return true end
  return util.containsText(card.cardTitle:lower(), query) or util.containsText(card.id:lower(), query)
end

return F
