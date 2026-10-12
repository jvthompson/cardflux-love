-- Connection to a Cardflux server (the Go app in server/). Uses the same
-- line protocol as peer hosting; requests carry payload.rid and are answered
-- with {type="response", payload={rid, ok, error?, message?, ...}}.
--
-- The lobby screens read this object's fields every frame (immediate-mode
-- UI): info, self, users, rooms, games, chat, room, roomChat. Game traffic
-- for the room the player is in goes to the channel from :gameChannel(),
-- which looks like src/net/game_client.lua to ClientGame.
local json = require("lib.json")
local P = require("src.net.protocol")
local settings = require("src.data.settings")
local imageCache = require("src.data.image_cache")

local S = {}
S.__index = S

-- Messages that belong to the game screen rather than the lobby.
local GAME_TYPES = {
  gameData = true, fullState = true, cardDragPreview = true, cardDragPreviewEnd = true,
  arrowDragPreview = true, arrowDragPreviewEnd = true,
}

S.DISCONNECT_MESSAGES = {
  kicked = "An admin disconnected you from the server.",
  accountDisabled = "Your account has been disabled.",
  accountDeleted = "Your account has been deleted.",
  loggedInElsewhere = "Your account signed in from another connection.",
  serverShutdown = "The server shut down.",
  serverShuttingDown = "The server is shutting down and isn't accepting connections.",
  versionMismatch = "This server needs a different version of Cardflux.",
}

-- The client hashes the password before sending it (no TLS on the wire);
-- the server bcrypts the hash.
function S.passwordHash(email, password)
  local raw = "cardflux:" .. email:lower():gsub("^%s+", ""):gsub("%s+$", "") .. ":" .. password
  return love.data.encode("string", "hex", love.data.hash("sha256", raw))
end

---------------------------------------------------------------------------
-- Saved sign-ins, per server ("host:port" -> { token, email }). Only kept
-- when the player ticks "Remember me"; otherwise every sign-in asks for
-- the email and password again.
---------------------------------------------------------------------------

local SESSIONS_KEY = "server_sessions"

function S.savedSession(key)
  local all = settings.get(SESSIONS_KEY)
  return type(all) == "table" and all[key] or nil
end

function S.saveSession(key, token, email)
  local all = settings.get(SESSIONS_KEY)
  if type(all) ~= "table" then all = json.object() end
  all[key] = json.object({ "token", token, "email", email, "remember", true })
  settings.set(SESSIONS_KEY, all)
end

function S.forgetSession(key)
  local all = settings.get(SESSIONS_KEY)
  if type(all) ~= "table" or not all[key] then return end
  local email = all[key].email
  -- Keep the email (and the Remember me choice) so the sign-in form can
  -- prefill them.
  all[key] = json.object({ "email", email, "remember", true })
  settings.set(SESSIONS_KEY, all)
end

-- Drops everything saved for the server, email included.
function S.clearSession(key)
  local all = settings.get(SESSIONS_KEY)
  if type(all) ~= "table" or not all[key] then return end
  all[key] = nil
  settings.set(SESSIONS_KEY, all)
end

---------------------------------------------------------------------------
-- Construction
---------------------------------------------------------------------------

-- Takes over a connection whose hello was answered with serverInfo
-- (see game_client.lua).
function S.adopt(conn, host, port, info)
  local self = setmetatable({
    conn = conn, host = host, port = port, key = host .. ":" .. port, info = info or {},
    status = "connected", -- "connected" | "disconnected"
    nextRid = 0, pending = {},
    users = {}, rooms = {}, games = {}, chat = {}, roomChat = {}, tradeChat = {},
    avatarRequested = {}, avatarKeys = {},
    listeners = {},
  }, S)
  local now = love.timer.getTime()
  self.lastActivity, self.lastPing = now, now
  P.register(self)
  return self
end

function S:on(event, fn) self.listeners[event] = fn end

function S:emit(event, ...)
  local fn = self.listeners[event]
  if fn then fn(...) end
end

---------------------------------------------------------------------------
-- Requests
---------------------------------------------------------------------------

-- Sends a request; onResponse(resp) gets the response table (resp.ok,
-- resp.error, resp.message, ...). A dropped connection answers every
-- pending request with error "disconnected".
function S:request(msgType, payload, onResponse)
  self.nextRid = self.nextRid + 1
  local rid = self.nextRid
  payload = payload or json.object()
  payload.rid = rid
  self.pending[rid] = onResponse or false
  self:send(msgType, payload)
  return rid
end

function S:send(msgType, payload)
  if self.conn and not self.conn.closed then self.conn:send(msgType, payload) end
end

function S:isAdmin() return self.self ~= nil and self.self.isAdmin == true end
function S:isCollectionMode() return self.info.mode == "collection" end

function S:gameById(id)
  for _, g in ipairs(self.games) do
    if g.id == id then return g end
  end
end

function S:roomById(id)
  for _, r in ipairs(self.rooms) do
    if r.id == id then return r end
  end
end

-- The room this client is in (kept fresh from "rooms" broadcasts).
function S:currentRoom()
  return self.roomId and self:roomById(self.roomId) or nil
end

-- The trade this client is in, if any (kept fresh from "trade" pushes).
-- myOffer/theirOffer are read from the trade's offers map, which is keyed
-- by user id.
function S:currentTrade()
  local t = self.trade
  if not t then return nil end
  local otherId = t.a.id == self.self.id and t.b.id or t.a.id
  return t, t.offers[self.self.id], t.offers[otherId], otherId
end

-- Image-cache key for a user's avatar, fetching it on first use; nil
-- while loading or when the user has none.
function S:avatarKey(hash)
  if not hash or hash == "" then return nil end
  if self.avatarKeys[hash] then return self.avatarKeys[hash] end
  if not self.avatarRequested[hash] then
    self.avatarRequested[hash] = true
    self:request("avatarGet", json.object({ "hash", hash }), function(r)
      if not r.ok then return end
      local ok, bytes = pcall(love.data.decode, "string", "base64", r.data)
      if not ok then return end
      local key = "srvavatar:" .. hash
      imageCache.putBytes(key, bytes)
      self.avatarKeys[hash] = key
    end)
  end
  return nil
end

-- userId -> avatar cache key for every online user (for TableScreen).
function S:avatarKeysByUserId()
  local out = {}
  for _, u in ipairs(self.users) do
    out[u.id] = self:avatarKey(u.avatarHash)
  end
  return out
end

---------------------------------------------------------------------------
-- Game channel: what ClientGame talks to
---------------------------------------------------------------------------

function S:gameChannel()
  local server = self
  local ch = self.channel
  if ch then return ch end
  ch = { status = "connected" }
  function ch:send(t, p) server:send(t, p) end
  -- ClientGame calls disconnect when it is done; the server connection
  -- itself stays up for the lobby.
  function ch:disconnect()
    self.onMessage, self.onStatus = nil, nil
    if server.channel == self then server.channel = nil end
  end
  self.channel = ch
  return ch
end

function S:closeChannel()
  local ch = self.channel
  self.channel = nil
  if ch then ch.onMessage, ch.onStatus = nil, nil end
end

---------------------------------------------------------------------------
-- Pump
---------------------------------------------------------------------------

local function sortRooms(rooms)
  table.sort(rooms, function(a, b) return (a.createdAt or 0) < (b.createdAt or 0) end)
  return rooms
end

function S:handle(m)
  local p = m.payload
  local t = m.type
  if t == "response" then
    local rid = tonumber(p.rid)
    local cb = rid and self.pending[rid]
    if rid then self.pending[rid] = nil end
    if cb then cb(p) end
  elseif t == "lobbyState" then
    self.info = p.server or self.info
    self.self = p.self
    self.users = p.users or {}
    self.rooms = sortRooms(p.rooms or {})
    self.games = p.games or {}
    self.chat = p.chat or {}
    self:emit("lobbyState")
  elseif t == "users" then
    self.users = p.users or {}
  elseif t == "rooms" then
    self.rooms = sortRooms(p.rooms or {})
    self:emit("rooms")
  elseif t == "games" then
    self.games = p.games or {}
  elseif t == "serverInfo" then
    self.info = p
  elseif t == "self" then
    self.self = p
  elseif t == "tokens" then
    if self.self then self.self.tokens = p.tokens end
  elseif t == "newToken" then
    self.token = p.token
    -- Replace the remembered token, but don't start remembering one.
    local saved = S.savedSession(self.key)
    if saved and saved.remember and saved.token then
      S.saveSession(self.key, p.token, saved.email or (self.self and self.self.email))
    end
  elseif t == "chat" then
    local list = p.roomId and self.roomChat or (p.tradeId and self.tradeChat) or self.chat
    list[#list + 1] = p.line
    if #list > 200 then table.remove(list, 1) end
    self:emit("chat", p.line, p.roomId)
  elseif t == "toast" then
    require("src.ui.kit.overlays").toast(p.message)
  elseif t == "tradeInvite" then
    self:emit("tradeInvite", p)
  elseif t == "trade" then
    if not (self.trade and self.trade.id == p.id) then self.tradeChat = p.chat or {} end
    self.trade = p
    self:emit("trade")
  elseif t == "tradeClosed" then
    if self.trade and self.trade.id == p.tradeId then self.trade = nil end
    self:emit("tradeClosed", p)
  elseif t == "serverShutdown" then
    -- An admin scheduled a shutdown: warn on whatever screen is showing.
    local seconds = tonumber(p.seconds) or 0
    self.shutdownAt = love.timer.getTime() + seconds
    local minutes = math.max(1, math.floor(seconds / 60 + 0.5))
    require("src.ui.kit.overlays").alert("Server Shutting Down",
      "The server will shut down in " .. minutes .. (minutes == 1 and " minute" or " minutes")
      .. ". Finish up and save anything you want to keep.")
    self:emit("serverShutdown", seconds)
  elseif t == "roomClosed" then
    local mine = self.roomId == p.roomId
    if mine then
      self.roomId, self.spectating = nil, false
      self.roomChat = {}
    end
    self:emit("roomClosed", p.roomId, p.reason, mine)
  elseif t == "disconnect" then
    self.disconnectReason = p.reason
  elseif GAME_TYPES[t] then
    local ch = self.channel
    if ch then
      if t == "gameData" then ch.lastGameData = m
      elseif t == "fullState" then ch.lastFullState = m end
      if ch.onMessage then ch.onMessage(m) end
    end
    self:emit("game", m)
  end
end

function S:update()
  if self.status ~= "connected" then return end
  local now = love.timer.getTime()
  local msgs, gotData = self.conn:poll()
  if gotData then self.lastActivity = now end
  for _, m in ipairs(msgs) do
    if m.type == "ping" then
      self:send("pong")
    else
      self:handle(m)
    end
  end
  if self.conn.closed or now - self.lastActivity > P.heartbeatTimeout then
    self:handleDisconnect()
  elseif now - self.lastPing >= P.heartbeatInterval then
    self.lastPing = now
    self:send("ping")
  end
end

function S:handleDisconnect()
  if self.status == "disconnected" then return end
  self.status = "disconnected"
  if self.conn then self.conn:close() end
  P.unregister(self)
  local pending = self.pending
  self.pending = {}
  for _, cb in pairs(pending) do
    if cb then cb({ ok = false, error = "disconnected", message = "Lost connection to the server." }) end
  end
  local ch = self.channel
  if ch then
    ch.status = "disconnected"
    ch.disconnectReason = self.disconnectReason
    if ch.onStatus then ch.onStatus("disconnected") end
  end
  self:emit("disconnected", self.disconnectReason)
end

-- Leaves the server on purpose.
function S:disconnect()
  self.listeners = {}
  self:closeChannel()
  if self.conn then self.conn:close() end
  self.status = "disconnected"
  P.unregister(self)
end

S.stop = S.disconnect

function S:disconnectMessage()
  return S.DISCONNECT_MESSAGES[self.disconnectReason or ""] or "Lost connection to the server."
end

return S
