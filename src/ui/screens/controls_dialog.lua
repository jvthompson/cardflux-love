-- Controls reference dialog, opened from the Game Menu. Renders CONTROLS.md
-- (packed into game.love by tools/build.ps1) so the in-app breakdown and the
-- shipped file never drift apart. Understands the subset of Markdown that
-- file uses: #/##/### headings, pipe tables, "- " bullets, paragraphs and
-- **bold** (shown as plain text, or as a bold line when it is the whole line).
local ui = require("src.ui.kit.ui")
local theme = require("src.ui.kit.theme")
local overlays = require("src.ui.kit.overlays")

local M = {}

local SOURCE = "CONTROLS.md"

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
local function plain(s) return (s:gsub("%*%*", ""):gsub("`", "")) end

local function splitRow(line)
  local cells = {}
  local body = trim(line):gsub("^|", ""):gsub("|$", "")
  for cell in (body .. "|"):gmatch("(.-)|") do cells[#cells + 1] = plain(trim(cell)) end
  return cells
end

-- Markdown text -> list of blocks { kind = "h1"|"h2"|"h3"|"bold"|"p"|"bullet"|"table", ... }.
function M.parse(text)
  local blocks, para, tbl = {}, nil, nil
  local function flush()
    if para then blocks[#blocks + 1] = { kind = "p", text = para } end
    if tbl then blocks[#blocks + 1] = tbl end
    para, tbl = nil, nil
  end
  for raw in (text .. "\n"):gmatch("(.-)\r?\n") do
    local line = trim(raw)
    if line == "" then
      flush()
    elseif line:match("^|") then
      if para then flush() end
      if not line:match("^|[%s%-:|]+$") then -- skip the |---| separator
        local cells = splitRow(line)
        if not tbl then
          tbl = { kind = "table", header = cells, rows = {} }
        else
          tbl.rows[#tbl.rows + 1] = cells
        end
      end
    else
      if tbl then flush() end
      local hashes, rest = line:match("^(#+)%s+(.*)$")
      if hashes then
        flush()
        blocks[#blocks + 1] = { kind = "h" .. math.min(3, #hashes), text = plain(rest) }
      elseif line:match("^%- ") then
        flush()
        blocks[#blocks + 1] = { kind = "bullet", text = plain(line:sub(3)) }
      elseif line:match("^%*%*.*%*%*$") and not line:sub(3, -3):find("%*%*") then
        flush()
        blocks[#blocks + 1] = { kind = "bold", text = line:sub(3, -3) }
      else
        para = para and (para .. " " .. plain(line)) or plain(line)
      end
    end
  end
  flush()
  return blocks
end

local cache = {}

-- Reads and parses a packed Markdown file, cached by path. Shared by any
-- screen that renders one of these files in a dialog (e.g. support_dialog.lua).
function M.loadBlocks(source)
  if not cache[source] then
    local ok, text = pcall(love.filesystem.read, source)
    cache[source] = M.parse((ok and text) or (source .. " is missing from this build."))
  end
  return cache[source]
end

-- Column widths as fractions of the table width, by column count.
local COLS = { [1] = { 1 }, [2] = { 0.34, 0.66 }, [3] = { 0.24, 0.46, 0.30 } }
local CELL_PAD = 8

local function drawTable(b, x, y, w)
  local c = theme.c
  local n = #b.header
  local fr = COLS[n] or {}
  local widths, xs = {}, {}
  local cx = x
  for i = 1, n do
    widths[i] = w * (fr[i] or 1 / n)
    xs[i] = cx
    cx = cx + widths[i]
  end
  local function row(cells, yy, header)
    local h = 0
    local weight = header and "bold" or nil
    for i = 1, n do
      h = math.max(h, ui.textHeight(cells[i] or "", widths[i] - 2 * CELL_PAD, 13, weight))
    end
    h = h + 2 * CELL_PAD
    if header then ui.rect("fill", x, yy, w, h, 0, c.surfaceContainerHighest) end
    for i = 1, n do
      ui.text(cells[i] or "", xs[i] + CELL_PAD, yy + CELL_PAD,
        { w = widths[i] - 2 * CELL_PAD, size = 13, weight = weight, color = header and c.onSurface or c.onSurfaceVariant })
    end
    ui.divider(x, yy + h - 1, w, theme.alpha(c.outline, 0.4))
    return h
  end
  local yy = y + row(b.header, y, true)
  for _, r in ipairs(b.rows) do yy = yy + row(r, yy, false) end
  return yy - y
end

-- Renders a parsed block list (from M.loadBlocks/M.parse) at (x, y) within
-- width w. Returns the height used.
function M.drawBlocks(x, y, w, list)
  local c = theme.c
  local yy = y
  local first = true
  for _, b in ipairs(list) do
    if b.kind == "h1" then
      -- The dialog title already names the page.
    elseif b.kind == "h2" then
      if not first then yy = yy + 20 end
      ui.text(b.text, x, yy, { size = 18, weight = "bold", color = c.primary })
      yy = yy + 30
    elseif b.kind == "h3" then
      yy = yy + 12
      ui.text(b.text, x, yy, { size = 15, weight = "bold", color = c.onSurface })
      yy = yy + 26
    elseif b.kind == "bold" then
      yy = yy + 8
      ui.text(b.text, x, yy, { weight = "bold", color = c.onSurface })
      yy = yy + 24
    elseif b.kind == "bullet" then
      ui.text("•", x + 4, yy, { size = 13, color = c.onSurfaceVariant })
      ui.text(b.text, x + 20, yy, { w = w - 20, size = 13, color = c.onSurfaceVariant })
      yy = yy + ui.textHeight(b.text, w - 20, 13) + 6
    elseif b.kind == "p" then
      ui.text(b.text, x, yy, { w = w, size = 13, color = c.onSurfaceVariant })
      yy = yy + ui.textHeight(b.text, w, 13) + 10
    elseif b.kind == "table" then
      yy = yy + drawTable(b, x, yy, w) + 12
    end
    if b.kind ~= "h1" then first = false end
  end
  return yy - y
end

function M.open()
  local list = M.loadBlocks(SOURCE)
  return overlays.dialog({
    title = "Controls",
    width = 820,
    content = function(_, x, y, w) return M.drawBlocks(x, y, w, list) end,
    actions = { { label = "Done", variant = "filled" } },
  })
end

return M
