-- Server game-cache sync (src/net/asset_sync.lua): manifest diffing,
-- dropped-file cleanup and in-memory memoization. The actual download
-- (src/net/asset_worker.lua, run on a thread when files are missing) has
-- its own coverage in asset_worker_test.lua; these tests stick to the
-- "nothing to download" paths so they don't need a real network thread.
local json = require("lib.json")
local fs = require("src.data.fs")
local A = require("src.net.asset_sync")

return function(t)
  local counter = 0
  local function tempDir()
    counter = counter + 1
    love.filesystem.createDirectory("test_tmp")
    local dir = fs.join(love.filesystem.getSaveDirectory(), "test_tmp", "asset_sync" .. counter)
    fs.removeTree(dir)
    fs.mkdirs(dir)
    return dir
  end
  local function write(path, data)
    fs.mkdirs(fs.dirname(path))
    fs.writeFile(path, data)
  end
  local function sha256(data)
    return love.data.encode("string", "hex", love.data.hash("sha256", data)):lower()
  end

  t.describe("cache paths", function()
    t.it("sanitizes the server key and game id into folder names", function()
      local sc = { key = "myhost:1234" }
      local gf = A.gameFolder(sc, "my/game")
      t.ok(gf:find("myhost_1234", 1, true) ~= nil)
      t.ok(gf:find("my_game", 1, true) ~= nil)
      t.notOk(gf:find("myhost:1234", 1, true) ~= nil)
      t.eq(A.gameFolder(sc, "my/game"), fs.join(A.cacheRoot(sc), "games", "my_game"))
    end)
  end)

  t.describe("ensureGame", function()
    t.it("returns the memoized game without a request when the manifest hash is unchanged", function()
      local requested = false
      local sc = {
        key = "memo_srv",
        gameById = function() return { manifestHash = "h1" } end,
        request = function() requested = true end,
      }
      local fakeGame = { id = "demo" }
      sc.loadedGames = { demo = { hash = "h1", game = fakeGame } }
      local got
      A.ensureGame(sc, "demo", function(game) got = game end)
      t.notOk(requested)
      t.ok(got == fakeGame)
    end)

    t.it("loads straight from the cache when every file already matches the manifest", function()
      local sc = { key = "match_srv", gameById = function() return nil end }
      local folder = A.gameFolder(sc, "demo")
      write(fs.join(folder, "gamedef.json"), json.encode({ id = "demo", name = "Demo", cards = {} }))
      write(fs.join(folder, "a.png"), "card a")
      write(fs.join(folder, ".cardflux_manifest.json"), json.encode({ ["a.png"] = sha256("card a") }))
      local requestCount = 0
      sc.request = function(_, cmd, payload, cb)
        requestCount = requestCount + 1
        t.eq(cmd, "gameManifest")
        t.eq(payload.gameId, "demo")
        cb({ ok = true, manifestHash = "h2", files = { { path = "a.png", sha256 = sha256("card a"), size = 6 } } })
      end
      local game, err
      A.ensureGame(sc, "demo", function(g, e) game, err = g, e end)
      t.eq(requestCount, 1)
      t.isNil(err)
      t.eq(game.id, "demo")
      t.ok(A.cachedGame(sc, "demo") == game)
    end)

    t.it("removes files the server dropped, from both disk and the manifest", function()
      local sc = { key = "drop_srv", gameById = function() return nil end }
      local folder = A.gameFolder(sc, "demo")
      write(fs.join(folder, "gamedef.json"), json.encode({ id = "demo", name = "Demo", cards = {} }))
      write(fs.join(folder, "a.png"), "card a")
      write(fs.join(folder, "old.png"), "stale")
      write(fs.join(folder, ".cardflux_manifest.json"),
        json.encode({ ["a.png"] = sha256("card a"), ["old.png"] = sha256("stale") }))
      sc.request = function(_, _, _, cb)
        cb({ ok = true, manifestHash = "h3", files = { { path = "a.png", sha256 = sha256("card a"), size = 6 } } })
      end
      local game
      A.ensureGame(sc, "demo", function(g) game = g end)
      t.eq(game.id, "demo")
      t.notOk(fs.exists(fs.join(folder, "old.png")))
      local index = json.decode(fs.readFile(fs.join(folder, ".cardflux_manifest.json")))
      t.isNil(index["old.png"])
      t.eq(index["a.png"], sha256("card a"))
    end)

    t.it("reports the server's error instead of loading when the manifest request fails", function()
      local sc = { key = "err_srv", gameById = function() return nil end,
        request = function(_, _, _, cb) cb({ ok = false, message = "no such game" }) end }
      local game, err
      A.ensureGame(sc, "demo", function(g, e) game, err = g, e end)
      t.isNil(game)
      t.eq(err, "no such game")
    end)
  end)

  t.describe("cachedGame", function()
    t.it("is nil until a game has been loaded for that id", function()
      local sc = { key = "fresh_srv" }
      t.isNil(A.cachedGame(sc, "demo"))
    end)
  end)
end
