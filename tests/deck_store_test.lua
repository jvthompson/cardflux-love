-- Deck storage backends (src/data/deck_store.lua): the local deck library
-- folder and a Cardflux server's per-account deck storage, behind the same
-- callback API.
local models = require("src.core.models")
local paths = require("src.data.paths")
local settings = require("src.data.settings")
local fs = require("src.data.fs")
local decks = require("src.data.deck_library")
local store = require("src.data.deck_store")

return function(t)
  local counter = 0

  -- Points paths.decksDir() at a scratch folder for the duration of fn,
  -- then restores whatever was configured before (same save/restore
  -- pattern as data_test.lua's "recent servers" case).
  local function withTempDecksDir(fn)
    counter = counter + 1
    love.filesystem.createDirectory("test_tmp")
    local dir = fs.join(love.filesystem.getSaveDirectory(), "test_tmp", "deck_store" .. counter)
    fs.removeTree(dir)
    fs.mkdirs(dir)
    local saved = settings.get(settings.keys.decksDirectoryPath)
    paths.setDecksDir(dir)
    local ok, err = pcall(fn, dir)
    if saved == nil then settings.remove(settings.keys.decksDirectoryPath) else settings.set(settings.keys.decksDirectoryPath, saved) end
    if not ok then error(err, 0) end
  end

  local function deck()
    return models.DeckConfig.new("g", { models.SubDeck.new("main_deck", { models.DeckEntry.new("a", 2) }) })
  end

  local function fakeSc(request, name)
    return { info = { name = name or "Test Server" }, request = request }
  end

  t.describe("deck_store local", function()
    t.it("writes, lists and removes a deck in the configured decks dir", function()
      withTempDecksDir(function()
        local s = store.localStore()
        t.eq(s.kind, "local")
        local game = models.GameDefinition.new({ id = "g", name = "G" })

        local wrote
        s:write(game, "My Deck", deck(), function(ok, err, path) wrote = { ok, err, path } end)
        t.ok(wrote[1])
        t.isNil(wrote[2])
        t.ok(wrote[3]:find("My Deck", 1, true) ~= nil)

        local listed
        s:list(game, function(scan) listed = scan end)
        t.eq(t.ids(listed.entries, "displayName"), { "My Deck" })

        local removed
        s:remove(game, "My Deck", function(ok) removed = ok end)
        t.ok(removed)
        s:list(game, function(scan) listed = scan end)
        t.eq(#listed.entries, 0)
      end)
    end)
  end)

  t.describe("deck_store server", function()
    t.it("lists server decks, merging in a game's built-in decks", function()
      local sc = fakeSc(function(_, cmd, payload, cb)
        t.eq(cmd, "deckList")
        t.eq(payload.gameId, "g")
        cb({ ok = true, decks = { { name = "Server Deck", deck = models.DeckConfig.toJson(deck()) } } })
      end, "My Server")
      local s = store.serverStore(sc)
      t.eq(s.kind, "server")
      t.eq(s.label, "My Server")
      local game = models.GameDefinition.new({ id = "g", name = "G" }) -- no folderPath: no built-ins
      local entries, err
      s:list(game, function(scan, e) entries, err = scan, e end)
      t.eq(t.ids(entries.entries, "displayName"), { "Server Deck" })
      t.isNil(err)
    end)

    t.it("reports an incompatible deck instead of failing the whole list", function()
      local sc = fakeSc(function(_, _, _, cb)
        cb({ ok = true, decks = { { name = "Bad", deck = { notADeck = true } } } })
      end)
      local game = models.GameDefinition.new({ id = "g", name = "G" })
      local got
      store.serverStore(sc):list(game, function(scan) got = scan end)
      t.eq(#got.entries, 0)
      t.eq(t.ids(got.incompatible, "displayName"), { "Bad" })
    end)

    t.it("surfaces the server's error message when the list request fails", function()
      local sc = fakeSc(function(_, _, _, cb) cb({ ok = false, message = "nope" }) end)
      local game = models.GameDefinition.new({ id = "g", name = "G" })
      local err
      store.serverStore(sc):list(game, function(_, e) err = e end)
      t.eq(err, "nope")
    end)

    t.it("saves to the server, and optionally mirrors to the local library", function()
      withTempDecksDir(function()
        local saveCall
        local sc = fakeSc(function(_, cmd, payload, cb)
          saveCall = { cmd = cmd, payload = payload }
          cb({ ok = true })
        end)
        local s = store.serverStore(sc)
        s.alsoLocal = true
        local game = models.GameDefinition.new({ id = "g", name = "G" })
        local result
        s:write(game, "Mirrored", deck(), function(ok, err, where) result = { ok, err, where } end)
        t.eq(saveCall.cmd, "deckSave")
        t.eq(saveCall.payload.name, "Mirrored")
        t.eq(saveCall.payload.overwrite, true)
        t.ok(result[1])
        t.isNil(result[2])
        t.eq(result[3], s.label)
        t.ok(decks.deckExists(paths.decksDir(), "g", "Mirrored"))
      end)
    end)

    t.it("doesn't mirror locally when alsoLocal is off", function()
      withTempDecksDir(function()
        local sc = fakeSc(function(_, _, _, cb) cb({ ok = true }) end)
        local game = models.GameDefinition.new({ id = "g", name = "G" })
        store.serverStore(sc):write(game, "ServerOnly", deck(), function() end)
        t.notOk(decks.deckExists(paths.decksDir(), "g", "ServerOnly"))
      end)
    end)

    t.it("removes a server deck", function()
      local deleteCall
      local sc = fakeSc(function(_, cmd, payload, cb)
        deleteCall = { cmd = cmd, payload = payload }
        cb({ ok = true })
      end)
      local game = models.GameDefinition.new({ id = "g", name = "G" })
      local removed
      store.serverStore(sc):remove(game, "Gone", function(ok) removed = ok end)
      t.eq(deleteCall.cmd, "deckDelete")
      t.eq(deleteCall.payload.name, "Gone")
      t.ok(removed)
    end)
  end)
end
