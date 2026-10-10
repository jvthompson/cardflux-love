-- Port of widgets/zones_tab.dart: a reorderable list of expandable
-- ZoneDefinition editors. Edits apply straight to game.zones.
local ui = require("src.ui.kit.ui")
local theme = require("src.ui.kit.theme")
local widgets = require("src.ui.kit.widgets")
local colorpicker = require("src.ui.kit.colorpicker")
local models = require("src.core.models")
local util = require("src.core.util")
local uuid = require("src.core.uuid")
local common = require("src.ui.screens.gamedef.common")

local keyOf = common.keyOf

local T = {}
T.__index = T

function T.new(editor)
  return setmetatable({ editor = editor, expanded = {} }, T)
end

local KIND_OPTIONS = { { value = "card", label = "Card Zone" }, { value = "widget", label = "Widget Zone" } }
local WIDGET_KIND_OPTIONS = { { value = "counter", label = "Counter" } }
local SIDE_OPTIONS = { { value = "left", label = "Left" }, { value = "right", label = "Right" } }

local function isInteger(s) return s:match("^%-?%d+$") ~= nil end

-- A text field with grey helper text under it. Returns (text, height).
local function fieldWithHelper(id, x, y, w, text, label, helper, disabled)
  local v = ui.textField(id, x, y, w, text, { label = label, disabled = disabled, labelBackground = theme.c.surfaceContainer })
  local hh = ui.textHeight(helper, w - 24, 12)
  ui.text(helper, x + 12, y + 48 + 4, { w = w - 24, size = 12, color = disabled and theme.c.disabled or theme.c.onSurfaceVariant })
  return v, 48 + 4 + hh
end

-- The card-zone settings below the Zone Type picker. Returns height used.
function T:drawCardZoneFields(zone, k, x, y, w)
  local c = theme.c
  local cards = self.editor.game.cards
  local yy = y
  local h
  zone.shared, h = common.switchTile(k .. ":shared", "Shared",
    "One public pile for everyone, instead of one private pile per player", x, yy, w, zone.shared)
  yy = yy + h
  zone.dealsBuiltDeck, h = common.switchTile(k .. ":deals", "Deals Built Deck",
    "Receives the player's own loaded deck at game start (owned zones only)", x, yy, w, zone.dealsBuiltDeck,
    { disabled = zone.shared })
  yy = yy + h

  -- Deck Type keeps what's typed; an empty field means main_deck.
  local function deckTypeOf(s) return util.trim(s) == "" and "main_deck" or s end
  local st = ui.state(k .. ":deckTypeText")
  if st.text == nil or deckTypeOf(st.text) ~= zone.deckType then st.text = zone.deckType end
  local text
  text, h = fieldWithHelper(k .. ":decktype", x, yy, w, st.text, "Deck Type",
    "Which subdeck (by name) this zone loads from a chosen deck file -- defaults to main_deck", not zone.dealsBuiltDeck)
  st.text = text
  zone.deckType = deckTypeOf(text)
  yy = yy + h + 8
  zone.deckOptional, h = common.switchTile(k .. ":optional", "Deck Optional",
    "A chosen deck may leave this zone's subdeck empty or missing (deals empty instead of being rejected)",
    x, yy, w, zone.deckOptional, { disabled = not zone.dealsBuiltDeck })
  yy = yy + h
  zone.faceUp, h = common.switchTile(k .. ":faceup", "Face Up", "Cards in this zone show their real face", x, yy, w, zone.faceUp)
  yy = yy + h
  zone.shuffleable, h = common.switchTile(k .. ":shufflable", "Shuffleable", "Show a shuffle button for this zone",
    x, yy, w, zone.shuffleable)
  yy = yy + h
  zone.autoShuffle, h = common.switchTile(k .. ":autoshuffle", "Auto Shuffle",
    "Randomize this zone's order automatically when the game loads", x, yy, w, zone.autoShuffle)
  yy = yy + h
  zone.visibleToAll, h = common.switchTile(k .. ":visible", "Visible To All",
    "Let opponents see the real cards in this owned zone", x, yy, w, zone.visibleToAll, { disabled = zone.shared })
  yy = yy + h
  zone.isDiscardPile, h = common.switchTile(k .. ":discard", "Is Discard Pile",
    "Pressing D sends a hovered table card here", x, yy, w, zone.isDiscardPile)
  yy = yy + h + 8

  -- Shared deck (only meaningful for shared zones).
  local notShared = not zone.shared
  ui.text("Shared Deck", x, yy, { weight = "bold", color = notShared and c.disabled or c.onSurface })
  yy = yy + 20
  zone.standardDeck, h = common.switchTile(k .. ":standard", "Standard 52-Card Deck",
    "Deal one of each traditional playing card automatically", x, yy, w, zone.standardDeck, { disabled = notShared })
  yy = yy + h + 4
  text, h = fieldWithHelper(k .. ":deckname", x, yy, w, zone.deckName or "", "Deck Name",
    "Loads this deck from the Deck Library's folder for this game", notShared or zone.standardDeck)
  if text ~= (zone.deckName or "") then zone.deckName = text ~= "" and text or nil end
  yy = yy + h + 12
  zone.side = ui.segmented(k .. ":side", x, yy, 240, SIDE_OPTIONS, zone.side, { disabled = notShared })
  yy = yy + 40 + 16

  -- Starting contents, ignored when another source fills the zone.
  local hasDeckName = zone.deckName ~= nil and zone.deckName ~= ""
  local ignored = zone.dealsBuiltDeck or zone.standardDeck or hasDeckName
  ui.text("Starting Contents", x, yy, { weight = "bold", color = ignored and c.disabled or c.onSurface })
  yy = yy + 20
  if ignored then
    local why = zone.dealsBuiltDeck and "Ignored while Deals Built Deck is on."
      or zone.standardDeck and "Ignored while Standard 52-Card Deck is on."
      or "Ignored while a Deck Name is set."
    ui.text(why, x, yy + 4, { size = 12, color = c.onSurfaceVariant })
    yy = yy + 24
  end
  local options = util.map(cards, function(card) return { value = card.id, label = card.cardTitle } end)
  local remove
  for i, entry in ipairs(zone.entries) do
    local ek = k .. ":entry" .. i
    local dw = w - 8 - common.stepperWidth
    local picked = ui.dropdown(ek .. ":card", x, yy + 4, dw, options, entry.definitionId,
      { h = 40, disabled = ignored, placeholder = "(unknown card)", size = 14 })
    if picked ~= entry.definitionId then zone.entries[i] = models.DeckEntry.new(picked, entry.quantity) end
    local q, removed = common.stepper(ek, x + w, yy + 4, entry.quantity, { removeTooltip = "Remove Entry", disabled = ignored })
    if q ~= entry.quantity then zone.entries[i] = models.DeckEntry.new(zone.entries[i].definitionId, q) end
    if removed then remove = i end
    yy = yy + 48
  end
  if remove then table.remove(zone.entries, remove) end
  if ui.button("Add Entry", x - 8, yy, nil, 40, { variant = "text", icon = "add", id = k .. ":addentry",
    disabled = ignored or #cards == 0 }) then
    zone.entries[#zone.entries + 1] = models.DeckEntry.new(cards[1].id, 1)
  end
  yy = yy + 40
  return yy - y
end

-- The widget-zone settings. Returns height used.
function T:drawWidgetZoneFields(zone, k, x, y, w)
  local yy = y + 12
  ui.text("Widget Zone", x, yy, { weight = "bold" })
  yy = yy + 20 + 8
  zone.widgetKind = ui.dropdown(k .. ":wkind", x, yy, w, WIDGET_KIND_OPTIONS, zone.widgetKind,
    { label = "Widget Type", labelBackground = theme.c.surfaceContainer })
  yy = yy + 48 + 12
  -- Starting Value keeps what's typed; anything unparsable counts as 0.
  local function valueOf(s) return isInteger(s) and tonumber(s) or 0 end
  local st = ui.state(k .. ":startText")
  if st.text == nil or valueOf(st.text) ~= zone.counterStartingValue then
    st.text = tostring(zone.counterStartingValue)
  end
  st.text = ui.textField(k .. ":start", x, yy, w, st.text, { label = "Starting Value",
    labelBackground = theme.c.surfaceContainer, filter = function(s) return s:match("^[%d%-]*$") ~= nil end })
  zone.counterStartingValue = valueOf(st.text)
  yy = yy + 48 + 12
  local cw = (w - 12) / 2
  local h1, h2
  zone.counterStartingColor, h1 = colorpicker.field(k .. ":color", x, yy, cw, zone.counterStartingColor,
    { hexLabel = "Starting Color (hex)", labelBackground = theme.c.surfaceContainer })
  zone.counterStartingTextColor, h2 = colorpicker.field(k .. ":textcolor", x + cw + 12, yy, cw, zone.counterStartingTextColor,
    { hexLabel = "Starting Text Color (hex)", labelBackground = theme.c.surfaceContainer })
  yy = yy + math.max(h1, h2)
  return yy - y
end

-- One zone's card: header (handle, name/id, delete) and, when expanded,
-- every field. Returns its height.
function T:drawZone(ro, i, zone, x, y, w)
  local c = theme.c
  local zk = keyOf(zone)
  local k = "zt:" .. zk
  local headerH = 64
  local expanded = self.expanded[zk]
  -- The card background must go down before the fields, so measure the
  -- body from last frame's height.
  local st = ui.state(k)
  local h = headerH + (expanded and (st.bodyH or 0) or 0)
  widgets.card(x, y, w, h, { radius = 12 })
  if common.expansionHeader(k .. ":hdr", x + 48, y, w - 48 - 56, headerH) then self.expanded[zk] = not expanded end
  ro:handle(i, x + 4, y + 12, y, h)
  ui.text(zone.name == "" and "(unnamed zone)" or zone.name, x + 56, y + 12, { w = w - 56 - 64, ellipsis = true })
  ui.text(zone.id, x + 56, y + 34, { w = w - 56 - 64, ellipsis = true, size = 12, color = c.onSurfaceVariant })
  if ui.iconButton("delete_outline", x + w - 52, y + 12, { id = k .. ":del", tooltip = "Delete Zone" }) then
    self.pendingRemove = zone
  end
  if not expanded then return h end

  local fx, fw = x + 16, w - 32
  local yy = y + headerH
  zone.id = ui.textField(k .. ":id", fx, yy, fw, zone.id, { label = "Zone ID", labelBackground = c.surfaceContainer })
  yy = yy + 48 + 12
  zone.name = ui.textField(k .. ":name", fx, yy, fw, zone.name, { label = "Zone Name", labelBackground = c.surfaceContainer })
  yy = yy + 48 + 12
  zone.kind = ui.dropdown(k .. ":kind", fx, yy, fw, KIND_OPTIONS, zone.kind,
    { label = "Zone Type", labelBackground = c.surfaceContainer })
  yy = yy + 48
  if zone.kind == "card" then
    yy = yy + self:drawCardZoneFields(zone, k, fx, yy, fw)
  else
    yy = yy + self:drawWidgetZoneFields(zone, k, fx, yy, fw)
  end
  yy = yy + 16
  st.bodyH = yy - (y + headerH)
  return headerH + st.bodyH
end

function T:draw(x, y, w, h)
  local game = self.editor.game
  self.pendingRemove = nil
  local pad = 16
  local off = ui.beginScroll("zt:scroll", x, y, w, h)
  local cx, cw = x + pad, w - 2 * pad
  local yy = y + pad - off
  local ro = widgets.reorder("zt:zones")
  for i, zone in ipairs(game.zones) do
    yy = yy + self:drawZone(ro, i, zone, cx, yy, cw) + 12
  end
  local from, to = ro:finish(cx, cw)
  if from then widgets.moveItem(game.zones, from, to) end
  if self.pendingRemove then util.removeValue(game.zones, self.pendingRemove) end
  if ui.button("Add Zone", cx, yy, nil, 40, { variant = "outlined", icon = "add", id = "zt:add" }) then
    game.zones[#game.zones + 1] = models.ZoneDefinition.new({ id = uuid.v4(), name = "New Zone" })
  end
  yy = yy + 40 + pad
  ui.endScroll("zt:scroll", yy + off - y)
end

return T
