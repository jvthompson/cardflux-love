-- Worker thread body for src/data/image_cache.lua: decodes image files off
-- the main thread. Receives { key, path, maxDim } on the request channel and
-- replies on the result channel with an atomic pair: the key, then either
-- the decoded ImageData or an error string.
local requests, results = ...

require("love.image")
require("love.filesystem")
local imageUtils = require("src.data.image_utils")

while true do
  local req = requests:demand()
  if req == "quit" then break end
  local ok, data, err = pcall(imageUtils.decodeFile, req.path)
  if ok and data then
    if req.maxDim then
      local ok2, scaled = pcall(imageUtils.downscaleToFit, data, req.maxDim)
      if ok2 then data = scaled end
    end
    results:performAtomic(function(c) c:push(req.key) c:push(data) end)
  else
    local message = tostring(ok and err or data)
    results:performAtomic(function(c) c:push(req.key) c:push(message) end)
  end
end
