-- Port of practice_game_select_screen.dart.
local ui = require("src.ui.kit.ui")
local models = require("src.core.models")
local color = require("src.core.color")
local GamePicker = require("src.ui.screens.game_picker")

local S = {}
S.__index = S

local function app() return require("src.app") end

function S.new(playerCount)
  local self = setmetatable({ title = "Choose a Game", playerCount = playerCount }, S)
  self.picker = GamePicker.new(function(game) self:chooseGame(game) end)
  return self
end

-- Seat 1 is you; the other seats get the next unused palette colors.
function S:buildPlayers()
  local A = app()
  local players = { models.PlayerInfo.new({ id = "seat1", name = A.playerName(), role = "host", color = A.profile.color }) }
  local used = { [A.profile.color] = true }
  for seat = 2, self.playerCount do
    local c = color.boardWidgetColorPalette[1]
    for _, p in ipairs(color.boardWidgetColorPalette) do
      if not used[p] then c = p break end
    end
    used[c] = true
    players[#players + 1] = models.PlayerInfo.new({ id = "seat" .. seat, name = "Player " .. seat, role = "host", color = c })
  end
  return players
end

function S:chooseGame(game)
  -- An empty deck map (not nil): built-deck zones start empty and each
  -- seat loads a deck at the table, like Flutter's practice mode.
  app().push(require("src.ui.screens.practice_game").new({ game = game, players = self:buildPlayers(), deckConfigsByPlayerId = {} }))
end

function S:update(dt) self.picker:update(dt) end

function S:draw(x, y, w, h)
  local label = "Load a Saved Game..."
  local bw = ui.buttonWidth(label, { icon = "folder_open" })
  if ui.button(label, x + w - 16 - bw, y + 16, bw, nil, { variant = "outlined", icon = "folder_open" }) then
    local players = self:buildPlayers()
    app().push(require("src.ui.screens.load_saved_game").new(players, function(game, state)
      app().push(require("src.ui.screens.practice_game").new({ game = game, players = players, loadedState = state }))
    end))
  end
  self.picker:draw(x, y + 56, w, h - 56)
end

return S
