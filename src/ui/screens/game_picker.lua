-- Port of widgets/game_picker.dart + game_grid.dart: the game library
-- grid with folder path, Refresh and Change Folder. A component embedded
-- by screens (not a screen itself).
local ui = require("src.ui.kit.ui")
local theme = require("src.ui.kit.theme")
local overlays = require("src.ui.kit.overlays")
local fileDialog = require("src.platform.file_dialog")
local loader = require("src.data.game_loader")
local paths = require("src.data.paths")
local resolver = require("src.data.image_resolver")
local imageCache = require("src.data.image_cache")
local ops = require("src.data.gamedef_ops")

local P = {}
P.__index = P

local TILE_W = 268
local MAX_COLUMNS = 7
local SPACING = 16
local TEXT_BLOCK_H = 64

-- onGameChosen(game). opts.excludeStandardDeck hides the Standard 52-Card
-- Deck (it can't be customized, so the deck editors leave it out).
function P.new(onGameChosen, opts)
  local self = setmetatable({ onGameChosen = onGameChosen, games = nil, busy = false }, P)
  self.excludeStandardDeck = opts and opts.excludeStandardDeck or false
  self.directoryPath = paths.gamesDir()
  self.standardDeck = loader.loadStandardDeck()
  self:refresh()
  return self
end

-- Loads on the next update so the progress indicator gets a frame first.
function P:refresh()
  self.busy = true
  self.error = nil
  self.pendingLoad = 2
end

function P:update()
  if self.pendingLoad then
    self.pendingLoad = self.pendingLoad - 1
    if self.pendingLoad > 0 then return end
    self.pendingLoad = nil
    resolver.clearCache()
    local ok, games = pcall(loader.loadGamesFromDirectory, self.directoryPath)
    if ok then
      table.sort(games, function(a, b) return a.name < b.name end)
      self.games = games
      if #games == 0 then self.error = "No valid games found in that folder." end
    else
      self.games = {}
      self.error = "Could not read that folder: " .. tostring(games)
    end
    self.busy = false
  end
end

-- Port of move_library_prompt.dart.
function P.maybeMoveLibraryFolder(oldRoot, newRoot, whatLabel, after)
  if ops.isSamePath(oldRoot, newRoot) or not ops.directoryHasEntries(oldRoot) then
    after()
    return
  end
  overlays.dialog({
    title = "Move Existing Files?",
    message = 'Move your existing ' .. whatLabel .. ' library files from\n"' .. oldRoot .. '"\nto\n"' .. newRoot .. '"?',
    width = 480,
    dismissible = false,
    actions = {
      { label = "Don't Move", variant = "text", onClick = function() after() end },
      { label = "Move", variant = "filled", onClick = function()
        local ok, err = pcall(ops.moveDirectoryContents, oldRoot, newRoot)
        if not ok then overlays.toast("Could not move the files: " .. tostring(err)) end
        after()
      end },
    },
  })
end

function P:chooseDirectory()
  local path = fileDialog.pickFolder({ title = "Choose your game library folder", initialDir = self.directoryPath })
  if not path then return end
  P.maybeMoveLibraryFolder(self.directoryPath, path, "game", function()
    paths.setGamesDir(path)
    self.directoryPath = path
    self:refresh()
  end)
end

local function drawTile(game, x, y, w, h, onTap)
  local c = theme.c
  local r = ui.region("game:" .. (game.folderPath or game.id), x, y, w, h, { cursor = "hand" })
  ui.rect("fill", x + 1, y + 1, w, h, 8, { 0, 0, 0, 0.38 })
  ui.rect("fill", x, y, w, h, 8, c.surface)
  ui.rect("line", x + 0.5, y + 0.5, w - 1, h - 1, 8, c.outlineVariant)
  if r.hovered then ui.rect("fill", x, y, w, h, 8, theme.alpha(c.onSurface, 0.06)) end
  local pad = 12
  local logoSize = math.min(w - 2 * pad, h - 2 * pad - 8 - 44)
  local lx, ly = x + (w - logoSize) / 2, y + pad
  local logoPath = resolver.resolveGameLogoImagePath(game.folderPath)
  local img = logoPath and imageCache.get(logoPath)
  if img then
    local iw, ih = img:getDimensions()
    local s = math.min(logoSize / iw, logoSize / ih)
    love.graphics.setColor(1, 1, 1)
    love.graphics.draw(img, lx + (logoSize - iw * s) / 2, ly + (logoSize - ih * s) / 2, 0, s, s)
  elseif not logoPath or imageCache.status(logoPath) == "error" then
    ui.rect("fill", lx, ly, logoSize, logoSize, 6, c.surfaceContainerHighest)
    ui.iconCentered("style", lx, ly, logoSize, logoSize, 32, c.onSurfaceVariant)
  end
  local ty = ly + logoSize + 8
  ui.text(game.name, x + pad, ty, { weight = "bold", w = w - 2 * pad, align = "center", ellipsis = true })
  ui.text(game.caption or (#game.cards .. " card(s)"), x + pad, ty + 22, { size = 12, w = w - 2 * pad, align = "center", color = c.onSurfaceVariant })
  if r.clicked then onTap() end
end

function P:draw(x, y, w, h)
  local c = theme.c
  local pad = 24
  x, y, w, h = x + pad, y + pad, w - 2 * pad, h - 2 * pad
  local yy = y
  ui.text("Games", x, yy, { weight = "bold" })
  yy = yy + 28
  ui.text(self.directoryPath, x, yy, { size = 12, color = c.onSurfaceVariant, w = w - 96, h = 40, valign = "middle", ellipsis = true })
  if ui.iconButton("refresh", x + w - 88, yy, { tooltip = "Refresh", disabled = self.busy, id = "gp:refresh" }) then self:refresh() end
  if ui.iconButton("folder_open", x + w - 44, yy, { tooltip = "Change Folder...", disabled = self.busy, id = "gp:folder" }) then
    self:chooseDirectory()
  end
  yy = yy + 44
  if self.busy then
    ui.progressBar(x, yy + 4, w, 2)
    yy = yy + 10
  elseif self.error then
    ui.text(self.error, x, yy + 4, { color = theme.fixed.red, w = w })
    yy = yy + 24
  end
  yy = yy + 12

  local tiles = {}
  for _, g in ipairs(self.games or {}) do
    if g.id ~= self.standardDeck.id then tiles[#tiles + 1] = g end
  end
  if not self.excludeStandardDeck then tiles[#tiles + 1] = self.standardDeck end

  P.drawGrid("gp:grid", tiles, x, yy, w, y + h - yy, pad, function(g) self.onGameChosen(g) end)
end

-- Port of game_grid.dart's GameGridView: up to seven 268px tiles per row,
-- centered, in a scroll view that extends `pad` past each side.
-- onTap(game); each game needs name, cards (or a caption) and, for its
-- logo, folderPath.
function P.drawGrid(scrollId, games, x, y, w, viewH, pad, onTap)
  local columns = math.max(1, math.min(MAX_COLUMNS, math.floor((w + SPACING) / (TILE_W + SPACING))))
  local tileW = TILE_W
  if columns == 1 and w < TILE_W then tileW = w end
  local gridW = columns * tileW + (columns - 1) * SPACING
  local gx = x + (w - gridW) / 2
  local tileH = tileW + TEXT_BLOCK_H
  local off = ui.beginScroll(scrollId, x - pad, y, w + 2 * pad, viewH)
  for i, g in ipairs(games) do
    local col, row = (i - 1) % columns, math.floor((i - 1) / columns)
    local tx, ty = gx + col * (tileW + SPACING), y + 4 + row * (tileH + SPACING) - off
    if ty + tileH > y - 10 and ty < y + viewH + 10 then
      drawTile(g, tx, ty, tileW, tileH, function() onTap(g) end)
    end
  end
  local rows = math.ceil(#games / columns)
  ui.endScroll(scrollId, rows * tileH + (rows - 1) * SPACING + 8)
end

return P
