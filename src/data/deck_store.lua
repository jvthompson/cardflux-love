-- Where decks are listed, loaded and saved: the local deck library folder,
-- or a Cardflux server's per-account deck storage. Both backends use the
-- same callback API so the deck dialogs don't care which one they have.
--
--   store.kind                       "local" | "server"
--   store.label                      shown in dialogs ("your deck library", server name)
--   store:list(game, cb)             cb({ entries = { {displayName, deck, isBuiltIn} }, incompatible = {...} }, err)
--   store:write(game, name, deck, cb) cb(ok, errMessage, where)
--   store:remove(game, name, cb)     cb(ok, errMessage)
local json = require("lib.json")
local models = require("src.core.models")
local paths = require("src.data.paths")
local decks = require("src.data.deck_library")

local M = {}

---------------------------------------------------------------------------
-- Local folder
---------------------------------------------------------------------------

local Local = { kind = "local", label = "your deck library" }
Local.__index = Local

function M.localStore() return setmetatable({}, Local) end

function Local:list(game, cb)
  local ok, scan = pcall(decks.loadAllDecksForGame, paths.decksDir(), game)
  if ok then cb(scan) else cb({ entries = {}, incompatible = {} }, tostring(scan)) end
end

function Local:write(game, name, deck, cb)
  local path, err = decks.writeDeck(paths.decksDir(), game.id, name, deck)
  if cb then cb(path ~= nil, err and tostring(err), path) end
end

function Local:remove(game, name, cb)
  local fs = require("src.data.fs")
  local ok = fs.remove(decks.deckPath(paths.decksDir(), game.id, name))
  if cb then cb(ok ~= false) end
end

---------------------------------------------------------------------------
-- Server (src/net/server_client.lua)
---------------------------------------------------------------------------

local Server = { kind = "server" }
Server.__index = Server

-- alsoLocal: when true, saves also write a copy to the local library.
function M.serverStore(sc)
  return setmetatable({ sc = sc, label = sc.info.name or "the server", alsoLocal = false }, Server)
end

function Server:list(game, cb)
  self.sc:request("deckList", json.object({ "gameId", game.id, "full", true }), function(r)
    -- Built-in decks ship inside the (cached) game folder.
    local builtIn = decks.loadBuiltInDecksForGame(game)
    local entries, incompatible = {}, {}
    if r.ok then
      for _, d in ipairs(r.decks or {}) do
        local ok, deck = pcall(models.DeckConfig.fromJson, d.deck)
        if ok then
          entries[#entries + 1] = { displayName = d.name, deck = deck, isBuiltIn = false }
        else
          incompatible[#incompatible + 1] = { displayName = d.name }
        end
      end
    end
    for _, e in ipairs(builtIn.entries) do entries[#entries + 1] = e end
    cb({ entries = entries, incompatible = incompatible }, (not r.ok) and (r.message or "Could not load decks.") or nil)
  end)
end

function Server:write(game, name, deck, cb)
  local payload = json.object({ "gameId", game.id, "name", name, "deck", models.DeckConfig.toJson(deck), "overwrite", true })
  self.sc:request("deckSave", payload, function(r)
    if r.ok and self.alsoLocal then
      local path, err = decks.writeDeck(paths.decksDir(), game.id, name, deck)
      if not path then
        if cb then cb(true, "Saved on the server, but the local copy failed: " .. tostring(err), self.label) end
        return
      end
    end
    if cb then cb(r.ok == true, r.message, self.label) end
  end)
end

function Server:remove(game, name, cb)
  self.sc:request("deckDelete", json.object({ "gameId", game.id, "name", name }), function(r)
    if cb then cb(r.ok == true, r.message) end
  end)
end

return M
