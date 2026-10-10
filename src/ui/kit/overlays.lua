-- Modal dialogs, context menus and snackbars, drawn above the current
-- screen each frame by the app shell (overlays.draw).
local ui = require("src.ui.kit.ui")
local theme = require("src.ui.kit.theme")

local O = {}

local dialogs = {}

-- Top of the content area (below the custom title bar). Dialog scrims start
-- here so the title bar stays visible and usable, like Flutter's navigator.
O.contentTop = 0
local menus = {}
local toasts = {}

---------------------------------------------------------------------------
-- Dialogs
---------------------------------------------------------------------------

-- Opens a modal dialog. spec:
--   title        string
--   width        number (default 400)
--   dark         bool: draw with the fixed dark overlay panel (in-game)
--   content      function(d, x, y, w) -> height used (optional)
--   message      string (shortcut for plain text content)
--   actions      { {label=, variant=, onClick=fn(d) -> keepOpen?, disabled=fn|bool}, ... }
--   onDismiss    function(d) when closed by Escape / scrim click
--   dismissible  default true
-- Returns the dialog object; d:close() closes it.
function O.dialog(spec)
  local d = setmetatable(spec, { __index = { close = function(self) O.closeDialog(self) end } })
  d.width = d.width or 400
  d.dismissible = d.dismissible ~= false
  d.contentH = d.contentH or 0
  d.state = d.state or {}
  dialogs[#dialogs + 1] = d
  return d
end

function O.closeDialog(d)
  for i, x in ipairs(dialogs) do
    if x == d then
      table.remove(dialogs, i)
      ui.blur()
      return
    end
  end
end

function O.topDialog() return dialogs[#dialogs] end
function O.anyOpen() return #dialogs > 0 or #menus > 0 end

-- Simple confirm dialog.
function O.confirm(title, message, confirmLabel, onConfirm, opts)
  opts = opts or {}
  return O.dialog({
    title = title, message = message, width = opts.width or 420, dark = opts.dark,
    actions = {
      { label = opts.cancelLabel or "Cancel", variant = "text" },
      { label = confirmLabel or "OK", variant = opts.danger and "danger" or "filled", onClick = function() onConfirm() end },
    },
  })
end

function O.alert(title, message, opts)
  opts = opts or {}
  return O.dialog({ title = title, message = message, width = opts.width or 420, dark = opts.dark,
    actions = { { label = "OK", variant = "text" } } })
end

local function drawDialog(d, isTop)
  local sw, sh = ui.screenSize()
  local top = O.contentTop
  ui.cover(-1e9, top, 2e9, 2e9)
  ui._modalOpenNext = true
  love.graphics.setColor(0, 0, 0, d.dark and 0.25 or 0.32)
  love.graphics.rectangle("fill", 0, top, sw, sh - top)

  local c = theme.c
  local fg = d.dark and theme.fixed.white or c.onSurface
  local w = math.min(d.width, sw - 32)
  local pad = 24
  local titleH = d.title and 40 or 0
  local actionsH = (d.actions and #d.actions > 0) and (24 + ui.BUTTON_H + 24) or pad
  local maxContentH = sh - O.contentTop - 64 - titleH - actionsH - pad
  local contentH = math.min(d.contentH, maxContentH)
  local h = pad + titleH + contentH + actionsH
  local x, y = math.floor((sw - w) / 2), math.floor(top + (sh - top - h) / 2)
  d.rect = { x = x, y = y, w = w, h = h }

  ui.shadow(x, y, w, h, 28, 3)
  ui.rect("fill", x, y, w, h, 28, d.dark and theme.fixed.overlayPanel or c.surfaceContainerHigh)
  if d.title then
    ui.text(d.title, x + pad, y + pad, { size = 22, color = fg, w = w - 2 * pad, ellipsis = true })
  end

  -- Content (scrolls if taller than the screen allows).
  local cx, cy, cw = x + pad, y + pad + titleH, w - 2 * pad
  local off = ui.beginScroll("dialog:" .. tostring(d), cx - 4, cy, cw + 8, contentH)
  local used = 0
  if d.message then
    used = ui.textHeight(d.message, cw, 14)
    ui.text(d.message, cx, cy - off, { w = cw, color = d.dark and { 1, 1, 1, 0.8 } or c.onSurfaceVariant })
  end
  if d.content then
    used = used + (d.content(d, cx, cy - off + used, cw) or 0)
  end
  ui.endScroll("dialog:" .. tostring(d), used)
  d.contentH = used

  -- Actions, right-aligned.
  if d.actions and #d.actions > 0 then
    local ax = x + w - pad
    local ay = y + h - 24 - ui.BUTTON_H
    for i = #d.actions, 1, -1 do
      local a = d.actions[i]
      local bw = ui.buttonWidth(a.label)
      ax = ax - bw
      local disabled = a.disabled
      if type(disabled) == "function" then disabled = disabled(d) end
      if a.visible == nil or (type(a.visible) == "function" and a.visible(d)) or a.visible == true then
        if ui.button(a.label, ax, ay, bw, nil, { variant = a.variant or "text", disabled = disabled, id = tostring(d) .. ":a" .. i,
          color = (d.dark and (a.variant or "text") == "text") and theme.fixed.white or nil }) then
          local keep = a.onClick and a.onClick(d)
          if not keep then O.closeDialog(d) end
        end
        ax = ax - 8
      else
        ax = ax + bw
      end
    end
  end

  -- Scrim click / Escape handled in O.keypressed and here.
  if isTop and d.dismissible and ui.mousePressed(1) and not ui.hoverIgnoringLayer(x, y, w, h) and #menus == 0 then
    O.closeDialog(d)
    if d.onDismiss then d.onDismiss(d) end
  end
end

---------------------------------------------------------------------------
-- Context menus (nested)
---------------------------------------------------------------------------

-- items: { {label=, icon=, onSelect=fn, submenu={...}, disabled=bool,
--           checked=bool, divider=true}, ... }
function O.menu(x, y, items, opts)
  menus = { { x = x, y = y, items = items, dark = opts and opts.dark, width = opts and opts.width } }
end

function O.closeMenus() menus = {} end

-- Screen rect of a visible menu item by label (for scripted UI tests).
function O.menuItemRect(label)
  for i = #menus, 1, -1 do
    for _, r in ipairs(menus[i].itemRects or {}) do
      if r.label == label then return r end
    end
  end
  return nil
end
function O.menuOpen() return #menus > 0 end

local ITEM_H = 40

local function menuWidth(m)
  if m.width then return m.width end
  local w = 112
  for _, it in ipairs(m.items) do
    if not it.divider then
      local iw = ui.textWidth(it.label, 14) + 32 + (it.icon and 36 or 0) + (it.submenu and 28 or 0) + (it.checked ~= nil and 32 or 0)
      if iw > w then w = iw end
    end
  end
  return math.min(w, 420)
end

local function menuHeight(m)
  local h = 16
  for _, it in ipairs(m.items) do h = h + (it.divider and 9 or ITEM_H) end
  return h
end

local function drawMenu(level)
  local m = menus[level]
  local sw, sh = ui.screenSize()
  local w, h = menuWidth(m), menuHeight(m)
  local x, y = m.x, m.y
  if x + w > sw - 4 then x = (m.parentX and m.parentX - w) or (sw - 4 - w) end
  if y + h > sh - 4 then y = math.max(4, sh - 4 - h) end
  m.rect = { x = x, y = y, w = w, h = h }
  if level == 1 then ui.cover(-1e9, -1e9, 2e9, 2e9) else ui.cover(x, y, w, h) end
  local c = theme.c
  local bg = m.dark and theme.hex("#303030") or c.surfaceContainer
  local fg = m.dark and theme.fixed.white or c.onSurface
  ui.shadow(x, y, w, h, 4, 2)
  ui.rect("fill", x, y, w, h, 4, bg)
  local yy = y + 8
  m.itemRects = {}
  for i, it in ipairs(m.items) do
    if not it.divider then m.itemRects[#m.itemRects + 1] = { label = it.label, x = x, y = yy, w = w, h = ITEM_H } end
    if it.divider then
      ui.divider(x, yy + 4, w, m.dark and { 1, 1, 1, 0.12 } or c.outlineVariant)
      yy = yy + 9
    else
      local r = ui.region("menu" .. level .. ":" .. i .. ":" .. it.label, x, yy, w, ITEM_H, { cursor = (not it.disabled) and "hand" or nil })
      local col = it.disabled and theme.alpha(fg, 0.38) or fg
      if r.hovered and not it.disabled then ui.rect("fill", x, yy, w, ITEM_H, 0, theme.alpha(fg, 0.08)) end
      local tx = x + 16
      if it.checked ~= nil then
        if it.checked then ui.icon("check", tx, yy + 9, 22, col) end
        tx = tx + 32
      end
      if it.icon then
        ui.icon(it.icon, tx, yy + 8, 24, col)
        tx = tx + 36
      end
      ui.text(it.label, tx, yy, { h = ITEM_H, valign = "middle", color = col, w = x + w - tx - (it.submenu and 32 or 12), ellipsis = true })
      if it.submenu then ui.icon("chevron_right", x + w - 32, yy + 8, 24, col) end
      if not it.disabled then
        if it.submenu and (r.hovered or r.clicked) then
          if not menus[level + 1] or menus[level + 1].items ~= it.submenu then
            for j = #menus, level + 1, -1 do menus[j] = nil end
            menus[level + 1] = { x = x + w - 4, y = yy - 8, items = it.submenu, dark = m.dark, parentX = x + 4 }
          end
        elseif r.hovered and menus[level + 1] and not it.submenu then
          for j = #menus, level + 1, -1 do menus[j] = nil end
        end
        if r.clicked and not it.submenu then
          menus = {}
          if it.onSelect then it.onSelect() end
          return
        end
      end
      yy = yy + ITEM_H
    end
  end
  if menus[level + 1] then
    ui.overlay(function() if menus[level + 1] then drawMenu(level + 1) end end)
  end
  if level == 1 and (ui.mousePressed(1) or ui.mousePressed(2)) then
    -- Close when clicking outside every open menu.
    local mx, my = ui.mouse()
    local inside = false
    for _, mm in ipairs(menus) do
      local rr = mm.rect
      if rr and mx >= rr.x and my >= rr.y and mx < rr.x + rr.w and my < rr.y + rr.h then inside = true end
    end
    if not inside then menus = {} end
  end
end

---------------------------------------------------------------------------
-- Snackbars
---------------------------------------------------------------------------

function O.toast(text, seconds)
  toasts[#toasts + 1] = { text = text, until_ = love.timer.getTime() + (seconds or 4) }
end

local function drawToasts()
  local now = love.timer.getTime()
  local keep = {}
  for _, t in ipairs(toasts) do
    if t.until_ > now then keep[#keep + 1] = t end
  end
  toasts = keep
  local t = toasts[#toasts]
  if not t then return end
  local sw, sh = ui.screenSize()
  local f = theme.font(14)
  local w = math.min(sw - 32, math.max(344, f:getWidth(t.text) + 32))
  local x, y = (sw - w) / 2, sh - 48 - 24
  local fade = math.min(1, (t.until_ - now) * 4)
  ui.cover(x, y, w, 48)
  love.graphics.setColor(0.2, 0.2, 0.2, 0.95 * fade)
  love.graphics.rectangle("fill", x, y, w, 48, 4, 4)
  ui.text(t.text, x + 16, y, { w = w - 32, h = 48, valign = "middle", ellipsis = true, color = { 0.95, 0.95, 0.95, fade } })
end

---------------------------------------------------------------------------
-- Frame hooks
---------------------------------------------------------------------------

-- Queue all overlays for this frame (call after drawing the screen).
function O.draw()
  for i, d in ipairs(dialogs) do
    ui.overlay(function()
      if dialogs[i] == d then drawDialog(d, i == #dialogs) end
    end)
  end
  if #menus > 0 then ui.overlay(function() if menus[1] then drawMenu(1) end end) end
  ui.overlay(drawToasts)
end

-- Escape closes the top menu, then the top dismissible dialog. Returns true
-- when handled.
function O.keypressed(key)
  if key == "escape" then
    if #menus > 0 then
      menus[#menus] = nil
      return true
    end
    local d = dialogs[#dialogs]
    if d and d.dismissible then
      O.closeDialog(d)
      if d.onDismiss then d.onDismiss(d) end
      return true
    end
  end
  if key == "return" or key == "kpenter" then
    local d = dialogs[#dialogs]
    if d and d.onEnter then
      d.onEnter(d)
      return true
    end
  end
  return #dialogs > 0 or #menus > 0
end

return O
