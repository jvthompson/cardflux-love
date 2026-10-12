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
-- The collection grid matches the Deck Editor's card pool: cards a third
-- larger, with up to three lines of name.
local POOL_SCALE = 4 / 3
local PW, PH = CW * POOL_SCALE, CH * POOL_SCALE
local NAME_LINES = 3

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

local function newBadge(x, y)
  ui.rect("fill", x, y, 36, 18, 9, theme.fixed.green)
  ui.text("NEW", x, y, { size = 10, weight = "bold", w = 36, h = 18, align = "center", valign = "middle", color = theme.fixed.white })
end

-- An opened pack: the cards are revealed one at a time (Next Card / Skip),
-- then shown together, with cards new to the collection marked.
function C:showPack(set, ids, before, title)
  local game = self.game
  local cards = {}
  for _, id in ipairs(ids) do
    local def = models.GameDefinition.cardById(game, id)
    if def then cards[#cards + 1] = { def = def, new = (before[id] or 0) == 0 } end
  end
  title = title or (set.name .. " Pack")
  sound.play("shuffle")
  if #cards == 0 then return end
  self:revealPack(cards, title)
end

-- One card at a time, drawn large inside the dialog.
local REVEAL_W = 480
function C:revealPack(cards, title)
  local game = self.game
  local index = 1
  local nextAction = { label = "Next Card", variant = "filled" }
  local function showAll() self:showPackSummary(cards, title) end
  local function advance(d)
    if index >= #cards then
      d:close()
      showAll()
      return true
    end
    index = index + 1
    sound.play("draw")
    if index == #cards then nextAction.label = "Show All" end
    return true
  end
  nextAction.onClick = advance
  if #cards == 1 then nextAction.label = "Show All" end
  overlays.dialog({
    title = title,
    width = REVEAL_W,
    dismissible = false,
    onEnter = advance,
    content = function(_, x, y, w)
      local card = cards[index]
      local def = card.def
      ui.text("Card " .. index .. " of " .. #cards, x, y, { w = w, align = "center", size = 13, color = theme.c.onSurfaceVariant })
      -- Fit the card (portrait or turned) in a box under the counter.
      local _, sh = ui.screenSize()
      local boxW, boxH = w, math.max(240, math.min(460, sh - 380))
      local turned = def.orientation and def.orientation ~= "portrait"
      local bw, bh = turned and CH or CW, turned and CW or CH
      local s = math.min(boxW / bw, boxH / bh)
      local cy = y + 28 + bh * s / 2
      CR.draw({ def = def, faceUp = true, cx = x + w / 2, cy = cy, scale = s,
        angle = CR.orientationTurns(def.orientation) * 2 * math.pi, cardBacks = game.cardBacks })
      if card.new then newBadge(x + (w - bw * s) / 2 + 8, y + 28 + 8) end
      local ty = y + 28 + bh * s + 12
      ui.text(def.cardTitle, x, ty, { w = w, align = "center", weight = "bold", maxLines = 2 })
      return ty - y + ui.textHeight(def.cardTitle, w) + 4
    end,
    actions = {
      { label = "Skip", variant = "text", onClick = function(d) d:close(); showAll(); return true end },
      nextAction,
    },
  })
end

-- Every card from the pack, laid out like the Deck Editor's card pool, with
-- the Space preview for the hovered card.
function C:showPackSummary(cards, title)
  local game = self.game
  local gap = 12
  local nameH = NAME_LINES * theme.font(11):getHeight()
  local tileW, rowH = PW + 24, PH + 6 + nameH + 4
  local perRow = math.min(#cards, 6)
  local width = math.max(420, perRow * (tileW + gap) - gap + 48)
  overlays.dialog({
    title = title,
    width = width,
    content = function(_, x, y, w)
      local hovered
      local rows = math.ceil(#cards / perRow)
      for i, card in ipairs(cards) do
        local col, row = (i - 1) % perRow, math.floor((i - 1) / perRow)
        local rowCount = math.min(perRow, #cards - row * perRow)
        local rowW = rowCount * (tileW + gap) - gap
        local tx = x + (w - rowW) / 2 + col * (tileW + gap)
        local cx, ty = tx + tileW / 2, y + 8 + row * (rowH + gap)
        local r = ui.region("pk:" .. i, cx - PW / 2, ty, PW, PH + 6 + nameH)
        CR.draw({ def = card.def, faceUp = true, cx = cx, cy = ty + PH / 2, scale = POOL_SCALE,
          angle = CR.orientationTurns(card.def.orientation) * 2 * math.pi, cardBacks = game.cardBacks })
        if card.new then newBadge(cx - PW / 2 + 4, ty + 4) end
        ui.text(card.def.cardTitle, tx, ty + PH + 6, { size = 11, w = tileW, align = "center", maxLines = NAME_LINES })
        if r.hovered then hovered = card.def end
      end
      if hovered and love.keyboard.isDown("space") then
        ui.overlay(function()
          local sw, sh = ui.screenSize()
          CR.drawPreview(CR.definitionFaces(hovered, game.cardBacks), game.cardBacks, sw, sh, (ui.mouse()))
        end)
      end
      return 8 + rows * (rowH + gap) - gap
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
  -- Free cards are always owned, in unlimited copies (not counted in total).
  local distinct, total = 0, 0
  for _, d in ipairs(game.cards) do
    if d.isFreeCard and not d.unownable then
      distinct = distinct + 1
    elseif not d.unownable and (owned[d.id] or 0) > 0 then
      distinct, total = distinct + 1, total + owned[d.id]
    end
  end
  local collectible = #util.filter(game.cards, function(d) return not d.unownable end)
  ui.text("Your Cards", x, y, { size = 18 })
  ui.text(distinct .. " of " .. collectible .. " cards  ·  " .. total .. " copies", x, y + 26, { size = 13, color = c.onSurfaceVariant })
  local yy = filterBar.drawFilters("co", self.filters, game, x, y + 52, w - 150, { compact = true })
  self.ownedOnly = ui.checkbox("co:owned", x + w - 130, y + 52 + 7, self.ownedOnly, { label = "Owned only" })
  yy = filterBar.drawSearch("co", self.filters, x, yy + 8, w, { labelBackground = c.surface }) + 4
  local visible = util.filter(filterBar.visible(self.filters, game), function(d)
    return not d.unownable and (not self.ownedOnly or d.isFreeCard or (owned[d.id] or 0) > 0)
  end)
  if #visible == 0 then
    ui.text(self.ownedOnly and distinct == 0 and "You don't own any cards for this game yet. Open a pack above."
      or "No cards match these filters.", x, yy + 24, { w = w, align = "center", color = c.onSurfaceVariant })
  end
  -- Same tile layout as the Deck Editor's card pool.
  local gh = y + h - yy
  local nameH = NAME_LINES * theme.font(11):getHeight()
  local maxExtent, rowH, gap = PW + 24, PH + 6 + nameH + 4, 12
  local cols = math.max(1, math.ceil((w + gap) / (maxExtent + gap)))
  local tileW = (w - (cols - 1) * gap) / cols
  local off = ui.beginScroll("co:grid", x, yy, w, gh)
  for i, def in ipairs(visible) do
    local col, row = (i - 1) % cols, math.floor((i - 1) / cols)
    local tx, ty = x + col * (tileW + gap), yy + 12 + row * (rowH + gap) - off
    if ty + rowH > yy and ty < yy + gh then
      local n = owned[def.id] or 0
      local have = def.isFreeCard or n > 0
      local cx = tx + tileW / 2
      local r = ui.region("co:card:" .. def.id, cx - PW / 2, ty, PW, PH + 6 + nameH)
      CR.draw({ def = def, faceUp = true, cx = cx, cy = ty + PH / 2, scale = POOL_SCALE, alpha = have and 1 or 0.25,
        angle = CR.orientationTurns(def.orientation) * 2 * math.pi, cardBacks = game.cardBacks })
      if have then
        love.graphics.setColor(0, 0, 0, 0.87)
        love.graphics.circle("fill", cx + PW / 2 + 6 - 11, ty - 6 + 11, 11)
        ui.text(def.isFreeCard and "∞" or ("×" .. n), cx + PW / 2 - 16, ty - 6, { size = 11, weight = "bold", w = 22, h = 22, align = "center", valign = "middle",
          color = theme.fixed.white })
      end
      ui.text(def.cardTitle, tx, ty + PH + 6, { size = 11, w = tileW, align = "center", maxLines = NAME_LINES,
        color = have and c.onSurface or c.onSurfaceVariant })
      if r.hovered then self.hovered = def end
    end
  end
  ui.endScroll("co:grid", 24 + math.ceil(#visible / cols) * (rowH + gap) - gap)
end

-- Space preview of the hovered card, as in the Deck Editor.
function C:drawPreview()
  if overlays.anyOpen() or ui.focus or not love.keyboard.isDown("space") or not self.hovered then return end
  local sw, sh = ui.screenSize()
  CR.drawPreview(CR.definitionFaces(self.hovered, self.game.cardBacks), self.game.cardBacks, sw, sh, (ui.mouse()))
end

function C:draw(x, y, w, h)
  if not self.game then
    decksScreen.drawGameList(self.sc, "co:games", x, y, w, h, "Open packs and see which cards you own for each game.",
      function(g) self:open(g) end, { excludeStandardDeck = true })
    return
  end
  local pad = 24
  self.hovered = nil
  local yy = self:drawStore(x + pad, y + pad, w - 2 * pad)
  ui.divider(x + pad, yy + 8, w - 2 * pad)
  self:drawCollection(x + pad, yy + 24, w - 2 * pad, y + h - yy - 24 - pad)
  ui.overlay(function() self:drawPreview() end)
end

return C
