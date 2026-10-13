-- In-app file/folder picker, replacing the native OS dialog: the native one
-- has an unfixable Windows z-order bug when the window is maximized (a DWM
-- quirk for fullscreen-shaped borderless windows -- see src/platform/
-- file_dialog.lua), and no native implementation at all on Mac. Same `opts`
-- shape as the old dialog (title, filters, initialDir), but this one is an
-- immediate-mode overlay so it can only resolve later, when the user acts:
-- onResult(path) fires exactly once, with the chosen path or nil (cancelled).
local ui = require("src.ui.kit.ui")
local theme = require("src.ui.kit.theme")
local overlays = require("src.ui.kit.overlays")
local fs = require("src.data.fs")

local M = {}

local ROW_H = 40
local LIST_H = 360
local DIALOG_W = 560

local function defaultDir()
  local home = fs.isWindows and os.getenv("USERPROFILE") or os.getenv("HOME")
  if home and fs.isDir(home) then return home end
  return love.filesystem.getWorkingDirectory()
end

local function extensionSet(filters)
  if not filters then return nil end
  local set = {}
  for _, f in ipairs(filters) do
    for _, ext in ipairs(f.extensions) do set["." .. ext:lower()] = true end
  end
  return set
end

-- fs.list's entries, directories first (always shown, so the user can keep
-- navigating), then files filtered by `exts` (nil = unfiltered), skipped
-- entirely in folder-pick mode.
local function listEntries(dir, exts, foldersOnly)
  local items = fs.list(dir)
  if not items then return nil end
  local dirs, files = {}, {}
  for _, e in ipairs(items) do
    if e.isDir then
      dirs[#dirs + 1] = e
    elseif not foldersOnly and (not exts or exts[fs.extension(e.name)]) then
      files[#files + 1] = e
    end
  end
  for _, f in ipairs(files) do dirs[#dirs + 1] = f end
  return dirs
end

-- opts: title, folder (bool), filters ({ {name=, extensions={...}}, ... }), initialDir
local function open(opts, onResult)
  local exts = extensionSet(not opts.folder and opts.filters or nil)
  local st = {
    dir = (opts.initialDir and fs.isDir(opts.initialDir)) and opts.initialDir or defaultDir(),
    pathText = nil, error = nil, entries = {},
  }
  local done = false
  local function finish(path)
    if done then return end
    done = true
    onResult(path)
  end

  local function navigate(dir)
    local items = listEntries(dir, exts, opts.folder)
    if not items then
      overlays.toast("Can't open that folder.", 2)
      return
    end
    st.dir, st.entries, st.error, st.pathText = dir, items, nil, nil
  end
  navigate(st.dir)

  return overlays.dialog({
    title = opts.title or (opts.folder and "Choose a Folder" or "Choose a File"),
    width = DIALOG_W,
    onDismiss = function() finish(nil) end,
    content = function(_, x, y, w)
      local c = theme.c
      local yy = y

      if ui.iconButton("arrow_upward", x, yy, { tooltip = "Up one level", id = "filepicker:up" }) then
        navigate(fs.dirname(st.dir))
      end
      if ui.iconButton("refresh", x + 44, yy, { tooltip = "Refresh", id = "filepicker:refresh" }) then
        navigate(st.dir)
      end
      local fieldOpts = { h = 40, error = st.error }
      local text, _, submitted = ui.textField("filepicker:path", x + 92, yy, w - 92, st.pathText or st.dir, fieldOpts)
      st.pathText = text
      if submitted then
        if fs.isDir(text) then
          navigate(text)
        else
          st.error = "Not a folder."
        end
      end
      yy = yy + ui.textFieldHeight(fieldOpts) + 8
      ui.divider(x, yy, w)
      yy = yy + 8

      local listTop = yy
      local off = ui.beginScroll("filepicker:list", x, listTop, w, LIST_H)
      local ry = listTop - off
      for i, e in ipairs(st.entries) do
        local r = ui.region("filepicker:item" .. i, x, ry, w, ROW_H, { cursor = "hand" })
        if r.hovered then ui.rect("fill", x, ry, w, ROW_H, 0, theme.alpha(c.onSurface, 0.08)) end
        ui.icon(e.isDir and "folder" or "insert_drive_file", x + 8, ry + (ROW_H - 20) / 2, 20, c.onSurfaceVariant)
        ui.text(e.name, x + 40, ry, { h = ROW_H, valign = "middle", w = w - 56, ellipsis = true })
        if r.clicked then
          if e.isDir then
            navigate(fs.join(st.dir, e.name))
          else
            finish(fs.join(st.dir, e.name))
          end
        end
        ry = ry + ROW_H
      end
      ui.endScroll("filepicker:list", #st.entries * ROW_H)

      return (listTop - y) + LIST_H
    end,
    actions = opts.folder and {
      { label = "Cancel", variant = "text", onClick = function() finish(nil) end },
      { label = "Select This Folder", variant = "filled", onClick = function() finish(st.dir) end },
    } or {
      { label = "Cancel", variant = "text", onClick = function() finish(nil) end },
    },
  })
end

function M.openFile(opts, onResult)
  opts = opts or {}
  opts.folder = false
  return open(opts, onResult)
end

function M.pickFolder(opts, onResult)
  opts = opts or {}
  opts.folder = true
  return open(opts, onResult)
end

return M
