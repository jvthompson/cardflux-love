local function hasArg(name)
  for _, a in ipairs(arg or {}) do
    if a == name then return true end
  end
  return false
end

TEST_MODE = hasArg("--test")

-- Windows: declare per-monitor DPI awareness before the window exists, so
-- the window is in real pixels and the app scales its own UI (sharp text)
-- instead of Windows stretching a 96-DPI bitmap. See src/platform/window.lua.
local function enableDpiAwareness()
  local okFfi, ffi = pcall(require, "ffi")
  if not okFfi or ffi.os ~= "Windows" then return end
  pcall(ffi.cdef, [[
    int SetProcessDpiAwarenessContext(void* value);
    int SetProcessDPIAware(void);
  ]])
  local user32 = ffi.load("user32")
  -- DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = (HANDLE)-4 (Windows 10 1703+).
  local ok, res = pcall(function() return user32.SetProcessDpiAwarenessContext(ffi.cast("void*", -4)) end)
  if not ok or res == 0 then pcall(function() user32.SetProcessDPIAware() end) end
end

if not TEST_MODE then pcall(enableDpiAwareness) end

function love.conf(t)
  t.identity = "cardtable"
  t.version = "11.5"
  t.console = false

  t.window.title = "CardTable"
  t.window.width = 1280
  t.window.height = 720
  t.window.minwidth = 960
  t.window.minheight = 600
  t.window.resizable = true
  t.window.borderless = true
  t.window.vsync = 1
  t.window.msaa = 4
  t.window.highdpi = false

  if TEST_MODE then
    -- Separate save directory so tests never touch real settings or data.
    t.identity = "cardtable_tests"
    t.window = false
    t.modules.audio = false
    t.modules.sound = false
    t.modules.joystick = false
  end
  t.modules.physics = false
  t.modules.video = false
  t.modules.joystick = false
end
