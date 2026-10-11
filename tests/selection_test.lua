-- Box selection hit tests and keeping moved items on the table
-- (src/ui/table/selection.lua).
local sel = require("src.ui.table.selection")
local geo = require("src.core.geometry")

return function(t)
  local WW, WH, M = geo.worldWidth, geo.worldHeight, geo.tablePanMarginFraction
  local EDGE = sel.EDGE_MARGIN

  t.describe("rectFromPoints", function()
    t.it("normalizes any drag direction", function()
      t.eq(sel.rectFromPoints(50, 80, 10, 20), { x = 10, y = 20, w = 40, h = 60 })
    end)
  end)

  t.describe("boxHits", function()
    local box = { x = 100, y = 100, w = 100, h = 100 }

    t.it("hits a box item it touches, misses one beside it", function()
      t.ok(sel.boxHits(box, { x = 190, y = 190, w = 50, h = 50 }))
      t.notOk(sel.boxHits(box, { x = 201, y = 100, w = 50, h = 50 }))
    end)

    t.it("uses the rotated bounding box for turned cards", function()
      -- A 70x100 card centered 40px right of the box edge: unrotated its
      -- half width (35) does not reach; turned 90 degrees (half width 50) it does.
      local card = { cx = 240, cy = 150, hw = 35, hh = 50, angle = 0.0001, x = 205, y = 100, w = 70, h = 100 }
      t.notOk(sel.boxHits(box, card))
      card.angle = math.pi / 2
      t.ok(sel.boxHits(box, card))
    end)

    t.it("tests circles against the closest point of the box", function()
      t.ok(sel.boxHits(box, { cx = 205, cy = 150, circle = 7.5 }))
      -- Diagonal from the corner: ~8.5px away, radius 7.5.
      t.notOk(sel.boxHits(box, { cx = 206, cy = 206, circle = 7.5 }))
    end)
  end)

  t.describe("halfExtents", function()
    t.it("swaps width and height on odd quarter turns", function()
      t.eq({ sel.halfExtents(70, 100, 0) }, { 35, 50 })
      t.eq({ sel.halfExtents(70, 100, 0.25) }, { 50, 35 })
      t.eq({ sel.halfExtents(70, 100, -0.25) }, { 50, 35 })
      t.eq({ sel.halfExtents(70, 100, 0.5) }, { 35, 50 })
      t.eq({ sel.halfExtents(70, 100, 0.75 + 0.5) }, { 50, 35 })
    end)
  end)

  t.describe("clampWorldCenter", function()
    t.it("leaves an item that is fully on the table alone", function()
      t.eq({ sel.clampWorldCenter(1280, 720, 35, 50) }, { 1280, 720 })
    end)

    t.it("pulls items back from all four edges", function()
      local minX, maxX = -M * WW + EDGE + 35, WW * (1 + M) - EDGE - 35
      local minY, maxY = -M * WH + EDGE + 50, WH * (1 + M) - EDGE - 50
      t.eq({ sel.clampWorldCenter(-5000, -5000, 35, 50) }, { minX, minY })
      t.eq({ sel.clampWorldCenter(9000, 9000, 35, 50) }, { maxX, maxY })
    end)

    t.it("uses the turned extents", function()
      local x = sel.clampWorldCenter(-5000, 720, sel.halfExtents(70, 100, 0.25))
      t.eq(x, -M * WW + EDGE + 50)
    end)
  end)
end
