-- src/net/host_server.lua: hello/welcome handshake, roster, heartbeats, kicks.
-- Drives it with fake connections (same double as server_client_test.lua)
-- rather than real sockets, so self.server/accept() is never exercised here
-- -- only the business logic above the socket layer.
local H = require("src.net.host_server")
local P = require("src.net.protocol")
local color = require("src.core.color")

return function(t)
  local palette = color.boardWidgetColorPalette

  local function fakeConn()
    local c = { sent = {}, inbox = {}, closed = false }
    function c:send(msgType, payload) self.sent[#self.sent + 1] = { type = msgType, payload = payload } end
    function c:sendRaw(line) self.sent[#self.sent + 1] = { raw = line } end
    function c:poll()
      local msgs = self.inbox
      self.inbox = {}
      return msgs, #msgs > 0
    end
    function c:close() self.closed = true end
    function c:closeAfterFlush() self.closed = true end
    return c
  end

  local function host(maxPlayers)
    local h = H.new()
    h.hostPlayer = { id = "host", name = "Host", color = palette[1] }
    h.maxPlayers = maxPlayers or 4
    h.server = { accept = function() return nil end } -- no real socket.bind; satisfies H:update's guard
    return h
  end

  t.describe("handleHello", function()
    t.it("assigns a free color, sends welcome, and joins the roster", function()
      local h = host()
      local conn = fakeConn()
      h:handleHello(conn, { payload = { name = "Alice" } })
      local id = h.joinOrder[1]
      t.ok(id)
      t.eq(h.clients[id].name, "Alice")
      t.eq(h.clients[id].color, palette[2]) -- palette[1] already used by the host
      t.eq(#conn.sent, 2) -- a direct welcome, plus the roster broadcast (sent to everyone, including the joiner)
      t.eq(conn.sent[1].type, "welcome")
      t.eq(conn.sent[1].payload.playerId, id)
      t.eq(conn.sent[1].payload.hostName, "Host")
      t.notOk(conn.sent[1].payload.reconnected)
    end)

    t.it("refuses a new client once at capacity", function()
      local h = host(1) -- host already fills the only seat
      local conn = fakeConn()
      h:handleHello(conn, { payload = { name = "Bob" } })
      t.ok(conn.closed)
      t.eq(#conn.sent, 0)
      t.eq(h:clientCount(), 0)
    end)

    t.it("reclaims a disconnected seat only when reclaimableIdCheck allows it", function()
      local h = host()
      h.reclaimableIdCheck = function(id) return id == "existing" end

      local ok = fakeConn()
      h:handleHello(ok, { payload = { name = "Carol", rejoinPlayerId = "existing" } })
      t.eq(h.joinOrder[1], "existing")
      t.eq(ok.sent[1].payload.playerId, "existing")
      t.ok(ok.sent[1].payload.reconnected)

      local refused = fakeConn()
      h:handleHello(refused, { payload = { name = "Dave", rejoinPlayerId = "someone-else" } })
      t.eq(refused.sent[1].type, "disconnect")
      t.eq(refused.sent[1].payload.reason, "seatUnavailable")
      t.ok(refused.closed)
      t.eq(h:clientCount(), 1) -- Dave never joined
    end)
  end)

  t.describe("resolveColor", function()
    t.it("keeps a free requested color but reassigns a taken one", function()
      local h = host()
      t.eq(h:resolveColor(palette[3]), palette[3]) -- free, honored
      h:handleHello(fakeConn(), { payload = { name = "Alice", color = palette[2] } })
      -- Alice now holds palette[2]; requesting it again falls through to the next free color
      t.eq(h:resolveColor(palette[2]), palette[3])
      local conn2 = fakeConn()
      h:handleHello(conn2, { payload = { name = "Bob", color = palette[2] } })
      local bobId = h.joinOrder[2]
      t.eq(h.clients[bobId].color, palette[3])
    end)
  end)

  t.describe("roster", function()
    t.it("lists the host first, then join order, unless a seat order is set", function()
      local h = host()
      h:handleHello(fakeConn(), { payload = { name = "Alice" } })
      h:handleHello(fakeConn(), { payload = { name = "Bob" } })
      local aliceId, bobId = h.joinOrder[1], h.joinOrder[2]
      t.eq(t.ids(h:roster(), "id"), { "host", aliceId, bobId })
      h:setSeatOrder({ bobId, "host", aliceId })
      t.eq(t.ids(h:roster(), "id"), { bobId, "host", aliceId })
    end)
  end)

  t.describe("update: pending connections", function()
    t.it("promotes a pending connection to a client once it says hello", function()
      local h = host()
      local conn = fakeConn()
      conn.inbox = { { type = "hello", payload = { name = "Eve" } } }
      h.pendingConns = { { conn = conn, since = love.timer.getTime() } }
      h:update()
      t.eq(#h.pendingConns, 0)
      t.eq(h:clientCount(), 1)
    end)

    t.it("drops a pending connection that never says hello before the heartbeat timeout", function()
      local h = host()
      local conn = fakeConn()
      h.pendingConns = { { conn = conn, since = love.timer.getTime() - (P.heartbeatTimeout + 1) } }
      h:update()
      t.eq(#h.pendingConns, 0)
      t.ok(conn.closed)
      t.eq(h:clientCount(), 0)
    end)

    t.it("keeps waiting on a pending connection within the timeout", function()
      local h = host()
      local conn = fakeConn()
      h.pendingConns = { { conn = conn, since = love.timer.getTime() } }
      h:update()
      t.eq(#h.pendingConns, 1)
      t.notOk(conn.closed)
    end)
  end)

  t.describe("update: connected clients", function()
    t.it("answers ping with pong directly, without routing it to onIncoming", function()
      local h = host()
      h:handleHello(fakeConn(), { payload = { name = "Alice" } })
      local id = h.joinOrder[1]
      local routed = {}
      h.onIncoming = function(pid, m) routed[#routed + 1] = m.type end
      h.clients[id].conn.inbox = { { type = "ping", payload = {} } }
      h:update()
      t.eq(h.clients[id].conn.sent[#h.clients[id].conn.sent].type, "pong")
      t.eq(#routed, 0)
    end)

    t.it("routes other messages to onIncoming and refreshes activity", function()
      local h = host()
      h:handleHello(fakeConn(), { payload = { name = "Alice" } })
      local id = h.joinOrder[1]
      h.clients[id].lastActivity = love.timer.getTime() - 100
      local seen
      h.onIncoming = function(pid, m) seen = { pid = pid, type = m.type } end
      h.clients[id].conn.inbox = { { type = "cardMove", payload = { x = 1 } } }
      h:update()
      t.eq(seen.pid, id)
      t.eq(seen.type, "cardMove")
      t.near(h.clients[id].lastActivity, love.timer.getTime(), 1)
    end)

    t.it("disconnects a client whose connection closed", function()
      local h = host()
      local rosterUpdates = 0
      h.onRoster = function() rosterUpdates = rosterUpdates + 1 end
      h:handleHello(fakeConn(), { payload = { name = "Alice" } })
      local id = h.joinOrder[1]
      h.clients[id].conn.closed = true
      h:update()
      t.isNil(h.clients[id])
      t.eq(h:clientCount(), 0)
      t.eq(rosterUpdates, 2) -- join + leave
    end)

    t.it("disconnects a client after the heartbeat timeout with no activity", function()
      local h = host()
      h:handleHello(fakeConn(), { payload = { name = "Alice" } })
      local id = h.joinOrder[1]
      h.clients[id].lastActivity = love.timer.getTime() - (P.heartbeatTimeout + 1)
      h:update()
      t.isNil(h.clients[id])
    end)

    t.it("sends a ping once the heartbeat interval has elapsed", function()
      local h = host()
      h:handleHello(fakeConn(), { payload = { name = "Alice" } })
      local id = h.joinOrder[1]
      local conn = h.clients[id].conn
      conn.sent = {}
      h.clients[id].lastPing = love.timer.getTime() - (P.heartbeatInterval + 1)
      h:update()
      t.eq(conn.sent[#conn.sent].type, "ping")
    end)
  end)

  t.describe("kick", function()
    t.it("tells the client why, flush-closes, and removes it from the roster", function()
      local h = host()
      h:handleHello(fakeConn(), { payload = { name = "Alice" } })
      local id = h.joinOrder[1]
      local conn = h.clients[id].conn
      h:kick(id)
      t.eq(conn.sent[#conn.sent].type, "disconnect")
      t.eq(conn.sent[#conn.sent].payload.reason, "kicked")
      t.ok(conn.closed)
      t.isNil(h.clients[id])
    end)
  end)

  t.describe("broadcast", function()
    t.it("sends the raw line to every client except the excluded one", function()
      local h = host()
      h:handleHello(fakeConn(), { payload = { name = "Alice" } })
      h:handleHello(fakeConn(), { payload = { name = "Bob" } })
      local aliceId, bobId = h.joinOrder[1], h.joinOrder[2]
      h.clients[aliceId].conn.sent, h.clients[bobId].conn.sent = {}, {}
      h:broadcast("ping", nil, aliceId)
      t.eq(#h.clients[aliceId].conn.sent, 0)
      t.eq(#h.clients[bobId].conn.sent, 1)
    end)
  end)

  t.describe("stop", function()
    t.it("broadcasts a reason, flush-closes everyone, and clears state", function()
      local h = host()
      h:handleHello(fakeConn(), { payload = { name = "Alice" } })
      local id = h.joinOrder[1]
      local conn = h.clients[id].conn
      local stopped = false
      h.onStopped = function() stopped = true end
      h:stop("hostLeft")
      -- stop() broadcasts raw (sendRaw), unlike kick()'s direct send
      local last = P.decodeLine((conn.sent[#conn.sent].raw or ""):gsub("\n$", ""))
      t.eq(last.type, "disconnect")
      t.eq(last.payload.reason, "hostLeft")
      t.ok(conn.closed)
      t.eq(h:clientCount(), 0)
      t.ok(stopped)
    end)
  end)
end
