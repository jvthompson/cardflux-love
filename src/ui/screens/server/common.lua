-- Helpers shared by the Cardflux server screens: game downloads with a
-- progress dialog, entering rooms/games, and getting back to the lobby.
local ui = require("src.ui.kit.ui")
local theme = require("src.ui.kit.theme")
local overlays = require("src.ui.kit.overlays")
local widgets = require("src.ui.kit.widgets")
local json = require("lib.json")
local assetSync = require("src.net.asset_sync")
local deckStore = require("src.data.deck_store")

local M = {}

local function app() return require("src.app") end

local function formatBytes(n)
  if n >= 1024 * 1024 then return string.format("%.1f MB", n / (1024 * 1024)) end
  return string.format("%d KB", math.floor(n / 1024 + 0.5))
end

-- Makes sure a server game is downloaded and current, showing a progress
-- dialog while files download. onReady(game) runs once it is loaded.
function M.withGame(sc, gameId, onReady)
  local cached = assetSync.cachedGame(sc, gameId)
  local info = sc:gameById(gameId)
  local st = { done = 0, total = 0, bytes = 0, reused = 0, checking = true }
  local dialog
  local function close() if dialog then dialog:close() dialog = nil end end
  assetSync.ensureGame(sc, gameId, function(game, err)
    close()
    if not game then
      overlays.alert("Couldn't Load Game", err or "The game could not be downloaded.")
      return
    end
    onReady(game)
  end, function(done, total, bytes, reused)
    st.checking, st.done, st.total, st.bytes, st.reused = false, done, total, bytes, reused or 0
    if not dialog then
      dialog = overlays.dialog({
        title = "Downloading " .. (info and info.name or "game"),
        width = 420, dismissible = false,
        content = function(_, x, y, w)
          ui.progressBar(x, y + 4, w, 4, st.total > 0 and st.done / st.total or 0)
          local status = st.done .. " of " .. st.total .. " files (" .. formatBytes(st.bytes) .. " downloaded"
          if st.reused > 0 then status = status .. ", " .. st.reused .. " already on this computer" end
          ui.text(status .. ")", x, y + 20, { w = w, ellipsis = true })
          ui.text("Game files are kept on this computer, so this only happens when the server's copy changes.", x, y + 44,
            { w = w, size = 12, color = theme.c.onSurfaceVariant })
          return 44 + ui.textHeight("Game files are kept on this computer, so this only happens when the server's copy changes.", w, 12)
        end,
        actions = {},
      })
    end
  end)
  local _ = cached
end

-- Pops every screen above the server lobby (then toasts `message`).
function M.returnToLobby(message)
  local A = app()
  while A.top() and not A.top().isServerLobby do
    local before = A.top()
    A.pop()
    if A.top() == before then break end
  end
  if message then overlays.toast(message) end
end

-- The table for a running room (playing or spectating).
function M.gameScreen(sc, game, spectating)
  local MP = require("src.ui.screens.multiplayer")
  local room = sc:currentRoom()
  local ch = sc:gameChannel()
  -- Spectators watch under the same id the server filters for them.
  return MP.ClientGame.new(ch, spectating and ("spectator:" .. sc.self.id) or sc.self.id, {
    localGame = game,
    spectator = spectating,
    collectionMode = room and room.collectionMode,
    deckStore = deckStore.serverStore(sc),
    avatarKeys = function() return sc:avatarKeysByUserId() end,
    leaveMessage = spectating and "Stop watching this game?"
      or "Leave the game? Your seat is kept, so you can rejoin from the lobby while the game is running.",
    disconnectMessage = function() return sc:disconnectMessage() end,
    onExit = function(message)
      if sc.roomId then sc:request("roomLeave", json.object()) end
      sc.roomId, sc.spectating = nil, false
      sc:closeChannel()
      if sc.status ~= "connected" then
        app().popToHome(message)
      else
        M.returnToLobby(spectating and nil or message)
      end
    end,
  })
end

-- Joins (mode "join") or watches (mode "spectate") a room, downloading
-- its game first. Running games open the table; waiting ones the room.
function M.enterRoom(sc, room, mode)
  M.withGame(sc, room.gameId, function(game)
    -- The channel must exist before the request: a running game sends
    -- gameData + fullState right after the reply.
    sc:closeChannel()
    sc:gameChannel()
    sc:request(mode == "spectate" and "roomSpectate" or "roomJoin", json.object({ "roomId", room.id }), function(r)
      if not r.ok then
        sc:closeChannel()
        overlays.alert(mode == "spectate" and "Couldn't Watch Game" or "Couldn't Join Game", r.message or "Something went wrong.")
        return
      end
      sc.roomId, sc.spectating = r.room.id, mode == "spectate"
      sc.roomChat = r.chat or {}
      M.openRoomScreen(sc, game, r.room)
    end)
  end)
end

function M.openRoomScreen(sc, game, room)
  if room.state == "playing" then
    app().push(M.gameScreen(sc, game, sc.spectating))
  else
    app().push(require("src.ui.screens.server.room").new(sc, game))
  end
end

-- Small avatar + name row used by the lobby and the room.
function M.userRow(sc, user, x, y, w, opts)
  opts = opts or {}
  local size = opts.size or 28
  local key = sc:avatarKey(user.avatarHash)
  widgets.avatar(x, y + ((opts.h or size) - size) / 2, size, user.color or 0xFF455A64, key and { key = key } or nil, false)
  ui.text(user.name, x + size + 10, y, { w = w - size - 10, h = opts.h or size, valign = "middle", ellipsis = true,
    weight = opts.bold and "bold" or nil, color = opts.color })
end

function M.timeLabel(at)
  return os.date("%H:%M", at)
end

return M
