-- Image decoding and pixel helpers that work without a window (usable from
-- worker threads and tests). LÖVE decodes PNG/JPEG/BMP/TGA/GIF natively;
-- WebP goes through libwebp via FFI when libwebp.dll (or libwebp.so) is
-- available next to the executable or on the library path.
local ffi = require("ffi")
local fs = require("src.data.fs")

require("love.image")
require("love.filesystem")

local I = {}

---------------------------------------------------------------------------
-- WebP (optional)
---------------------------------------------------------------------------

local webp
local webpTried = false

local function loadWebp()
  if webpTried then return webp end
  webpTried = true
  pcall(ffi.cdef, [[
    uint8_t* WebPDecodeRGBA(const uint8_t* data, size_t size, int* width, int* height);
    void WebPFree(void* ptr);
  ]])
  -- Look next to the app: the exe folder when fused, the project folder
  -- during development (`love .`).
  local dirs = {}
  local okFused, fused = pcall(love.filesystem.isFused)
  local okDir, dir = pcall(okFused and fused and love.filesystem.getSourceBaseDirectory or love.filesystem.getSource)
  if okDir and dir then dirs[1] = fs.normalize(dir) end

  local candidates = {}
  for _, d in ipairs(dirs) do
    for _, e in ipairs(fs.list(d) or {}) do
      local n = e.name:lower()
      -- libwebp depends on libsharpyuv; preloading it by full path lets
      -- Windows resolve that import even though the app folder isn't on
      -- the DLL search path. Names cover vcpkg (libsharpyuv.dll) and
      -- MSYS2 (libsharpyuv-0.dll) builds.
      if n:match("^libsharpyuv.*%.dll$") or n:match("^libsharpyuv.*%.so") then
        pcall(ffi.load, fs.join(d, e.name))
      end
      if n:match("^libwebp%-?%d*%.dll$") or n:match("^libwebp%.so") then
        candidates[#candidates + 1] = fs.join(d, e.name)
      end
    end
  end
  for _, name in ipairs({ "libwebp", "webp" }) do candidates[#candidates + 1] = name end

  for _, name in ipairs(candidates) do
    local loaded, lib = pcall(ffi.load, name)
    if loaded then
      webp = lib
      break
    end
  end
  return webp
end

function I.webpAvailable() return loadWebp() ~= nil end

local function isWebp(bytes)
  return #bytes >= 12 and bytes:sub(1, 4) == "RIFF" and bytes:sub(9, 12) == "WEBP"
end

local function decodeWebp(bytes)
  local lib = loadWebp()
  if not lib then return nil, "WebP images need libwebp.dll next to the app" end
  local w, h = ffi.new("int[1]"), ffi.new("int[1]")
  local px = lib.WebPDecodeRGBA(bytes, #bytes, w, h)
  if px == nil then return nil, "invalid WebP image" end
  local data = love.image.newImageData(w[0], h[0], "rgba8", ffi.string(px, w[0] * h[0] * 4))
  pcall(function() lib.WebPFree(px) end)
  return data
end

---------------------------------------------------------------------------
-- Decoding
---------------------------------------------------------------------------

function I.decodeBytes(bytes, name)
  if isWebp(bytes) then return decodeWebp(bytes) end
  local ok, result = pcall(function()
    return love.image.newImageData(love.filesystem.newFileData(bytes, name or "image"))
  end)
  if ok then return result end
  return nil, tostring(result)
end

-- Returns ImageData, or nil, error.
function I.decodeFile(path)
  local bytes, err = fs.readFile(path)
  if not bytes then return nil, err end
  return I.decodeBytes(bytes, fs.basename(path))
end

---------------------------------------------------------------------------
-- Pixel operations (rgba8 ImageData)
---------------------------------------------------------------------------

local function toRgba8(src)
  if src:getFormat() == "rgba8" then return src end
  local w, h = src:getDimensions()
  local out = love.image.newImageData(w, h, "rgba8")
  out:paste(src, 0, 0, 0, 0, w, h)
  return out
end

-- Rotates 90 degrees clockwise.
function I.rotateClockwise(src)
  src = toRgba8(src)
  local w, h = src:getDimensions()
  local out = love.image.newImageData(h, w, "rgba8")
  local sp = ffi.cast("uint32_t*", src:getFFIPointer())
  local dp = ffi.cast("uint32_t*", out:getFFIPointer())
  -- (x, y) in src -> (h - 1 - y, x) in dst (dst width = h)
  for y = 0, h - 1 do
    local row = y * w
    local dx = h - 1 - y
    for x = 0, w - 1 do
      dp[x * h + dx] = sp[row + x]
    end
  end
  return out
end

-- Area-average downscale so the longer side is at most maxDim. Returns the
-- source unchanged when it already fits.
function I.downscaleToFit(src, maxDim)
  src = toRgba8(src)
  local sw, sh = src:getDimensions()
  local larger = math.max(sw, sh)
  if larger <= maxDim then return src end
  local scale = maxDim / larger
  local tw = math.max(1, math.floor(sw * scale + 0.5))
  local th = math.max(1, math.floor(sh * scale + 0.5))
  local out = love.image.newImageData(tw, th, "rgba8")
  local sp = ffi.cast("uint8_t*", src:getFFIPointer())
  local dp = ffi.cast("uint8_t*", out:getFFIPointer())
  local fx, fy = sw / tw, sh / th
  for ty = 0, th - 1 do
    local y0 = math.floor(ty * fy)
    local y1 = math.max(y0 + 1, math.min(sh, math.floor((ty + 1) * fy)))
    for tx = 0, tw - 1 do
      local x0 = math.floor(tx * fx)
      local x1 = math.max(x0 + 1, math.min(sw, math.floor((tx + 1) * fx)))
      local r, g, b, a, n = 0, 0, 0, 0, 0
      for y = y0, y1 - 1 do
        local base = (y * sw) * 4
        for x = x0, x1 - 1 do
          local i = base + x * 4
          r = r + sp[i]
          g = g + sp[i + 1]
          b = b + sp[i + 2]
          a = a + sp[i + 3]
          n = n + 1
        end
      end
      local o = (ty * tw + tx) * 4
      dp[o] = math.floor(r / n + 0.5)
      dp[o + 1] = math.floor(g / n + 0.5)
      dp[o + 2] = math.floor(b / n + 0.5)
      dp[o + 3] = math.floor(a / n + 0.5)
    end
  end
  return out
end

function I.encodePng(imageData)
  return imageData:encode("png"):getString()
end

---------------------------------------------------------------------------
-- Landscape -> portrait correction for imported card art
---------------------------------------------------------------------------

-- Rotates every landscape image in `paths` 90 degrees clockwise, in place,
-- keeping each file's format. PNG is handled in-process; JPEG goes through
-- one PowerShell/System.Drawing call on Windows (LÖVE can't encode JPEG).
-- Best-effort, like the Flutter version: failures leave files as copied.
function I.rotateLandscapeImages(paths)
  local jpegs = {}
  for _, path in ipairs(paths) do
    local ext = fs.extension(path)
    if ext == ".png" then
      pcall(function()
        local data = I.decodeFile(path)
        if data and data:getWidth() > data:getHeight() then
          fs.writeFile(path, I.encodePng(I.rotateClockwise(data)))
        end
      end)
    elseif ext == ".jpg" or ext == ".jpeg" then
      jpegs[#jpegs + 1] = path
    end
  end
  if #jpegs > 0 and fs.isWindows then I.rotateJpegsWindows(jpegs) end
end

function I.rotateJpegsWindows(paths)
  local listFile = fs.join(fs.tempDir(), "cardflux_rotate_" .. os.time() .. "_" .. math.random(1e6) .. ".txt")
  fs.writeFile(listFile, table.concat(paths, "\r\n"))
  local script = [[
Add-Type -AssemblyName System.Drawing
foreach ($p in [System.IO.File]::ReadAllLines($args[0], [System.Text.Encoding]::UTF8)) {
  if (-not $p) { continue }
  try {
    $bytes = [System.IO.File]::ReadAllBytes($p)
    $ms = New-Object System.IO.MemoryStream(,$bytes)
    $img = [System.Drawing.Image]::FromStream($ms)
    if ($img.Width -gt $img.Height) {
      $img.RotateFlip([System.Drawing.RotateFlipType]::Rotate90FlipNone)
      $img.Save($p, [System.Drawing.Imaging.ImageFormat]::Jpeg)
    }
    $img.Dispose(); $ms.Dispose()
  } catch {}
}
]]
  local scriptFile = listFile:gsub("%.txt$", ".ps1")
  fs.writeFile(scriptFile, "\239\187\191" .. script)
  os.execute('powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' .. scriptFile .. '" "' .. listFile .. '" >NUL 2>&1')
  fs.remove(scriptFile)
  fs.remove(listFile)
end

return I
