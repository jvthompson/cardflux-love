-- Near-fullscreen Markdown viewer for a game's rulebook.md, with a
-- table-of-contents sidebar built from the document's headings. Shared by
-- the table screen and the deck editor (opened via Ctrl+R in both).
local ui = require("src.ui.kit.ui")
local theme = require("src.ui.kit.theme")
local overlays = require("src.ui.kit.overlays")
local panel = require("src.ui.kit.panel")
local controls = require("src.ui.screens.controls_dialog")
local fs = require("src.data.fs")
local imageUtils = require("src.data.image_utils")
local rulebookSettings = require("src.data.rulebook_settings")

local RV = {}
RV.__index = RV

local TOC_W = 260
local TOC_GAP = 16
local TOC_INDENT = 14
local CONTENT_PAD = 20
local TOC_TEXT_COLOR = { 1, 1, 1, 0.85 }
local EMPTY_TEXT_COLOR = { 1, 1, 1, 0.54 }

function RV.new(game)
  local self = setmetatable({}, RV)
  self.game = game
  self.open = false
  self.loaded = false
  self.restoreDone = false
  self.pendingRestore = nil
  self.scrollId = "rulebook:body:" .. tostring(game.id)
  self.tocScrollId = "rulebook:toc:" .. tostring(game.id)
  self.tocVisible = true
  return self
end

function RV:ensureLoaded()
  if self.loaded then return end
  self.loaded = true
  local path = self.game.folderPath and fs.join(self.game.folderPath, "rulebook.md")
  local data = path and fs.readFile(path)
  self.hasContent = data ~= nil
  self.blocks = data and controls.parse(data) or {}
  if self.hasContent then self:loadImages() end
end

-- Resolves every `![alt](path)` block's path relative to the game's folder
-- and decodes it into a drawable Image, synchronously, once, right here -
-- simplest option, and fine for a rulebook's modest handful of diagrams.
--
-- If rulebooks grow to carry many/large images and this starts to visibly
-- hitch when first opening one, the alternative is to reuse
-- src/data/image_cache.lua instead: it already does async load/decode/
-- cache off the main thread (the same pipeline card art uses). That would
-- mean dropping this eager loop and instead calling imageCache.get(path)
-- every frame from controls_dialog.lua's drawBlocks "image" case (it
-- returns the Image once ready, nil while still pending/loading, so the
-- block just redraws blank-then-filled-in over a frame or two) - a bit
-- more moving parts, not needed unless this sync version proves slow.
function RV:loadImages()
  for _, b in ipairs(self.blocks) do
    if b.kind == "image" and self.game.folderPath then
      local data = imageUtils.decodeFile(fs.join(self.game.folderPath, b.path))
      if data then
        local ok, img = pcall(love.graphics.newImage, data)
        if ok then b.image = img end
      end
    end
  end
end

function RV:toggle()
  self.open = not self.open
  if self.open then
    self:ensureLoaded()
    if not self.restoreDone then
      local saved = rulebookSettings.getScroll(self.game.id)
      -- Pre-emptive: also overwrites any stale in-memory scrollState left by
      -- an earlier screen instance that happened to reuse this same id
      -- string this session. (beginScroll would otherwise clamp this back
      -- to 0 on a truly first-ever open, since it has no contentH yet - the
      -- real fix is the pendingRestore re-apply after this frame's
      -- endScroll, below.)
      ui.scrollTo(self.scrollId, saved)
      self.pendingRestore = saved
    end
  else
    rulebookSettings.setScroll(self.game.id, ui.scrollOffset(self.scrollId))
  end
end

function RV:drawToc(toc, x, y, w, h)
  local c = theme.c
  local off = ui.beginScroll(self.tocScrollId, x, y, w, h)
  local startY = y - off
  local yy = startY
  for i, entry in ipairs(toc) do
    local indent = (entry.level - 1) * TOC_INDENT
    local rowW = w - indent
    local rowH = ui.textHeight(entry.text, rowW - 8, 12) + 10
    if yy + rowH > y and yy < y + h then
      local r = ui.region("rbtoc:" .. i, x, yy, w, rowH, { cursor = "hand" })
      if r.hovered then ui.rect("fill", x, yy, w, rowH, 4, theme.alpha(c.onSurface, 0.08)) end
      ui.text(entry.text, x + indent + 8, yy + 5, { w = rowW - 8, size = 12, maxLines = 2, color = TOC_TEXT_COLOR })
      if r.pressed then ui.scrollTo(self.scrollId, entry.y) end
    end
    yy = yy + rowH
  end
  ui.endScroll(self.tocScrollId, yy - startY)
end

-- onClose: called when the panel's X button or outside-click scrim fires.
-- Must be the host screen's own toggle method (e.g. T:toggleRulebook), not
-- self:toggle() directly - the host tracks its own rulebookOpen flag that
-- gates whether this draw() call even happens, and self:toggle() alone
-- can't reach back to flip that off.
function RV:draw(onClose)
  -- This panel's chrome (panel.lua) is always the fixed dark "in-game
  -- overlay" style, same family as the Game Menu/Log/Card Library panels -
  -- not the live app theme. controls_dialog.drawBlocks colors its text from
  -- theme.c though, so without this override it picks up whatever theme.c
  -- happens to be live (which can be theme.light, e.g. the app's own light
  -- mode, or table_screen's forced-light table background) and renders
  -- dark-on-dark against this always-dark panel. Force dark here, matching
  -- T:drawLibrary's identical workaround, so the content is always readable
  -- regardless of the app's light/dark setting or which screen opened this.
  local savedTheme = theme.c
  theme.c = theme.dark

  local sw, sh = ui.screenSize()
  local pw, ph = (sw - 40) * 0.5, (sh - overlays.contentTop - 40) * 0.75
  local leading = {
    icon = self.tocVisible and "chevron_left" or "chevron_right",
    tooltip = self.tocVisible and "Hide contents" or "Show contents",
    onClick = function() self.tocVisible = not self.tocVisible end,
  }
  local x, y, w, h = panel.draw("rulebook", pw, ph, "Rulebook", onClose, nil, leading)
  x, y, w, h = x + CONTENT_PAD, y + CONTENT_PAD, w - 2 * CONTENT_PAD, h - 2 * CONTENT_PAD

  if not self.hasContent then
    ui.text("This game doesn't have a rulebook yet.", x, y,
      { w = w, h = h, align = "center", valign = "middle", color = EMPTY_TEXT_COLOR })
    theme.c = savedTheme
    return
  end

  local docX = self.tocVisible and (x + TOC_W + TOC_GAP) or x
  local docW = self.tocVisible and (w - TOC_W - TOC_GAP) or w
  local off = ui.beginScroll(self.scrollId, docX, y, docW, h)
  local toc = {}
  local height = controls.drawBlocks(docX, y - off, docW, self.blocks, {
    showH1 = true,
    onHeading = function(level, text, yOffset) toc[#toc + 1] = { level = level, text = text, y = yOffset } end,
  })
  ui.endScroll(self.scrollId, height)

  if self.pendingRestore then
    ui.scrollTo(self.scrollId, self.pendingRestore)
    self.pendingRestore = nil
    self.restoreDone = true
  end

  if self.tocVisible then self:drawToc(toc, x, y, TOC_W, h) end
  theme.c = savedTheme
end

return RV
