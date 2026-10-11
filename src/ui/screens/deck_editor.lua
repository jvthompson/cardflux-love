-- Ports of deck_editor_game_select_screen.dart and deck_editor_screen.dart:
-- pick a game, then build a deck from its cards (left-click a card to add a
-- copy, right-click to remove one) and save/open it as a DeckConfig file in
-- the Deck Library. A deck here starts empty.
local ui = require("src.ui.kit.ui")
local theme = require("src.ui.kit.theme")
local overlays = require("src.ui.kit.overlays")
local widgets = require("src.ui.kit.widgets")
local filterBar = require("src.ui.kit.card_filter_bar")
local models = require("src.core.models")
local util = require("src.core.util")
local paths = require("src.data.paths")
local decks = require("src.data.deck_library")
local fileDialog = require("src.platform.file_dialog")
local resolver = require("src.data.image_resolver")
local CR = require("src.ui.table.card_render")
local GamePicker = require("src.ui.screens.game_picker")
local deckLibraryDialog = require("src.ui.screens.deck_library_dialog")

local CW, CH = CR.cardWidth, CR.cardHeight
-- The card pool draws cards a third larger, with up to three lines of name.
local POOL_SCALE = 4 / 3
local PW, PH = CW * POOL_SCALE, CH * POOL_SCALE
local NAME_LINES = 3

local function app() return require("src.app") end

---------------------------------------------------------------------------
-- Open Deck dialog (_DeckLibraryPickerDialog)
---------------------------------------------------------------------------

-- onChosen(deck)
local function openDeckPicker(game, onChosen)
  local st = { root = paths.decksDir() }
  local function refresh()
    st.error = nil
    local ok, scan = pcall(decks.loadAllDecksForGame, st.root, game)
    if ok then
      st.scan = scan
    else
      st.scan = nil
      st.error = "Could not read that folder: " .. tostring(scan)
    end
  end
  refresh()

  local dialog
  local function changeFolder()
    local chosen = fileDialog.pickFolder({ title = "Choose your deck library folder", initialDir = st.root })
    if not chosen then return end
    GamePicker.maybeMoveLibraryFolder(st.root, chosen, "deck", function()
      paths.setDecksDir(chosen)
      st.root = chosen
      refresh()
    end)
  end

  local function browseSingleFile()
    local path = fileDialog.openFile({ title = "Open Deck", filters = fileDialog.jsonFilters })
    if not path then return true end
    local deck, reason = decks.readDeckFile(path)
    if not deck then
      st.error = reason == "legacy" and models.LegacyDeckFormatError.message or "That file is not a valid deck."
      return true
    end
    if deck.gameId ~= game.id then
      st.error = "That deck is for a different game (" .. deck.gameId .. ")."
      return true
    end
    onChosen(deck)
    return false
  end

  dialog = overlays.dialog({
    title = "Open Deck -- " .. game.name,
    width = 360 + 48,
    content = function(d, x, y, w)
      local c = theme.c
      local h = 360
      ui.text(st.root, x, y, { size = 12, color = c.onSurfaceVariant, w = w - 48, h = 40, valign = "middle", ellipsis = true })
      if ui.iconButton("folder_open", x + w - 40, y, { tooltip = "Change Deck Library Folder...", id = "od:folder" }) then changeFolder() end
      local yy = y + 48
      ui.divider(x, yy, w)
      yy = yy + 8
      local listH = y + h - yy
      local entries = st.scan and st.scan.entries or {}
      local incompatible = st.scan and st.scan.incompatible or {}
      if st.error then
        ui.text(st.error, x, yy, { w = w, h = listH, align = "center", valign = "middle", color = theme.fixed.red })
      elseif #entries == 0 and #incompatible == 0 then
        ui.text("No decks found for " .. game.name .. ".", x, yy, { w = w, h = listH, align = "center", valign = "middle", color = c.onSurfaceVariant })
      else
        local off = ui.beginScroll("od:list", x, yy, w, listH)
        local ry = yy - off
        for i, e in ipairs(entries) do
          local rowH = e.isBuiltIn and 56 or 40
          local r = ui.region("od:item" .. i, x, ry, w, rowH, { cursor = "hand" })
          if r.hovered then ui.rect("fill", x, ry, w, rowH, 0, theme.alpha(c.onSurface, 0.08)) end
          if e.isBuiltIn then
            ui.text(e.displayName, x + 16, ry + 8, { w = w - 140, ellipsis = true })
            ui.text("Built-in", x + 16, ry + 28, { size = 12, color = c.onSurfaceVariant })
          else
            ui.text(e.displayName, x + 16, ry, { h = rowH, valign = "middle", w = w - 140, ellipsis = true })
          end
          ui.text(decks.cardCount(e) .. " card(s)", x, ry, { w = w - 16, h = rowH, valign = "middle", align = "right", size = 12, color = c.onSurfaceVariant })
          if r.clicked then
            d:close()
            onChosen(e.deck)
          end
          ry = ry + rowH
        end
        for _, e in ipairs(incompatible) do
          local dim = theme.alpha(c.onSurface, 0.38)
          ui.text(e.displayName, x + 16, ry + 8, { w = w - 32, ellipsis = true, color = dim })
          ui.text("Old format -- rebuild in the Deck Editor", x + 16, ry + 28, { size = 12, color = theme.fixed.red })
          ry = ry + 56
        end
        ui.endScroll("od:list", ry + ui.scrollOffset("od:list") - yy)
      end
      return h
    end,
    actions = {
      { label = "Browse for a different file...", variant = "text", onClick = browseSingleFile },
      { label = "Cancel", variant = "text" },
    },
  })
  return dialog
end

---------------------------------------------------------------------------
-- Deck Editor screen
---------------------------------------------------------------------------

local E = {}
E.__index = E

-- One slot per distinct deckType the game's deck-building zones declare
-- (labeled by the first zone using it; required unless every zone using
-- it is deckOptional), or a single implicit main_deck slot.
local function buildSlots(game)
  local zones = models.GameDefinition.deckBuildingZones(game)
  if #zones == 0 then return { { deckType = "main_deck", label = "Deck", required = true } } end
  local slots, byType = {}, {}
  for _, z in ipairs(zones) do
    local s = byType[z.deckType]
    if not s then
      s = { deckType = z.deckType, label = z.name, required = false }
      byType[z.deckType] = s
      slots[#slots + 1] = s
    end
    s.required = s.required or not z.deckOptional
  end
  return slots
end

-- An insertion-ordered definitionId -> quantity map (Dart's Map order is
-- what the deck list shows and the file stores).
local function newQuantities() return { order = {}, qty = {} } end

local function total(q)
  local n = 0
  for _, id in ipairs(q.order) do n = n + q.qty[id] end
  return n
end

-- opts (optional, for a Cardflux server):
--   store     a src/data/deck_store.lua store for Open/Save
--   ownedQty  definitionId -> copies owned (collection mode): the pool shows
--             only owned, unownable and free cards, and copies are capped
function E.new(game, opts)
  opts = opts or {}
  local self = setmetatable({ title = "Deck Editor", game = game, store = opts.store, ownedQty = opts.ownedQty }, E)
  self.slots = buildSlots(game)
  self.quantitiesBySlot = {}
  for _, s in ipairs(self.slots) do self.quantitiesBySlot[s.deckType] = newQuantities() end
  self.activeDeckType = self.slots[1].deckType
  self.filters = filterBar.newState(game)
  return self
end

function E:active() return self.quantitiesBySlot[self.activeDeckType] end

-- Copies of a card across every slot (collection limits are per deck).
function E:copiesInDeck(id)
  local n = 0
  for _, q in pairs(self.quantitiesBySlot) do n = n + (q.qty[id] or 0) end
  return n
end

-- Copies a collection allows, or nil when unlimited.
function E:ownedLimit(id)
  if not self.ownedQty then return nil end
  local def = models.GameDefinition.cardById(self.game, id)
  if def and (def.unownable or def.isFreeCard) then return nil end
  return self.ownedQty[id] or 0
end

function E:addCopy(id)
  local limit = self:ownedLimit(id)
  if limit and self:copiesInDeck(id) >= limit then
    overlays.toast("You only own " .. limit .. (limit == 1 and " copy" or " copies") .. " of that card.")
    return
  end
  local q = self:active()
  if not q.qty[id] then q.order[#q.order + 1] = id end
  q.qty[id] = (q.qty[id] or 0) + 1
end

function E:removeCopy(id)
  local q = self:active()
  local current = q.qty[id]
  if not current then return end
  if current <= 1 then
    q.qty[id] = nil
    util.removeValue(q.order, id)
  else
    q.qty[id] = current - 1
  end
end

function E:buildDeckConfig()
  local subdecks = {}
  for _, s in ipairs(self.slots) do
    local q = self.quantitiesBySlot[s.deckType]
    subdecks[#subdecks + 1] = models.SubDeck.new(s.deckType,
      util.map(q.order, function(id) return models.DeckEntry.new(id, q.qty[id]) end))
  end
  return models.DeckConfig.new(self.game.id, subdecks)
end

function E:saveDeck()
  local missing = {}
  for _, s in ipairs(self.slots) do
    if s.required and total(self.quantitiesBySlot[s.deckType]) == 0 then missing[#missing + 1] = s.label end
  end
  if #missing > 0 then
    overlays.toast("Add at least one card to: " .. table.concat(missing, ", ") .. " before saving.")
    return
  end
  deckLibraryDialog.promptSaveDeck(self.game, self:buildDeckConfig(), nil, { store = self.store })
end

-- Replaces every slot with the deck's entries, skipping cards this game
-- no longer has.
function E:loadDeck(deck)
  if deck.gameId ~= self.game.id then
    overlays.toast("That deck is for a different game (" .. deck.gameId .. ").")
    return
  end
  for _, s in ipairs(self.slots) do
    local q = newQuantities()
    for _, e in ipairs(models.DeckConfig.entriesFor(deck, s.deckType)) do
      if models.GameDefinition.cardById(self.game, e.definitionId) then
        if not q.qty[e.definitionId] then q.order[#q.order + 1] = e.definitionId end
        q.qty[e.definitionId] = e.quantity
      end
    end
    self.quantitiesBySlot[s.deckType] = q
  end
  self:clampToCollection()
end

-- Trims copies beyond what the collection owns (later slots give way first).
function E:clampToCollection()
  if not self.ownedQty then return end
  local trimmed = 0
  for i = #self.slots, 1, -1 do
    local q = self.quantitiesBySlot[self.slots[i].deckType]
    for j = #q.order, 1, -1 do
      local id = q.order[j]
      local limit = self:ownedLimit(id)
      if limit then
        local over = self:copiesInDeck(id) - limit
        if over > 0 then
          local cut = math.min(over, q.qty[id])
          trimmed = trimmed + cut
          q.qty[id] = q.qty[id] - cut
          if q.qty[id] <= 0 then
            q.qty[id] = nil
            table.remove(q.order, j)
          end
        end
      end
    end
  end
  if trimmed > 0 then
    overlays.toast("Removed " .. trimmed .. " card(s) your collection doesn't have.")
  end
end

function E:openDeck()
  if self.store and self.store.kind == "server" then
    deckLibraryDialog.open(self.game, {}, function(deck) self:loadDeck(deck) end, { store = self.store })
    return
  end
  openDeckPicker(self.game, function(deck) self:loadDeck(deck) end)
end

-- The pool: every card, or (collection mode) the ones owned, unownable or free.
function E:visibleCards()
  local visible = filterBar.visible(self.filters, self.game)
  if not self.ownedQty then return visible end
  return util.filter(visible, function(def) return def.unownable or def.isFreeCard or (self.ownedQty[def.id] or 0) > 0 end)
end

function E:drawPool(x, y, w, h)
  local game = self.game
  local yy = filterBar.drawFilters("de", self.filters, game, x + 12, y, w - 24)
  yy = filterBar.drawSearch("de", self.filters, x + 12, yy + 12, w - 24, { labelBackground = theme.c.surface })
  local visible = self:visibleCards()
  local gx, gy, gw, gh = x, yy, w, y + h - yy
  if #visible == 0 and self.ownedQty then
    ui.text("Your collection has no cards matching these filters. Open packs from the server lobby's Collection screen.",
      gx + 24, gy, { w = gw - 48, h = math.min(gh, 200), align = "center", valign = "middle", color = theme.c.onSurfaceVariant })
  end
  local nameH = NAME_LINES * theme.font(11):getHeight()
  local maxExtent, rowH, gap = PW + 24, PH + 6 + nameH + 4, 12
  local inner = gw - 24
  local cols = math.max(1, math.ceil((inner + gap) / (maxExtent + gap)))
  local tileW = (inner - (cols - 1) * gap) / cols
  local active = self:active()
  local off = ui.beginScroll("de:pool", gx, gy, gw, gh)
  for i, def in ipairs(visible) do
    local col, row = (i - 1) % cols, math.floor((i - 1) / cols)
    local tx, ty = gx + 12 + col * (tileW + gap), gy + 12 + row * (rowH + gap) - off
    if ty + rowH > gy and ty < gy + gh then
      local cx = tx + tileW / 2
      local r = ui.region("de:card:" .. def.id, cx - PW / 2, ty, PW, PH + 6 + nameH, { cursor = "hand" })
      -- Collection mode: a green badge (top left) counts the owned copies not
      -- yet in the deck, and the card dims once they're all used.
      local limit = self:ownedLimit(def.id)
      local unused = limit and math.max(0, limit - self:copiesInDeck(def.id))
      CR.draw({ def = def, faceUp = true, cx = cx, cy = ty + PH / 2, scale = POOL_SCALE, alpha = unused == 0 and 0.35 or 1,
        angle = CR.orientationTurns(def.orientation) * 2 * math.pi, cardBacks = game.cardBacks })
      local n = active.qty[def.id] or (self.ownedQty and 0)
      if n then
        love.graphics.setColor(0, 0, 0, 0.87)
        love.graphics.circle("fill", cx + PW / 2 + 6 - 11, ty - 6 + 11, 11)
        ui.text(tostring(n), cx + PW / 2 - 16, ty - 6, { size = 11, weight = "bold", w = 22, h = 22, align = "center", valign = "middle", color = theme.fixed.white })
      end
      if unused then
        love.graphics.setColor(theme.fixed.green)
        love.graphics.circle("fill", cx - PW / 2 - 6 + 11, ty - 6 + 11, 11)
        ui.text(tostring(unused), cx - PW / 2 - 6, ty - 6, { size = 11, weight = "bold", w = 22, h = 22, align = "center", valign = "middle", color = theme.fixed.white })
      end
      local label = limit and (def.cardTitle .. " (" .. self:copiesInDeck(def.id) .. "/" .. limit .. ")") or def.cardTitle
      ui.text(label, tx, ty + PH + 6, { size = 11, w = tileW, align = "center", maxLines = NAME_LINES })
      if r.hovered then self.hoveredId = def.id end
      if r.clicked then self:addCopy(def.id) end
      if r.rightClicked then self:removeCopy(def.id) end
    end
  end
  ui.endScroll("de:pool", 24 + math.ceil(#visible / cols) * (rowH + gap) - gap)
end

function E:drawDeckPanel(x, y, w, h)
  local c = theme.c
  local yy = y
  if #self.slots > 1 then
    local opts, segW = {}, 0
    for _, s in ipairs(self.slots) do
      opts[#opts + 1] = { value = s.deckType, label = s.label }
      segW = math.max(segW, ui.textWidth(s.label, 14, "medium") + 26 + 24)
    end
    local sw = math.min(w - 24, segW * #opts)
    self.activeDeckType = ui.segmented("de:slots", x + 12, yy + 12, sw, opts, self.activeDeckType)
    yy = yy + 12 + 40
  end
  local active = self:active()
  local label
  for _, s in ipairs(self.slots) do if s.deckType == self.activeDeckType then label = s.label end end
  ui.text(label .. " -- " .. total(active) .. " card(s)", x + 12, yy + 12, { weight = "bold", w = w - 24, ellipsis = true })
  yy = yy + 12 + 20 + 12
  ui.divider(x, yy, w)
  yy = yy + 1
  local listH = y + h - yy
  if #active.order == 0 then
    ui.text("Left-click a card to add it", x, yy, { w = w, h = listH, align = "center", valign = "middle", color = c.onSurfaceVariant })
    return
  end
  local rowH = 48
  local off = ui.beginScroll("de:deck", x, yy, w, listH)
  local remove
  for i, id in ipairs(active.order) do
    local ry = yy + (i - 1) * rowH - off
    if ry + rowH > yy and ry < yy + listH then
      local def = models.GameDefinition.cardById(self.game, id)
      local r = ui.region("de:row:" .. id, x, ry, w, rowH, { cursor = "hand" })
      if r.hovered then
        ui.rect("fill", x, ry, w, rowH, 0, theme.alpha(c.onSurface, 0.08))
        self.hoveredId = id
      end
      local trailing = "×" .. active.qty[id]
      local tw = ui.textWidth(trailing, 14)
      ui.text(def and def.cardTitle or id, x + 16, ry, { h = rowH, valign = "middle", w = w - 48 - tw, ellipsis = true })
      ui.text(trailing, x, ry, { w = w - 16, h = rowH, valign = "middle", align = "right", color = c.onSurfaceVariant })
      if r.clicked then remove = id end
    end
  end
  ui.endScroll("de:deck", #active.order * rowH)
  if remove then self:removeCopy(remove) end
end

local DECK_W = 240

-- Space preview: a big copy of the hovered card in the half of the screen
-- away from the mouse, as on the table. A card with a back shows Front
-- above Back.
function E:drawPreview()
  if overlays.anyOpen() or ui.focus or not love.keyboard.isDown("space") then return end
  local def = self.hoveredId and models.GameDefinition.cardById(self.game, self.hoveredId)
  if not def then return end
  local cardBacks = self.game.cardBacks
  local faces = { { def = def, faceUp = true, orientation = def.orientation } }
  if def.cardBackId ~= nil then
    local _, _, backOrientation = resolver.resolveCardBackImagePath(cardBacks, def)
    faces[2] = { def = def, faceUp = false, orientation = backOrientation or "portrait" }
  end
  local sw, sh = ui.screenSize()
  CR.drawPreview(faces, cardBacks, sw, sh, (ui.mouse()))
end

function E:draw(x, y, w, h)
  local c = theme.c
  self.hoveredId = nil
  local tbH = widgets.editorToolbar(x, y, w, "Edit Deck -- " .. self.game.name, {
    { icon = "folder_open", tooltip = "Open Deck...", id = "de:open", onClick = function() self:openDeck() end },
    { icon = "save", tooltip = "Save Deck...", id = "de:save", onClick = function() self:saveDeck() end },
  })
  local by, bh = y + tbH + 1, h - tbH - 1
  -- Deck list 240 wide on the right; the pool takes the rest.
  local deckW = DECK_W
  local poolW = w - deckW - 1
  ui.pushClip(x, by, poolW, bh)
  self:drawPool(x, by, poolW, bh)
  ui.popClip()
  ui.rect("fill", x + poolW, by, 1, bh, 0, c.outlineVariant)
  ui.pushClip(x + poolW + 1, by, deckW, bh)
  self:drawDeckPanel(x + poolW + 1, by, deckW, bh)
  ui.popClip()
  ui.overlay(function() self:drawPreview() end)
end

---------------------------------------------------------------------------
-- Game select (DeckEditorGameSelectScreen)
---------------------------------------------------------------------------

local S = {}
S.__index = S

function S.new()
  local self = setmetatable({ title = "Deck Editor" }, S)
  self.picker = GamePicker.new(function(game) app().push(E.new(game)) end, { excludeStandardDeck = true })
  return self
end

function S:update(dt) self.picker:update(dt) end
function S:draw(x, y, w, h) self.picker:draw(x, y, w, h) end

return { GameSelect = S, Editor = E, buildSlots = buildSlots }
