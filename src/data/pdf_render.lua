-- PDFium bindings (via LuaJIT FFI) for rendering a PDF rulebook page to a
-- drawable image, the same shape as image_utils.lua's WebP-via-FFI binding:
-- lazily load an optional vendored DLL, soft-fail (nil, message) when it
-- isn't present rather than erroring.
--
-- pdfium.dll is the prebuilt, statically-linked "pdfium-win-x64" release
-- from https://github.com/bblanchon/pdfium-binaries (BSD-3-Clause, see
-- that project's LICENSE -- several third-party components it bundles have
-- their own permissive licenses, listed there too). It has no sibling DLL
-- dependency (only standard Windows system DLLs), unlike libwebp/libsharpyuv.
local ffi = require("ffi")
local fs = require("src.data.fs")

require("love.image")

local P = {}

local BGRA = 4 -- FPDFBitmap_BGRA

local pdfium
local pdfiumTried = false

local function loadPdfium()
  if pdfiumTried then return pdfium end
  pdfiumTried = true
  pcall(ffi.cdef, [[
    typedef void* FPDF_DOCUMENT;
    typedef void* FPDF_PAGE;
    typedef void* FPDF_BITMAP;
    void FPDF_InitLibrary(void);
    FPDF_DOCUMENT FPDF_LoadMemDocument(const void* data_buf, int size, const char* password);
    void FPDF_CloseDocument(FPDF_DOCUMENT document);
    int FPDF_GetPageCount(FPDF_DOCUMENT document);
    FPDF_PAGE FPDF_LoadPage(FPDF_DOCUMENT document, int page_index);
    void FPDF_ClosePage(FPDF_PAGE page);
    double FPDF_GetPageWidth(FPDF_PAGE page);
    double FPDF_GetPageHeight(FPDF_PAGE page);
    FPDF_BITMAP FPDFBitmap_CreateEx(int width, int height, int format, void* first_scan, int stride);
    void FPDFBitmap_FillRect(FPDF_BITMAP bitmap, int left, int top, int width, int height, unsigned long color);
    void FPDF_RenderPageBitmap(FPDF_BITMAP bitmap, FPDF_PAGE page, int start_x, int start_y, int size_x, int size_y, int rotate, int flags);
    uint8_t* FPDFBitmap_GetBuffer(FPDF_BITMAP bitmap);
    int FPDFBitmap_GetStride(FPDF_BITMAP bitmap);
    void FPDFBitmap_Destroy(FPDF_BITMAP bitmap);
  ]])
  -- Look next to the app: the exe folder when fused, the project folder
  -- during development (`love .`) -- same lookup image_utils.lua's
  -- loadWebp() uses.
  local dirs = {}
  local okFused, fused = pcall(love.filesystem.isFused)
  local okDir, dir = pcall(okFused and fused and love.filesystem.getSourceBaseDirectory or love.filesystem.getSource)
  if okDir and dir then dirs[1] = fs.normalize(dir) end

  local candidates = {}
  for _, d in ipairs(dirs) do
    for _, e in ipairs(fs.list(d) or {}) do
      if e.name:lower() == "pdfium.dll" then candidates[#candidates + 1] = fs.join(d, e.name) end
    end
  end
  candidates[#candidates + 1] = "pdfium"

  for _, name in ipairs(candidates) do
    local loaded, lib = pcall(ffi.load, name)
    if loaded then
      pdfium = lib
      break
    end
  end
  if pdfium then pcall(function() pdfium.FPDF_InitLibrary() end) end
  return pdfium
end

function P.available() return loadPdfium() ~= nil end

-- Opens a document from in-memory PDF bytes. Returns a handle (which keeps
-- `bytes` alive internally -- PDFium reads from that buffer lazily during
-- rendering, not just at load time, so it must not be collected first), or
-- nil, message.
function P.openDocument(bytes)
  local lib = loadPdfium()
  if not lib then return nil, "PDF rulebooks need pdfium.dll next to the app" end
  local ok, doc = pcall(lib.FPDF_LoadMemDocument, bytes, #bytes, nil)
  if not ok then return nil, tostring(doc) end
  if doc == nil then return nil, "invalid or unsupported PDF" end
  return { lib = lib, doc = doc, bytes = bytes }
end

function P.closeDocument(handle)
  if not handle then return end
  pcall(function() handle.lib.FPDF_CloseDocument(handle.doc) end)
end

function P.pageCount(handle)
  local ok, n = pcall(handle.lib.FPDF_GetPageCount, handle.doc)
  return (ok and n) or 0
end

-- Page size in PDF points (1/72 inch), metadata-only -- no rasterization.
function P.pageSize(handle, index)
  local lib = handle.lib
  local ok, page = pcall(lib.FPDF_LoadPage, handle.doc, index)
  if not ok or page == nil then return nil end
  local okW, w = pcall(lib.FPDF_GetPageWidth, page)
  local okH, h = pcall(lib.FPDF_GetPageHeight, page)
  pcall(lib.FPDF_ClosePage, page)
  if not (okW and okH) then return nil end
  return w, h
end

-- Renders page `index` to an rgba8 love.image.ImageData `pixelWidth` pixels
-- wide (height follows the page's own aspect ratio). Returns data, or nil,
-- message.
function P.renderPage(handle, index, pixelWidth)
  local lib = handle.lib
  local ok, page = pcall(lib.FPDF_LoadPage, handle.doc, index)
  if not ok or page == nil then return nil, "could not load page" end

  local okW, pw = pcall(lib.FPDF_GetPageWidth, page)
  local okH, ph = pcall(lib.FPDF_GetPageHeight, page)
  if not (okW and okH) or pw <= 0 or ph <= 0 then
    pcall(lib.FPDF_ClosePage, page)
    return nil, "invalid page size"
  end
  local pixelHeight = math.max(1, math.floor(pixelWidth * ph / pw + 0.5))

  -- Let PDFium own the buffer/stride (don't assume stride == width*4).
  local okBmp, bitmap = pcall(lib.FPDFBitmap_CreateEx, pixelWidth, pixelHeight, BGRA, nil, 0)
  if not okBmp or bitmap == nil then
    pcall(lib.FPDF_ClosePage, page)
    return nil, "could not create bitmap"
  end

  local renderOk = pcall(function()
    -- Pages have no inherent background; fill white first so text-only
    -- pages don't show through as transparent/black.
    lib.FPDFBitmap_FillRect(bitmap, 0, 0, pixelWidth, pixelHeight, 0xFFFFFFFF)
    lib.FPDF_RenderPageBitmap(bitmap, page, 0, 0, pixelWidth, pixelHeight, 0, 0)
  end)

  local data
  if renderOk then
    local okBuf, buf = pcall(lib.FPDFBitmap_GetBuffer, bitmap)
    local okStride, stride = pcall(lib.FPDFBitmap_GetStride, bitmap)
    if okBuf and buf ~= nil and okStride then
      local ok2, result = pcall(function()
        local out = love.image.newImageData(pixelWidth, pixelHeight, "rgba8")
        local sp = ffi.cast("uint8_t*", buf)
        local dp = ffi.cast("uint8_t*", out:getFFIPointer())
        for y = 0, pixelHeight - 1 do
          local srcRow, dstRow = y * stride, y * pixelWidth * 4
          for x = 0, pixelWidth - 1 do
            local si, di = srcRow + x * 4, dstRow + x * 4
            dp[di] = sp[si + 2]     -- R <- B
            dp[di + 1] = sp[si + 1] -- G
            dp[di + 2] = sp[si]     -- B <- R
            dp[di + 3] = sp[si + 3] -- A
          end
        end
        return out
      end)
      if ok2 then data = result end
    end
  end

  pcall(lib.FPDFBitmap_Destroy, bitmap)
  pcall(lib.FPDF_ClosePage, page)
  if not data then return nil, "could not render page" end
  return data
end

return P
