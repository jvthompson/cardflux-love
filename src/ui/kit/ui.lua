-- Immediate-mode UI core and basic widgets.
--
-- Everything is drawn and hit-tested in absolute screen coordinates during
-- love.draw. Input arrives through the ui.on* hooks (called from the LÖVE
-- callbacks) and is consumed during the next frame.
--
-- Layers: content drawn later in a frame (dialogs, menus, popups) goes in a
-- higher layer via ui.overlay(fn). Each layer declares the screen area it
-- covers (ui.cover); a widget is hoverable only if its layer was the
-- topmost one under the mouse in the previous frame, so a dialog blocks the
-- screen underneath it.
--
-- Widget ids: pass opts.id when the same label can appear twice at once;
-- otherwise the id defaults to label + position.
local utf8 = require("utf8")
local theme = require("src.ui.kit.theme")

local ui = {}
ui.theme = theme

---------------------------------------------------------------------------
-- Frame + input state
---------------------------------------------------------------------------

local input = {
  mx = 0, my = 0,
  down = {}, pressed = {}, released = {}, clicks = {},
  pressX = {}, pressY = {},
  wheelX = 0, wheelY = 0,
  keys = {},   -- queued { key, scancode, isrepeat } for the focused field
  text = {},   -- queued text input
}
ui.input = input

local layer = 0             -- current layer index this frame
local layerCount = 0
local covers = {}           -- this frame: { layer, x, y, w, h }
local topLayerAtMouse = 0   -- computed from previous frame's covers
local overlays = {}         -- deferred draw functions (each gets its own layer)
local clipStack = {}
local cursor = "arrow"
local cursors = {}
local tooltipText, tooltipId, tooltipSince
local hoveredId
local frameTime = 0
local frameIndex = 0

ui.active = nil       -- id holding the mouse capture
ui.focus = nil        -- focused text field id
local pendingFocus     -- focus request applied at frame end
local focusOrder = {}  -- focusable ids in draw order this frame
local lastFocusOrder = {}
local fieldState = {}  -- per text field: caret, anchor, scrollX
local scrollState = {} -- per scroll view: y, contentH
local widgetState = {} -- misc per-id state (dropdown open etc.)

function ui.state(id)
  local s = widgetState[id]
  if not s then
    s = {}
    widgetState[id] = s
  end
  return s
end

function ui.time() return frameTime end

---------------------------------------------------------------------------
-- Scale: the UI works in logical units; the frame is drawn under
-- love.graphics.scale(theme.scale) (see App.draw).
---------------------------------------------------------------------------

local screenW, screenH = 1280, 720

-- Logical size of the window.
function ui.screenSize() return screenW, screenH end

-- Rounds a logical coordinate down to a whole physical pixel (keeps text
-- crisp at fractional scales).
function ui.snap(v)
  local s = theme.scale
  return math.floor(v * s) / s
end

-- love.graphics.setScissor in logical units (scissors ignore transforms).
local function setScissor(x, y, w, h)
  if not x then return love.graphics.setScissor() end
  local s = theme.scale
  local x1, y1 = math.floor(x * s), math.floor(y * s)
  love.graphics.setScissor(x1, y1, math.max(0, math.ceil((x + w) * s) - x1), math.max(0, math.ceil((y + h) * s) - y1))
end
ui.setScissor = setScissor

---------------------------------------------------------------------------
-- Input hooks (called from LÖVE callbacks)
---------------------------------------------------------------------------

function ui.onMousePressed(x, y, button, presses)
  input.mx, input.my = x, y
  input.down[button] = true
  input.pressed[button] = true
  input.clicks[button] = presses or 1
  input.pressX[button], input.pressY[button] = x, y
end

function ui.onMouseReleased(x, y, button)
  input.mx, input.my = x, y
  input.down[button] = false
  input.released[button] = true
end

function ui.onMouseMoved(x, y)
  input.mx, input.my = x, y
end

function ui.onWheel(dx, dy)
  input.wheelX = input.wheelX + dx
  input.wheelY = input.wheelY + dy
end

-- Returns true when the UI wants this key (a field has focus).
function ui.onKeyPressed(key, scancode, isrepeat)
  if ui.focus then
    input.keys[#input.keys + 1] = { key = key, scancode = scancode, isrepeat = isrepeat }
    return true
  end
  return false
end

function ui.onTextInput(t)
  if ui.focus then
    input.text[#input.text + 1] = t
    return true
  end
  return false
end

-- True when a modal layer (dialog) currently covers everything.
function ui.modalOpen() return ui._modalOpen == true end

---------------------------------------------------------------------------
-- Frame lifecycle
---------------------------------------------------------------------------

function ui.beginFrame(w, h)
  screenW, screenH = w or screenW, h or screenH
  frameTime = love.timer.getTime()
  frameIndex = frameIndex + 1
  layer, layerCount = 0, 0
  covers = { { layer = 0, x = -1e9, y = -1e9, w = 2e9, h = 2e9 } }
  overlays = {}
  clipStack = {}
  focusOrder = {}
  cursor = "arrow"
  hoveredId = nil
  ui._modalOpenNext = false
  love.graphics.setScissor()
end

local function contains(r, x, y)
  return x >= r.x and y >= r.y and x < r.x + r.w and y < r.y + r.h
end

local drawTooltip

function ui.endFrame()
  -- Run overlays; each may queue more (e.g. a submenu).
  local i = 1
  while i <= #overlays do
    layerCount = layerCount + 1
    layer = layerCount
    clipStack = {}
    love.graphics.setScissor()
    overlays[i]()
    i = i + 1
  end
  layer = 0

  drawTooltip()

  -- Topmost layer under the mouse decides next frame's hover.
  topLayerAtMouse = 0
  for _, c in ipairs(covers) do
    if c.layer > topLayerAtMouse and contains(c, input.mx, input.my) then topLayerAtMouse = c.layer end
  end
  ui._modalOpen = ui._modalOpenNext

  -- Release capture when the button goes up.
  if input.released[1] and not input.down[1] then ui.active = nil end

  -- Clicking anywhere outside the focused field unfocuses it.
  if input.pressed[1] and ui.focus and not ui._focusHitThisFrame then ui.focus = nil end
  ui._focusHitThisFrame = false
  if pendingFocus ~= nil then
    ui.focus = pendingFocus ~= false and pendingFocus or nil
    pendingFocus = nil
  end
  lastFocusOrder = focusOrder

  local c = cursors[cursor]
  if c == nil and cursor ~= "arrow" then
    local ok, sc = pcall(love.mouse.getSystemCursor, cursor)
    c = ok and sc or false
    cursors[cursor] = c
  end
  love.mouse.setCursor(c or nil)

  input.pressed, input.released, input.clicks = {}, {}, {}
  input.wheelX, input.wheelY = 0, 0
  input.keys, input.text = {}, {}
end

-- Draw fn later, above everything drawn so far, in its own layer.
function ui.overlay(fn) overlays[#overlays + 1] = fn end

-- Declares that the current layer covers a screen area (blocks layers below).
function ui.cover(x, y, w, h)
  covers[#covers + 1] = { layer = layer, x = x, y = y, w = w, h = h }
end

-- Full-screen modal cover for the current layer.
function ui.coverAll()
  ui.cover(-1e9, -1e9, 2e9, 2e9)
  ui._modalOpenNext = true
end

function ui.layer() return layer end

function ui.setCursor(name) cursor = name end

---------------------------------------------------------------------------
-- Clipping
---------------------------------------------------------------------------

local function currentClip() return clipStack[#clipStack] end

function ui.pushClip(x, y, w, h)
  local c = currentClip()
  if c then
    local x2, y2 = math.min(x + w, c.x + c.w), math.min(y + h, c.y + c.h)
    x, y = math.max(x, c.x), math.max(y, c.y)
    w, h = math.max(0, x2 - x), math.max(0, y2 - y)
  end
  local r = { x = x, y = y, w = w, h = h }
  clipStack[#clipStack + 1] = r
  setScissor(x, y, w, h)
end

function ui.popClip()
  clipStack[#clipStack] = nil
  local c = currentClip()
  if c then
    setScissor(c.x, c.y, c.w, c.h)
  else
    love.graphics.setScissor()
  end
end

---------------------------------------------------------------------------
-- Hit testing
---------------------------------------------------------------------------

-- Is the mouse over this rect, in the active layer, inside the clip?
function ui.hover(x, y, w, h)
  if layer ~= topLayerAtMouse then return false end
  local mx, my = input.mx, input.my
  if mx < x or my < y or mx >= x + w or my >= y + h then return false end
  local c = currentClip()
  if c and not contains(c, mx, my) then return false end
  return true
end

-- True when nothing above the base layer (dialogs, menus, overlays) was
-- under the mouse last frame -- for screens that hit-test on their own.
function ui.baseHasMouse() return topLayerAtMouse == 0 end

function ui.mouse() return input.mx, input.my end
function ui.mouseDown(b) return input.down[b or 1] == true end
function ui.mousePressed(b) return input.pressed[b or 1] == true end
function ui.mouseReleased(b) return input.released[b or 1] == true end
function ui.clickCount(b) return input.clicks[b or 1] or 0 end
function ui.wheel() return input.wheelX, input.wheelY end

function ui.consumeWheel() input.wheelX, input.wheelY = 0, 0 end

-- Generic interactive region. Returns a table:
--   hovered, pressed (this frame, any button), held (mouse captured),
--   clicked (left release inside after pressing inside), rightClicked,
--   doubleClicked.
function ui.region(id, x, y, w, h, opts)
  local r = { hovered = ui.hover(x, y, w, h) }
  if r.hovered then hoveredId = id end
  if r.hovered and input.pressed[1] then
    ui.active = id
    r.pressed = true
    if input.clicks[1] and input.clicks[1] >= 2 then r.doubleClicked = true end
  end
  if r.hovered and input.pressed[2] then r.rightClicked = true end
  r.held = ui.active == id and input.down[1] == true
  if ui.active == id and input.released[1] then
    if r.hovered then r.clicked = true end
  end
  if r.hovered and opts and opts.cursor then ui.setCursor(opts.cursor) end
  if r.hovered and opts and opts.tooltip then ui.tooltip(id, opts.tooltip) end
  return r
end

function ui.defaultId(label, x, y)
  return tostring(label) .. "@" .. math.floor(x) .. "," .. math.floor(y) .. "#" .. layer
end

---------------------------------------------------------------------------
-- Tooltips
---------------------------------------------------------------------------

function ui.tooltip(id, text)
  if tooltipId ~= id then
    tooltipId, tooltipText, tooltipSince = id, text, frameTime
  else
    tooltipText = text
  end
  ui._tooltipSeen = true
end

drawTooltip = function()
  if not ui._tooltipSeen or input.down[1] then
    tooltipId = nil
  end
  ui._tooltipSeen = false
  if tooltipId and frameTime - tooltipSince > 0.5 and tooltipText then
    local f = theme.font(12)
    local w, h = f:getWidth(tooltipText) + 16, f:getHeight() + 8
    local sw, sh = ui.screenSize()
    local x = math.min(input.mx + 12, sw - w - 4)
    local y = input.my + 20
    if y + h > sh then y = input.my - h - 8 end
    love.graphics.setScissor()
    love.graphics.setColor(0.38, 0.38, 0.38, 0.95)
    love.graphics.rectangle("fill", x, y, w, h, 4, 4)
    love.graphics.setColor(1, 1, 1)
    love.graphics.setFont(f)
    love.graphics.print(tooltipText, x + 8, y + 4)
  end
end

---------------------------------------------------------------------------
-- Drawing helpers
---------------------------------------------------------------------------

local setColor = theme.setColor
ui.setColor = setColor

function ui.rect(mode, x, y, w, h, r, color, lineWidth)
  if color then setColor(color) end
  if lineWidth then love.graphics.setLineWidth(lineWidth) end
  love.graphics.rectangle(mode, x, y, w, h, r or 0, r or 0)
  if lineWidth then love.graphics.setLineWidth(1) end
end

-- Text helpers. align: "left" | "center" | "right"; valign "top"|"middle".
function ui.text(str, x, y, opts)
  opts = opts or {}
  local f = opts.font or theme.font(opts.size or 14, opts.weight)
  love.graphics.setFont(f)
  setColor(opts.color or theme.c.onSurface)
  str = tostring(str)
  if opts.w then
    if opts.ellipsis then str = ui.ellipsize(str, f, opts.w) end
    local ty = y
    if opts.h and opts.valign == "middle" then
      local _, lines = f:getWrap(str, opts.w)
      ty = y + (opts.h - #lines * f:getHeight()) / 2
    end
    love.graphics.printf(str, ui.snap(x), ui.snap(ty), opts.w, opts.align or "left")
  else
    local ty = y
    if opts.h and opts.valign == "middle" then ty = y + (opts.h - f:getHeight()) / 2 end
    love.graphics.print(str, ui.snap(x), ui.snap(ty))
  end
  return f
end

function ui.textWidth(str, size, weight) return theme.font(size or 14, weight):getWidth(tostring(str)) end

-- Height of wrapped text in a given width.
function ui.textHeight(str, w, size, weight)
  local f = theme.font(size or 14, weight)
  local _, lines = f:getWrap(tostring(str), w)
  return math.max(1, #lines) * f:getHeight()
end

function ui.ellipsize(str, font, maxW)
  if font:getWidth(str) <= maxW then return str end
  local ell = "…"
  local n = utf8.len(str) or #str
  local lo, hi = 0, n
  while lo < hi do
    local mid = math.ceil((lo + hi) / 2)
    local sub = str:sub(1, (utf8.offset(str, mid + 1) or #str + 1) - 1)
    if font:getWidth(sub .. ell) <= maxW then lo = mid else hi = mid - 1 end
  end
  return str:sub(1, (utf8.offset(str, lo + 1) or #str + 1) - 1) .. ell
end

function ui.icon(name, x, y, size, color)
  local f = theme.iconFont(size or 24)
  love.graphics.setFont(f)
  setColor(color or theme.c.onSurface)
  local g = theme.glyph(name)
  love.graphics.print(g, ui.snap(x), ui.snap(y + (size - f:getHeight()) / 2))
end

-- Icon centered in a box.
function ui.iconCentered(name, x, y, w, h, size, color)
  local f = theme.iconFont(size or 24)
  local g = theme.glyph(name)
  love.graphics.setFont(f)
  setColor(color or theme.c.onSurface)
  love.graphics.print(g, ui.snap(x + (w - f:getWidth(g)) / 2), ui.snap(y + (h - f:getHeight()) / 2))
end

function ui.shadow(x, y, w, h, r, strength)
  strength = strength or 1
  for i = 3, 1, -1 do
    love.graphics.setColor(0, 0, 0, 0.06 * strength)
    love.graphics.rectangle("fill", x - i + 1, y - i + 2, w + 2 * i - 2, h + 2 * i - 1, (r or 0) + i, (r or 0) + i)
  end
end

function ui.divider(x, y, w, color)
  setColor(color or theme.c.outlineVariant)
  love.graphics.rectangle("fill", x, y, w, 1)
end

---------------------------------------------------------------------------
-- Buttons
---------------------------------------------------------------------------

ui.BUTTON_H = 40

-- Natural width of a button.
function ui.buttonWidth(label, opts)
  opts = opts or {}
  local w = ui.textWidth(label, opts.size or 14, "medium") + 48
  if opts.icon then w = w + 26 end
  return w
end

-- variant: "filled" (default) | "outlined" | "text" | "tonal" | "danger"
-- Returns true when clicked.
function ui.button(label, x, y, w, h, opts)
  opts = opts or {}
  h = h or ui.BUTTON_H
  w = w or ui.buttonWidth(label, opts)
  local id = opts.id or ui.defaultId(label, x, y)
  local c = theme.c
  local disabled = opts.disabled
  local r = disabled and { hovered = false } or ui.region(id, x, y, w, h, { cursor = "hand", tooltip = opts.tooltip })
  local variant = opts.variant or "filled"
  local bg, fg, border
  if variant == "filled" then
    bg, fg = c.primary, c.onPrimary
  elseif variant == "tonal" then
    bg, fg = c.secondaryContainer, c.onSecondaryContainer
  elseif variant == "danger" then
    bg, fg = c.error, theme.isDark and theme.hex("#690005") or c.onPrimary
  elseif variant == "outlined" then
    fg, border = c.primary, c.outline
  else
    fg = c.primary
  end
  if opts.color then fg = opts.color end
  if disabled then
    if bg then bg = theme.alpha(c.onSurface, 0.12) end
    fg = c.disabled
    if border then border = theme.alpha(c.onSurface, 0.12) end
  end
  local radius = opts.radius or h / 2
  if bg then ui.rect("fill", x, y, w, h, radius, bg) end
  if border then ui.rect("line", x + 0.5, y + 0.5, w - 1, h - 1, radius, border) end
  if r.hovered or r.held then
    ui.rect("fill", x, y, w, h, radius, theme.alpha(fg, r.held and 0.12 or 0.08))
  end
  local f = theme.font(opts.size or 14, "medium")
  local tw = f:getWidth(label)
  local contentW = tw + (opts.icon and 26 or 0)
  local cx = x + (w - contentW) / 2
  if opts.icon then
    ui.icon(opts.icon, cx, y + (h - 18) / 2, 18, fg)
    cx = cx + 26
  end
  ui.text(label, cx, y, { font = f, color = fg, h = h, valign = "middle" })
  return r.clicked == true and not disabled
end

-- Round icon button (default 40px). Returns true when clicked.
function ui.iconButton(icon, x, y, opts)
  opts = opts or {}
  local size = opts.size or 40
  local id = opts.id or ui.defaultId(icon, x, y)
  local disabled = opts.disabled
  local r = disabled and { hovered = false } or ui.region(id, x, y, size, size, { cursor = "hand", tooltip = opts.tooltip })
  local fg = disabled and theme.c.disabled or (opts.color or theme.c.onSurfaceVariant)
  if opts.background then
    ui.rect("fill", x, y, size, size, size / 2, opts.background)
  end
  if r.hovered or r.held then
    love.graphics.setColor(fg[1], fg[2], fg[3], r.held and 0.16 or 0.1)
    love.graphics.circle("fill", x + size / 2, y + size / 2, size / 2)
  end
  ui.iconCentered(icon, x, y, size, size, opts.iconSize or math.floor(size * 0.6), fg)
  return r.clicked == true and not disabled
end

---------------------------------------------------------------------------
-- Checkbox / switch / segmented
---------------------------------------------------------------------------

-- Returns the (possibly toggled) value.
function ui.checkbox(id, x, y, value, opts)
  opts = opts or {}
  local size = 18
  local label = opts.label
  local w = size + (label and (8 + ui.textWidth(label, 14)) or 0)
  local r = opts.disabled and { hovered = false } or ui.region(id, x - 11, y - 11, w + 22, size + 22, { cursor = "hand", tooltip = opts.tooltip })
  local c = theme.c
  local col = opts.disabled and c.disabled or (value and (opts.color or c.primary) or c.onSurfaceVariant)
  if r.hovered then
    love.graphics.setColor(col[1], col[2], col[3], 0.1)
    love.graphics.circle("fill", x + size / 2, y + size / 2, 20)
  end
  if value then
    ui.rect("fill", x, y, size, size, 2, col)
    setColor(opts.disabled and c.surface or c.onPrimary)
    love.graphics.setLineWidth(2)
    love.graphics.line(x + 4, y + 9, x + 7.5, y + 12.5, x + 14, y + 5.5)
    love.graphics.setLineWidth(1)
  else
    ui.rect("line", x + 1, y + 1, size - 2, size - 2, 2, col, 2)
  end
  if label then ui.text(label, x + size + 8, y, { h = size, valign = "middle", color = opts.disabled and c.disabled or c.onSurface }) end
  if r.clicked and not opts.disabled then return not value end
  return value
end

function ui.switch(id, x, y, value, opts)
  opts = opts or {}
  local w, h = 52, 32
  local r = opts.disabled and { hovered = false } or ui.region(id, x, y, w, h, { cursor = "hand", tooltip = opts.tooltip })
  local c = theme.c
  local alphaMul = opts.disabled and 0.38 or 1
  if value then
    ui.rect("fill", x, y, w, h, h / 2, theme.alpha(c.primary, alphaMul))
    setColor(c.onPrimary, alphaMul)
    love.graphics.circle("fill", x + w - h / 2, y + h / 2, 12)
  else
    ui.rect("fill", x, y, w, h, h / 2, theme.alpha(c.surfaceContainerHighest, alphaMul))
    ui.rect("line", x + 1, y + 1, w - 2, h - 2, h / 2 - 1, theme.alpha(c.outline, alphaMul), 2)
    setColor(c.outline, alphaMul)
    love.graphics.circle("fill", x + h / 2, y + h / 2, 8)
  end
  if r.hovered then
    setColor(c.onSurface, 0.06)
    love.graphics.circle("fill", value and (x + w - h / 2) or (x + h / 2), y + h / 2, 20)
  end
  if r.clicked and not opts.disabled then return not value end
  return value
end

-- Labelled switch row: label on the left, switch on the right of width w.
function ui.switchRow(id, label, x, y, w, value, opts)
  opts = opts or {}
  local col = opts.disabled and theme.c.disabled or theme.c.onSurface
  ui.text(label, x, y, { w = w - 64, h = 32, valign = "middle", color = col })
  if opts.subtitle then
    -- subtitle drawn below; caller reserves the space
    ui.text(opts.subtitle, x, y + 30, { w = w - 64, size = 12, color = theme.c.onSurfaceVariant })
  end
  return ui.switch(id, x + w - 52, y, value, opts)
end

-- Segmented button. options = { {value=, label=}, ... }; returns selected.
-- opts: h, disabled
function ui.segmented(id, x, y, w, options, selected, opts)
  opts = opts or {}
  local h = opts.h or 40
  local n = #options
  local segW = w / n
  local c = theme.c
  for i, o in ipairs(options) do
    local sx = x + (i - 1) * segW
    local r = opts.disabled and { hovered = false } or ui.region(id .. ":" .. i, sx, y, segW, h, { cursor = "hand" })
    local isSel = o.value == selected
    if isSel then ui.rect("fill", sx, y, segW, h, 0, opts.disabled and theme.alpha(c.onSurface, 0.12) or c.secondaryContainer) end
    if r.hovered then ui.rect("fill", sx, y, segW, h, 0, theme.alpha(c.onSurface, 0.06)) end
    local label = o.label
    local tw = ui.textWidth(label, 14, "medium") + (isSel and 26 or 0)
    local tx = sx + (segW - tw) / 2
    local fg = opts.disabled and c.disabled or (isSel and c.onSecondaryContainer or c.onSurface)
    if isSel then
      ui.icon("check", tx, y + (h - 18) / 2, 18, fg)
      tx = tx + 26
    end
    ui.text(label, tx, y, { weight = "medium", h = h, valign = "middle", color = fg })
    if r.clicked then selected = o.value end
  end
  local border = opts.disabled and theme.alpha(c.onSurface, 0.12) or c.outline
  ui.rect("line", x + 0.5, y + 0.5, w - 1, h - 1, h / 2, border)
  for i = 1, n - 1 do
    setColor(border)
    love.graphics.rectangle("fill", math.floor(x + i * segW), y, 1, h)
  end
  return selected
end

---------------------------------------------------------------------------
-- Progress
---------------------------------------------------------------------------

function ui.spinner(cx, cy, radius, color)
  setColor(color or theme.c.primary)
  love.graphics.setLineWidth(math.max(2, radius / 6))
  local t = frameTime * 4
  love.graphics.arc("line", "open", cx, cy, radius, t, t + math.pi * (1.1 + 0.4 * math.sin(frameTime * 2)), 24)
  love.graphics.setLineWidth(1)
end

-- value nil = indeterminate.
function ui.progressBar(x, y, w, h, value, color)
  local c = theme.c
  ui.rect("fill", x, y, w, h, h / 2, theme.alpha(color or c.primary, 0.24))
  setColor(color or c.primary)
  if value then
    love.graphics.rectangle("fill", x, y, w * math.max(0, math.min(1, value)), h, h / 2, h / 2)
  else
    local t = (frameTime * 0.8) % 1.4 - 0.2
    local x0 = x + w * math.max(0, t)
    local x1 = x + w * math.min(1, t + 0.4)
    if x1 > x0 then love.graphics.rectangle("fill", x0, y, x1 - x0, h, h / 2, h / 2) end
  end
end

---------------------------------------------------------------------------
-- Scroll views
---------------------------------------------------------------------------

-- Begin a vertical scroll view. Returns the scroll offset; draw content at
-- (y - offset). Must be paired with ui.endScroll(id, contentHeight).
function ui.beginScroll(id, x, y, w, h)
  local s = scrollState[id]
  if not s then
    s = { y = 0, contentH = 0, target = 0 }
    scrollState[id] = s
  end
  s.x, s.yy, s.w, s.h = x, y, w, h
  s.hovered = ui.hover(x, y, w, h)
  local maxY = math.max(0, s.contentH - h)
  if s.target > maxY then s.target = maxY end
  if s.y > maxY then s.y = maxY end
  ui.pushClip(x, y, w, h)
  return math.floor(s.y)
end

function ui.endScroll(id, contentHeight)
  local s = scrollState[id]
  ui.popClip()
  s.contentH = contentHeight
  local maxY = math.max(0, contentHeight - s.h)
  if s.hovered and input.wheelY ~= 0 and maxY > 0 then
    s.target = math.max(0, math.min(maxY, s.target - input.wheelY * 60))
    input.wheelY = 0
  end
  s.y = s.y + (s.target - s.y) * 0.45
  if math.abs(s.target - s.y) < 0.5 then s.y = s.target end
  if maxY > 0 then
    local trackH = s.h
    local thumbH = math.max(24, trackH * s.h / contentHeight)
    local thumbY = s.yy + (trackH - thumbH) * (s.y / maxY)
    local bx = s.x + s.w - 8
    local r = ui.region(id .. ":thumb", bx - 2, s.yy, 10, trackH)
    if r.pressed then s.dragOffset = input.my - thumbY end
    if r.held and s.dragOffset then
      local ny = input.my - s.dragOffset
      s.target = math.max(0, math.min(maxY, (ny - s.yy) / math.max(1, trackH - thumbH) * maxY))
      s.y = s.target
    end
    setColor(theme.c.onSurface, (r.hovered or r.held) and 0.45 or 0.25)
    love.graphics.rectangle("fill", bx, thumbY, 6, thumbH, 3, 3)
  end
end

function ui.scrollTo(id, y)
  local s = scrollState[id]
  if s then
    s.target = y
    s.y = y
  else
    scrollState[id] = { y = y, target = y, contentH = 0 }
  end
end

function ui.scrollToEnd(id)
  local s = scrollState[id]
  if s then
    s.target = math.max(0, s.contentH - (s.h or 0))
    s.y = s.target
  end
end

function ui.scrollOffset(id)
  local s = scrollState[id]
  return s and s.y or 0
end

---------------------------------------------------------------------------
-- Text fields
---------------------------------------------------------------------------

local function utf8Len(s) return utf8.len(s) or #s end

local function byteOffset(s, charIndex)
  -- byte position after `charIndex` characters (charIndex 0 -> 0)
  if charIndex <= 0 then return 0 end
  local o = utf8.offset(s, charIndex + 1)
  return (o or (#s + 1)) - 1
end

local function sub(s, i, j) -- character substring [i, j) 0-based
  return s:sub(byteOffset(s, i) + 1, byteOffset(s, j))
end

local function isWordChar(ch) return ch:match("[%w_]") ~= nil end

local function wordLeft(text, pos)
  local chars = {}
  for _, c in utf8.codes(text) do chars[#chars + 1] = utf8.char(c) end
  local p = pos
  while p > 0 and not isWordChar(chars[p]) do p = p - 1 end
  while p > 0 and isWordChar(chars[p]) do p = p - 1 end
  return p
end

local function wordRight(text, pos)
  local chars = {}
  for _, c in utf8.codes(text) do chars[#chars + 1] = utf8.char(c) end
  local n, p = #chars, pos
  while p < n and not isWordChar(chars[p + 1]) do p = p + 1 end
  while p < n and isWordChar(chars[p + 1]) do p = p + 1 end
  return p
end

function ui.focusField(id) pendingFocus = id end
function ui.blur() pendingFocus = false end

-- Single-line outlined text field with a floating label.
--   text, changed, submitted = ui.textField(id, x, y, w, text, opts)
-- opts: label, hint, prefix, error (string), disabled, password, maxLength,
--       h (default 48), autofocus, filter (fn(str)->bool for inserted text),
--       selectAllOnFocus, noTab, onTab (fn(shift): replaces Tab traversal)
function ui.textField(id, x, y, w, text, opts)
  opts = opts or {}
  text = text or ""
  local h = opts.h or 48
  local c = theme.c
  local st = fieldState[id]
  if not st then
    st = { caret = utf8Len(text), anchor = nil, scrollX = 0, blink = frameTime }
    fieldState[id] = st
  end
  -- Autofocus whenever the field (re)appears, e.g. a dialog opened again.
  if opts.autofocus and st.lastFrame ~= frameIndex - 1 then pendingFocus = id end
  st.lastFrame = frameIndex
  local n = utf8Len(text)
  if st.caret > n then st.caret = n end
  if st.anchor and st.anchor > n then st.anchor = n end
  if not opts.disabled then focusOrder[#focusOrder + 1] = id end

  local focused = ui.focus == id
  local f = theme.font(opts.size or 16)
  local padX = 12
  local prefixW = opts.prefix and f:getWidth(opts.prefix) or 0
  local innerX = x + padX + prefixW
  local innerW = w - padX * 2 - prefixW - (opts.trailingW or 0)
  local changed, submitted = false, false

  local r = opts.disabled and { hovered = false } or ui.region(id, x, y, w, h, { cursor = "ibeam" })

  local function caretFromMouse(mx)
    local rel = mx - innerX + st.scrollX
    local best, bestD = 0, math.abs(rel)
    local i = 0
    for p, _ in utf8.codes(text) do
      i = i + 1
      local wpx = f:getWidth(text:sub(1, (utf8.offset(text, i + 1) or #text + 1) - 1))
      local d = math.abs(rel - wpx)
      if d < bestD then best, bestD = i, d end
      if wpx > rel + 50 then break end
      local _ = p
    end
    return best
  end

  if r.pressed then
    ui._focusHitThisFrame = true
    if not focused then
      pendingFocus = id
      if opts.selectAllOnFocus then
        st.anchor, st.caret = 0, n
      else
        st.caret = caretFromMouse(input.mx)
        st.anchor = nil
      end
    else
      local pos = caretFromMouse(input.mx)
      if input.clicks[1] and input.clicks[1] >= 2 then
        st.anchor, st.caret = wordLeft(text, pos), wordRight(text, pos)
      elseif love.keyboard.isDown("lshift", "rshift") then
        st.anchor = st.anchor or st.caret
        st.caret = pos
      else
        st.caret, st.anchor = pos, nil
      end
    end
    st.blink = frameTime
  elseif r.held and focused and input.down[1] and not (input.clicks[1] and input.clicks[1] >= 2) then
    local pos = caretFromMouse(input.mx)
    if pos ~= st.caret then
      st.anchor = st.anchor or st.caret
      st.caret = pos
    end
  end
  if focused and r.pressed then ui._focusHitThisFrame = true end

  local function selection()
    if st.anchor == nil or st.anchor == st.caret then return nil end
    return math.min(st.anchor, st.caret), math.max(st.anchor, st.caret)
  end

  local function deleteSelection()
    local a, b = selection()
    if not a then return false end
    text = sub(text, 0, a) .. sub(text, b, utf8Len(text))
    st.caret, st.anchor = a, nil
    changed = true
    return true
  end

  local function insert(s)
    if opts.filter and not opts.filter(s) then return end
    deleteSelection()
    if opts.maxLength and utf8Len(text) + utf8Len(s) > opts.maxLength then
      s = sub(s, 0, math.max(0, opts.maxLength - utf8Len(text)))
    end
    text = sub(text, 0, st.caret) .. s .. sub(text, st.caret, utf8Len(text))
    st.caret = st.caret + utf8Len(s)
    changed = true
  end

  if focused and not opts.disabled then
    ui._focusHitThisFrame = ui._focusHitThisFrame or false
    for _, t in ipairs(input.text) do insert(t) end
    local ctrl = love.keyboard.isDown("lctrl", "rctrl")
    local shift = love.keyboard.isDown("lshift", "rshift")
    for _, k in ipairs(input.keys) do
      local key = k.key
      local len = utf8Len(text)
      local function move(to)
        if shift then st.anchor = st.anchor or st.caret else st.anchor = nil end
        st.caret = math.max(0, math.min(len, to))
      end
      if key == "left" then
        local a = selection()
        if a and not shift then st.caret, st.anchor = a, nil
        else move(ctrl and wordLeft(text, st.caret) or st.caret - 1) end
      elseif key == "right" then
        local _, b = selection()
        if b and not shift then st.caret, st.anchor = b, nil
        else move(ctrl and wordRight(text, st.caret) or st.caret + 1) end
      elseif key == "home" then move(0)
      elseif key == "end" then move(len)
      elseif key == "backspace" then
        if not deleteSelection() and st.caret > 0 then
          local from = ctrl and wordLeft(text, st.caret) or st.caret - 1
          text = sub(text, 0, from) .. sub(text, st.caret, len)
          st.caret = from
          changed = true
        end
      elseif key == "delete" then
        if not deleteSelection() and st.caret < len then
          local to = ctrl and wordRight(text, st.caret) or st.caret + 1
          text = sub(text, 0, st.caret) .. sub(text, to, len)
          changed = true
        end
      elseif ctrl and key == "a" then
        st.anchor, st.caret = 0, len
      elseif ctrl and (key == "c" or key == "x") then
        local a, b = selection()
        if a then
          love.system.setClipboardText(sub(text, a, b))
          if key == "x" then deleteSelection() end
        end
      elseif ctrl and key == "v" then
        local clip = (love.system.getClipboardText() or ""):gsub("[\r\n]+", " ")
        if clip ~= "" then insert(clip) end
      elseif key == "return" or key == "kpenter" then
        submitted = true
      elseif key == "escape" then
        pendingFocus = false
      elseif key == "tab" and opts.onTab then
        opts.onTab(shift)
      elseif key == "tab" and not opts.noTab then
        -- Move focus to the next/previous field (last frame's order).
        local order = #lastFocusOrder > 0 and lastFocusOrder or focusOrder
        for i, fid in ipairs(order) do
          if fid == id then
            local j = shift and i - 1 or i + 1
            if j < 1 then j = #order elseif j > #order then j = 1 end
            pendingFocus = order[j]
            local ns = fieldState[order[j]]
            if ns then ns.anchor, ns.caret = 0, 1e9 end
            break
          end
        end
      end
      st.blink = frameTime
    end
  end

  -- Drawing
  local borderCol = opts.error and c.error or (focused and c.primary or c.outline)
  if opts.disabled then borderCol = theme.alpha(c.onSurface, 0.12) end
  if opts.filled ~= false and opts.background then ui.rect("fill", x, y, w, h, 4, opts.background) end
  ui.rect("line", x + 0.5, y + 0.5, w - 1, h - 1, 4, borderCol, focused and 2 or 1)

  local floatLabel = opts.label and (focused or text ~= "" or opts.prefix)
  if floatLabel then
    local lf = theme.font(12)
    local lw = lf:getWidth(opts.label) + 8
    ui.rect("fill", x + 8, y - 2, lw, 4, 0, opts.labelBackground or c.surface)
    ui.text(opts.label, x + 12, y - lf:getHeight() / 2, { font = lf, color = opts.error and c.error or (focused and c.primary or c.onSurfaceVariant) })
  end

  -- Keep the caret visible.
  local caretPx = f:getWidth(sub(text, 0, st.caret))
  if caretPx - st.scrollX > innerW - 2 then st.scrollX = caretPx - innerW + 2 end
  if caretPx - st.scrollX < 0 then st.scrollX = caretPx end
  if f:getWidth(text) < innerW then st.scrollX = 0 end

  local ty = y + (h - f:getHeight()) / 2
  ui.pushClip(x + 2, y + 2, w - 4, h - 4)
  if opts.prefix then ui.text(opts.prefix, x + padX, ty, { font = f, color = c.onSurfaceVariant }) end
  ui.popClip()
  ui.pushClip(innerX, y + 2, innerW, h - 4)
  local display = opts.password and string.rep("•", utf8Len(text)) or text
  if text == "" and not floatLabel and (opts.label or opts.hint) then
    ui.text(opts.label or opts.hint, innerX, ty, { font = f, color = c.onSurfaceVariant })
  elseif text == "" and opts.hint and focused then
    ui.text(opts.hint, innerX, ty, { font = f, color = theme.alpha(c.onSurfaceVariant, 0.7) })
  end
  local a, b = selection()
  if focused and a then
    local sx = innerX - st.scrollX + f:getWidth(sub(display, 0, a))
    local ex = innerX - st.scrollX + f:getWidth(sub(display, 0, b))
    ui.rect("fill", sx, ty, ex - sx, f:getHeight(), 0, theme.alpha(c.primary, 0.3))
  end
  ui.text(display, innerX - st.scrollX, ty, { font = f, color = opts.disabled and c.disabled or c.onSurface })
  if focused and ((frameTime - st.blink) % 1.0) < 0.55 then
    setColor(c.primary)
    love.graphics.rectangle("fill", math.floor(innerX - st.scrollX + f:getWidth(sub(display, 0, st.caret))), ty, 2, f:getHeight())
  end
  ui.popClip()

  if opts.error and opts.error ~= "" then
    ui.text(opts.error, x + 12, y + h + 4, { size = 12, color = c.error, w = w - 24 })
  end
  return text, changed, submitted
end

-- Height a text field occupies including its error line.
function ui.textFieldHeight(opts)
  return (opts and opts.h or 48) + ((opts and opts.error and opts.error ~= "") and 20 or 0)
end

---------------------------------------------------------------------------
-- Dropdown (select)
---------------------------------------------------------------------------

-- options = { {value=, label=}, ... }. Returns the selected value.
-- opts: label (floating), disabled, h, maxPopupH
function ui.dropdown(id, x, y, w, options, selected, opts)
  opts = opts or {}
  local h = opts.h or 48
  local c = theme.c
  local st = ui.state(id)
  -- A pick made in the popup (drawn later, in an overlay) lands next frame.
  if st.hasPick then
    selected = st.pick
    st.hasPick, st.pick = false, nil
  end
  local current
  for _, o in ipairs(options) do
    if o.value == selected then current = o end
  end
  local r = opts.disabled and { hovered = false } or ui.region(id, x, y, w, h, { cursor = "hand" })
  local border = opts.disabled and theme.alpha(c.onSurface, 0.12) or (st.open and c.primary or c.outline)
  ui.rect("line", x + 0.5, y + 0.5, w - 1, h - 1, 4, border, st.open and 2 or 1)
  if opts.label then
    local lf = theme.font(12)
    ui.rect("fill", x + 8, y - 2, lf:getWidth(opts.label) + 8, 4, 0, opts.labelBackground or c.surface)
    ui.text(opts.label, x + 12, y - lf:getHeight() / 2, { font = lf, color = st.open and c.primary or c.onSurfaceVariant })
  end
  ui.text(current and current.label or (opts.placeholder or ""), x + 12, y, {
    w = w - 48, h = h, valign = "middle", ellipsis = true, size = opts.size or 16,
    color = opts.disabled and c.disabled or (current and c.onSurface or c.onSurfaceVariant),
  })
  ui.iconCentered("arrow_drop_down", x + w - 40, y, 36, h, 24, opts.disabled and c.disabled or c.onSurfaceVariant)
  if r.clicked then st.open = not st.open end

  if st.open then
    local itemH = 40
    local sw, sh = ui.screenSize()
    local popupH = math.min(#options * itemH + 16, opts.maxPopupH or 360, sh - 16)
    local py = y + h + 2
    if py + popupH > sh - 8 then py = math.max(8, y - popupH - 2) end
    local px, pw = x, math.max(w, opts.popupW or 0)
    if px + pw > sw - 8 then px = sw - 8 - pw end
    ui.overlay(function()
      ui.cover(-1e9, -1e9, 2e9, 2e9) -- swallow clicks outside to close
      ui.shadow(px, py, pw, popupH, 4, 2)
      ui.rect("fill", px, py, pw, popupH, 4, c.surfaceContainer)
      local off = ui.beginScroll(id .. ":popup", px, py + 8, pw, popupH - 16)
      local yy = py + 8 - off
      for i, o in ipairs(options) do
        local ir = ui.region(id .. ":opt" .. i, px, yy, pw, itemH, { cursor = "hand" })
        if o.value == selected then ui.rect("fill", px, yy, pw, itemH, 0, theme.alpha(c.primary, 0.12)) end
        if ir.hovered then ui.rect("fill", px, yy, pw, itemH, 0, theme.alpha(c.onSurface, 0.08)) end
        ui.text(o.label, px + 12, yy, { w = pw - 24, h = itemH, valign = "middle", ellipsis = true, color = c.onSurface })
        if ir.clicked then
          st.pick, st.hasPick = o.value, true
          st.open = false
        end
        yy = yy + itemH
      end
      ui.endScroll(id .. ":popup", #options * itemH)
      if input.pressed[1] and not ui.hover(px, py, pw, popupH) and not ui.hoverIgnoringLayer(x, y, w, h) then
        st.open = false
      end
      if input.pressed[2] then st.open = false end
    end)
  end
  return selected
end

function ui.hoverIgnoringLayer(x, y, w, h)
  local mx, my = input.mx, input.my
  return mx >= x and my >= y and mx < x + w and my < y + h
end

return ui
