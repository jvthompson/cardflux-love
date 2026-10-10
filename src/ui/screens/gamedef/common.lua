-- Helpers shared by the Game Definition Editor's tabs.
--
-- The editor works on a GameDefinition holding BARE image file names (see
-- gamedef_ops.loadGameDefFile); anything that renders an image builds a
-- display-only copy with resolved paths, never stored back.
local ui = require("src.ui.kit.ui")
local theme = require("src.ui.kit.theme")
local overlays = require("src.ui.kit.overlays")
local fs = require("src.data.fs")
local ops = require("src.data.gamedef_ops")
local resolver = require("src.data.image_resolver")
local imageCache = require("src.data.image_cache")
local fileDialog = require("src.platform.file_dialog")

local C = {}

-- Stable per-object key for widget ids: list items keep their text field
-- state across reorders and across edits to their own (editable) ids.
local keys = setmetatable({}, { __mode = "k" })
local nextKey = 0
function C.keyOf(obj)
  local k = keys[obj]
  if not k then
    nextKey = nextKey + 1
    k = "o" .. nextKey
    keys[obj] = k
  end
  return k
end

C.orientationOptions = {
  { value = "portrait", label = "portrait" },
  { value = "left", label = "left" },
  { value = "right", label = "right" },
}

C.imageFilters = { { name = "Images", extensions = ops.imageFilterList } }

-- A copy of card with its image path resolved for drawing.
function C.displayCard(folderPath, card)
  if card.imagePath == nil then return card end
  local copy = {}
  for k, v in pairs(card) do copy[k] = v end
  copy.imagePath = resolver.resolveBareImagePath(folderPath, card.imagePath, card.setId)
  return copy
end

function C.displayCardBacks(folderPath, cardBacks)
  local out = {}
  for i, b in ipairs(cardBacks) do
    if b.imagePath == nil then
      out[i] = b
    else
      out[i] = { id = b.id, name = b.name, orientation = b.orientation,
        imagePath = resolver.resolveBareImagePath(folderPath, b.imagePath) }
    end
  end
  return out
end

-- Picks an image file and copies it into destFolder; returns its bare file
-- name, or nil when cancelled or the copy failed (with a snackbar).
function C.chooseImage(destFolder, correctCardOrientation)
  local path = fileDialog.openFile({ title = "Choose Image", filters = C.imageFilters })
  if not path then return nil end
  local ok, fileName, err = pcall(ops.copyPickedImage, path, destFolder, correctCardOrientation)
  if not ok or not fileName then
    overlays.toast("Could not copy that image: " .. tostring(ok and err or fileName))
    return nil
  end
  -- The copy may have replaced a file the caches already hold.
  imageCache.invalidate(fs.join(destFolder, fileName))
  resolver.clearCache()
  return fileName
end

-- Grey helper text wrapped to w; returns its height.
function C.helpText(text, x, y, w)
  ui.text(text, x, y, { w = w, size = 12, color = theme.c.onSurfaceVariant })
  return ui.textHeight(text, w, 12)
end

-- A bold section heading; returns its height.
function C.heading(text, x, y, w)
  ui.text(text, x, y, { weight = "bold", w = w, ellipsis = true })
  return 20
end

-- Port of SwitchListTile: title and optional wrapped subtitle on the left,
-- a switch on the right. Returns (value, height).
function C.switchTile(id, title, subtitle, x, y, w, value, opts)
  opts = opts or {}
  local c = theme.c
  local tw = w - 52 - 16
  local subH = subtitle and ui.textHeight(subtitle, tw, 12) or 0
  local h = math.max(48, 8 + 20 + subH + 8)
  local disabled = opts.disabled
  ui.text(title, x, y + 8, { w = tw, color = disabled and c.disabled or c.onSurface })
  if subtitle then
    ui.text(subtitle, x, y + 28, { w = tw, size = 12, color = disabled and c.disabled or c.onSurfaceVariant })
  end
  value = ui.switch(id, x + w - 52, y + (h - 32) / 2, value, { disabled = disabled })
  return value, h
end

-- Draws an image into a box: "contain" (whole image, letterboxed) or
-- "cover" (fills, cropped). quarterTurns rotates it in place. Returns
-- true when drawn, false when missing/broken (caller draws a fallback),
-- or "loading".
function C.drawImageInBox(path, x, y, w, h, fit, quarterTurns)
  if not path then return false end
  local img = imageCache.get(path)
  if not img then
    return imageCache.status(path) == "loading" and "loading" or false
  end
  local iw, ih = img:getDimensions()
  local turned = quarterTurns ~= nil and quarterTurns % 2 == 1
  local bw, bh = turned and ih or iw, turned and iw or ih
  local s = fit == "cover" and math.max(w / bw, h / bh) or math.min(w / bw, h / bh)
  if fit == "cover" then ui.pushClip(x, y, w, h) end
  love.graphics.setColor(1, 1, 1)
  love.graphics.draw(img, x + w / 2, y + h / 2, (quarterTurns or 0) * math.pi / 2, s, s, iw / 2, ih / 2)
  if fit == "cover" then ui.popClip() end
  return true
end

-- The card-sized (70x100) thumbnail box used by the card-back rows: the
-- image cover-fit, or an icon when there's none / it can't load.
function C.imagePreviewBox(path, x, y, w, h)
  local c = theme.c
  local drawn = C.drawImageInBox(path, x + 1, y + 1, w - 2, h - 2, "cover")
  if drawn ~= true and drawn ~= "loading" then
    ui.iconCentered(path and "broken_image" or "image_not_supported", x, y, w, h, 24, c.outline)
  end
  ui.rect("line", x + 0.5, y + 0.5, w - 1, h - 1, 6, c.outline)
end

-- ExpansionTile-style header. Returns (clicked, hovered).
function C.expansionHeader(id, x, y, w, h)
  local r = ui.region(id, x, y, w, h, { cursor = "hand" })
  if r.hovered then ui.rect("fill", x, y, w, h, 8, theme.alpha(theme.c.onSurface, 0.04)) end
  return r.clicked == true
end

-- -, quantity, + and a remove button for a quantity row ending at right.
-- Returns (newQuantity, removeClicked). opts: removeTooltip, disabled.
function C.stepper(id, right, y, quantity, opts)
  opts = opts or {}
  local x = right - 40 - 40 - 24 - 40
  local q = quantity
  local off = opts.disabled
  if ui.iconButton("remove", x, y, { id = id .. ":dec", disabled = off or quantity <= 1 }) then q = quantity - 1 end
  ui.text(tostring(quantity), x + 40, y, { w = 24, h = 40, align = "center", valign = "middle",
    color = off and theme.c.disabled or theme.c.onSurface })
  if ui.iconButton("add", x + 64, y, { id = id .. ":inc", disabled = off }) then q = quantity + 1 end
  local removed = ui.iconButton("close", x + 104, y, { id = id .. ":rm", tooltip = opts.removeTooltip, disabled = off })
  return q, removed
end
C.stepperWidth = 40 + 24 + 40 + 40

return C
