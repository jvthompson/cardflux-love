-- Worker thread for src/net/asset_sync.lua: brings each requested file
-- into the game's cache folder and reports progress. A file whose content
-- is already on this computer (untracked in the cache folder, in a local
-- game folder with the same game id, or in another server's cache) is
-- verified by SHA-256 and reused; the rest are downloaded over a second
-- connection to the server (the asset channel), opened only if needed.
--
-- job: { host, port, token, gameId, folder, files = { {path, sha256, size}, ... },
--        gamesDir, cacheGameDir, serverRoots = { <save dir>/servers, ... } }
-- out: channel receiving { kind = "file", path, sha256, bytes, reused }
--      then { kind = "done" } or { kind = "error", message }
local job, out = ...

require("love.filesystem")
require("love.data")
require("love.timer")
local socket = require("socket")
local json = require("lib.json")
local fs = require("src.data.fs")

local function line(msgType, payload)
  return json.encode(json.object({ "type", msgType, "payload", payload or json.object() })) .. "\n"
end

local function fail(message)
  out:push({ kind = "error", message = message })
end

-- Local copies ------------------------------------------------------------

local function sha256(data)
  return love.data.encode("string", "hex", love.data.hash("sha256", data)):lower()
end

-- Sizes of the files in a directory, listed once. Non-Windows listings
-- report size 0, which means "unknown".
local dirSizes = {}
local function sizeOf(path)
  local dir = fs.dirname(path)
  local sizes = dirSizes[dir]
  if not sizes then
    sizes = {}
    for _, e in ipairs(fs.list(dir) or {}) do
      if not e.isDir then sizes[e.name:lower()] = e.size end
    end
    dirSizes[dir] = sizes
  end
  return sizes[fs.basename(path):lower()]
end

-- Local game folders whose gamedef.json has this game's id.
local function localGameFolders()
  local out = {}
  if not job.gamesDir then return out end
  for _, e in ipairs(fs.list(job.gamesDir) or {}) do
    if e.isDir then
      local folder = fs.join(job.gamesDir, e.name)
      for _, f in ipairs(fs.list(folder) or {}) do
        if not f.isDir and f.name:lower() == "gamedef.json" then
          local def = json.tryDecode(fs.readFile(fs.join(folder, f.name)) or "")
          if type(def) == "table" and def.id == job.gameId then out[#out + 1] = folder end
          break
        end
      end
    end
  end
  return out
end

-- Every folder that may hold a copy, the cache folder itself first.
local function sourceFolders()
  local out, seen = {}, {}
  local function add(folder)
    local key = fs.normalize(folder):lower()
    if not seen[key] and fs.isDir(folder) then
      seen[key] = true
      out[#out + 1] = folder
    end
  end
  add(job.folder)
  for _, folder in ipairs(localGameFolders()) do add(folder) end
  for _, root in ipairs(job.serverRoots or {}) do
    for _, e in ipairs(fs.list(root) or {}) do
      if e.isDir then add(fs.join(root, e.name, "games", job.cacheGameDir)) end
    end
  end
  return out
end

-- Copies a verified local copy into place; true when it did.
local function reuseLocal(f, dest, sources)
  for _, folder in ipairs(sources) do
    local src = fs.join(folder, (f.path:gsub("/", fs.sep)))
    local size = sizeOf(src)
    if size and (size == f.size or size == 0 or not f.size) then
      local data = fs.readFile(src)
      if data and sha256(data) == f.sha256 then
        if folder ~= job.folder then
          fs.mkdirs(fs.dirname(dest))
          local wok, werr = fs.writeFile(dest, data)
          if not wok then error("could not write " .. dest .. ": " .. tostring(werr)) end
        end
        return true
      end
    end
  end
  return false
end

-- Downloads -----------------------------------------------------------------

local sock

local function send(msgType, payload)
  local s, e = sock:send(line(msgType, payload))
  if not s then error("send failed: " .. tostring(e)) end
end

-- Next non-ping message; answers pings so the server keeps us alive.
local function receive()
  while true do
    local l, e = sock:receive("*l")
    if not l then error("connection lost: " .. tostring(e)) end
    local m = json.tryDecode(l)
    if type(m) == "table" and type(m.type) == "string" then
      if m.type == "ping" then
        send("pong")
      elseif m.type ~= "pong" then
        return m.type, (type(m.payload) == "table" and m.payload or {})
      end
    end
  end
end

local function connect()
  sock = socket.tcp()
  sock:settimeout(10)
  local ok, err = sock:connect(job.host, job.port)
  if not ok then error("Could not connect for downloads: " .. tostring(err), 0) end
  pcall(sock.setoption, sock, "tcp-nodelay", true)
  sock:settimeout(30)
  send("assetHello", json.object({ "token", job.token }))
  local t, p = receive()
  if t ~= "assetReady" then error(t == "disconnect" and ("server refused downloads (" .. tostring(p.reason) .. ")") or "unexpected reply " .. t) end
end

local function download(f)
  if not sock then connect() end
  send("assetGet", json.object({ "gameId", job.gameId, "path", f.path }))
  local parts = {}
  while true do
    local mt, mp = receive()
    if mt == "assetError" then error(f.path .. ": " .. tostring(mp.error)) end
    if mt == "assetData" and mp.path == f.path then
      parts[#parts + 1] = love.data.decode("string", "base64", mp.data)
      if mp.done then break end
    end
  end
  return table.concat(parts)
end

local okAll, problem = pcall(function()
  local sources = sourceFolders()
  for _, f in ipairs(job.files) do
    local dest = fs.join(job.folder, (f.path:gsub("/", fs.sep)))
    if reuseLocal(f, dest, sources) then
      out:push({ kind = "file", path = f.path, sha256 = f.sha256, bytes = 0, reused = true })
    else
      local data = download(f)
      fs.mkdirs(fs.dirname(dest))
      local wok, werr = fs.writeFile(dest, data)
      if not wok then error("could not write " .. dest .. ": " .. tostring(werr)) end
      out:push({ kind = "file", path = f.path, sha256 = f.sha256, bytes = #data })
    end
  end
end)
if sock then pcall(sock.close, sock) end
if okAll then out:push({ kind = "done" }) else fail(tostring(problem)) end
