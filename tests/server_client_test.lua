-- Cardflux server client (src/net/server_client.lua): password hashing,
-- request/response matching and routing game traffic to the game channel.
local SC = require("src.net.server_client")
local P = require("src.net.protocol")

return function(t)
  -- A connection double: records sends and replays queued messages on poll.
  local function fakeConn()
    local c = { sent = {}, inbox = {}, closed = false }
    function c:send(msgType, payload) self.sent[#self.sent + 1] = { type = msgType, payload = payload } end
    function c:poll()
      local msgs = self.inbox
      self.inbox = {}
      return msgs, #msgs > 0
    end
    function c:close() self.closed = true end
    return c
  end

  local function client()
    local conn = fakeConn()
    local sc = SC.adopt(conn, "127.0.0.1", 51234, { name = "Test", mode = "free" })
    P.unregister(sc) -- driven by hand below
    return sc, conn
  end

  t.describe("password hash", function()
    t.it("matches the server's sha256(cardflux:<email>:<password>) and ignores email case/spaces", function()
      local want = "16313f81ab87dd766544fbb30db5f1427a15cfaa993cfa970e422a2235f7305c"
      t.eq(SC.passwordHash("alice@example.com", "secret1"), want)
      t.eq(SC.passwordHash("  Alice@Example.COM ", "secret1"), want)
    end)
  end)

  t.describe("requests", function()
    t.it("matches responses to requests by rid", function()
      local sc, conn = client()
      local got = {}
      sc:request("deckList", { gameId = "g" }, function(r) got.a = r end)
      sc:request("gameList", nil, function(r) got.b = r end)
      t.eq(conn.sent[1].payload.rid, 1)
      t.eq(conn.sent[2].payload.rid, 2)
      conn.inbox = { { type = "response", payload = { rid = 2, ok = true, games = {} } },
        { type = "response", payload = { rid = 1, ok = false, error = "noGame" } } }
      sc:update()
      t.eq(got.a.error, "noGame")
      t.ok(got.b.ok)
    end)

    t.it("fails pending requests when the connection drops", function()
      local sc, conn = client()
      local got
      sc:request("deckList", {}, function(r) got = r end)
      conn.closed = true
      sc:update()
      t.eq(got.error, "disconnected")
      t.eq(sc.status, "disconnected")
    end)
  end)

  t.describe("routing", function()
    t.it("keeps lobby state and sends game messages to the channel", function()
      local sc, conn = client()
      local ch = sc:gameChannel()
      local seen = {}
      ch.onMessage = function(m) seen[#seen + 1] = m.type end
      conn.inbox = {
        { type = "lobbyState", payload = { self = { id = "u1", name = "A", tokens = 3 }, users = {}, rooms = {}, games = {}, chat = {} } },
        { type = "gameData", payload = { id = "g" } },
        { type = "fullState", payload = { revision = 1 } },
        { type = "tokens", payload = { tokens = 7 } },
      }
      sc:update()
      t.eq(seen, { "gameData", "fullState" })
      t.eq(ch.lastFullState.payload.revision, 1)
      t.eq(sc.self.tokens, 7)
    end)

    t.it("clears the current room when it closes", function()
      local sc, conn = client()
      sc.roomId = "r1"
      local mine
      sc:on("roomClosed", function(_, _, m) mine = m end)
      conn.inbox = { { type = "roomClosed", payload = { roomId = "r1", reason = "idle" } } }
      sc:update()
      t.isNil(sc.roomId)
      t.ok(mine)
    end)

    t.it("records a scheduled shutdown and warns the player", function()
      local overlays = require("src.ui.kit.overlays")
      local sc, conn = client()
      local seconds
      sc:on("serverShutdown", function(s) seconds = s end)
      conn.inbox = { { type = "serverShutdown", payload = { seconds = 300, by = "Admin" } } }
      sc:update()
      t.eq(seconds, 300)
      t.near(sc.shutdownAt - love.timer.getTime(), 300, 1)
      local d = overlays.topDialog()
      t.ok(d and d.title == "Server Shutting Down")
      overlays.closeDialog(d)
    end)
  end)

  t.describe("trading", function()
    t.it("emits tradeInvite pushes", function()
      local sc, conn = client()
      local got
      sc:on("tradeInvite", function(p) got = p end)
      conn.inbox = { { type = "tradeInvite", payload = { tradeId = "t1", gameId = "g1", fromId = "u2", fromName = "Bob" } } }
      sc:update()
      t.eq(got.fromName, "Bob")
    end)

    t.it("tracks the current trade and seeds chat from the first push", function()
      local sc, conn = client()
      sc.self = { id = "u1" }
      local emitted = 0
      sc:on("trade", function() emitted = emitted + 1 end)
      conn.inbox = { { type = "trade", payload = { id = "t1", gameId = "g1",
        a = { id = "u1", name = "A" }, b = { id = "u2", name = "B" }, offers = {}, chat = { { text = "hi" } } } } }
      sc:update()
      t.eq(sc.trade.id, "t1")
      t.eq(#sc.tradeChat, 1)
      t.eq(emitted, 1)
      -- A later push for the same trade updates state without wiping chat.
      conn.inbox = { { type = "trade", payload = { id = "t1", gameId = "g1",
        a = { id = "u1", name = "A" }, b = { id = "u2", name = "B" }, offers = {}, chat = { { text = "hi" } } } } }
      sc:update()
      t.eq(#sc.tradeChat, 1)
    end)

    t.it("appends trade chat lines to tradeChat, not the lobby/room chat", function()
      local sc, conn = client()
      sc.self = { id = "u1" }
      sc.trade = { id = "t1" }
      sc.tradeChat = {}
      conn.inbox = { { type = "chat", payload = { tradeId = "t1", line = { name = "Bob", text = "hey" } } } }
      sc:update()
      t.eq(#sc.tradeChat, 1)
      t.eq(#sc.chat, 0)
    end)

    t.it("clears the current trade when it closes", function()
      local sc, conn = client()
      sc.trade = { id = "t1" }
      local reason
      sc:on("tradeClosed", function(p) reason = p.reason end)
      conn.inbox = { { type = "tradeClosed", payload = { tradeId = "t1", reason = "completed" } } }
      sc:update()
      t.isNil(sc.trade)
      t.eq(reason, "completed")
    end)
  end)
end
