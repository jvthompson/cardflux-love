-- The Set / tag-group filter buttons, Sort menu and search box shared by
-- every filterable card list (the Deck Editor pool and the table's Card
-- Library), so they all filter identically (see core/card_filters.lua).
local ui = require("src.ui.kit.ui")
local theme = require("src.ui.kit.theme")
local util = require("src.core.util")
local filters = require("src.core.card_filters")
local filterMenu = require("src.ui.kit.filter_menu")

local input = ui.input

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

-- True when any Set/Type filter is on (search and sort don't count).
function B.isFiltered(st)
  if next(st.sets) then return true end
  for _, m in pairs(st.selected) do if next(m) then return true end end
  for _, m in pairs(st.excluded) do if next(m) then return true end end
  return false
end

-- "Clear Filters" plus a wrapped row of filter buttons and the Sort menu,
-- starting at y. Draws nothing for a game with no sets or tag groups.
-- Returns the y just below what was drawn.
-- opts.compact: one row -- opts.leading buttons ({label=, icon=, id=,
-- onClick=}) first, then the filters, and Clear Filters at the end only
-- while a filter is on.
function B.drawFilters(prefix, st, game, x, y, w, opts)
  opts = opts or {}
  local compact = opts.compact
  local groups = util.filter(game.tagGroups, function(g) return #g.tags > 0 end)
  local leading = opts.leading or {}
  if #game.sets == 0 and #groups == 0 and #leading == 0 then return y end
  local yy = y + 12
  if not compact then
    if ui.button("Clear Filters", x - 8, yy, nil, 40, { variant = "text", icon = "filter_alt_off", id = prefix .. ":clear" }) then
      B.clear(st, game)
    end
    yy = yy + 44
  end
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
  for _, b in ipairs(leading) do
    local bw = ui.buttonWidth(b.label, { icon = b.icon })
    local px = place(bw)
    if ui.button(b.label, px, yy, bw, 40, { variant = b.variant or "tonal", icon = b.icon, id = b.id }) then b.onClick() end
  end
  if #leading > 0 and (#game.sets > 0 or #groups > 0) then
    ui.rect("fill", fx, yy + 8, 1, 24, 0, theme.c.outlineVariant)
    fx = fx + 9
  end
  if #game.sets == 0 and #groups == 0 then return yy + 40 end
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
  if compact and B.isFiltered(st) then
    local label = "Clear Filters"
    local bw = ui.buttonWidth(label, { icon = "filter_alt_off" })
    px = place(bw)
    if ui.button(label, px, yy, bw, 40, { variant = "text", icon = "filter_alt_off", id = prefix .. ":clear" }) then
      B.clear(st, game)
    end
  end
  return yy + 40
end

-- Every distinct extraField name across the game's cards (case-insensitive
-- dedup, first-seen casing kept), alphabetical.
local function extraFieldNames(game)
  local seen, names = {}, {}
  for _, c in ipairs(game.cards) do
    for key in pairs(c.extraFields) do
      local lk = key:lower()
      if not seen[lk] then
        seen[lk] = true
        names[#names + 1] = key
      end
    end
  end
  table.sort(names, function(a, b) return a:lower() < b:lower() end)
  return names
end

local SUGGEST_ITEM_H = 36
local SUGGEST_MAX_VISIBLE = 6

-- While the search field is focused and the query is still a bare
-- ":fieldName" token (no space typed yet), shows a popup of matching
-- extraField names below it. Up/Down move the highlight (wrapping), Enter
-- or a click fills the field with ":name " ready to type the search text,
-- and Escape (or losing focus, or typing the space) dismisses it the same
-- way any other field-attached popup does.
local function drawFieldSuggestions(id, st, game, x, y, w)
  if ui.focus ~= id then return end
  local query = st.query or ""
  if query:sub(1, 1) ~= ":" or query:find(" ") then return end
  local typed = query:sub(2):lower()
  local names = util.filter(extraFieldNames(game), function(n)
    return typed == "" or util.containsText(n:lower(), typed)
  end)
  if #names == 0 then return end

  local sst = ui.state(id .. ":suggest")
  local scrollId = id .. ":suggest:scroll"
  if sst.lastTyped ~= typed then
    sst.hi, sst.lastTyped = 1, typed
    ui.scrollTo(scrollId, 0)
  end
  sst.hi = math.max(1, math.min(#names, sst.hi))

  local function pick(name)
    st.query = ":" .. name .. " "
    ui.focusFieldAtEnd(id)
  end
  for _, k in ipairs(input.keys) do
    if k.key == "down" then sst.hi, sst.follow = sst.hi < #names and sst.hi + 1 or 1, true
    elseif k.key == "up" then sst.hi, sst.follow = sst.hi > 1 and sst.hi - 1 or #names, true
    elseif k.key == "return" or k.key == "kpenter" then pick(names[sst.hi]) end
  end

  local c = theme.c
  local listH = math.min(#names, SUGGEST_MAX_VISIBLE) * SUGGEST_ITEM_H
  local popupH = listH + 8
  local sw, sh = ui.screenSize()
  local px, py, pw = x, y, w
  if py + popupH > sh - 8 then py = math.max(8, y - popupH - 48) end
  if px + pw > sw - 8 then px = sw - 8 - pw end
  ui.overlay(function()
    ui.cover(-1e9, -1e9, 2e9, 2e9)
    -- Keeps the field "focused" while a click lands inside the popup
    -- instead of the field itself (same trick ui.textField uses for its
    -- own region) -- otherwise the generic outside-click blur would close
    -- this popup before the click's release could pick anything.
    if input.pressed[1] and ui.hoverIgnoringLayer(px, py, pw, popupH) then ui._focusHitThisFrame = true end
    ui.shadow(px, py, pw, popupH, 4, 2)
    ui.rect("fill", px, py, pw, popupH, 4, c.surfaceContainer)
    -- Keep the keyboard-highlighted row in view (mouse hover doesn't need
    -- this -- a hovered row is already on screen), the same "scroll to
    -- reveal" idea ui.textArea uses to keep its caret's line visible.
    if sst.follow then
      sst.follow = false
      local top, bottom = (sst.hi - 1) * SUGGEST_ITEM_H, sst.hi * SUGGEST_ITEM_H
      local cur = ui.scrollOffset(scrollId)
      if top < cur then ui.scrollTo(scrollId, top)
      elseif bottom > cur + listH then ui.scrollTo(scrollId, bottom - listH) end
    end
    local off = ui.beginScroll(scrollId, px, py + 4, pw, listH)
    local yy = py + 4 - off
    for i, name in ipairs(names) do
      local ir = ui.region(id .. ":sg" .. i, px, yy, pw, SUGGEST_ITEM_H, { cursor = "hand" })
      if ir.hovered then
        sst.hi = i
        ui.rect("fill", px, yy, pw, SUGGEST_ITEM_H, 0, theme.alpha(c.onSurface, 0.08))
      elseif i == sst.hi then
        ui.rect("fill", px, yy, pw, SUGGEST_ITEM_H, 0, theme.alpha(c.primary, 0.12))
      end
      ui.text(name, px + 12, yy, { w = pw - 24, h = SUGGEST_ITEM_H, valign = "middle", ellipsis = true, color = c.onSurface })
      if ir.clicked then pick(name) end
      yy = yy + SUGGEST_ITEM_H
    end
    ui.endScroll(scrollId, #names * SUGGEST_ITEM_H)
  end)
end

-- Search-by-name-or-ID field with a clear button, plus ":fieldName text"
-- to search one extraField by name (see core/card_filters.lua) -- typing
-- ":" pops up a list of the game's extraField names to autocomplete from
-- (see drawFieldSuggestions above). opts: labelBackground, clearColor.
-- Returns the y just below it.
function B.drawSearch(prefix, st, game, x, y, w, opts)
  opts = opts or {}
  local id = prefix .. ":search"
  st.query = ui.textField(id, x, y, w - (st.query ~= "" and 44 or 0), st.query, {
    label = "Search", hint = "Search by name or ID, or :field text", h = 44, labelBackground = opts.labelBackground })
  if st.query ~= "" and ui.iconButton("clear", x + w - 40, y + 2, { tooltip = "Clear search", id = prefix .. ":clearq", color = opts.clearColor }) then
    st.query = ""
  end
  drawFieldSuggestions(id, st, game, x, y + 44, w)
  return y + 44
end

return B
