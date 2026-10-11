-- Keeps a local copy of a server's games: <saveDir>/servers/<host_port>/games/<gameId>/
-- in the same layout as game_library, so game_loader and image resolution
-- work on it unchanged. Files are compared by sha256 against the server's
-- manifest; only new or changed ones are downloaded (by asset_worker.lua on
-- a second connection).
local json = require("lib.json")
local fs = require("src.data.fs")
local P = require("src.net.protocol")
local loader = require("src.data.game_loader")
local resolver = require("src.data.image_resolver")
local paths = require("src.data.paths")

local A = {}

local INDEX = ".cardflux_manifest.json"

local function safe(s) return (tostring(s):gsub("[^%w%.%-_]", "_")) end

function A.cacheRoot(sc)
  return fs.join(love.filesystem.getSaveDirectory(), "servers", safe(sc.key))
end

function A.gameFolder(sc, gameId) return fs.join(A.cacheRoot(sc), "games", safe(gameId)) end

-- Every servers/ folder that may hold another cached copy: this save
-- directory's and those of sibling identities (e.g. a second instance
-- started with --identity).
local function serverRoots()
  local save = paths.supportDir()
  local roots = { fs.join(save, "servers") }
  local parent = fs.dirname(save)
  for _, e in ipairs(fs.list(parent) or {}) do
    local dir = fs.join(parent, e.name)
    if e.isDir and fs.normalize(dir):lower() ~= fs.normalize(save):lower() then
      roots[#roots + 1] = fs.join(dir, "servers")
    end
  end
  return roots
end

local function readIndex(folder)
  local raw = fs.readFile(fs.join(folder, INDEX))
  local t = raw and json.tryDecode(raw)
  return type(t) == "table" and t or {}
end

local function writeIndex(folder, index)
  fs.mkdirs(folder)
  fs.writeFile(fs.join(folder, INDEX), json.encode(index))
end

local function loadCached(folder)
  local games = loader.loadFromFolder(folder)
  return games[1]
end

-- Jobs in flight, polled from the protocol loop.
local Job = {}
Job.__index = Job

function Job:update()
  while true do
    local msg = self.channel:pop()
    if msg == nil then break end
    if msg.kind == "file" then
      self.index[msg.path] = msg.sha256
      self.done = self.done + 1
      self.bytes = self.bytes + (msg.bytes or 0)
      if msg.reused then self.reused = self.reused + 1 end
      if self.done % 25 == 0 then writeIndex(self.folder, self.index) end
      if self.onProgress then self.onProgress(self.done, self.total, self.bytes, self.reused) end
    elseif msg.kind == "done" then
      return self:finish(nil)
    elseif msg.kind == "error" then
      return self:finish(msg.message)
    end
  end
  if not self.thread:isRunning() and self.channel:getCount() == 0 then
    local terr = self.thread:getError()
    self:finish(terr or "The download stopped unexpectedly.")
  end
end

function Job:finish(err)
  if self.finished then return end
  self.finished = true
  P.unregister(self)
  writeIndex(self.folder, self.index)
  self.onDone(err)
end

-- Ensures the game is cached and current, then calls onDone(game) or
-- onDone(nil, errorMessage). onProgress(done, total, bytes, reused) reports
-- progress; `reused` counts files found already on this computer. Loaded games are memoized per manifest hash.
function A.ensureGame(sc, gameId, onDone, onProgress)
  sc.loadedGames = sc.loadedGames or {}
  local info = sc:gameById(gameId)
  local memo = sc.loadedGames[gameId]
  if memo and info and memo.hash == info.manifestHash then return onDone(memo.game) end
  local folder = A.gameFolder(sc, gameId)
  sc:request("gameManifest", json.object({ "gameId", gameId }), function(r)
    if not r.ok then return onDone(nil, r.message or "The server doesn't have that game.") end
    local index = readIndex(folder)
    local wanted, todo = {}, {}
    for _, f in ipairs(r.files or {}) do
      wanted[f.path] = true
      local local_ = fs.join(folder, (f.path:gsub("/", fs.sep)))
      if index[f.path] ~= f.sha256 or not fs.isFile(local_) then todo[#todo + 1] = f end
    end
    -- Files the server dropped.
    for path in pairs(index) do
      if not wanted[path] then
        fs.remove(fs.join(folder, (path:gsub("/", fs.sep))))
        index[path] = nil
      end
    end
    local function loaded(err)
      if err then return onDone(nil, err) end
      resolver.clearCache()
      local ok, game = pcall(loadCached, folder)
      if not ok or not game then return onDone(nil, "The downloaded game could not be loaded.") end
      sc.loadedGames[gameId] = { hash = r.manifestHash, game = game }
      onDone(game)
    end
    if #todo == 0 then
      writeIndex(folder, index)
      return loaded(nil)
    end
    local saved = require("src.net.server_client").savedSession(sc.key)
    local job = setmetatable({ folder = folder, index = index, done = 0, total = #todo, bytes = 0, reused = 0,
      onProgress = onProgress, onDone = loaded, channel = love.thread.newChannel() }, Job)
    job.thread = love.thread.newThread("src/net/asset_worker.lua")
    local files = {}
    for i, f in ipairs(todo) do files[i] = { path = f.path, sha256 = f.sha256, size = f.size } end
    job.thread:start({ host = sc.host, port = sc.port, token = sc.token or (saved and saved.token), gameId = gameId,
      folder = folder, files = files, gamesDir = paths.gamesDir(), cacheGameDir = safe(gameId),
      serverRoots = serverRoots() }, job.channel)
    P.register(job)
    if onProgress then onProgress(0, #todo, 0, 0) end
  end)
end

-- A game already in memory (no network), or nil.
function A.cachedGame(sc, gameId)
  local memo = sc.loadedGames and sc.loadedGames[gameId]
  return memo and memo.game
end

return A
