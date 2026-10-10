-- The Set / tag-group filter buttons, Sort menu and search box shared by
-- every filterable card list (the Deck Editor pool and the table's Card
-- Library), so they all filter identically (see core/card_filters.lua).
local ui = require("src.ui.kit.ui")
local util = require("src.core.util")
local filters = require("src.core.card_filters")
local filterMenu = require("src.ui.kit.filter_menu")

local B = {}

-- Fully permissive: nothing selected, nothing excluded, no search.
function B.newState(game)
  local st = { selected = {}, excluded = {}, sets = {}, query = "" }
  for _, g in ipairs(game.tagGroups) do
    st.selected[g.id] = {}
    st.excluded[g.id] = {}
  end
  return st
end

-- Resets every Set/Type filter. Leaves the sort key and search alone.
function B.clear(st, game)
  st.sets = {}
  for _, g in ipairs(game.tagGroups) do
    st.selected[g.id] = {}
    st.excluded[g.id] = {}
  end
end

function B.visible(st, game)
  local out = {}
  for _, c in ipairs(game.cards) do
    if filters.cardMatchesFilters(c, game.tagGroups, st.selected, st.excluded, st.sets, st.query) then out[#out + 1] = c end
  end
  return filters.sortCardDefinitions(out, st.sortKey, game.sets, game.tagGroups)
end

local function count(set)
  local n = 0
  for _ in pairs(set) do n = n + 1 end
  return n
end

-- "Clear Filters" plus a wrapped row of filter buttons and the Sort menu,
-- starting at y. Draws nothing for a game with no sets or tag groups.
-- Returns the y just below what was drawn.
function B.drawFilters(prefix, st, game, x, y, w)
  local groups = util.filter(game.tagGroups, function(g) return #g.tags > 0 end)
  if #game.sets == 0 and #groups == 0 then return y end
  local yy = y + 12
  if ui.button("Clear Filters", x - 8, yy, nil, 40, { variant = "text", icon = "filter_alt_off", id = prefix .. ":clear" }) then
    B.clear(st, game)
  end
  yy = yy + 44
  local fx = x
  local function place(width)
    if fx + width > x + w and fx > x then
      fx = x
      yy = yy + 48
    end
    local px = fx
    fx = fx + width + 8
    return px
  end
  if #game.sets > 0 then
    local opts = util.map(game.sets, function(s)
      local n = 0
      for _, c in ipairs(game.cards) do if c.setId == s.id then n = n + 1 end end
      return { id = s.id, name = s.name .. " (" .. n .. ")" }
    end)
    local px = place(filterMenu.triggerWidth("Set (" .. count(st.sets) .. ")"))
    filterMenu.multiSelect(prefix .. ":sets", px, yy, "Set", opts, st.sets)
  end
  for _, g in ipairs(groups) do
    local px = place(filterMenu.triggerWidth(g.name .. " (" .. count(st.selected[g.id]) .. ")"))
    filterMenu.multiSelect(prefix .. ":g:" .. g.id, px, yy, g.name, util.map(g.tags, function(t) return { id = t, name = t } end),
      st.selected[g.id], st.excluded[g.id])
  end
  local sortOpts = {}
  if #game.sets > 0 then sortOpts[#sortOpts + 1] = { id = filters.sortBySet, name = "Set" } end
  sortOpts[#sortOpts + 1] = { id = filters.sortByName, name = "Name (A-Z)" }
  for _, g in ipairs(groups) do sortOpts[#sortOpts + 1] = { id = g.id, name = g.name } end
  local label = "Sort"
  for _, o in ipairs(sortOpts) do if o.id == st.sortKey then label = "Sort: " .. o.name end end
  local px = place(filterMenu.triggerWidth(label))
  st.sortKey = filterMenu.sortMenu(prefix .. ":sort", px, yy, sortOpts, st.sortKey)
  return yy + 40
end

-- Search-by-name-or-ID field with a clear button. opts: labelBackground,
-- clearColor. Returns the y just below it.
function B.drawSearch(prefix, st, x, y, w, opts)
  opts = opts or {}
  st.query = ui.textField(prefix .. ":search", x, y, w - (st.query ~= "" and 44 or 0), st.query, {
    label = "Search", hint = "Search by name or ID", h = 44, labelBackground = opts.labelBackground })
  if st.query ~= "" and ui.iconButton("clear", x + w - 40, y + 2, { tooltip = "Clear search", id = prefix .. ":clearq", color = opts.clearColor }) then
    st.query = ""
  end
  return y + 44
end

return B
