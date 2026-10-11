-- Server asset worker (src/net/asset_worker.lua): files already on this
-- computer are verified by SHA-256 and reused instead of downloaded.
local fs = require("src.data.fs")
local json = require("lib.json")

return function(t)
  local counter = 0
  local function tempDir()
    counter = counter + 1
    love.filesystem.createDirectory("test_tmp")
    local dir = fs.join(love.filesystem.getSaveDirectory(), "test_tmp", "assets" .. counter)
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
  local function entry(path, data) return { path = path, sha256 = sha256(data), size = #data } end

  -- Runs the worker to completion. Port 1 refuses connections, so any
  -- attempt to download fails the job.
  local function run(job)
    job.host, job.port, job.token, job.gameId = "127.0.0.1", 1, "x", job.gameId or "demo"
    job.cacheGameDir = job.cacheGameDir or job.gameId
    local ch = love.thread.newChannel()
    local th = love.thread.newThread("src/net/asset_worker.lua")
    th:start(job, ch)
    local msgs = {}
    while true do
      local m = ch:demand(10)
      if not m then error("worker timed out: " .. tostring(th:getError())) end
      msgs[#msgs + 1] = m
      if m.kind == "done" or m.kind == "error" then break end
    end
    th:wait()
    return msgs
  end
  local function reusedCount(msgs)
    local n = 0
    for _, m in ipairs(msgs) do if m.kind == "file" and m.reused then n = n + 1 end end
    return n
  end

  t.describe("local copies", function()
    t.it("reuses an untracked file already in the cache folder without connecting", function()
      local root = tempDir()
      local folder = fs.join(root, "cache", "games", "demo")
      write(fs.join(folder, "set1", "a.png"), "card a")
      local msgs = run({ folder = folder, files = { entry("set1/a.png", "card a") } })
      t.eq(msgs[#msgs].kind, "done")
      t.eq(reusedCount(msgs), 1)
    end)

    t.it("copies a matching file from a local game folder with the same game id", function()
      local root = tempDir()
      local games = fs.join(root, "games")
      write(fs.join(games, "Demo Game", "gamedef.json"), json.encode({ id = "demo", name = "Demo" }))
      write(fs.join(games, "Demo Game", "set1", "a.png"), "card a")
      write(fs.join(games, "Other", "gamedef.json"), json.encode({ id = "other" }))
      write(fs.join(games, "Other", "set1", "b.png"), "card b")
      local folder = fs.join(root, "cache", "games", "demo")
      local msgs = run({ folder = folder, gamesDir = games, files = { entry("set1/a.png", "card a") } })
      t.eq(msgs[#msgs].kind, "done")
      t.eq(fs.readFile(fs.join(folder, "set1", "a.png")), "card a")
    end)

    t.it("copies a matching file from another server's cache", function()
      local root = tempDir()
      local servers = fs.join(root, "servers")
      write(fs.join(servers, "otherhost_1234", "games", "demo", "back.png"), "back")
      local folder = fs.join(servers, "localhost_1234", "games", "demo")
      local msgs = run({ folder = folder, serverRoots = { servers }, files = { entry("back.png", "back") } })
      t.eq(msgs[#msgs].kind, "done")
      t.eq(fs.readFile(fs.join(folder, "back.png")), "back")
    end)

    t.it("downloads when the local copy's content differs", function()
      local root = tempDir()
      local folder = fs.join(root, "cache", "games", "demo")
      write(fs.join(folder, "a.png"), "card A") -- same size, different bytes
      local msgs = run({ folder = folder, files = { entry("a.png", "card a") } })
      t.eq(msgs[#msgs].kind, "error")
      t.eq(reusedCount(msgs), 0)
      t.eq(fs.readFile(fs.join(folder, "a.png")), "card A")
    end)
  end)
end
