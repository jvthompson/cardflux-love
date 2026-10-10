-- Port of widgets/sets_tab.dart. "Add Set..." picks a folder of card art:
-- its name becomes the set id (and default name), its images are copied
-- into <gameFolder>/<id>/, and one card is created per image.
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

local keyOf = common.keyOf

local T = {}
T.__index = T

function T.new(editor)
  return setmetatable({ editor = editor }, T)
end

function T:addSet()
  local sourcePath = fileDialog.pickFolder({ title = "Choose a folder of card images" })
  if not sourcePath then return end
  local id = ops.deriveIdFromFolderPath(sourcePath)
  if util.any(self.editor.game.sets, function(s) return s.id == id end) then
    overlays.toast('A set named "' .. id .. '" already exists.')
    return
  end
  -- Copy on a later frame so the spinner shows first.
  self.busy = true
  self.pendingAdd = { sourcePath = sourcePath, id = id, frames = 2 }
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
    game.sets[#game.sets + 1] = models.GameSet.new({ id = p.id, name = p.id })
    for _, c in ipairs(newCards) do game.cards[#game.cards + 1] = c end
  end)
  resolver.clearCache()
  if not ok then overlays.toast("Could not add set: " .. tostring(err)) end
  self.busy = false
end

function T:confirmDelete(set)
  local game = self.editor.game
  local count = #util.filter(game.cards, function(c) return c.setId == set.id end)
  overlays.confirm("Remove Set", 'Remove "' .. set.name .. '" and its ' .. count .. " card(s) from this game definition? "
    .. "This will not delete any files on disk.", "Remove", function()
    util.removeValue(game.sets, set)
    game.cards = util.filter(game.cards, function(c) return c.setId ~= set.id end)
    models.GameDefinition.invalidateIndex(game)
  end)
end

-- One set's card: name, id and card count, delete, and (when the set has
-- cards carrying a Rarity tag) its Pack Settings. Returns its height.
function T:drawSet(set, rarityTags, x, y, w)
  local c = theme.c
  local game = self.editor.game
  local k = "st:" .. keyOf(set)
  local st = ui.state(k)
  local h = st.h or 72
  widgets.card(x, y, w, h, { radius = 12 })
  local pad = 12
  local count, hasRarity = 0, false
  for _, card in ipairs(game.cards) do
    if card.setId == set.id then
      count = count + 1
      if not hasRarity then
        for _, t in ipairs(card.types) do
          if util.contains(rarityTags, t) then
            hasRarity = true
            break
          end
        end
      end
    end
  end
  local fw = w - 2 * pad - 16 - 160 - 48
  set.name = ui.textField(k .. ":name", x + pad, y + pad, fw, set.name, { label = "Set Name", labelBackground = c.surfaceContainer })
  local ix = x + pad + fw + 16
  ui.text(set.id, ix, y + pad + 4, { w = 160, ellipsis = true, color = c.onSurfaceVariant })
  ui.text(count .. " card(s)", ix, y + pad + 24, { w = 160, size = 12, color = c.onSurfaceVariant })
  if ui.iconButton("delete_outline", x + w - pad - 40, y + pad + 4, { id = k .. ":del", tooltip = "Remove Set" }) then
    self.pendingDelete = set
  end
  local yy = y + pad + 48
  if hasRarity then
    ui.divider(x + pad, yy + 12, w - 2 * pad)
    yy = yy + 24
    ui.text("Pack Settings", x + pad, yy, { weight = "medium" })
    yy = yy + 24
    yy = yy + common.helpText("How many random cards of each Rarity a Pack Generator widget deals from this set. "
      .. "No settings configured: 10 random cards, rarities ignored.", x + pad, yy, w - 2 * pad) + 8
    local options = util.map(rarityTags, function(t) return { value = t, label = t } end)
    local remove
    for i, p in ipairs(set.packSettings) do
      local pk = k .. ":pack" .. i
      local dw = w - 2 * pad - 8 - common.stepperWidth
      p.tag = ui.dropdown(pk .. ":tag", x + pad, yy + 4, dw, options, p.tag, { h = 40, size = 14, placeholder = "(unknown tag)" })
      local q, removed = common.stepper(pk, x + w - pad, yy + 4, p.count, { removeTooltip = "Remove Pack Setting" })
      p.count = q
      if removed then remove = i end
      yy = yy + 48
    end
    if remove then table.remove(set.packSettings, remove) end
    if ui.button("Add Pack Setting", x + pad - 8, yy, nil, 40, { variant = "text", icon = "add", id = k .. ":addpack",
      disabled = #rarityTags == 0 }) then
      set.packSettings[#set.packSettings + 1] = models.PackSetting.new({ tag = rarityTags[1] or "", count = 1 })
    end
    yy = yy + 40
  end
  st.h = yy + pad - y
  return st.h
end

function T:draw(x, y, w, h)
  local game = self.editor.game
  self.pendingDelete = nil
  local rarityTags = ops.rarityTags(game.tagGroups)
  local pad = 16
  local off = ui.beginScroll("st:scroll", x, y, w, h)
  local cx, cw = x + pad, w - 2 * pad
  local yy = y + pad - off
  for _, set in ipairs(game.sets) do
    yy = yy + self:drawSet(set, rarityTags, cx, yy, cw) + 8
  end
  yy = yy + 8
  if ui.button("Add Set...", cx, yy, nil, 40, { variant = "outlined", icon = "add", id = "st:add", disabled = self.busy }) then
    self:addSet()
  end
  yy = yy + 40
  if self.busy then
    ui.spinner(cx + cw / 2, yy + 16 + 12, 12)
    yy = yy + 40
  end
  yy = yy + pad
  ui.endScroll("st:scroll", yy + off - y)
  if self.pendingDelete then self:confirmDelete(self.pendingDelete) end
end

return T
