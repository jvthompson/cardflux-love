-- src/net/game_client.lua: the hello handshake, heartbeats, and message
-- routing/caching. Driven with a fake connector/connection (same double
-- style as server_client_test.lua and host_server_test.lua) rather than
-- real sockets, so src/net/protocol.lua's P.connect is never exercised here.
local C = require("src.net.game_client")
local P = require("src.net.protocol")

return function(t)
  local function fakeConn()
    local c = { sent = {}, inbox = {}, closed = false }
    function c:send(msgType, payload) self.sent[#self.sent + 1] = { type = msgType, payload = payload } end
    function c:poll()
      local msgs = self.inbox
      self.inbox = {}
      return msgs, #msgs > 0
    end
    function c:close() self.closed = true end
    c.startHeartbeat = P.Connection.startHeartbeat
    c.heartbeat = P.Connection.heartbeat
    return c
  end

  -- Skips the connecting phase: as if the connector already resolved.
  local function connected()
    local c = C.new()
    local conn = fakeConn()
    c.conn = conn
    conn:startHeartbeat(love.timer.getTime())
    return c, conn
  end

  t.describe("connecting", function()
    t.it("sends hello once the connector resolves, and reports failure otherwise", function()
      local c = C.new()
      local conn = fakeConn()
      c.hello = { name = "Alice", color = 7 }
      c.connector = { poll = function() return "connected", conn end }
      c:update()
      t.eq(c.conn, conn)
      t.eq(conn.sent[1].type, "hello")
      t.eq(conn.sent[1].payload.name, "Alice")
      t.eq(conn.sent[1].payload.color, 7)
      t.eq(conn.sent[1].payload.serverProtocol, P.serverProtocolVersion)

      local c2 = C.new()
      c2.hello = { name = "Bob", color = 1 }
      c2.connector = { poll = function() return "failed", "connection refused" end }
      c2:update()
      t.eq(c2.status, "failed")
      t.eq(c2.errorMessage, "connection refused")
      t.isNil(c2.conn)
    end)

    t.it("does nothing while the connector is still pending", function()
      local c = C.new()
      c.status = "connecting" -- set by :connect(), which this test bypasses
      c.hello = { name = "Alice", color = 1 }
      local polls = 0
      c.connector = { poll = function() polls = polls + 1; return "pending" end }
      c:update()
      t.eq(polls, 1)
      t.isNil(c.conn)
      t.eq(c.status, "connecting")
    end)
  end)

  t.describe("handshake replies", function()
    t.it("treats a serverInfo reply as talking to a dedicated server, not a peer host", function()
      local c, conn = connected()
      conn.inbox = { { type = "serverInfo", payload = { motd = "hi" } } }
      c:update()
      t.eq(c.status, "server")
      t.eq(c.serverInfo.motd, "hi")
    end)

    t.it("stores welcome fields and reports connected", function()
      local c, conn = connected()
      conn.inbox = { { type = "welcome",
        payload = { hostName = "Host", playerId = "p1", assignedColor = 3, reconnected = true } } }
      c:update()
      t.eq(c.status, "connected")
      t.eq(c.opponentName, "Host")
      t.eq(c.assignedPlayerId, "p1")
      t.eq(c.assignedColor, 3)
      t.ok(c.reconnected)
    end)

    t.it("records the reason on disconnect without emitting it as a message", function()
      local c, conn = connected()
      local seen = {}
      c.onMessage = function(m) seen[#seen + 1] = m.type end
      conn.inbox = { { type = "disconnect", payload = { reason = "kicked" } } }
      c:update()
      t.eq(c.disconnectReason, "kicked")
      t.eq(#seen, 0)
    end)
  end)

  t.describe("message routing", function()
    t.it("replies to ping with pong and does not forward it", function()
      local c, conn = connected()
      local seen = {}
      c.onMessage = function(m) seen[#seen + 1] = m.type end
      conn.inbox = { { type = "ping", payload = {} } }
      c:update()
      t.eq(conn.sent[#conn.sent].type, "pong")
      t.eq(#seen, 0)
    end)

    t.it("caches the latest lobbyRosterUpdate/gameData/fullState and forwards everything else", function()
      local c, conn = connected()
      local seen = {}
      c.onMessage = function(m) seen[#seen + 1] = m.type end
      conn.inbox = {
        { type = "lobbyRosterUpdate", payload = { players = {} } },
        { type = "gameData", payload = { id = "g1" } },
        { type = "fullState", payload = { revision = 5 } },
        { type = "chat", payload = { text = "hi" } },
      }
      c:update()
      t.eq(seen, { "lobbyRosterUpdate", "gameData", "fullState", "chat" })
      t.eq(c.lastLobbyRosterUpdate.payload.players, {})
      t.eq(c.lastGameData.payload.id, "g1")
      t.eq(c.lastFullState.payload.revision, 5)
    end)
  end)

  t.describe("heartbeat", function()
    t.it("sends a ping once the heartbeat interval has elapsed", function()
      local c, conn = connected()
      conn.lastPing = love.timer.getTime() - (P.heartbeatInterval + 1)
      c:update()
      t.eq(conn.sent[#conn.sent].type, "ping")
    end)

    t.it("disconnects after the heartbeat timeout with no activity", function()
      local c, conn = connected()
      local statuses = {}
      c.onStatus = function(s) statuses[#statuses + 1] = s end
      conn.lastActivity = love.timer.getTime() - (P.heartbeatTimeout + 1)
      c:update()
      t.eq(c.status, "disconnected")
      t.ok(conn.closed)
      t.eq(statuses[#statuses], "disconnected")
    end)

    t.it("disconnects immediately when the connection itself reports closed", function()
      local c, conn = connected()
      conn.closed = true
      c:update()
      t.eq(c.status, "disconnected")
    end)
  end)

  t.describe("disconnect", function()
    t.it("closes the connection, clears callbacks, and sets status directly", function()
      local c, conn = connected()
      c.onMessage, c.onStatus = function() end, function() end
      c:disconnect()
      t.ok(conn.closed)
      t.eq(c.status, "disconnected")
      t.isNil(c.onMessage)
      t.isNil(c.onStatus)
    end)

    t.it("send is a no-op once there is no connection", function()
      local c = C.new()
      c:send("ping") -- must not error
      t.ok(true)
    end)
  end)
end
