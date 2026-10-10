-- App settings dialog, opened from the Home screen and the in-game menu.
-- New settings go here as sections: a heading, then rows.
local ui = require("src.ui.kit.ui")
local theme = require("src.ui.kit.theme")
local overlays = require("src.ui.kit.overlays")
local window = require("src.platform.window")
local profile = require("src.data.profile")

local M = {}

local function app() return require("src.app") end

local function pct(v) return math.floor(v * 100 + 0.5) .. "%" end

local function scaleOptions()
  local opts = {}
  for _, v in ipairs(app().uiScaleOptions) do
    opts[#opts + 1] = { value = v, label = v == 1 and "100% (Default)" or pct(v) }
  end
  return opts
end

local function heading(text, x, y)
  ui.text(text, x, y, { size = 14, weight = "bold", color = theme.c.primary })
  return 28
end

-- opts.inGame: opened over the game table (which always draws light).
function M.open(opts)
  opts = opts or {}
  local A = app()
  local options = scaleOptions()
  return overlays.dialog({
    title = "Settings",
    width = 440,
    content = function(_, x, y, w)
      local c = theme.c
      local yy = y

      yy = yy + heading("Display", x, yy)
      local current = A.uiScaleSetting()
      local picked = ui.dropdown("settings:uiScale", x, yy + 6, w, options, current,
        { label = "UI scale", labelBackground = c.surfaceContainerHigh })
      if picked ~= current then A.setUiScaleSetting(picked) end
      yy = yy + 6 + 48 + 8
      local dpi, eff = window.dpiScale(), A.effectiveScale()
      local note = "Windows display scaling: " .. pct(dpi) .. ". Effective scale: " .. pct(eff) .. "."
      if eff + 0.005 < dpi * A.uiScaleSetting() then
        note = note .. " Limited so the app still fits on this screen."
      end
      ui.text(note, x, yy, { w = w, size = 12, color = c.onSurfaceVariant })
      yy = yy + ui.textHeight(note, w, 12) + 24

      yy = yy + heading("Appearance", x, yy)
      local subtitle = opts.inGame and "The game table always uses the light theme." or nil
      if ui.switchRow("settings:dark", "Dark mode", x, yy, w, theme.isDark, { subtitle = subtitle }) ~= theme.isDark then
        theme.setDark(not theme.isDark)
        profile.setDarkMode(theme.isDark)
      end
      yy = yy + 32 + (subtitle and ui.textHeight(subtitle, w - 64, 12) + 4 or 0)
      return yy - y
    end,
    actions = { { label = "Done", variant = "filled" } },
  })
end

return M
