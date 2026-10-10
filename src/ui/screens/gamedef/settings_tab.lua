-- Port of widgets/game_settings_tab.dart: the game's name, its card backs
-- (the first is the default), its tag groups, and the duplicate-card
-- checks. Edits apply straight to the editor's working GameDefinition.
local ui = require("src.ui.kit.ui")
local theme = require("src.ui.kit.theme")
local widgets = require("src.ui.kit.widgets")
local models = require("src.core.models")
local util = require("src.core.util")
local uuid = require("src.core.uuid")
local fs = require("src.data.fs")
local resolver = require("src.data.image_resolver")
local common = require("src.ui.screens.gamedef.common")
local dialogs = require("src.ui.screens.gamedef.dialogs")
local CR = require("src.ui.table.card_render")

local keyOf = common.keyOf

local T = {}
T.__index = T

function T.new(editor)
  return setmetatable({ editor = editor, newGroupName = "", expanded = {}, newTag = {}, duplicateTag = {} }, T)
end

local PAD = 24
local ROW_PAD = 12

-- One card back's row: drag handle, thumbnail, name / image / orientation,
-- delete. Returns its height.
function T:drawCardBackRow(ro, i, back, x, y, w)
  local c = theme.c
  local folder = self.editor.folderPath
  local k = "gs:back:" .. keyOf(back)
  local h = ROW_PAD + 48 + 8 + 40 + 8 + 48 + ROW_PAD
  widgets.card(x, y, w, h, { radius = 12 })
  ro:handle(i, x + 4, y + (h - 40) / 2, y, h)
  local tx = x + 48
  local path = back.imagePath and resolver.resolveBareImagePath(folder, back.imagePath)
  common.imagePreviewBox(path, tx, y + ROW_PAD, CR.cardWidth, CR.cardHeight)
  local fx = tx + CR.cardWidth + 16
  local fw = x + w - 56 - fx
  back.name = ui.textField(k .. ":name", fx, y + ROW_PAD, fw, back.name, {
    label = i == 1 and "Name (Default)" or "Name", labelBackground = c.surfaceContainer })
  local by = y + ROW_PAD + 48 + 8
  if ui.button("Choose Image...", fx, by, nil, 40, { variant = "outlined", id = k .. ":choose" }) then
    local name = common.chooseImage(folder)
    if name then back.imagePath = name end
  end
  if back.imagePath ~= nil then
    local bw = ui.buttonWidth("Choose Image...")
    if ui.button("Clear", fx + bw + 4, by, nil, 40, { variant = "text", id = k .. ":clear" }) then back.imagePath = nil end
  end
  back.orientation = ui.dropdown(k .. ":orient", fx, by + 48, fw, common.orientationOptions, back.orientation,
    { label = "Orientation", labelBackground = c.surfaceContainer })
  if ui.iconButton("delete_outline", x + w - 48, y + ROW_PAD, { id = k .. ":del", tooltip = "Remove Card Back" }) then
    self.pendingRemoveBack = back
  end
  return h
end

-- One tag group: header (handle, name, delete, chevron) and, when
-- expanded, its name field, reorderable tags and a new-tag row.
function T:drawTagGroup(ro, i, group, x, y, w)
  local c = theme.c
  local gk = keyOf(group)
  local k = "gs:group:" .. gk
  local expanded = self.expanded[gk]
  local headerH = 56
  -- Body first (its height sizes the border), drawn below the header.
  local bodyY = y + headerH
  local inner = x + 12
  local iw = w - 24
  local bodyH = 0
  if expanded then
    local by = bodyY
    group.name = ui.textField(k .. ":name", inner, by, iw, group.name, { label = "Group Name", h = 44 })
    by = by + 44 + 8
    local tro = widgets.reorder(k .. ":tags")
    local removeTag
    for ti, tag in ipairs(group.tags) do
      local th = 48
      ui.rect("line", inner + 0.5, by + 0.5, iw - 1, th - 1, 6, c.outlineVariant)
      tro:handle(ti, inner + 4, by + 4, by, th)
      ui.text(tag, inner + 48, by, { h = th, valign = "middle", w = iw - 48 - 48, ellipsis = true })
      if ui.iconButton("close", inner + iw - 44, by + 4, { id = k .. ":rmtag:" .. ti, tooltip = "Remove Tag" }) then removeTag = ti end
      by = by + th + 4
    end
    local from, to = tro:finish(inner, iw)
    if from then widgets.moveItem(group.tags, from, to) end
    if removeTag then table.remove(group.tags, removeTag) end
    by = by + 4
    local err = self.duplicateTag[gk] and "Tag already exists" or nil
    local text, changed, submitted = ui.textField(k .. ":newtag", inner, by, iw - 48, self.newTag[gk] or "",
      { label = "New tag", h = 44, error = err })
    self.newTag[gk] = text
    if changed then self.duplicateTag[gk] = nil end
    local add = ui.iconButton("add", inner + iw - 40, by + 2, { id = k .. ":addtag", tooltip = "Add Tag" })
    if submitted or add then
      local trimmed = util.trim(text)
      if trimmed ~= "" then
        if util.contains(group.tags, trimmed) then
          self.duplicateTag[gk] = true
        else
          group.tags[#group.tags + 1] = trimmed
          self.newTag[gk] = ""
          self.duplicateTag[gk] = nil
        end
      end
    end
    by = by + ui.textFieldHeight({ h = 44, error = err }) + 12
    bodyH = by - bodyY
  end
  local h = headerH + bodyH
  ui.rect("line", x + 0.5, y + 0.5, w - 1, h - 1, 8, c.outlineVariant)
  -- Header.
  if common.expansionHeader(k .. ":hdr", x + 48, y, w - 48 - 96, headerH) then self.expanded[gk] = not expanded end
  ro:handle(i, x + 4, y + 8, y, h)
  ui.text(group.name == "" and "(unnamed group)" or group.name, x + 56, y, { h = headerH, valign = "middle", w = w - 56 - 104, ellipsis = true })
  if ui.iconButton("delete_outline", x + w - 96, y + 8, { id = k .. ":del", tooltip = "Delete Group" }) then self.pendingRemoveGroup = group end
  if ui.iconButton(expanded and "expand_less" or "expand_more", x + w - 48, y + 8, { id = k .. ":exp" }) then
    self.expanded[gk] = not expanded
  end
  return h
end

function T:addGroup()
  local game = self.editor.game
  local trimmed = util.trim(self.newGroupName)
  if trimmed == "" or util.any(game.tagGroups, function(g) return g.name == trimmed end) then return end
  game.tagGroups[#game.tagGroups + 1] = models.TagGroup.new({ id = uuid.v4(), name = trimmed, tags = {} })
  self.newGroupName = ""
end

function T:addCardBack()
  local editor = self.editor
  local name = common.chooseImage(editor.folderPath)
  if not name then return end
  local backs = editor.game.cardBacks
  backs[#backs + 1] = models.CardBackDefinition.new({ id = uuid.v4(), name = fs.stripExtension(name), imagePath = name })
end

function T:draw(x, y, w, h)
  local editor = self.editor
  local game = editor.game
  self.pendingRemoveBack, self.pendingRemoveGroup = nil, nil
  local off = ui.beginScroll("gs:scroll", x, y, w, h)
  local cx, cw = x + PAD, w - 2 * PAD
  local yy = y + PAD - off

  game.name = ui.textField("gs:name", cx, yy, cw, game.name, { label = "Game Name" })
  yy = yy + 48 + 24

  -- Card backs.
  yy = yy + common.heading("Card Backs", cx, yy, cw)
  yy = yy + common.helpText('The first one is this game\'s default -- drag to reorder and change which one that '
    .. 'is. Each card can then pick a specific back (or "Unique") on the Card View tab.', cx, yy, cw) + 8
  local ro = widgets.reorder("gs:backs")
  for i, back in ipairs(game.cardBacks) do
    yy = yy + self:drawCardBackRow(ro, i, back, cx, yy, cw) + 8
  end
  local from, to = ro:finish(cx, cw)
  if from then widgets.moveItem(game.cardBacks, from, to) end
  if self.pendingRemoveBack then util.removeValue(game.cardBacks, self.pendingRemoveBack) end
  if ui.button("Add Card Back...", cx, yy, nil, 40, { variant = "outlined", icon = "add", id = "gs:addback" }) then
    self:addCardBack()
  end
  yy = yy + 40 + 24

  -- Tag groups.
  yy = yy + common.heading("Tag Groups", cx, yy, cw)
  yy = yy + common.helpText("Drag to reorder groups or the tags within them -- this also reorders their filter buttons "
    .. "and the Types fields on each card.", cx, yy, cw) + 8
  local gro = widgets.reorder("gs:groups")
  for i, group in ipairs(game.tagGroups) do
    yy = yy + self:drawTagGroup(gro, i, group, cx, yy, cw) + 12
  end
  from, to = gro:finish(cx, cw)
  if from then widgets.moveItem(game.tagGroups, from, to) end
  if self.pendingRemoveGroup then util.removeValue(game.tagGroups, self.pendingRemoveGroup) end
  local text, _, submitted = ui.textField("gs:newgroup", cx, yy, cw - 48, self.newGroupName, { label = "New tag group" })
  self.newGroupName = text
  local add = ui.iconButton("add", cx + cw - 44, yy + 4, { id = "gs:addgroup", tooltip = "Add Tag Group" })
  if submitted or add then self:addGroup() end
  yy = yy + 48 + 24

  -- Duplicate checks.
  yy = yy + common.heading("Card IDs", cx, yy, cw)
  yy = yy + common.helpText("Every card needs a unique ID. New imports are checked automatically, but this "
    .. "looks across all cards for any that still collide, so you can fix them by hand.", cx, yy, cw) + 8
  if ui.button("Check for Duplicate Card IDs...", cx, yy, nil, 40, { variant = "outlined", icon = "copy_all", id = "gs:dupids" }) then
    dialogs.showDuplicateCardIds(editor)
  end
  yy = yy + 40 + 16
  yy = yy + common.helpText("A different kind of duplicate: cards in the same set that share the exact same image "
    .. "file. This offers to merge each such group into one card, combining their tags.", cx, yy, cw) + 8
  if ui.button("Merge Duplicate Card Images...", cx, yy, nil, 40, { variant = "outlined", icon = "merge_type", id = "gs:dupimg" }) then
    dialogs.showMergeDuplicateImages(editor)
  end
  yy = yy + 40 + PAD
  ui.endScroll("gs:scroll", yy + off - y)
end

return T
