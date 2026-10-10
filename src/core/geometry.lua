-- Port of lib/game/geometry_utils.dart.
local util = require("src.core.util")

local G = {}

G.worldWidth = 2560
G.worldHeight = 1440
G.tablePanMarginFraction = 0.5

function G.worldCenteringOffset(worldW, worldH, viewportW, viewportH)
  return (viewportW - worldW) / 2, (viewportH - worldH) / 2
end

function G.clampCardCenterY(proposedCenterY, tableHeight, cardHeight, margin)
  margin = margin or 10
  local halfCard = cardHeight / 2
  local tableMargin = tableHeight * G.tablePanMarginFraction
  local lower = margin + halfCard - tableMargin
  local upper = tableHeight - margin - halfCard + tableMargin
  if lower > upper then return tableHeight / 2 end
  return util.clamp(proposedCenterY, lower, upper)
end

function G.canonicalToLocalPixel(fx, fy, tableWidth, tableHeight, isMirrored)
  local ux = isMirrored and (1 - fx) or fx
  local uy = isMirrored and (1 - fy) or fy
  return ux * tableWidth, uy * tableHeight
end

function G.localPixelToCanonical(pixelX, pixelY, tableWidth, tableHeight, isMirrored)
  local m = G.tablePanMarginFraction
  local fx = util.clamp(pixelX / tableWidth, -m, 1 + m)
  local fy = util.clamp(pixelY / tableHeight, -m, 1 + m)
  if isMirrored then return 1 - fx, 1 - fy end
  return fx, fy
end

return G
