-- Near-fullscreen viewer for a game's rulebook: either rulebook.md (with a
-- table-of-contents sidebar built from the document's headings) or, when
-- present, rulebook.pdf instead (continuous-scroll page images, no ToC --
-- the PDF carries its own structure). A PDF takes precedence over a
-- Markdown file when a folder has both. Shared by the table screen and the
-- deck editor (opened via Ctrl+R in both).
local ui = require("src.ui.kit.ui")
local theme = require("src.ui.kit.theme")
local overlays = require("src.ui.kit.overlays")
local panel = require("src.ui.kit.panel")
local controls = require("src.ui.screens.controls_dialog")
local fs = require("src.data.fs")
local imageUtils = require("src.data.image_utils")
local rulebookSettings = require("src.data.rulebook_settings")
local pdfDocCache = require("src.data.pdf_doc_cache")

local RV = {}
RV.__index = RV

local TOC_W = 260
local TOC_GAP = 16
local TOC_INDENT = 14
local CONTENT_PAD = 20
local TOC_TEXT_COLOR = { 1, 1, 1, 0.85 }
local EMPTY_TEXT_COLOR = { 1, 1, 1, 0.54 }

local PDF_PAGE_GAP = 16
-- Reserved on the right of the PDF page column so the scrollbar thumb
-- (drawn inside the scroll region's own width) never sits on top of a page,
-- which otherwise fills the column edge-to-edge.
local PDF_SCROLLBAR_GUTTER = 20
-- US Letter portrait (8.5x11in) -- there's no ToC to size the panel around
-- in PDF mode, so instead of the Markdown layout's wide 50%-of-screen
-- panel, size it just wide enough for a full page at this aspect ratio to
-- show at the panel's own height.
local PAGE_ASPECT = 8.5 / 11
-- This panel is always the dark "overlay" theme (see :draw()), where the
-- default scrollbar thumb (theme.c.onSurface at low alpha) reads as too
-- dim against page content -- brighten just this panel's scrollbars.
local SCROLL_THUMB_OPTS = { thumbAlpha = 0.6, thumbAlphaHover = 0.85 }
-- Rasterization width in pixels: comfortably above this panel's widest real
-- content column (at most half the screen, minus padding) on even a 4K
-- monitor, without rendering absurdly large textures. Fixed per page and
-- not re-rendered on window resize -- the resulting image is just scaled by
-- love.graphics.draw to fit the current column width every frame, so a
-- drastic resize after opening can look slightly soft; acceptable for v1.
local PDF_RENDER_WIDTH = 1600

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

-- Every page always scales to fill the full content width (docW already
-- has the panel's own padding subtracted out), regardless of the PDF's own
-- page size -- so a PDF with small native pages still fills the viewer.
local function computePdfLayout(pointSizes, docW, gap)
  local pages, y = {}, 0
  for i, size in ipairs(pointSizes) do
    local pw, ph = size[1], size[2]
    local h = (pw > 0) and (docW * ph / pw) or 0
    pages[i] = { y = y, h = h }
    y = y + h + gap
  end
  return { pages = pages, contentHeight = math.max(0, y - gap) }
end
RV._computePdfLayout = computePdfLayout

function RV:ensureLoaded()
  if self.loaded then return end
  self.loaded = true
  local folder = self.game.folderPath
  local pdfPath = folder and fs.join(folder, "rulebook.pdf")
  local mdPath = folder and fs.join(folder, "rulebook.md")
  if pdfPath and fs.isFile(pdfPath) then
    self.kind = "pdf"
    self.hasContent = true
    self.pdfCache = pdfDocCache.new(pdfPath)
    return
  end
  self.kind = "md"
  local data = mdPath and fs.readFile(mdPath)
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
      -- Reused for both formats: a game only ever has one active rulebook
      -- kind at a time, so there's no key collision to worry about.
      local saved = rulebookSettings.getScroll(self.game.id)
      -- Pre-emptive: also overwrites any stale in-memory scrollState left by
      -- an earlier screen instance that happened to reuse this same id
      -- string this session. (beginScroll would otherwise clamp this back
      -- to 0 on a truly first-ever open, since it has no contentH yet - the
      -- real fix is the pendingRestore re-apply after this frame's
      -- endScroll (Markdown), or once PDF layout is known (PDF), below.)
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
  ui.endScroll(self.tocScrollId, yy - startY, SCROLL_THUMB_OPTS)
end

-- Continuous-scroll PDF page stack: only the pages intersecting the
-- viewport (plus one screen's worth of slack, to prefetch just ahead of
-- scrolling) are requested/drawn, same "only touch visible rows" idiom as
-- deck_library_dialog.lua's deck-tile grid.
function RV:drawPdfPages(x, y, w, h, off, pageW)
  local c = theme.c
  local cache = self.pdfCache
  local slack = h
  for i, pg in ipairs(self.pdfLayout.pages) do
    local ty = y + pg.y - off
    if ty + pg.h > y - slack and ty < y + h + slack then
      cache:requestPage(i - 1, PDF_RENDER_WIDTH)
      local p = cache.pages[i - 1]
      if p and p.state == "ready" then
        local imgW = p.image:getDimensions()
        local scale = pageW / imgW
        love.graphics.setColor(1, 1, 1, 1) -- undo whatever color the last draw call left active
        love.graphics.draw(p.image, x, ty, 0, scale, scale)
      else
        ui.rect("fill", x, ty, pageW, pg.h, 4, theme.alpha(c.onSurface, 0.06))
        if p and p.state == "error" then
          ui.text("Couldn't render this page.", x, ty, { w = pageW, h = pg.h, align = "center", valign = "middle", color = EMPTY_TEXT_COLOR })
        end
      end
    end
  end
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

  if self.pdfCache then self.pdfCache:update() end

  local sw, sh = ui.screenSize()
  local ph = (sh - overlays.contentTop - 40) * 0.75
  local pw
  if self.kind == "pdf" then
    local contentH = ph - panel.TITLE_BAR_H - 2 * CONTENT_PAD
    local pageW = contentH * PAGE_ASPECT
    pw = math.min(sw - 40, pageW + PDF_SCROLLBAR_GUTTER + 2 * CONTENT_PAD)
  else
    pw = (sw - 40) * 0.5
  end
  local showToc = self.kind == "md"
  local leading = showToc and {
    icon = self.tocVisible and "chevron_left" or "chevron_right",
    tooltip = self.tocVisible and "Hide contents" or "Show contents",
    onClick = function() self.tocVisible = not self.tocVisible end,
  } or nil
  local x, y, w, h = panel.draw("rulebook", pw, ph, "Rulebook", onClose, nil, leading)
  x, y, w, h = x + CONTENT_PAD, y + CONTENT_PAD, w - 2 * CONTENT_PAD, h - 2 * CONTENT_PAD

  if not self.hasContent then
    ui.text("This game doesn't have a rulebook yet.", x, y,
      { w = w, h = h, align = "center", valign = "middle", color = EMPTY_TEXT_COLOR })
    theme.c = savedTheme
    return
  end

  if self.kind == "pdf" then
    if self.pdfCache.openError then
      ui.text("This rulebook's PDF couldn't be loaded: " .. self.pdfCache.openError, x, y,
        { w = w, h = h, align = "center", valign = "middle", color = EMPTY_TEXT_COLOR })
      theme.c = savedTheme
      return
    end
    if not self.pdfCache.pointSizes then
      ui.spinner(x + w / 2, y + h / 2, 14)
      theme.c = savedTheme
      return
    end
    local pageW = w - PDF_SCROLLBAR_GUTTER
    if not self.pdfLayout then self.pdfLayout = computePdfLayout(self.pdfCache.pointSizes, pageW, PDF_PAGE_GAP) end
    local off = ui.beginScroll(self.scrollId, x, y, w, h)
    self:drawPdfPages(x, y, w, h, off, pageW)
    ui.endScroll(self.scrollId, self.pdfLayout.contentHeight, SCROLL_THUMB_OPTS)
    if self.pendingRestore then
      ui.scrollTo(self.scrollId, self.pendingRestore)
      self.pendingRestore = nil
      self.restoreDone = true
    end
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
  ui.endScroll(self.scrollId, height, SCROLL_THUMB_OPTS)

  if self.pendingRestore then
    ui.scrollTo(self.scrollId, self.pendingRestore)
    self.pendingRestore = nil
    self.restoreDone = true
  end

  if self.tocVisible then self:drawToc(toc, x, y, TOC_W, h) end
  theme.c = savedTheme
end

return RV
