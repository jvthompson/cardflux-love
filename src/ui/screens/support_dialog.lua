-- "Support the author" dialog, opened from the Home screen. Renders
-- SUPPORT-ME.md (packed into game.love by tools/build.ps1) and links to the
-- author's Ko-fi page.
local overlays = require("src.ui.kit.overlays")
local controls = require("src.ui.screens.controls_dialog")

local M = {}

local SOURCE = "SUPPORT-ME.md"
M.kofiUrl = "https://ko-fi.com/jamesvthompson"

function M.open()
  local list = controls.loadBlocks(SOURCE)
  return overlays.dialog({
    title = "Support The Author",
    width = 460,
    content = function(_, x, y, w) return controls.drawBlocks(x, y, w, list) end,
    actions = {
      { label = "Maybe Later", variant = "text" },
      { label = "Visit Ko-fi.com", variant = "filled", onClick = function() love.system.openURL(M.kofiUrl) end },
    },
  })
end

return M
