-- Server Deck Editor entry: pick one of the server's games, then edit decks
-- stored on the server (optionally also saved locally). In collection mode
-- the pool is limited to the cards the player owns.
local ui = require("src.ui.kit.ui")
local theme = require("src.ui.kit.theme")
local overlays = require("src.ui.kit.overlays")
local json = require("lib.json")
local deckStore = require("src.data.deck_store")
local common = require("src.ui.screens.server.common")

local D = {}
D.__index = D

local function app() return require("src.app") end

-- A list of the server's games; onPick(gameInfo).
function D.drawGameList(sc, id, x, y, w, h, subtitle, onPick)
  local c = theme.c
  local colW = math.min(640, w - 48)
  local cx = math.floor(x + (w - colW) / 2)
  local off = ui.beginScroll(id, x, y, w, h)
  local yy = y + 24 - off
  ui.text("Choose a game", cx, yy, { size = 22 })
  yy = yy + 32
  ui.text(subtitle, cx, yy, { w = colW, color = c.onSurfaceVariant })
  yy = yy + ui.textHeight(subtitle, colW) + 20
  if #sc.games == 0 then
    ui.text("This server doesn't have any games yet.", cx, yy, { w = colW, color = c.onSurfaceVariant })
  end
  for _, g in ipairs(sc.games) do
    local r = ui.region(id .. ":" .. g.id, cx, yy, colW, 64, { cursor = "hand" })
    ui.rect("fill", cx, yy, colW, 64, 12, r.hovered and c.surfaceContainerHigh or c.surfaceContainer)
    ui.text(g.name, cx + 20, yy + 12, { weight = "bold", w = colW - 60, ellipsis = true })
    local sets = #(g.sets or {})
    ui.text(g.cardCount .. " cards" .. (sets > 0 and ("  ·  " .. sets .. (sets == 1 and " set" or " sets")) or ""), cx + 20, yy + 34,
      { size = 12, color = c.onSurfaceVariant })
    ui.icon("chevron_right", cx + colW - 36, yy + 20, 24, c.onSurfaceVariant)
    if r.clicked then onPick(g) end
    yy = yy + 64 + 10
  end
  ui.endScroll(id, yy + off - y + 24)
end

function D.new(sc)
  return setmetatable({ title = "Deck Editor", sc = sc }, D)
end

function D:open(info)
  local sc = self.sc
  common.withGame(sc, info.id, function(game)
    local store = deckStore.serverStore(sc)
    local Editor = require("src.ui.screens.deck_editor").Editor
    if not sc:isCollectionMode() then
      app().push(Editor.new(game, { store = store }))
      return
    end
    sc:request("collectionGet", json.object({ "gameId", game.id }), function(r)
      if not r.ok then
        overlays.alert("Couldn't Load Collection", r.message or "Something went wrong.")
        return
      end
      app().push(Editor.new(game, { store = store, ownedQty = r.cards or {} }))
    end)
  end)
end

function D:draw(x, y, w, h)
  local sub = self.sc:isCollectionMode()
    and "Decks are saved on the server. In collection mode you can only use cards you own."
    or "Decks are saved on the server, so they're available wherever you sign in."
  D.drawGameList(self.sc, "sd:games", x, y, w, h, sub, function(g) self:open(g) end)
end

return D
