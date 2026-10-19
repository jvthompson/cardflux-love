-- Per-open-PDF page cache and its dedicated worker thread (one document =
-- one thread; see pdf_worker.lua's header for why). Mirrors image_cache.lua's
-- decode-off-thread/upload-on-main-thread split, but keyed by page index and
-- stateful (one open document) rather than a pool of one-shot file decodes.
--
--   local c = pdfDocCache.new(path)
--   c:update()                       -- call once per frame while in use
--   c.pageCount, c.pointSizes        -- nil until the "open" reply arrives
--   c.openError                      -- set if the document failed to open
--   c:requestPage(index, pixelWidth) -- 0-based; no-ops once pending/ready
--   c.pages[index].state/.image      -- "pending" | "ready" | "error"
--   c:destroy()                      -- tells the thread to quit
local C = {}
C.__index = C

function C.new(path)
  local self = setmetatable({}, C)
  self.pages = {}
  self.requests = love.thread.newChannel()
  self.results = love.thread.newChannel()
  self.thread = love.thread.newThread("src/data/pdf_worker.lua")
  self.thread:start(self.requests, self.results)
  self.requests:push({ op = "open", path = path })
  return self
end

function C:requestPage(index, pixelWidth)
  local p = self.pages[index]
  if p and (p.state == "pending" or p.state == "ready") then return end
  self.pages[index] = { state = "pending" }
  self.requests:push({ op = "render", index = index, pixelWidth = pixelWidth })
end

function C:update()
  while true do
    local kind = self.results:pop()
    if kind == nil then break end
    if kind == "open" then
      local ok = self.results:pop()
      if ok then
        self.pageCount = self.results:pop()
        self.pointSizes = self.results:pop()
      else
        self.openError = self.results:pop()
      end
    elseif kind == "page" then
      local index = self.results:pop()
      local data = self.results:pop()
      local err = self.results:pop()
      local p = self.pages[index]
      if p then
        if data then
          local ok, img = pcall(love.graphics.newImage, data)
          data:release()
          if ok then p.state, p.image = "ready", img else p.state, p.error = "error", tostring(img) end
        else
          p.state, p.error = "error", err
        end
      elseif data then
        data:release()
      end
    end
  end
end

function C:destroy()
  self.requests:push("quit")
end

return C
