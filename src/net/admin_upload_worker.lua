-- Worker thread for src/net/admin_file_manager.lua: uploads one local file
-- into a game's folder on the server, over the asset channel (admins only).
--
-- job: { host, port, token, gameId, path (destination, slash-separated), localPath }
-- out: channel receiving { kind = "progress", bytes } repeatedly,
--      then { kind = "done" } or { kind = "error", message }
local job, out = ...

require("love.filesystem")
require("love.data")
require("love.timer")
local socket = require("socket")
local json = require("lib.json")
local fs = require("src.data.fs")

local CHUNK = 192 * 1024 -- matches the server's assetChunk

local function line(msgType, payload)
  return json.encode(json.object({ "type", msgType, "payload", payload or json.object() })) .. "\n"
end

local function fail(message)
  out:push({ kind = "error", message = message })
end

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
  if not ok then error("Could not connect to upload: " .. tostring(err), 0) end
  pcall(sock.setoption, sock, "tcp-nodelay", true)
  sock:settimeout(30)
  send("assetHello", json.object({ "token", job.token }))
  local t, p = receive()
  if t ~= "assetReady" then error(t == "disconnect" and ("server refused the connection (" .. tostring(p.reason) .. ")") or "unexpected reply " .. t) end
end

local okAll, problem = pcall(function()
  local data = fs.readFile(job.localPath)
  if not data then error("Could not read " .. job.localPath) end
  connect()
  local total, offset = #data, 0
  repeat
    local n = math.min(CHUNK, total - offset)
    local chunk = data:sub(offset + 1, offset + n)
    local done = offset + n >= total
    send("assetPut", json.object({ "gameId", job.gameId, "path", job.path, "offset", offset,
      "size", total, "data", love.data.encode("string", "base64", chunk), "done", done }))
    local t, p = receive()
    if t == "assetPutError" then error(tostring(p.error)) end
    if t ~= "assetPutAck" then error("unexpected reply " .. t) end
    offset = offset + n
    out:push({ kind = "progress", bytes = offset })
  until offset >= total
end)
if sock then pcall(sock.close, sock) end
if okAll then out:push({ kind = "done" }) else fail(tostring(problem)) end
