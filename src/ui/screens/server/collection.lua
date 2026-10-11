-- Collection mode: spend tokens on packs for a game's sets and browse the
-- cards you own. Packs use the same algorithm as the Pack Generator widget
-- (run on the server).
local ui = require("src.ui.kit.ui")
local theme = require("src.ui.kit.theme")
local overlays = require("src.ui.kit.overlays")
local filterBar = require("src.ui.kit.card_filter_bar")
local json = require("lib.json")
local models = require("src.core.models")
local util = require("src.core.util")
local sound = require("src.game.sound")
local CR = require("src.ui.table.card_render")
local common = require("src.ui.screens.server.common")
local decksScreen = require("src.ui.screens.server.decks")

local CW, CH = CR.cardWidth, CR.cardHeight

local C = {}
C.__index = C

function C.new(sc)
  return setmetatable({ title = "Collection", sc = sc }, C)
end

function C:onBack()
  if self.game then
    self.game, self.owned, self.title = nil, nil, "Collection"
  else
    require("src.app").pop()
  end
end

function C:open(info)
  local sc = self.sc
  common.withGame(sc, info.id, function(game)
    sc:request("collectionGet", json.object({ "gameId", game.id }), function(r)
      if not r.ok then
        overlays.alert("Couldn't Load Collection", r.message or "Something went wrong.")
        return
      end
      self.game, self.info, self.owned = game, info, r.cards or {}
      self.filters = filterBar.newState(game)
      self.ownedOnly = true
      self.title = "Collection -- " .. game.name
    end)
  end)
end

function C:buyPack(set)
  local sc = self.sc
  self.buying = set.id
  sc:request("packBuy", json.object({ "gameId", self.game.id, "setId", set.id }), function(r)
    self.buying = nil
    if not r.ok then
      sound.play("error")
      overlays.alert("Couldn't Open Pack", r.message or "Something went wrong.")
      return
    end
    local before = util.shallowCopy(self.owned)
    for _, id in ipairs(r.cards) do self.owned[id] = (self.owned[id] or 0) + 1 end
    if sc.self then sc.self.tokens = r.tokens end
    self:showPack(set, r.cards, before)
  end)
end

function C:buyStarter(starter)
  local sc = self.sc
  self.buying = "starter:" .. starter.name
  sc:request("starterBuy", json.object({ "gameId", self.game.id, "name", starter.name }), function(r)
    self.buying = nil
    if not r.ok then
      sound.play("error")
      overlays.alert("Couldn't Buy Starter Deck", r.message or "Something went wrong.")
      return
    end
    local before = util.shallowCopy(self.owned)
    local ids = {}
    for id, n in pairs(r.cards or {}) do
      self.owned[id] = (self.owned[id] or 0) + n
      for _ = 1, n do ids[#ids + 1] = id end
    end
    table.sort(ids)
    if sc.self then sc.self.tokens = r.tokens end
    self:showPack({ name = starter.name }, ids, before, starter.name .. " Starter Deck")
    overlays.toast('Added "' .. (r.savedName or starter.name) .. '" to your decks.')
  end)
end

-- The opened pack, with cards new to the collection marked.
function C:showPack(set, ids, before, title)
  local game = self.game
  local cards = {}
  for _, id in ipairs(ids) do
    local def = models.GameDefinition.cardById(game, id)
    if def then cards[#cards + 1] = { def = def, new = (before[id] or 0) == 0 } end
  end
  sound.play("shuffle")
  local gap = 16
  local perRow = math.min(#cards, 5)
  local width = math.max(420, perRow * (CW + gap) - gap + 48)
  local hovered
  overlays.dialog({
    title = title or (set.name .. " Pack"),
    width = width,
    content = function(_, x, y, w)
      hovered = nil
      local rows = math.ceil(#cards / perRow)
      for i, card in ipairs(cards) do
        local col, row = (i - 1) % perRow, math.floor((i - 1) / perRow)
        local rowCount = math.min(perRow, #cards - row * perRow)
        local rowW = rowCount * (CW + gap) - gap
        local cx = x + (w - rowW) / 2 + col * (CW + gap) + CW / 2
        local ty = y + 8 + row * (CH + 44)
        local r = ui.region("pk:" .. i, cx - CW / 2, ty, CW, CH)
        CR.draw({ def = card.def, faceUp = true, cx = cx, cy = ty + CH / 2,
          angle = CR.orientationTurns(card.def.orientation) * 2 * math.pi, cardBacks = game.cardBacks })
        if card.new then
          ui.rect("fill", cx - CW / 2 + 4, ty + 4, 36, 18, 9, theme.fixed.green)
          ui.text("NEW", cx - CW / 2 + 4, ty + 4, { size = 10, weight = "bold", w = 36, h = 18, align = "center", valign = "middle",
            color = theme.fixed.white })
        end
        ui.text(card.def.cardTitle, cx - CW / 2 - 8, ty + CH + 6, { size = 12, w = CW + 16, align = "center", ellipsis = true })
        if r.hovered then hovered = card.def end
      end
      local _ = hovered
      return 8 + rows * (CH + 44)
    end,
    actions = { { label = "Done", variant = "filled" } },
  })
end

function C:drawStore(x, y, w)
  local c = theme.c
  local sc = self.sc
  local tokens = sc.self and sc.self.tokens or 0
  local cost = sc.info.packCost or 1
  local starters = self.info.starterDecks or {}
  local starterCost = sc.info.starterDeckCost or 3
  local function plural(n) return n .. (n == 1 and " token" or " tokens") end
  ui.text("Open Packs", x, y, { size = 18 })
  local balance = plural(tokens) .. "  ·  " .. plural(cost) .. " per pack"
  if #starters > 0 then balance = balance .. "  ·  " .. plural(starterCost) .. " per starter deck" end
  ui.text(balance, x, y + 26, { size = 13, color = c.onSurfaceVariant })
  local yy = y + 56
  local sets = self.info.sets or {}
  local bx = x
  if #sets == 0 then
    ui.text("This game has no sets, so it has no packs.", x, yy, { color = c.onSurfaceVariant })
    yy = yy + 24
  else
    for _, set in ipairs(sets) do
      local label = set.name
      local bw = math.max(160, ui.buttonWidth(label, { icon = "card_giftcard" }))
      if bx + bw > x + w and bx > x then
        bx = x
        yy = yy + 48
      end
      local busy = self.buying == set.id
      if ui.button(busy and "Opening..." or label, bx, yy, bw, 40, { variant = "tonal", icon = "card_giftcard", id = "co:buy:" .. set.id,
        disabled = self.buying ~= nil or tokens < cost, tooltip = set.cardCount .. " cards in this set" }) then
        self:buyPack(set)
      end
      bx = bx + bw + 8
    end
    yy = yy + 48
  end
  if #starters > 0 then
    ui.text("Starter Decks", x, yy + 4, { size = 14, color = c.onSurfaceVariant })
    yy = yy + 28
    bx = x
    for _, starter in ipairs(starters) do
      local bw = math.max(160, ui.buttonWidth(starter.name, { icon = "style" }))
      if bx + bw > x + w and bx > x then
        bx = x
        yy = yy + 48
      end
      local busy = self.buying == "starter:" .. starter.name
      if ui.button(busy and "Buying..." or starter.name, bx, yy, bw, 40, { variant = "tonal", icon = "style",
        id = "co:starter:" .. starter.name, disabled = self.buying ~= nil or tokens < starterCost,
        tooltip = starter.cardCount .. " cards  ·  " .. plural(starterCost) .. "; also saved to your decks" }) then
        self:buyStarter(starter)
      end
      bx = bx + bw + 8
    end
    yy = yy + 48
  end
  local cheapest = math.min(#sets > 0 and cost or math.huge, #starters > 0 and starterCost or math.huge)
  if cheapest ~= math.huge and tokens < cheapest then
    ui.text("You need more tokens. Admins can grant tokens, and some servers give out a regular allowance.", x, yy,
      { w = w, size = 12, color = c.onSurfaceVariant })
    yy = yy + 24
  end
  return yy
end

function C:drawCollection(x, y, w, h)
  local c = theme.c
  local game = self.game
  local owned = self.owned
  local distinct, total = 0, 0
  for _, n in pairs(owned) do
    distinct, total = distinct + 1, total + n
  end
  local collectible = #util.filter(game.cards, function(d) return not d.unownable end)
  ui.text("Your Cards", x, y, { size = 18 })
  ui.text(distinct .. " of " .. collectible .. " cards  ·  " .. total .. " copies", x, y + 26, { size = 13, color = c.onSurfaceVariant })
  local yy = filterBar.drawFilters("co", self.filters, game, x, y + 52, w - 150, { compact = true })
  self.ownedOnly = ui.checkbox("co:owned", x + w - 130, y + 52 + 7, self.ownedOnly, { label = "Owned only" })
  yy = filterBar.drawSearch("co", self.filters, x, yy + 8, w, { labelBackground = c.surface }) + 4
  local visible = util.filter(filterBar.visible(self.filters, game), function(d)
    return not d.unownable and (not self.ownedOnly or (owned[d.id] or 0) > 0)
  end)
  if #visible == 0 then
    ui.text(self.ownedOnly and distinct == 0 and "You don't own any cards for this game yet. Open a pack above."
      or "No cards match these filters.", x, yy + 24, { w = w, align = "center", color = c.onSurfaceVariant })
  end
  local gh = y + h - yy
  local tileW, rowH, gap = CW + 24, CH + 30, 12
  local cols = math.max(1, math.floor((w + gap) / (tileW + gap)))
  local off = ui.beginScroll("co:grid", x, yy, w, gh)
  for i, def in ipairs(visible) do
    local col, row = (i - 1) % cols, math.floor((i - 1) / cols)
    local tx, ty = x + col * (tileW + gap), yy + 8 + row * (rowH + gap) - off
    if ty + rowH > yy and ty < yy + gh then
      local n = owned[def.id] or 0
      local cx = tx + tileW / 2
      CR.draw({ def = def, faceUp = true, cx = cx, cy = ty + CH / 2, alpha = n > 0 and 1 or 0.25,
        angle = CR.orientationTurns(def.orientation) * 2 * math.pi, cardBacks = game.cardBacks })
      if n > 0 then
        love.graphics.setColor(0, 0, 0, 0.87)
        love.graphics.circle("fill", cx + CW / 2 - 5, ty + 5, 11)
        ui.text("×" .. n, cx + CW / 2 - 16, ty - 6, { size = 11, weight = "bold", w = 22, h = 22, align = "center", valign = "middle",
          color = theme.fixed.white })
      end
      ui.text(def.cardTitle, tx, ty + CH + 4, { size = 11, w = tileW, align = "center", ellipsis = true,
        color = n > 0 and c.onSurface or c.onSurfaceVariant })
    end
  end
  ui.endScroll("co:grid", 16 + math.ceil(#visible / cols) * (rowH + gap))
end

function C:draw(x, y, w, h)
  if not self.game then
    decksScreen.drawGameList(self.sc, "co:games", x, y, w, h, "Open packs and see which cards you own for each game.",
      function(g) self:open(g) end, { excludeStandardDeck = true })
    return
  end
  local pad = 24
  local yy = self:drawStore(x + pad, y + pad, w - 2 * pad)
  ui.divider(x + pad, yy + 8, w - 2 * pad)
  self:drawCollection(x + pad, yy + 24, w - 2 * pad, y + h - yy - 24 - pad)
end

return C
