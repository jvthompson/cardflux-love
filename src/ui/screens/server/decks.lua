-- Server Deck Editor entry: pick one of the server's games, then edit decks
-- stored on the server (optionally also saved locally). In collection mode
-- the pool is limited to the cards the player owns.
local overlays = require("src.ui.kit.overlays")
local json = require("lib.json")
local deckStore = require("src.data.deck_store")
local common = require("src.ui.screens.server.common")

local D = {}
D.__index = D

local function app() return require("src.app") end

-- Opens the server's Deck Editor for `info` (one of sc.games), pushing the
-- real Editor screen once the game is loaded.
function D.open(sc, info)
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

return D
