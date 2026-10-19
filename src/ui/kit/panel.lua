-- Shared full-panel chrome: scrim (click closes), dark rounded panel, title
-- row with a close button. Used by table_screen.lua's Game Menu/Log/Card
-- Library panels and by the Rulebook viewer (table screen + deck editor).
local ui = require("src.ui.kit.ui")
local theme = require("src.ui.kit.theme")
local overlays = require("src.ui.kit.overlays")

local M = {}

local PANEL = theme.fixed.overlayPanel
local WHITE = theme.fixed.white

-- Height of the title row returned content is offset below; exposed so a
-- caller can work out the content rect's size before calling M.draw (e.g.
-- to size a panel from its desired content size).
M.TITLE_BAR_H = 65

-- leading (optional): { icon, tooltip, onClick } - a small icon button
-- drawn before the title, e.g. a sidebar toggle.
-- Returns contentX, contentY, contentW, contentH (below the title bar).
function M.draw(id, w, h, title, onClose, trailing, leading)
  local sw, sh = ui.screenSize()
  local top = overlays.contentTop
  ui.cover(-1e9, top, 2e9, 2e9)
  love.graphics.setColor(0, 0, 0, 0.25)
  love.graphics.rectangle("fill", 0, top, sw, sh - top)
  local x, y = math.floor((sw - w) / 2), math.floor(top + (sh - top - h) / 2)
  if ui.mousePressed(1) and not ui.hoverIgnoringLayer(x, y, w, h) then onClose() end
  ui.rect("fill", x, y, w, h, 12, PANEL)
  local titleX = x + 16
  if leading then
    if ui.iconButton(leading.icon, x + 8, y + 12, { color = WHITE, tooltip = leading.tooltip, id = id .. ":leading" }) then
      leading.onClick()
    end
    titleX = x + 56
  end
  ui.text(title, titleX, y + 12, { size = 18, weight = "bold", color = WHITE, h = 40, valign = "middle" })
  if trailing then
    ui.text(trailing, x, y + 12, { w = w - 56, h = 40, valign = "middle", align = "right", color = { 1, 1, 1, 0.7 } })
  end
  if ui.iconButton("close", x + w - 48, y + 12, { color = WHITE, tooltip = "Close", id = id .. ":close" }) then onClose() end
  ui.divider(x, y + 64, w, { 1, 1, 1, 0.24 })
  return x, y + M.TITLE_BAR_H, w, h - M.TITLE_BAR_H
end

return M
