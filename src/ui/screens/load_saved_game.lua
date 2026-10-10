-- Ports of load_saved_game_screen.dart and seat_match_screen.dart.
local ui = require("src.ui.kit.ui")
local theme = require("src.ui.kit.theme")
local overlays = require("src.ui.kit.overlays")
local models = require("src.core.models")
local util = require("src.core.util")
local remap = require("src.core.save_remap")
local saves = require("src.data.save_files")
local GamePicker = require("src.ui.screens.game_picker")

local function app() return require("src.app") end

---------------------------------------------------------------------------
-- Seat match
---------------------------------------------------------------------------

local SeatMatch = {}
SeatMatch.__index = SeatMatch

-- onDone(map savedId -> currentId) on Confirm; onCancel() on Back.
function SeatMatch.new(unmatchedSaved, unmatchedCurrent, onDone, onCancel)
  return setmetatable({ title = "Match Returning Players", saved = unmatchedSaved,
    order = util.shallowCopy(unmatchedCurrent), onDone = onDone, onCancel = onCancel }, SeatMatch)
end

function SeatMatch:onBack()
  app().pop()
  if self.onCancel then self.onCancel() end
end

function SeatMatch:draw(x, y, w, h)
  local colW = math.min(480, w - 48)
  local cx = math.floor(x + (w - colW) / 2)
  local intro = "This save's players couldn't be matched to your current players by name alone. "
    .. "Choose who each saved player is now:"
  local introH = ui.textHeight(intro, colW, 14)
  local total = introH + 24 + #self.saved * 60 + 24 + 48
  local yy = math.floor(y + math.max(24, (h - total) / 2))
  ui.text(intro, cx, yy, { w = colW })
  yy = yy + introH + 24
  for i, sp in ipairs(self.saved) do
    ui.text('Saved as "' .. sp.name .. '"', cx, yy, { h = 48, valign = "middle", w = colW - 220, ellipsis = true })
    local options = util.map(self.order, function(p) return { value = p.id, label = p.name } end)
    local picked = ui.dropdown("seatmatch:" .. i, cx + colW - 200, yy, 200, options, self.order[i].id)
    if picked ~= self.order[i].id then
      for j, p in ipairs(self.order) do
        if p.id == picked then self.order[i], self.order[j] = self.order[j], self.order[i] break end
      end
    end
    yy = yy + 60
  end
  yy = yy + 24
  if ui.button("Confirm", cx, yy, colW, 48) then
    local map = {}
    for i, sp in ipairs(self.saved) do map[sp.id] = self.order[i].id end
    app().pop()
    self.onDone(map)
  end
end

---------------------------------------------------------------------------
-- Load saved game
---------------------------------------------------------------------------

local S = {}
S.__index = S

-- currentPlayers: the players the loaded game will have.
-- onLoaded(game, state) is called once a save is chosen and remapped.
function S.new(currentPlayers, onLoaded)
  local self = setmetatable({ title = "Load a Saved Game", currentPlayers = currentPlayers, onLoaded = onLoaded }, S)
  self.picker = GamePicker.new(function(game) self:chooseGame(game) end)
  return self
end

function S:chooseGame(game)
  if not game.folderPath then
    overlays.toast("This game has no folder on disk, so it has no saved games.")
    return
  end
  self.game = game
  self.entries = saves.listSaveGames(game.folderPath)
  self.title = "Load a Saved Game -- " .. game.name
end

function S:onBack()
  if self.game then
    self.game, self.entries = nil, nil
    self.title = "Load a Saved Game"
  else
    app().pop()
  end
end

local function validDefinitionIds(game)
  local ids = {}
  for _, c in ipairs(game.cards) do ids[c.id] = true end
  if util.any(game.zones, function(z) return z.shared and z.standardDeck end) then
    for _, c in ipairs(models.buildStandardDeckCards()) do ids[c.id] = true end
  end
  return ids
end

function S:pickSave(entry)
  local game = self.game
  local save, err = saves.readSaveGame(entry.filePath)
  if not save then
    overlays.toast("Could not read that save: " .. tostring(err))
    return
  end
  local function finish(idMap)
    local state, dropped = remap.buildLoadedTableState(save.state, self.currentPlayers, idMap, validDefinitionIds(game))
    if dropped > 0 then
      overlays.confirm("Some Cards No Longer Exist",
        dropped .. " card(s) in this save reference content that no longer exists in " .. game.name
          .. " (it's been edited since this save) and will be skipped. Continue loading?",
        "Continue", function() self.onLoaded(game, state) end)
    else
      self.onLoaded(game, state)
    end
  end
  local match = remap.matchPlayersByName(save.state.players, self.currentPlayers)
  if #match.unmatchedSaved > 0 then
    app().push(SeatMatch.new(match.unmatchedSaved, match.unmatchedCurrent, function(manual)
      local idMap = util.shallowCopy(match.matched)
      for k, v in pairs(manual) do idMap[k] = v end
      finish(idMap)
    end))
  else
    finish(match.matched)
  end
end

function S:update(dt) if not self.game then self.picker:update(dt) end end

function S:draw(x, y, w, h)
  if not self.game then
    self.picker:draw(x, y, w, h)
    return
  end
  local c = theme.c
  local entries = self.entries or {}
  if #entries == 0 then
    ui.text("No saved games found for " .. self.game.name .. ".", x, y, { w = w, h = h, align = "center", valign = "middle", color = c.onSurfaceVariant })
    return
  end
  local colW = math.min(480, w - 32)
  local cx = math.floor(x + (w - colW) / 2)
  local rowH, gap = 72, 8
  local total = #entries * (rowH + gap)
  local listY = y + math.max(16, (h - total) / 2)
  local viewH = math.min(total, h - 32)
  local off = ui.beginScroll("loadsave:list", cx - 8, listY, colW + 16, viewH)
  local yy = listY - off
  local need = #self.currentPlayers
  for i, e in ipairs(entries) do
    local compatible = e.playerCount == need
    local r = compatible and ui.region("loadsave:" .. i, cx, yy, colW, rowH, { cursor = "hand" }) or {}
    ui.rect("fill", cx, yy, colW, rowH, 12, c.surfaceContainer)
    if r.hovered then ui.rect("fill", cx, yy, colW, rowH, 12, theme.alpha(c.onSurface, 0.06)) end
    local fg = compatible and c.onSurface or c.disabled
    ui.text(e.displayName, cx + 16, yy + 14, { size = 16, color = fg, w = colW - 32, ellipsis = true })
    local sub = "Saved " .. saves.formatSavedAt(e.savedAt) .. " -- " .. (compatible
      and (e.playerCount .. " player(s)")
      or ("needs " .. need .. " player(s), this save has " .. e.playerCount))
    ui.text(sub, cx + 16, yy + 40, { size = 13, color = compatible and c.onSurfaceVariant or c.disabled, w = colW - 32, ellipsis = true })
    if r.clicked then self:pickSave(e) end
    yy = yy + rowH + gap
  end
  ui.endScroll("loadsave:list", total)
end

S.SeatMatch = SeatMatch
return S
