-- Collection mode: browse the cards you own for a game. Packs and starter
-- decks are bought from the Card Shop (src/ui/screens/server/shop.lua).
local ui = require("src.ui.kit.ui")
local theme = require("src.ui.kit.theme")
local overlays = require("src.ui.kit.overlays")
local filterBar = require("src.ui.kit.card_filter_bar")
local json = require("lib.json")
local util = require("src.core.util")
local CR = require("src.ui.table.card_render")
local common = require("src.ui.screens.server.common")

local CW, CH = CR.cardWidth, CR.cardHeight
-- The collection grid matches the Deck Editor's card pool: cards a third
-- larger, with up to three lines of name.
local POOL_SCALE = 4 / 3
local PW, PH = CW * POOL_SCALE, CH * POOL_SCALE
local NAME_LINES = 3

local C = {}
C.__index = C

function C.new(sc, info)
  local self = setmetatable({ title = "Collection", sc = sc }, C)
  if info then self:open(info) end
  return self
end

function C:onBack() require("src.app").pop() end

function C:open(info)
  local sc = self.sc
  common.withGame(sc, info.id, function(game)
    sc:request("collectionGet", json.object({ "gameId", game.id }), function(r)
      if not r.ok then
        overlays.alert("Couldn't Load Collection", r.message or "Something went wrong.")
        return
      end
      self.game, self.owned = game, r.cards or {}
      self.filters = filterBar.newState(game)
      self.ownedOnly = true
      self.title = "Collection -- " .. game.name
    end)
  end)
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
    ui.text(self.ownedOnly and distinct == 0 and "You don't own any cards for this game yet. Visit the Card Shop to open a pack."
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
    ui.spinner(x + w / 2, y + h / 2, 18)
    return
  end
  local pad = 24
  self.hovered = nil
  self:drawCollection(x + pad, y + pad, w - 2 * pad, h - 2 * pad)
  ui.overlay(function() self:drawPreview() end)
end

return C
