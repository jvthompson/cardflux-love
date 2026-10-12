-- Server Deck Editor entry: pick one of the server's games, then edit decks
-- stored on the server (optionally also saved locally). In collection mode
-- the pool is limited to the cards the player owns.
local ui = require("src.ui.kit.ui")
local theme = require("src.ui.kit.theme")
local overlays = require("src.ui.kit.overlays")
local json = require("lib.json")
local deckStore = require("src.data.deck_store")
local common = require("src.ui.screens.server.common")
local loader = require("src.data.game_loader")
local assetSync = require("src.net.asset_sync")
local GamePicker = require("src.ui.screens.game_picker")

local D = {}
D.__index = D

local function app() return require("src.app") end

-- The server's games as logo tiles (as the local game pickers show them);
-- onPick(gameInfo). opts.excludeStandardDeck leaves out the Standard
-- 52-Card Deck. Logos come from the game's downloaded copy, if any.
function D.drawGameList(sc, id, x, y, w, h, subtitle, onPick, opts)
  local c = theme.c
  local pad = 24
  x, y, w, h = x + pad, y + pad, w - 2 * pad, h - 2 * pad
  local yy = y
  ui.text("Choose a game", x, yy, { size = 22 })
  yy = yy + 32
  ui.text(subtitle, x, yy, { w = w, color = c.onSurfaceVariant })
  yy = yy + ui.textHeight(subtitle, w) + 20
  local tiles = {}
  for _, g in ipairs(sc.games) do
    if not (opts and opts.excludeStandardDeck and g.id == loader.standardDeckId) then
      local n, sets = g.cardCount or 0, #(g.sets or {})
      local caption = n .. (n == 1 and " card" or " cards")
      if sets > 0 then caption = caption .. "  ·  " .. sets .. (sets == 1 and " set" or " sets") end
      tiles[#tiles + 1] = { id = g.id, name = g.name, caption = caption,
        folderPath = assetSync.gameFolder(sc, g.id), info = g }
    end
  end
  if #tiles == 0 then
    ui.text("This server doesn't have any games yet.", x, yy, { w = w, color = c.onSurfaceVariant })
    return
  end
  GamePicker.drawGrid(id, tiles, x, yy, w, y + h - yy, pad, function(t) onPick(t.info) end)
end

function D.new(sc)
  return setmetatable({ title = "Deck Editor", sc = sc }, D)
end

function D:open(info)
  local sc = self.sc
  common.withGame(sc, info.id, function(game)
    local store = deckStore.serverStore(sc)
    local Editor = require("src.ui.screens.deck_editor").Editor
    if not sc:isCollectionMode() then
      app().push(Editor.new(game, { store = store }))
      return
    end
    sc:request("collectionGet", json.object({ "gameId", game.id }), function(r)
      if not r.ok then
        overlays.alert("Couldn't Load Collection", r.message or "Something went wrong.")
        return
      end
      app().push(Editor.new(game, { store = store, ownedQty = r.cards or {} }))
    end)
  end)
end

function D:draw(x, y, w, h)
  local sub = self.sc:isCollectionMode()
    and "Decks are saved on the server. In collection mode you can only use cards you own."
    or "Decks are saved on the server, so they're available wherever you sign in."
  D.drawGameList(self.sc, "sd:games", x, y, w, h, sub, function(g) self:open(g) end, { excludeStandardDeck = true })
end

return D
