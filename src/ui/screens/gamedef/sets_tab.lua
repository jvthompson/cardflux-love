-- Port of widgets/sets_tab.dart. "Add Set..." picks a folder of card art:
-- its name becomes the set id (and default name), its images are copied
-- into <gameFolder>/<id>/, and one card is created per image.
local ui = require("src.ui.kit.ui")
local theme = require("src.ui.kit.theme")
local overlays = require("src.ui.kit.overlays")
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

-- "Common ×10 · Rare ×1", or the default when nothing is configured.
local function packSummary(set)
  if #set.packSettings == 0 then return "10 random cards" end
  local parts = {}
  for _, p in ipairs(set.packSettings) do parts[#parts + 1] = (p.tag ~= "" and p.tag or "?") .. " ×" .. p.count end
  return table.concat(parts, " · ")
end

-- One set's row: name, id and card count, delete, and (when the set has
-- cards carrying a Rarity tag) a collapsible Pack Settings summary.
-- Returns its height.
function T:drawSet(set, rarityTags, x, y, w)
  local c = theme.c
  local game = self.editor.game
  local k = "st:" .. keyOf(set)
  local st = ui.state(k)
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
  local yy = y + 16
  local infoW = 180
  local fw = w - infoW - 16 - 44
  set.name = ui.textField(k .. ":name", x, yy, fw, set.name, { label = "Set Name" })
  local ix = x + fw + 16
  ui.text(set.id, ix, yy + 4, { w = infoW, ellipsis = true, color = c.onSurfaceVariant })
  ui.text(count .. (count == 1 and " card" or " cards"), ix, yy + 24, { w = infoW, size = 12, color = c.onSurfaceVariant })
  if ui.iconButton("delete_outline", x + w - 40, yy + 4, { id = k .. ":del", tooltip = "Remove Set" }) then
    self.pendingDelete = set
  end
  yy = yy + common.FIELD_H + 8
  if hasRarity then
    if common.collapseHeader(k .. ":packhdr", "Pack Settings", x - 4, yy, w - 30, 36, st.packOpen, packSummary(set)) then
      st.packOpen = not st.packOpen
    end
    common.infoIcon(k .. ":packinfo", x + w - 22, yy + 9, "How many random cards of each Rarity a Pack Generator "
      .. "widget deals from this set. No settings configured: 10 random cards, rarities ignored.")
    yy = yy + 36
    if st.packOpen then
      local px, pw = x + 28, w - 28
      local options = util.map(rarityTags, function(t) return { value = t, label = t } end)
      local remove
      for i, p in ipairs(set.packSettings) do
        local pk = k .. ":pack" .. i
        local dw = math.min(320, pw - 8 - common.stepperWidth)
        p.tag = ui.dropdown(pk .. ":tag", px, yy + 4, dw, options, p.tag, { h = 40, size = 14, placeholder = "(unknown tag)" })
        local q, removed = common.stepper(pk, px + dw + 8 + common.stepperWidth, yy + 4, p.count,
          { removeTooltip = "Remove Pack Setting" })
        p.count = q
        if removed then remove = i end
        yy = yy + 48
      end
      if remove then table.remove(set.packSettings, remove) end
      if ui.button("Add Pack Setting", px - 8, yy, nil, 40, { variant = "text", icon = "add", id = k .. ":addpack",
        disabled = #rarityTags == 0 }) then
        set.packSettings[#set.packSettings + 1] = models.PackSetting.new({ tag = rarityTags[1] or "", count = 1 })
      end
      yy = yy + 40
    end
  end
  return yy + 8 - y
end

function T:draw(x, y, w, h)
  local c = theme.c
  local game = self.editor.game
  self.pendingDelete = nil
  local rarityTags = ops.rarityTags(game.tagGroups)
  local off = ui.beginScroll("st:scroll", x, y, w, h)
  local cx, cw = common.column(x, w)
  local yy = y + common.PAD - off
  local addLabel = "Add Set..."
  local hh, add = common.sectionHeader("st:hdr", "Sets", cx, yy, cw, {
    count = #game.sets,
    info = "Add Set picks a folder of card images: its name becomes the set's ID, its images are copied into "
      .. "this game's folder, and one card is created per image.",
    action = { label = addLabel, icon = "add", id = "st:add", disabled = self.busy } })
  if add then self:addSet() end
  if self.busy then ui.spinner(cx + cw - ui.buttonWidth(addLabel, { icon = "add" }) - 24, yy + 20, 10) end
  yy = yy + hh + 4
  for i, set in ipairs(game.sets) do
    if i > 1 then ui.divider(cx, yy, cw) end
    yy = yy + self:drawSet(set, rarityTags, cx, yy, cw)
  end
  if #game.sets == 0 then
    ui.text("No sets yet.", cx, yy + 8, { color = c.onSurfaceVariant })
    yy = yy + 32
  end
  yy = yy + common.PAD
  ui.endScroll("st:scroll", yy + off - y)
  if self.pendingDelete then self:confirmDelete(self.pendingDelete) end
end

return T
