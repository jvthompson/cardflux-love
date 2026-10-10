-- Port of lib/networking/host_server.dart: accepts clients, runs the
-- hello/welcome handshake, keeps the lobby roster, heartbeats, kicks.
--
-- Callbacks (set by the owner):
--   onIncoming(senderId, msg)   every non-handshake, non-ping message
--   onRoster(roster)            roster changed (join/leave)
--   reclaimableIdCheck(id)      when set (game in progress), a hello must
--                               reclaim a disconnected seat or is refused
local socket = require("socket")
local json = require("lib.json")
local P = require("src.net.protocol")
local models = require("src.core.models")
local color = require("src.core.color")
local uuid = require("src.core.uuid")
local upnp = require("src.net.upnp")

local H = {}
H.__index = H

function H.new() return setmetatable({ clients = {}, joinOrder = {}, avatars = {}, pendingConns = {} }, H) end

-- hostPlayer: PlayerInfo; returns the bound port or nil, error.
function H:start(hostPlayer, maxPlayers, hostAvatarBytes, port)
  self.hostPlayer = hostPlayer
  self.maxPlayers = maxPlayers
  self.hostAvatarBytes = hostAvatarBytes
  local server, err = socket.bind("*", port or P.defaultGamePort)
  if not server then return nil, err end
  server:settimeout(0)
  self.server = server
  local _, boundPort = server:getsockname()
  self.port = tonumber(boundPort)
  P.register(self)
  -- Best-effort UPnP forward of the bound port, settled in the background
  -- (self.upnpMapped: nil while asking, then true/false). Never blocks
  -- hosting -- LAN play works regardless.
  if not self.noUpnp then
    upnp.requestMapping(self.port, function(mapping)
      if self.stopped then
        upnp.releaseMapping(mapping)
        return
      end
      self.upnpMapping = mapping
      self.upnpMapped = mapping ~= nil
    end)
  end
  return self.port
end

function H:avatarsByPlayerId()
  local out = {}
  if self.hostAvatarBytes then out[self.hostPlayer.id] = self.hostAvatarBytes end
  for id, b in pairs(self.avatars) do out[id] = b end
  return out
end

function H:setSeatOrder(ids) self.seatOrder = ids end

function H:roster()
  local list = { self.hostPlayer }
  for _, id in ipairs(self.joinOrder) do
    local c = self.clients[id]
    if c then list[#list + 1] = models.PlayerInfo.new({ id = id, name = c.name, role = "client", color = c.color }) end
  end
  if not self.seatOrder then return list end
  local byId = {}
  for _, p in ipairs(list) do byId[p.id] = p end
  local ordered = {}
  for _, id in ipairs(self.seatOrder) do
    if byId[id] then ordered[#ordered + 1] = byId[id] end
  end
  return ordered
end

function H:clientCount()
  local n = 0
  for _ in pairs(self.clients) do n = n + 1 end
  return n
end

function H:resolveColor(requested)
  local used = { [self.hostPlayer.color] = true }
  for _, c in pairs(self.clients) do used[c.color] = true end
  if requested and not used[requested] then return requested end
  for _, c in ipairs(color.boardWidgetColorPalette) do
    if not used[c] then return c end
  end
  return requested or color.boardWidgetColorPalette[1]
end

function H:handleHello(conn, msg)
  if self:clientCount() >= self.maxPlayers - 1 then
    conn:close()
    return
  end
  local p = msg.payload
  local rejoinId = type(p.rejoinPlayerId) == "string" and p.rejoinPlayerId or nil
  local reclaimed = rejoinId ~= nil and self.reclaimableIdCheck ~= nil and self.reclaimableIdCheck(rejoinId) == true
  if self.reclaimableIdCheck and not reclaimed then
    conn:send("disconnect", json.object({ "reason", "seatUnavailable" }))
    conn:closeAfterFlush()
    return
  end
  local name = type(p.name) == "string" and p.name or "Player"
  local col = self:resolveColor(type(p.color) == "number" and p.color or nil)
  local id = reclaimed and rejoinId or uuid.v4()
  if type(p.avatar) == "string" then
    local ok, bytes = pcall(love.data.decode, "string", "base64", p.avatar)
    if ok then self.avatars[id] = bytes end
  end
  local now = love.timer.getTime()
  self.clients[id] = { conn = conn, name = name, color = col, lastActivity = now, lastPing = now }
  local found = false
  for _, x in ipairs(self.joinOrder) do if x == id then found = true end end
  if not found then self.joinOrder[#self.joinOrder + 1] = id end
  self:sendTo(id, "welcome", json.object({ "hostName", self.hostPlayer.name, "playerId", id, "assignedColor", col, "reconnected", reclaimed }))
  self:broadcastRoster()
end

function H:handleDisconnect(id)
  local c = self.clients[id]
  if not c then return end
  self.clients[id] = nil
  c.conn:close()
  local order = {}
  for _, x in ipairs(self.joinOrder) do if x ~= id then order[#order + 1] = x end end
  self.joinOrder = order
  self:broadcastRoster()
end

function H:update()
  if not self.server then return end
  -- Accept new connections (they must say hello before anything else).
  while true do
    local sock = self.server:accept()
    if not sock then break end
    if self:clientCount() >= self.maxPlayers - 1 then
      sock:close()
    else
      self.pendingConns[#self.pendingConns + 1] = { conn = P.wrap(sock), since = love.timer.getTime() }
    end
  end
  local stillPending = {}
  for _, pc in ipairs(self.pendingConns) do
    local msgs = pc.conn:poll()
    local handled = false
    for _, m in ipairs(msgs) do
      if not handled and m.type == "hello" then
        handled = true
        self:handleHello(pc.conn, m)
      end
    end
    if not handled and not pc.conn.closed and love.timer.getTime() - pc.since < P.heartbeatTimeout then
      stillPending[#stillPending + 1] = pc
    elseif not handled then
      pc.conn:close()
    end
  end
  self.pendingConns = stillPending

  local now = love.timer.getTime()
  for _, id in ipairs(self.joinOrder) do
    local c = self.clients[id]
    if c then
      local msgs, gotData = c.conn:poll()
      if gotData then c.lastActivity = now end
      for _, m in ipairs(msgs) do
        if m.type == "ping" then
          c.conn:send("pong")
        elseif self.onIncoming and self.clients[id] then
          self.onIncoming(id, m)
        end
      end
      if c.conn.closed then
        self:handleDisconnect(id)
      elseif now - c.lastActivity > P.heartbeatTimeout then
        self:handleDisconnect(id)
      elseif now - c.lastPing >= P.heartbeatInterval then
        c.lastPing = now
        c.conn:send("ping")
      end
    end
  end
end

function H:kick(id)
  local c = self.clients[id]
  if not c then return end
  c.conn:send("disconnect", json.object({ "reason", "kicked" }))
  c.conn:closeAfterFlush()
  self:handleDisconnect(id)
end

function H:broadcastRoster()
  local r = self:roster()
  if self.onRoster then self.onRoster(r) end
  local avatars = json.object()
  local keys = {}
  for id in pairs(self:avatarsByPlayerId()) do keys[#keys + 1] = id end
  table.sort(keys)
  local all = self:avatarsByPlayerId()
  for _, id in ipairs(keys) do avatars[id] = love.data.encode("string", "base64", all[id]) end
  local players = json.array({})
  for i, p in ipairs(r) do players[i] = models.PlayerInfo.toJson(p) end
  self:broadcast("lobbyRosterUpdate", json.object({ "maxPlayers", self.maxPlayers, "players", players, "avatars", avatars }))
end

function H:sendTo(id, msgType, payload)
  local c = self.clients[id]
  if c then c.conn:send(msgType, payload) end
end

-- Encodes once and sends to every client (optionally skipping one).
function H:broadcast(msgType, payload, exceptId)
  local line = P.encodeLine(msgType, payload)
  for id, c in pairs(self.clients) do
    if id ~= exceptId then c.conn:sendRaw(line) end
  end
end

-- reason: optional disconnect reason sent to everyone first ("hostLeft").
function H:stop(reason)
  if reason then self:broadcast("disconnect", json.object({ "reason", reason })) end
  for _, c in pairs(self.clients) do c.conn:closeAfterFlush() end
  for _, pc in ipairs(self.pendingConns) do pc.conn:close() end
  self.clients, self.joinOrder, self.pendingConns = {}, {}, {}
  if self.server then pcall(self.server.close, self.server) end
  self.server = nil
  P.unregister(self)
  -- Not awaited; a still-in-flight request releases itself on settling.
  self.stopped = true
  upnp.releaseMapping(self.upnpMapping)
  self.upnpMapping = nil
  if self.onStopped then self.onStopped() end
end

return H
