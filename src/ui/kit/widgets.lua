-- Small composite widgets shared by several screens.
local ui = require("src.ui.kit.ui")
local theme = require("src.ui.kit.theme")
local color = require("src.core.color")
local imageCache = require("src.data.image_cache")

local W = {}

-- Port of avatar_widget.dart: an image (cover-fit) or a solid color square,
-- with a 4px border in the player's color. source: { path = } or
-- { key = cacheKey } for in-memory images registered with imageCache.putBytes.
function W.avatar(x, y, size, argb, source, showBorder)
  local col = { color.toRgba(argb) }
  local img
  if source then img = imageCache.get(source.path or source.key) end
  if img then
    local iw, ih = img:getDimensions()
    local s = math.max(size / iw, size / ih)
    local q = love.graphics.newQuad((iw - size / s) / 2, (ih - size / s) / 2, size / s, size / s, iw, ih)
    love.graphics.setColor(1, 1, 1)
    love.graphics.draw(img, q, x, y, 0, s, s)
    q:release()
  else
    ui.rect("fill", x, y, size, size, 0, col)
  end
  if showBorder ~= false then
    local bw = size >= 100 and 4 or 2
    love.graphics.setLineWidth(bw)
    ui.setColor(col)
    love.graphics.rectangle("line", x + bw / 2, y + bw / 2, size - bw, size - bw)
    love.graphics.setLineWidth(1)
  end
end

-- Orange (warning) / blue (info) message banner; returns height.
function W.banner(text, x, y, w, kind, onClick)
  local col = kind == "info" and theme.fixed.blue or theme.fixed.orange
  local th = ui.textHeight(text, w - 24, 14)
  local h = th + 24
  ui.rect("fill", x, y, w, h, 8, theme.alpha(col, 0.15))
  ui.rect("line", x + 0.5, y + 0.5, w - 1, h - 1, 8, col)
  ui.text(text, x + 12, y + 12, { w = w - 24, color = col })
  if onClick then
    local r = ui.region("banner:" .. text, x, y, w, h, { cursor = "hand" })
    if r.hovered then ui.rect("fill", x, y, w, h, 8, theme.alpha(col, 0.08)) end
    if r.clicked then onClick() end
  end
  return h
end

-- A labelled section heading (bold 14).
function W.heading(text, x, y, opts)
  ui.text(text, x, y, { weight = "bold", size = (opts and opts.size) or 14, color = theme.c.onSurface })
  return 20
end

-- Material-ish card container.
function W.card(x, y, w, h, opts)
  opts = opts or {}
  ui.rect("fill", x, y, w, h, opts.radius or 12, opts.color or theme.c.surfaceContainer)
  if opts.border then ui.rect("line", x + 0.5, y + 0.5, w - 1, h - 1, opts.radius or 12, theme.c.outlineVariant) end
end

-- Port of editor_toolbar.dart: a 56px in-body toolbar under the window
-- title bar, for a screen's own actions. actions = { {icon=, tooltip=,
-- onClick=, id=}, ... } drawn right to left from the end. Returns its height.
W.editorToolbarHeight = 56
function W.editorToolbar(x, y, w, title, actions)
  local c = theme.c
  local h = W.editorToolbarHeight
  ui.rect("fill", x, y, w, h, 0, c.surface)
  ui.rect("fill", x, y + h, w, 1, 0, theme.alpha(c.shadow or { 0, 0, 0, 1 }, 0.12))
  local ax = x + w - 8 - #actions * 48
  ui.text(title, x + 16, y, { size = 16, weight = "medium", h = h, valign = "middle", w = ax - x - 24, ellipsis = true })
  for i, a in ipairs(actions) do
    if ui.iconButton(a.icon, ax + (i - 1) * 48 + 4, y + 8, { tooltip = a.tooltip, id = a.id or ("tb:" .. a.icon), disabled = a.disabled }) then
      a.onClick()
    end
  end
  return h
end

-- Material tab bar: equal-width tabs with a primary underline under the
-- selected one. Returns (selectedIndex, height).
W.tabBarHeight = 48
function W.tabBar(id, x, y, w, labels, selected)
  local c = theme.c
  local h = W.tabBarHeight
  local tw = w / #labels
  for i, label in ipairs(labels) do
    local tx = x + (i - 1) * tw
    local r = ui.region(id .. ":" .. i, tx, y, tw, h, { cursor = "hand" })
    if r.hovered then ui.rect("fill", tx, y, tw, h, 0, theme.alpha(c.onSurface, 0.06)) end
    local isSel = i == selected
    ui.text(label, tx, y, { w = tw, h = h, align = "center", valign = "middle", weight = "medium",
      color = isSel and c.primary or c.onSurfaceVariant })
    if isSel then
      local lw = ui.textWidth(label, 14, "medium")
      ui.rect("fill", tx + (tw - lw) / 2, y + h - 3, lw, 3, 1.5, c.primary)
    end
    if r.clicked then selected = i end
  end
  ui.rect("fill", x, y + h - 1, w, 1, 0, c.outlineVariant)
  return selected, h
end

-- Material filter chip (32px). The leading icon is opts.icon when given,
-- else a check while selected. Returns (clicked, width).
W.chipHeight = 32
function W.chipWidth(label, selected, opts)
  local lead = ((opts and opts.icon) or selected) and 26 or 0
  return ui.textWidth(label, 14, "medium") + 32 + lead
end
function W.chip(label, x, y, selected, opts)
  opts = opts or {}
  local c = theme.c
  local h = W.chipHeight
  local w = W.chipWidth(label, selected, opts)
  local r = ui.region(opts.id or ui.defaultId(label, x, y), x, y, w, h, { cursor = "hand", tooltip = opts.tooltip })
  if selected then
    ui.rect("fill", x, y, w, h, 8, c.secondaryContainer)
  else
    ui.rect("line", x + 0.5, y + 0.5, w - 1, h - 1, 8, c.outline)
  end
  if r.hovered then ui.rect("fill", x, y, w, h, 8, theme.alpha(c.onSurface, 0.08)) end
  local tx = x + 16
  local lead = opts.icon or (selected and "check")
  if lead then
    ui.icon(lead, x + 8, y + 7, 18, selected and c.onSecondaryContainer or c.onSurfaceVariant)
    tx = x + 8 + 18 + 8
  end
  ui.text(label, tx, y, { h = h, valign = "middle", weight = "medium", color = selected and c.onSecondaryContainer or c.onSurface })
  return r.clicked == true, w
end

-- Places chips left to right, wrapping within width w. Returns a function
-- place(width) -> (x, y) and a function bottom() -> y below the last row.
function W.flow(x, y, w, rowH, gap)
  local fx, fy = x, y
  local function place(width)
    if fx + width > x + w and fx > x then
      fx = x
      fy = fy + rowH + gap
    end
    local px = fx
    fx = fx + width + gap
    return px, fy
  end
  return place, function() return fy + rowH end
end

-- Moves list[from] to index `to` (in the list after removal), in place.
function W.moveItem(list, from, to)
  local item = table.remove(list, from)
  table.insert(list, to, item)
end

-- Drag-to-reorder for a vertical list drawn immediate-mode:
--   local ro = W.reorder(id)
--   for i, item ... ro:handle(i, hx, hy, rowY, rowH) end  -- draws a handle
--   local from, to = ro:finish(x, w)  -- drop line; a move on release
-- `to` is the item's index after the move (W.moveItem semantics).
local Reorder = {}
Reorder.__index = Reorder

function W.reorder(id)
  local st = ui.state(id)
  st.rows = {}
  return setmetatable({ id = id, st = st }, Reorder)
end

function Reorder:handle(i, hx, hy, rowY, rowH)
  local st = self.st
  st.rows[i] = { y = rowY, h = rowH }
  local r = ui.region(self.id .. ":h" .. i, hx, hy, 40, 40, { cursor = "sizeall", tooltip = "Drag to reorder" })
  local col = theme.c.onSurfaceVariant
  if r.hovered or st.dragging == i then ui.rect("fill", hx + 4, hy + 4, 32, 32, 16, theme.alpha(col, 0.1)) end
  ui.iconCentered("drag_indicator", hx, hy, 40, 40, 24, col)
  if r.pressed and ui.mousePressed(1) then st.dragging = i end
end

function Reorder:finish(x, w)
  local st = self.st
  local from = st.dragging
  if not from then return nil end
  local rows = st.rows
  if not rows[from] then
    st.dragging = nil
    return nil
  end
  ui.setCursor("sizeall")
  local _, my = ui.mouse()
  -- Insertion slot p in 1..n+1: before the first row whose middle is below.
  local n = #rows
  local p = n + 1
  for i = 1, n do
    if my < rows[i].y + rows[i].h / 2 then
      p = i
      break
    end
  end
  local c = theme.c
  local d = rows[from]
  ui.rect("fill", x, d.y, w, d.h, 8, theme.alpha(c.primary, 0.08))
  local lineY = p <= n and rows[p].y - 4 or rows[n].y + rows[n].h + 2
  ui.rect("fill", x, lineY, w, 3, 1.5, c.primary)
  if not ui.mouseDown(1) then
    st.dragging = nil
    local to = p > from and p - 1 or p
    if to ~= from then return from, to end
  end
  return nil
end

return W
