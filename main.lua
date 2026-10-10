-- Cardflux (LÖVE port) entry point.

local function runTests(args)
  local filterArg
  for i, a in ipairs(args) do
    if a == "--test" and args[i + 1] and not args[i + 1]:find("^%-%-") then filterArg = args[i + 1] end
  end
  local files = {}
  for _, f in ipairs(love.filesystem.getDirectoryItems("tests")) do
    if f:match("_test%.lua$") then files[#files + 1] = "tests/" .. f end
  end
  table.sort(files)
  local ok = require("tests.runner").run(files, filterArg)
  love.event.quit(ok and 0 or 1)
end

function love.load(args)
  if TEST_MODE then
    runTests(args)
    return
  end
  -- Dev: --identity <name> uses a separate save folder (settings, avatar),
  -- e.g. to run a second instance as another player.
  for i, a in ipairs(args) do
    if a == "--identity" and args[i + 1] then love.filesystem.setIdentity(args[i + 1]) end
  end
  require("src.app").load(args)
end

if not TEST_MODE then
  local app
  local function A()
    app = app or require("src.app")
    return app
  end
  function love.update(dt) A().update(dt) end
  function love.draw() A().draw() end
  function love.keypressed(key, scancode, isrepeat) A().keypressed(key, scancode, isrepeat) end
  function love.keyreleased(key, scancode) A().keyreleased(key, scancode) end
  function love.textinput(text) A().textinput(text) end
  function love.mousepressed(x, y, button, istouch, presses) A().mousepressed(x, y, button, presses) end
  function love.mousereleased(x, y, button) A().mousereleased(x, y, button) end
  function love.mousemoved(x, y, dx, dy) A().mousemoved(x, y, dx, dy) end
  function love.wheelmoved(x, y) A().wheelmoved(x, y) end
  function love.resize(w, h) A().resize(w, h) end
  function love.filedropped(file) A().filedropped(file) end
  function love.directorydropped(path) A().directorydropped(path) end
  function love.focus(f) A().focus(f) end
  function love.quit() return A().quit() end

  -- Same as LÖVE 11's default love.run, except the loop function is kept
  -- out of the JIT: SDL invokes our window hit-test callback (an FFI
  -- callback, see src/platform/window.lua) from inside love.event.pump, and
  -- LuaJIT forbids entering a callback from a C call made by compiled code.
  function love.run()
    if love.load then love.load(love.arg.parseGameArguments(arg), arg) end
    if love.timer then love.timer.step() end
    local dt = 0
    local function loop()
      if love.event then
        love.event.pump()
        for name, a, b, c, d, e, f in love.event.poll() do
          if name == "quit" then
            if not love.quit or not love.quit() then return a or 0 end
          end
          love.handlers[name](a, b, c, d, e, f)
        end
      end
      if love.timer then dt = love.timer.step() end
      if love.update then love.update(dt) end
      if love.graphics and love.graphics.isActive() then
        love.graphics.origin()
        love.graphics.clear(love.graphics.getBackgroundColor())
        if love.draw then love.draw() end
        love.graphics.present()
      end
      if love.timer then love.timer.sleep(0.001) end
    end
    jit.off(loop)
    return loop
  end
end
