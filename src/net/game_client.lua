-- Port of lib/networking/game_client.dart.
--   status: "connecting" | "connected" | "failed" | "disconnected" | "server"
-- "server" means the address is a CardTable server rather than a peer host:
-- it answered hello with serverInfo, and the connection (self.conn) is
-- handed to src/net/server_client.lua.
-- Callbacks: onMessage(msg) for everything except ping/welcome/disconnect,
--            onStatus(status).
-- The last lobbyRosterUpdate / gameData / fullState are cached so a screen
-- that subscribes later can replay them.
local json = require("lib.json")
local P = require("src.net.protocol")

local C = {}
C.__index = C

function C.new() return setmetatable({ status = "idle" }, C) end

function C:setStatus(s)
  self.status = s
  if self.onStatus then self.onStatus(s) end
end

function C:connect(host, port, name, color, avatarBytes, rejoinPlayerId)
  self.status = "connecting"
  self.hello = { name = name, color = color, avatarBytes = avatarBytes, rejoinPlayerId = rejoinPlayerId }
  self.connector = P.connect(host, port, 5)
  P.register(self)
end

function C:update()
  if self.connector then
    local result, a = self.connector.poll()
    if result == "pending" then return end
    self.connector = nil
    if result == "failed" then
      self.errorMessage = tostring(a)
      P.unregister(self)
      self:setStatus("failed")
      return
    end
    self.conn = a
    self.conn:startHeartbeat(love.timer.getTime())
    local h = self.hello
    local payload = json.object({ "name", h.name, "color", h.color })
    if h.avatarBytes then payload.avatar = love.data.encode("string", "base64", h.avatarBytes) end
    if h.rejoinPlayerId then payload.rejoinPlayerId = h.rejoinPlayerId end
    payload.serverProtocol = P.serverProtocolVersion
    self.conn:send("hello", payload)
  end
  if not self.conn then return end
  local now = love.timer.getTime()
  local msgs, gotData = self.conn:poll()
  for _, m in ipairs(msgs) do
    if m.type == "ping" then
      self:send("pong")
    elseif m.type == "serverInfo" then
      self.serverInfo = m.payload
      P.unregister(self)
      self:setStatus("server")
      return
    elseif m.type == "welcome" then
      local p = m.payload
      self.opponentName = p.hostName
      self.assignedPlayerId = p.playerId
      self.assignedColor = p.assignedColor
      self.reconnected = p.reconnected == true
      self:setStatus("connected")
    elseif m.type == "disconnect" then
      self.disconnectReason = m.payload.reason
    else
      if m.type == "lobbyRosterUpdate" then self.lastLobbyRosterUpdate = m
      elseif m.type == "gameData" then self.lastGameData = m
      elseif m.type == "fullState" then self.lastFullState = m end
      if self.onMessage then self.onMessage(m) end
    end
  end
  local hb = self.conn:heartbeat(now, gotData)
  if hb == "timeout" then
    self:handleDisconnect()
  elseif hb == "ping" then
    self:send("ping")
  end
end

function C:handleDisconnect()
  if self.status == "disconnected" then return end
  if self.conn then self.conn:close() end
  P.unregister(self)
  self:setStatus("disconnected")
end

function C:send(msgType, payload)
  if self.conn then self.conn:send(msgType, payload) end
end

function C:disconnect()
  self.onMessage, self.onStatus = nil, nil
  if self.conn then self.conn:close() end
  self.connector = nil
  P.unregister(self)
  self.status = "disconnected"
end

C.stop = C.disconnect

return C
