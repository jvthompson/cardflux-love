-- Player-to-player trading: drag cards from the other player's collection
-- into your "Wants" box, confirm when you're happy with it, and the server
-- swaps the cards once both sides have confirmed.
local ui = require("src.ui.kit.ui")
local theme = require("src.ui.kit.theme")
local overlays = require("src.ui.kit.overlays")
local widgets = require("src.ui.kit.widgets")
local filterBar = require("src.ui.kit.card_filter_bar")
local json = require("lib.json")
local models = require("src.core.models")
local util = require("src.core.util")
local CR = require("src.ui.table.card_render")
local poolGrid = require("src.ui.table.card_pool_grid")
local common = require("src.ui.screens.server.common")

local PW, PH, POOL_SCALE, NAME_LINES = poolGrid.PW, poolGrid.PH, poolGrid.SCALE, poolGrid.NAME_LINES
-- Smaller thumbnails inside the want-boxes.
local WANT_SCALE = 0.6
local DRAG_THRESHOLD = 4

local T = {}
T.__index = T

local function app() return require("src.app") end

function T.new(sc, game)
  local self = setmetatable({ title = "Trade", sc = sc, game = game, isTradeScreen = true,
    tab = 1, chatText = "", seenChat = 0 }, T)
  self.myFilters = filterBar.newState(game)
  self.theirFilters = filterBar.newState(game)
  self:refreshMine()
  self:refreshTheirs()
  return self
end

function T:onBack()
  local sc = self.sc
  overlays.confirm("Leave Trade", "Cancel this trade?", "Leave", function()
    if sc.trade then sc:request("tradeLeave", json.object({ "tradeId", sc.trade.id })) end
    app().pop()
  end)
end

function T:refreshMine()
  local sc = self.sc
  sc:request("collectionGet", json.object({ "gameId", self.game.id }), function(r)
    if r.ok then self.myOwned = r.cards or {} end
  end)
end

function T:refreshTheirs()
  local sc = self.sc
  if not sc.trade then return end
  sc:request("tradeCollectionGet", json.object({ "tradeId", sc.trade.id }), function(r)
    if r.ok then self.theirOwned = r.cards or {} end
  end)
end

-- (me, them) as user summaries from the trade state ({id, name, color, avatarHash}).
function T:parties()
  local trade = self.sc.trade
  local sc = self.sc
  if trade.a.id == sc.self.id then return trade.a, trade.b end
  return trade.b, trade.a
end

---------------------------------------------------------------------------
-- Drag to offer: press a card in the partner's collection, drag it onto
-- your own want-box, release to add it (W.reorder's press/threshold/
-- continuous-hit-test scheme, trimmed for a single drop target).
---------------------------------------------------------------------------

function T:updateDrag()
  if self.dragging then
    if ui.mouseReleased(1) then
      local mx, my = ui.mouse()
      local box = self.myWantBoxRect
      if box and mx >= box.x and mx < box.x + box.w and my >= box.y and my < box.y + box.h then
        self.sc:request("tradeOffer", json.object({ "tradeId", self.sc.trade.id, "cardId", self.dragging.cardId, "delta", 1 }))
      end
      self.dragging = nil
    end
    return
  end
  if self.pressing then
    if not ui.mouseDown(1) then
      self.pressing = nil
      return
    end
    local mx, my = ui.mouse()
    local p = self.pressing
    if math.abs(mx - p.pressX) > DRAG_THRESHOLD or math.abs(my - p.pressY) > DRAG_THRESHOLD then
      self.dragging = { cardId = p.cardId, grabX = p.cx - p.pressX, grabY = p.cy - p.pressY }
      self.pressing = nil
    end
  end
end

function T:drawDragFeedback()
  if not self.dragging then return end
  local def = models.GameDefinition.cardById(self.game, self.dragging.cardId)
  if not def then return end
  ui.setCursor("hand")
  local box = self.myWantBoxRect
  if box then
    local mx, my = ui.mouse()
    local over = mx >= box.x and mx < box.x + box.w and my >= box.y and my < box.y + box.h
    if over then ui.rect("fill", box.x, box.y, box.w, box.h, 12, theme.alpha(theme.c.primary, 0.12)) end
  end
  local mx, my = ui.mouse()
  CR.draw({ def = def, faceUp = true, cx = mx + self.dragging.grabX, cy = my + self.dragging.grabY, scale = POOL_SCALE,
    angle = CR.orientationTurns(def.orientation) * 2 * math.pi, cardBacks = self.game.cardBacks })
end

---------------------------------------------------------------------------
-- Want boxes
---------------------------------------------------------------------------

function T:drawWantBox(x, y, w, h, who, offer, mine)
  local c = theme.c
  widgets.card(x, y, w, h, { radius = 12 })
  ui.text(who.name .. " Wants", x + 16, y + 12, { weight = "bold", w = w - 32, ellipsis = true })
  if mine then self.myWantBoxRect = { x = x, y = y, w = w, h = h } end
  local list = {}
  for id, qty in pairs(offer.cards) do list[#list + 1] = { id = id, qty = qty } end
  table.sort(list, function(a, b) return a.id < b.id end)
  if #list == 0 then
    local hint = mine and "Drag cards here from their collection." or "Nothing yet."
    ui.text(hint, x + 16, y + 44, { w = w - 32, color = c.onSurfaceVariant })
    return
  end
  local tw = PW * WANT_SCALE
  local place = widgets.flow(x + 16, y + 44, w - 32, PH * WANT_SCALE + 6, 10)
  ui.pushClip(x, y + 40, w, h - 44)
  for _, item in ipairs(list) do
    local def = models.GameDefinition.cardById(self.game, item.id)
    if def then
      local px, py = place(tw)
      local cx, cy = px + tw / 2, py + PH * WANT_SCALE / 2
      local r = mine and ui.region("tr:want:" .. item.id, px, py, tw, PH * WANT_SCALE, { cursor = "hand", tooltip = "Remove" })
        or { clicked = false }
      CR.draw({ def = def, faceUp = true, cx = cx, cy = cy, scale = POOL_SCALE * WANT_SCALE,
        angle = CR.orientationTurns(def.orientation) * 2 * math.pi, cardBacks = self.game.cardBacks })
      if item.qty > 1 then CR.drawCountBadge(cx + tw / 2 - 10, cy - PH * WANT_SCALE / 2 + 10, item.qty, 0.8) end
      if mine and r.clicked then
        self.sc:request("tradeOffer", json.object({ "tradeId", self.sc.trade.id, "cardId", item.id, "delta", -1 }))
      end
    end
  end
  ui.popClip()
end

---------------------------------------------------------------------------
-- Card grid (one of the two collections), a trimmed copy of the Collection
-- screen's grid: same tile layout, filter bar and Space-preview, but only
-- ever shows cards that are actually owned (nothing to want or give
-- otherwise), and the partner's grid is draggable.
---------------------------------------------------------------------------

function T:drawGrid(scope, x, y, w, h, filters, owned, draggable)
  local c = theme.c
  local game = self.game
  owned = owned or {}
  local yy = filterBar.drawFilters("tr:" .. scope, filters, game, x, y, w, { compact = true })
  yy = filterBar.drawSearch("tr:" .. scope, filters, game, x, yy + 8, w, { labelBackground = c.surface }) + 4
  local visible = util.filter(filterBar.visible(filters, game), function(d)
    return not d.unownable and (d.isFreeCard or (owned[d.id] or 0) > 0)
  end)
  if #visible == 0 then
    ui.text("No cards to show here.", x, yy + 24, { w = w, align = "center", color = c.onSurfaceVariant })
  end
  local gh = y + h - yy
  local nameH = poolGrid.nameH()
  poolGrid.draw("tr:grid:" .. scope, visible, x, yy, w, gh, 0, function(def, i, tx, ty, tileW, cx)
    local n = owned[def.id] or 0
    local r = ui.region("tr:card:" .. scope .. ":" .. def.id, cx - PW / 2, ty, PW, PH + 6 + nameH,
      { cursor = draggable and "hand" or nil })
    CR.draw({ def = def, faceUp = true, cx = cx, cy = ty + PH / 2, scale = POOL_SCALE,
      angle = CR.orientationTurns(def.orientation) * 2 * math.pi, cardBacks = game.cardBacks })
    love.graphics.setColor(0, 0, 0, 0.87)
    love.graphics.circle("fill", cx + PW / 2 + 6 - 11, ty - 6 + 11, 11)
    ui.text(def.isFreeCard and "∞" or ("×" .. n), cx + PW / 2 - 16, ty - 6, { size = 11, weight = "bold", w = 22, h = 22,
      align = "center", valign = "middle", color = theme.fixed.white })
    ui.text(def.cardTitle, tx, ty + PH + 6, { size = 11, w = tileW, align = "center", maxLines = NAME_LINES })
    if r.hovered then self.hovered = def end
    if draggable and r.pressed and not self.pressing and not self.dragging then
      local mx, my = ui.mouse()
      self.pressing = { cardId = def.id, pressX = mx, pressY = my, cx = cx, cy = ty + PH / 2 }
    end
  end)
end

function T:drawPreview()
  if overlays.anyOpen() or ui.focus or not love.keyboard.isDown("space") or not self.hovered then return end
  local sw, sh = ui.screenSize()
  CR.drawPreview(CR.definitionFaces(self.hovered, self.game.cardBacks), self.game.cardBacks, sw, sh, (ui.mouse()))
end

---------------------------------------------------------------------------
-- Confirm + chat
---------------------------------------------------------------------------

function T:drawConfirm(x, y, w, myOffer)
  local label = myOffer.confirmed and "Confirmed -- waiting..." or "Confirm Trade"
  local bw = math.min(280, w)
  if ui.button(label, x, y, bw, 48, { variant = myOffer.confirmed and "tonal" or "filled", id = "tr:confirm",
    icon = myOffer.confirmed and "hourglass_empty" or "check" }) then
    self.sc:request("tradeConfirm", json.object({ "tradeId", self.sc.trade.id, "confirmed", not myOffer.confirmed }))
  end
end

function T:drawChat(x, y, w, h)
  local c = theme.c
  local sc = self.sc
  ui.rect("fill", x, y, w, h, 12, c.surfaceContainer)
  ui.text("Chat", x + 16, y + 12, { weight = "bold" })
  local inputH = 48
  local ly, lh = y + 40, h - 40 - inputH - 24
  local off = ui.beginScroll("tr:chat", x + 8, ly, w - 16, lh)
  local cy = ly - off
  local textW = w - 32
  for _, line in ipairs(sc.tradeChat) do
    ui.text(common.timeLabel(line.at) .. "  " .. line.name, x + 16, cy, { size = 12, weight = "bold", color = c.onSurfaceVariant })
    cy = cy + 18
    ui.text(line.text, x + 16, cy, { w = textW })
    cy = cy + ui.textHeight(line.text, textW) + 10
  end
  ui.endScroll("tr:chat", cy + off - ly)
  if #sc.tradeChat ~= self.seenChat then
    self.seenChat = #sc.tradeChat
    ui.scrollToEnd("tr:chat")
  end
  if #sc.tradeChat == 0 then
    ui.text("Say hello!", x, ly, { w = w, h = lh, align = "center", valign = "middle", color = c.onSurfaceVariant })
  end
  local text, _, submitted = ui.textField("tr:chatinput", x + 12, y + h - inputH - 12, w - 24 - 44, self.chatText,
    { label = "Message", labelBackground = c.surfaceContainer, maxLength = 500 })
  self.chatText = text
  local send = ui.iconButton("send", x + w - 12 - 40, y + h - inputH - 12 + 4, { id = "tr:send", tooltip = "Send",
    disabled = text:match("^%s*$") ~= nil })
  if (submitted or send) and not text:match("^%s*$") then
    sc:send("chatSend", json.object({ "text", text, "tradeId", sc.trade.id }))
    self.chatText = ""
    ui.focusField("tr:chatinput")
  end
end

---------------------------------------------------------------------------
-- Draw
---------------------------------------------------------------------------

function T:draw(x, y, w, h)
  local sc = self.sc
  local trade = sc.trade
  if not trade then
    ui.spinner(x + w / 2, y + h / 2, 18)
    return
  end
  self:updateDrag()
  self.hovered = nil
  local me, them = self:parties()
  self.title = "Trade with " .. them.name
  local myOffer, theirOffer = trade.offers[me.id], trade.offers[them.id]

  local pad = 24
  local chatW = math.min(380, math.floor(w * 0.36))
  local bodyW = w - 3 * pad - chatW
  local bx = x + pad

  local boxGap, boxH = 16, 150
  local boxW = (bodyW - boxGap) / 2
  self:drawWantBox(bx, y + pad, boxW, boxH, me, myOffer, true)
  self:drawWantBox(bx + boxW + boxGap, y + pad, boxW, boxH, them, theirOffer, false)

  local yy = y + pad + boxH + 16
  ui.divider(bx, yy, bodyW)
  yy = yy + 16

  self.tab = widgets.tabBar("tr:tab", bx, yy, bodyW, { "Your Collection", them.name .. "'s Collection" }, self.tab)
  yy = yy + widgets.tabBarHeight + 12

  local confirmH = 56
  local gh = y + h - pad - yy - confirmH
  if self.tab == 1 then
    self:drawGrid("mine", bx, yy, bodyW, gh, self.myFilters, self.myOwned, false)
  else
    self:drawGrid("theirs", bx, yy, bodyW, gh, self.theirFilters, self.theirOwned, true)
  end
  self:drawConfirm(bx, yy + gh + 8, bodyW, myOffer)

  self:drawChat(x + w - pad - chatW, y + pad, chatW, h - 2 * pad)
  ui.overlay(function() self:drawDragFeedback() end)
  ui.overlay(function() self:drawPreview() end)
end

return T
