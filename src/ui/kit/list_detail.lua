-- List-left / detail-right split shared by the gamedef editor's tabs
-- (sets_tab.lua, zones_tab.lua): a list pane sized min(listW, 40% of w),
-- a 1px divider, and either the selected item's detail pane or a centered
-- placeholder message on the right. Reads/writes self.selected directly,
-- clamping it to the current list.
local ui = require("src.ui.kit.ui")
local theme = require("src.ui.kit.theme")
local util = require("src.core.util")

local M = {}

-- drawList(self, x, y, w, h) and drawDetail(self, item, x, y, w, h) are
-- self:method-shaped functions, passed unbound so this stays a plain
-- function rather than a class.
function M.draw(self, x, y, w, h, list, listW, drawList, drawDetail, emptyMessage)
  local c = theme.c
  if self.selected and not util.contains(list, self.selected) then self.selected = nil end
  if not self.selected then self.selected = list[1] end

  local lw = math.min(listW, math.floor(w * 0.4))
  ui.pushClip(x, y, lw, h)
  drawList(self, x, y, lw, h)
  ui.popClip()
  ui.rect("fill", x + lw, y, 1, h, 0, c.outlineVariant)
  local dx = x + lw + 1
  ui.pushClip(dx, y, w - lw - 1, h)
  if self.selected then
    drawDetail(self, self.selected, dx, y, w - lw - 1, h)
  else
    ui.text(emptyMessage, dx, y, { w = w - lw - 1, h = h, align = "center", valign = "middle",
      color = c.onSurfaceVariant })
  end
  ui.popClip()
end

return M
