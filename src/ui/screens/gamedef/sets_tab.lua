-- Port of widgets/sets_tab.dart, laid out as list + detail: a reorderable
-- set list on the left and the selected set's settings on the right, same
-- shape as zones_tab.lua. "Add Set..." picks a folder of card art: its name
-- becomes the set id (and default name), its images are copied into
-- <gameFolder>/<id>/, and one card is created per image.
local ui = require("src.ui.kit.ui")
local theme = require("src.ui.kit.theme")
local overlays = require("src.ui.kit.overlays")
local widgets = require("src.ui.kit.widgets")
local models = require("src.core.models")
local util = require("src.core.util")
local fs = require("src.data.fs")
local ops = require("src.data.gamedef_ops")
local resolver = require("src.data.image_resolver")
local fileDialog = require("src.platform.file_dialog")
local common = require("src.ui.screens.gamedef.common")
local listDetail = require("src.ui.kit.list_detail")

local keyOf = common.keyOf

local T = {}
T.__index = T

function T.new(editor)
  return setmetatable({ editor = editor }, T)
end

local LIST_W = 300
local ROW_H = 56

function T:addSet()
  fileDialog.pickFolder({ title = "Choose a folder of card images" }, function(sourcePath)
    if not sourcePath then return end
    local id = ops.deriveIdFromFolderPath(sourcePath)
    if util.any(self.editor.game.sets, function(s) return s.id == id end) then
      overlays.toast('A set named "' .. id .. '" already exists.')
      return
    end
    -- Copy on a later frame so the spinner shows first.
    self.busy = true
    self.pendingAdd = { sourcePath = sourcePath, id = id, frames = 2 }
  end)
end

function T:update()
  local p = self.pendingAdd
  if not p then return end
  p.frames = p.frames - 1
  if p.frames > 0 then return end
  self.pendingAdd = nil
  local game = self.editor.game
  local ok, err = pcall(function()
    ops.copySetImages(p.sourcePath, fs.join(self.editor.folderPath, p.id))
    local newCards = ops.buildCardsFromImageFolder(p.sourcePath, p.id, util.map(game.cards, function(c) return c.id end))
    local set = models.GameSet.new({ id = p.id, name = p.id })
    game.sets[#game.sets + 1] = set
    for _, c in ipairs(newCards) do game.cards[#game.cards + 1] = c end
    self.selected = set
  end)
  resolver.clearCache()
  if not ok then overlays.toast("Could not add set: " .. tostring(err)) end
  self.busy = false
end

-- Removes `set` and its cards after confirmation, then fixes up selection.
function T:confirmDelete(set)
  local game = self.editor.game
  local count = #util.filter(game.cards, function(c) return c.setId == set.id end)
  overlays.confirm("Remove Set", 'Remove "' .. set.name .. '" and its ' .. count .. " card(s) from this game definition? "
    .. "This will not delete any files on disk.", "Remove", function()
    local i
    for j, s in ipairs(game.sets) do if s == set then i = j end end
    util.removeValue(game.sets, set)
    game.cards = util.filter(game.cards, function(c) return c.setId ~= set.id end)
    models.GameDefinition.invalidateIndex(game)
    if self.selected == set then self.selected = i and game.sets[math.min(i, #game.sets)] or nil end
  end)
end

local function countCardsInSet(game, setId)
  local n = 0
  for _, card in ipairs(game.cards) do
    if card.setId == setId then n = n + 1 end
  end
  return n
end

-- True when some card in `set` carries a tag from rarityTags.
local function setHasRarity(game, set, rarityTags)
  for _, card in ipairs(game.cards) do
    if card.setId == set.id then
      for _, tg in ipairs(card.types) do
        if util.contains(rarityTags, tg) then return true end
      end
    end
  end
  return false
end

---------------------------------------------------------------------------
-- List
---------------------------------------------------------------------------

function T:drawList(x, y, w, h)
  local c = theme.c
  local game = self.editor.game
  ui.rect("fill", x, y, w, h, 0, c.surfaceContainer)
  local addLabel = "Add Set..."
  local hh, add = common.sectionHeader("st:list", "Sets", x + 16, y + 12, w - 32, {
    count = #game.sets,
    info = "Add Set picks a folder of card images: its name becomes the set's ID, its images are copied into "
      .. "this game's folder, and one card is created per image.",
    action = { label = addLabel, icon = "add", id = "st:add", disabled = self.busy } })
  if add then self:addSet() end
  if self.busy then
    local bw = ui.buttonWidth(addLabel, { icon = "add" })
    ui.spinner(x + w - 16 - bw - 24, y + 12 + 20, 10)
  end
  local ly = y + 12 + hh + 8
  local lh = y + h - ly
  local off = ui.beginScroll("st:list", x, ly, w, lh)
  local ro = widgets.reorder("st:sets")
  local yy = ly - off
  for i, set in ipairs(game.sets) do
    local count = countCardsInSet(game, set.id)
    local rx, rw = x + 8, w - 16
    local sel = set == self.selected
    local r = ui.region("st:row:" .. keyOf(set), rx + 40, yy, rw - 40, ROW_H, { cursor = "hand" })
    if sel then
      ui.rect("fill", rx, yy, rw, ROW_H, 8, c.secondaryContainer)
    elseif r.hovered then
      ui.rect("fill", rx, yy, rw, ROW_H, 8, theme.alpha(c.onSurface, 0.05))
    end
    ro:handle(i, rx, yy + (ROW_H - 40) / 2, yy, ROW_H)
    local fg = sel and c.onSecondaryContainer or c.onSurface
    local tx = rx + 48
    ui.text(set.name == "" and "(unnamed set)" or set.name, tx, yy + 9, { w = rx + rw - 8 - tx, ellipsis = true,
      weight = sel and "medium" or nil, color = fg })
    ui.text(set.id .. " · " .. count .. (count == 1 and " card" or " cards"), tx, yy + 30, { w = rx + rw - 8 - tx,
      ellipsis = true, size = 12, color = c.onSurfaceVariant })
    if r.clicked then
      self.selected = set
      ui.blur()
    end
    yy = yy + ROW_H + 2
  end
  local from, to = ro:finish(x + 8, w - 16)
  if from then widgets.moveItem(game.sets, from, to) end
  if #game.sets == 0 then
    ui.text("No sets yet.", x + 16, yy, { color = c.onSurfaceVariant })
  end
  ui.endScroll("st:list", #game.sets * (ROW_H + 2) + 12)
end

---------------------------------------------------------------------------
-- Detail
---------------------------------------------------------------------------

local function isNonNegativeDecimal(s) return s:match("^%d*%.?%d*$") ~= nil end

-- Finds set.packSettings' entry for `tag`, or nil.
local function findPackSetting(set, tag)
  for _, p in ipairs(set.packSettings) do
    if p.tag == tag then return p end
  end
  return nil
end

-- One rarity's editable chance field: the tag's name at left, a decimal
-- field at right. Creates/updates/removes the underlying PackSetting as
-- the value changes, keeping packSettings free of zero entries. The typed
-- text is kept in its own state so a trailing "." isn't clobbered mid-type.
-- Returns the row height.
local function drawPackRow(set, tag, k, x, y, w)
  local existing = findPackSetting(set, tag)
  local current = existing and existing.count or 0
  local st = ui.state(k .. ":text")
  if st.text == nil or (tonumber(st.text) or 0) ~= current then
    st.text = tostring(current)
  end
  local lw = math.min(220, w - 140)
  ui.text(tag, x, y, { w = lw, h = common.FIELD_H, valign = "middle", ellipsis = true })
  st.text = ui.textField(k .. ":field", x + lw + common.GAP, y, w - lw - common.GAP, st.text,
    { filter = isNonNegativeDecimal })
  local v = tonumber(st.text) or 0
  if v ~= current then
    if v == 0 then
      if existing then util.removeValue(set.packSettings, existing) end
    elseif existing then
      existing.count = v
    else
      set.packSettings[#set.packSettings + 1] = models.PackSetting.new({ tag = tag, count = v })
    end
  end
  return common.FIELD_H + 8
end

function T:drawDetail(set, x, y, w, h)
  local c = theme.c
  local game = self.editor.game
  local k = "st:" .. keyOf(set)
  local off = ui.beginScroll("st:detail", x, y, w, h)
  local cx, cw = common.column(x, w)
  local yy = y + common.PAD - off

  -- Header: name and delete.
  ui.text(set.name == "" and "(unnamed set)" or set.name, cx, yy, { size = 20, weight = "medium", h = 40,
    valign = "middle", w = cw - 160, ellipsis = true })
  local bw = ui.buttonWidth("Delete Set", { icon = "delete_outline" })
  if ui.button("Delete Set", cx + cw - bw, yy, bw, 40, { variant = "text", icon = "delete_outline", id = k .. ":del" }) then
    self.pendingDelete = set
  end
  yy = yy + 40 + 16

  local infoW = 160
  local fw = cw - infoW - common.GAP
  set.name = ui.textField(k .. ":name", cx, yy, fw, set.name, { label = "Set Name" })
  local ix = cx + fw + common.GAP
  ui.text(set.id, ix, yy + 4, { w = infoW, ellipsis = true, color = c.onSurfaceVariant })
  local count = countCardsInSet(game, set.id)
  ui.text(count .. (count == 1 and " card" or " cards"), ix, yy + 24, { w = infoW, size = 12, color = c.onSurfaceVariant })
  yy = yy + common.FIELD_H + 16

  local rarityTags = ops.rarityTags(game.tagGroups)
  if #rarityTags > 0 and setHasRarity(game, set, rarityTags) then
    yy = yy + 20
    common.groupLabel("Pack Settings", cx, yy, cw - 24)
    common.infoIcon(k .. ":packinfo", cx + cw - 22, yy + 1, "A value of 1 or more guarantees that many cards of "
      .. "that rarity in the pack. A fractional part (e.g. 0.5, or the .5 in 1.5) is the chance of one additional "
      .. "card of that rarity, on top of the rest of the pack. No rarities configured: 10 random cards, "
      .. "rarities ignored.")
    yy = yy + 20 + 10
    for _, tag in ipairs(rarityTags) do
      yy = yy + drawPackRow(set, tag, k .. ":pack:" .. tag, cx, yy, cw)
    end
  end
  yy = yy + common.PAD
  ui.endScroll("st:detail", yy + off - y)
end

function T:draw(x, y, w, h)
  local game = self.editor.game
  self.pendingDelete = nil
  listDetail.draw(self, x, y, w, h, game.sets, LIST_W, T.drawList, T.drawDetail, "Add a set to get started")
  if self.pendingDelete then self:confirmDelete(self.pendingDelete) end
end

return T
