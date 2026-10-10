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
local resolver = require("src.data.image_resolver")
local fileDialog = require("src.platform.file_dialog")
local CR = require("src.ui.table.card_render")
local GamePicker = require("src.ui.screens.game_picker")
local deckLibraryDialog = require("src.ui.screens.deck_library_dialog")

local CW, CH = CR.cardWidth, CR.cardHeight

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

function E.new(game)
  local self = setmetatable({ title = "Deck Editor", game = game }, E)
  self.slots = buildSlots(game)
  self.quantitiesBySlot = {}
  for _, s in ipairs(self.slots) do self.quantitiesBySlot[s.deckType] = newQuantities() end
  self.activeDeckType = self.slots[1].deckType
  self.filters = filterBar.newState(game)
  return self
end

function E:active() return self.quantitiesBySlot[self.activeDeckType] end

function E:addCopy(id)
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
  deckLibraryDialog.promptSaveDeck(self.game, self:buildDeckConfig())
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
end

function E:openDeck()
  openDeckPicker(self.game, function(deck) self:loadDeck(deck) end)
end

-- Draws a card scaled to fit (w, h), turned to its orientation.
local function fitScale(orientation, w, h)
  local rotated = orientation ~= "portrait"
  local bw, bh = rotated and CH or CW, rotated and CW or CH
  return math.min(w / bw, h / bh), bw, bh
end

local function fitCard(def, faceUp, orientation, cardBacks, x, y, w, h)
  local s, _, bh = fitScale(orientation, w, h)
  CR.draw({ def = def, faceUp = faceUp, cx = x + w / 2, cy = y + h / 2, scale = s,
    angle = CR.orientationTurns(orientation) * 2 * math.pi, cardBacks = cardBacks })
  return y + (h + bh * s) / 2 -- bottom edge of the drawn card
end

function E:drawPool(x, y, w, h)
  local game = self.game
  local yy = filterBar.drawFilters("de", self.filters, game, x + 12, y, w - 24)
  yy = filterBar.drawSearch("de", self.filters, x + 12, yy + 12, w - 24, { labelBackground = theme.c.surface })
  local visible = filterBar.visible(self.filters, game)
  local gx, gy, gw, gh = x, yy, w, y + h - yy
  local maxExtent, rowH, gap = CW + 24, CH + 28, 12
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
      local r = ui.region("de:card:" .. def.id, cx - CW / 2, ty, CW, CH + 4 + 16, { cursor = "hand" })
      CR.draw({ def = def, faceUp = true, cx = cx, cy = ty + CH / 2,
        angle = CR.orientationTurns(def.orientation) * 2 * math.pi, cardBacks = game.cardBacks })
      local n = active.qty[def.id]
      if n then
        love.graphics.setColor(0, 0, 0, 0.87)
        love.graphics.circle("fill", cx + CW / 2 + 6 - 11, ty - 6 + 11, 11)
        ui.text(tostring(n), cx + CW / 2 - 16, ty - 6, { size = 11, weight = "bold", w = 22, h = 22, align = "center", valign = "middle", color = theme.fixed.white })
      end
      ui.text(def.cardTitle, cx - CW / 2, ty + CH + 4, { size = 11, w = CW, align = "center", ellipsis = true })
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

-- Preview panel: 24px padding around the card image(s), with the title
-- below. A card with a back shows Front above Back.
local DECK_W = 240
local PREVIEW_W, PREVIEW_PAD, PREVIEW_TITLE_H = 560, 24, 16 + 24

function E:drawPreviewPanel(x, y, w, h)
  local c = theme.c
  ui.rect("fill", x, y, w, h, 0, theme.alpha(c.surfaceContainerHighest, 0.4))
  local def = self.hoveredId and models.GameDefinition.cardById(self.game, self.hoveredId)
  if not def then
    ui.text("Hover a card to preview", x, y, { w = w, h = h, align = "center", valign = "middle", color = c.onSurfaceVariant })
    return
  end
  local px, py, pw = x + PREVIEW_PAD, y + PREVIEW_PAD, w - 2 * PREVIEW_PAD
  local areaH = h - 2 * PREVIEW_PAD - PREVIEW_TITLE_H
  local cardBacks = self.game.cardBacks
  local titleY
  if def.cardBackId == nil then
    -- The card and its title, centered together.
    local sc, _, bh = fitScale(def.orientation, pw, areaH)
    local cardH = bh * sc
    local top = y + (h - (cardH + PREVIEW_TITLE_H)) / 2
    titleY = fitCard(def, true, def.orientation, cardBacks, px, top, pw, cardH) + 16
  else
    local labelH = 8 + 16
    local paneH = (areaH - 12) / 2 - labelH
    local frontBottom = fitCard(def, true, def.orientation, cardBacks, px, py, pw, paneH)
    ui.text("Front", px, frontBottom + 8, { size = 12, w = pw, align = "center", color = c.onSurfaceVariant })
    local by = py + paneH + labelH + 12
    local _, _, backOrientation = resolver.resolveCardBackImagePath(cardBacks, def)
    local backBottom = fitCard(def, false, backOrientation or "portrait", cardBacks, px, by, pw, paneH)
    ui.text("Back", px, backBottom + 8, { size = 12, w = pw, align = "center", color = c.onSurfaceVariant })
    titleY = backBottom + 8 + 16 + 12
  end
  ui.text(def.cardTitle, px, titleY, { size = 18, weight = "bold", w = pw, align = "center", ellipsis = true })
end

function E:draw(x, y, w, h)
  local c = theme.c
  self.hoveredId = nil
  local tbH = widgets.editorToolbar(x, y, w, "Edit Deck -- " .. self.game.name, {
    { icon = "folder_open", tooltip = "Open Deck...", id = "de:open", onClick = function() self:openDeck() end },
    { icon = "save", tooltip = "Save Deck...", id = "de:save", onClick = function() self:saveDeck() end },
  })
  local by, bh = y + tbH + 1, h - tbH - 1
  -- Deck list 240 wide, preview 560; the pool takes the rest. On a
  -- narrow window the preview gives way so the pool keeps three columns.
  local minPoolW = 3 * (CW + 24) + 2 * 12 + 24
  local deckW = DECK_W
  local previewW = util.clamp(w - deckW - 2 - minPoolW, 240, PREVIEW_W)
  local poolW = w - deckW - previewW - 2
  local leftW = poolW + 1 + deckW
  ui.pushClip(x, by, poolW, bh)
  self:drawPool(x, by, poolW, bh)
  ui.popClip()
  ui.rect("fill", x + poolW, by, 1, bh, 0, c.outlineVariant)
  ui.pushClip(x + poolW + 1, by, deckW, bh)
  self:drawDeckPanel(x + poolW + 1, by, deckW, bh)
  ui.popClip()
  ui.rect("fill", x + leftW, by, 1, bh, 0, c.outlineVariant)
  self:drawPreviewPanel(x + leftW + 1, by, w - leftW - 1, bh)
end

---------------------------------------------------------------------------
-- Game select (DeckEditorGameSelectScreen)
---------------------------------------------------------------------------

local S = {}
S.__index = S

function S.new()
  local self = setmetatable({ title = "Deck Editor" }, S)
  self.picker = GamePicker.new(function(game) app().push(E.new(game)) end)
  return self
end

function S:update(dt) self.picker:update(dt) end
function S:draw(x, y, w, h) self.picker:draw(x, y, w, h) end

return { GameSelect = S, Editor = E, buildSlots = buildSlots }
