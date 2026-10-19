-- Worker thread body for src/data/pdf_doc_cache.lua: owns one open PDF
-- document for its whole viewing session (unlike image_worker.lua's
-- stateless one-shot file decodes), since PDFium handles shouldn't be
-- touched concurrently from more than one thread -- keeping every call
-- against this document on a single dedicated thread sidesteps that
-- without needing a mutex.
--
-- Protocol (requests channel):
--   { op = "open", path = <string> }
--   { op = "render", index = <0-based int>, pixelWidth = <int> }
--   "quit"
-- Replies (results channel, pushed atomically):
--   "open", true, pageCount, { {w, h}, ... }   -- 1-based, PDF points
--   "open", false, errorMessage
--   "page", index, imageData, nil              -- imageData: love ImageData
--   "page", index, nil, errorMessage
local requests, results = ...

require("love.image")
local pdfRender = require("src.data.pdf_render")
local fs = require("src.data.fs")

local handle

while true do
  local req = requests:demand()
  if req == "quit" then
    pdfRender.closeDocument(handle)
    break
  elseif req.op == "open" then
    local bytes, readErr = fs.readFile(req.path)
    if not bytes then
      results:performAtomic(function(c) c:push("open") c:push(false) c:push(tostring(readErr or "could not read file")) end)
    else
      local h, err = pdfRender.openDocument(bytes)
      if not h then
        results:performAtomic(function(c) c:push("open") c:push(false) c:push(tostring(err)) end)
      else
        handle = h
        local count = pdfRender.pageCount(handle)
        local sizes = {}
        for i = 0, count - 1 do
          local w, hh = pdfRender.pageSize(handle, i)
          sizes[i + 1] = { w or 1, hh or 1 }
        end
        results:performAtomic(function(c)
          c:push("open") c:push(true) c:push(count) c:push(sizes)
        end)
      end
    end
  elseif req.op == "render" then
    if not handle then
      results:performAtomic(function(c) c:push("page") c:push(req.index) c:push(nil) c:push("document not open") end)
    else
      local ok, data, err = pcall(pdfRender.renderPage, handle, req.index, req.pixelWidth)
      if ok and data then
        results:performAtomic(function(c) c:push("page") c:push(req.index) c:push(data) c:push(nil) end)
      else
        results:performAtomic(function(c)
          c:push("page") c:push(req.index) c:push(nil) c:push(tostring((not ok) and data or err))
        end)
      end
    end
  end
end
