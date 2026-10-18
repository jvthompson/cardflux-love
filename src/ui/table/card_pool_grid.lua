-- Shared geometry/scroll for the "card pool" grid used by deck_editor.lua,
-- card_view_tab.lua, server/collection.lua and server/trade.lua: tiles
-- sized a third larger than a table card, columns sized to exactly fill
-- the available width (unlike game_picker.lua's fixed-width, per-row-
-- centered grid), a name below each tile. Callers still draw each tile's
-- own content (art, badges, selection, drag) -- only the layout and
-- scrolling is shared.
local ui = require("src.ui.kit.ui")
local theme = require("src.ui.kit.theme")
local CR = require("src.ui.table.card_render")

local M = {}

M.NAME_LINES = 3
M.SCALE = 4 / 3
M.CW, M.CH = CR.cardWidth, CR.cardHeight
M.PW, M.PH = M.CW * M.SCALE, M.CH * M.SCALE

function M.nameH() return M.NAME_LINES * theme.font(11):getHeight() end

-- Draws a scrollable grid of `items` into (x, y, w, h). `pad` insets the
-- tiles horizontally on both sides (0: flush with x/x+w, as collection.lua
-- and trade.lua want; 12: deck_editor.lua/card_view_tab.lua's gutter) --
-- the top inset is always 12, matching every caller.
-- drawTile(item, i, tx, ty, tileW, cx) is called for each tile currently
-- on screen; cx is the tile's horizontal center (tx + tileW / 2). Draw the
-- card art centered at (cx, ty + M.PH / 2) and the name at
-- (tx, ty + M.PH + 6, tileW).
function M.draw(scrollId, items, x, y, w, h, pad, drawTile)
  local nameH = M.nameH()
  local maxExtent, rowH, gap = M.PW + 24, M.PH + 6 + nameH + 4, 12
  local inner = w - 2 * pad
  local cols = math.max(1, math.ceil((inner + gap) / (maxExtent + gap)))
  local tileW = (inner - (cols - 1) * gap) / cols
  local off = ui.beginScroll(scrollId, x, y, w, h)
  for i, item in ipairs(items) do
    local col, row = (i - 1) % cols, math.floor((i - 1) / cols)
    local tx, ty = x + pad + col * (tileW + gap), y + 12 + row * (rowH + gap) - off
    if ty + rowH > y and ty < y + h then
      drawTile(item, i, tx, ty, tileW, tx + tileW / 2)
    end
  end
  ui.endScroll(scrollId, 24 + math.ceil(#items / cols) * (rowH + gap) - gap)
end

return M
