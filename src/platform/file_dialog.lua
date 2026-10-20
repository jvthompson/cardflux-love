-- File / folder pickers, delegating to the in-app picker UI
-- (src/ui/screens/file_picker_dialog.lua). This used to show a native
-- dialog (Vista-style IFileOpenDialog on Windows via COM/FFI, zenity/
-- kdialog on Unix), but the native Windows dialog has an unfixable z-order
-- bug when the app's borderless window is maximized, and there was never a
-- native implementation on Mac at all. D.openFile/D.pickFolder keep this
-- module's require path stable for callers, but are now async: onResult
-- fires once with the chosen path, or nil if cancelled.
local ffi = require("ffi")

local D = {}

local isWindows = ffi.os == "Windows"

-- "C:\..." / "\\server\share" on Windows, "/..." elsewhere.
function D.isAbsolute(path)
  if type(path) ~= "string" then return false end
  if isWindows then return path:match("^%a:[/\\]") ~= nil or path:match("^[/\\][/\\]") ~= nil end
  return path:sub(1, 1) == "/"
end

D.imageFilters = { { name = "Image", extensions = { "jpg", "jpeg", "png", "webp" } } }
D.jsonFilters = { { name = "JSON", extensions = { "json" } } }

-- opts: title, filters ({ {name=, extensions={"png",...}} }), initialDir,
-- multiple (bool). onResult(path) fires once: an absolute path, or nil if
-- cancelled -- or, with opts.multiple, an array of absolute paths (never
-- empty) instead of a single path.
function D.openFile(opts, onResult)
  require("src.ui.screens.file_picker_dialog").openFile(opts, onResult)
end

function D.pickFolder(opts, onResult)
  require("src.ui.screens.file_picker_dialog").pickFolder(opts, onResult)
end

return D
