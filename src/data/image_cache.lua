-- Lazy, threaded image cache for card art, backs, logos and avatars.
--
--   local img = imageCache.get(path)   -- Image, or nil while loading/failed
--   imageCache.status(path)            -- "ready" | "loading" | "error" | nil
--   imageCache.update()                -- call once per frame (uploads results)
--
-- Decoding runs on worker threads; uploads to the GPU happen on the main
-- thread in update(). Large images are downscaled to `maxDimension` before
-- upload. Least-recently-used entries are released when the estimated VRAM
-- use exceeds `budgetBytes`.
local C = {}

C.maxDimension = 1024
C.budgetBytes = 768 * 1024 * 1024
C.maxUploadsPerFrame = 8

local entries = {}   -- key -> { state, image, bytes, lastUsed, error }
local frame = 0
local usedBytes = 0
local workers, requests, results

local function ensureWorkers()
  if workers then return end
  requests = love.thread.newChannel()
  results = love.thread.newChannel()
  workers = {}
  local n = math.max(1, math.min(4, (love.system.getProcessorCount() or 2) - 1))
  for i = 1, n do
    local t = love.thread.newThread("src/data/image_worker.lua")
    t:start(requests, results)
    workers[i] = t
  end
end

local function makeImage(data)
  local img = love.graphics.newImage(data, { mipmaps = true })
  img:setFilter("linear", "linear", 4)
  img:setMipmapFilter("linear")
  return img
end

local function sizeOf(img)
  local w, h = img:getDimensions()
  return math.floor(w * h * 4 * 1.34) -- rgba8 plus mip chain
end

function C.get(path)
  if path == nil then return nil end
  local e = entries[path]
  if e then
    e.lastUsed = frame
    return e.image
  end
  ensureWorkers()
  entries[path] = { state = "loading", lastUsed = frame }
  requests:push({ key = path, path = path, maxDim = C.maxDimension })
  return nil
end

function C.status(path)
  local e = path and entries[path]
  return e and e.state or nil
end

function C.errorFor(path)
  local e = path and entries[path]
  return e and e.error or nil
end

-- Registers an image decoded from in-memory bytes (e.g. a network avatar).
-- Synchronous; the key should be unique per content (e.g. "avatar:<id>").
function C.putBytes(key, bytes)
  C.invalidate(key)
  local imageUtils = require("src.data.image_utils")
  local data, err = imageUtils.decodeBytes(bytes, key)
  if not data then
    entries[key] = { state = "error", error = err, lastUsed = frame }
    return nil
  end
  local img = makeImage(imageUtils.downscaleToFit(data, C.maxDimension))
  local bytesUsed = sizeOf(img)
  usedBytes = usedBytes + bytesUsed
  entries[key] = { state = "ready", image = img, bytes = bytesUsed, lastUsed = frame }
  return img
end

-- Drops a cached entry so the next get() reloads it from disk.
function C.invalidate(key)
  local e = entries[key]
  if not e then return end
  if e.image then
    usedBytes = usedBytes - (e.bytes or 0)
    e.image:release()
  end
  entries[key] = nil
end

function C.clear()
  for key in pairs(entries) do C.invalidate(key) end
end

local function evict()
  if usedBytes <= C.budgetBytes then return end
  local ready = {}
  for key, e in pairs(entries) do
    if e.state == "ready" and e.lastUsed < frame then ready[#ready + 1] = { key = key, used = e.lastUsed } end
  end
  table.sort(ready, function(a, b) return a.used < b.used end)
  for _, r in ipairs(ready) do
    if usedBytes <= C.budgetBytes * 0.8 then break end
    C.invalidate(r.key)
  end
end

function C.update()
  frame = frame + 1
  if not results then return end
  for _ = 1, C.maxUploadsPerFrame do
    local key, payload = results:performAtomic(function(c)
      local k = c:pop()
      if k == nil then return nil end
      return k, c:pop()
    end)
    if key == nil then break end
    local isData = type(payload) == "userdata"
    local e = entries[key]
    if e and e.state == "loading" then
      if isData then
        local ok, img = pcall(makeImage, payload)
        if ok then
          e.state, e.image, e.bytes = "ready", img, sizeOf(img)
          usedBytes = usedBytes + e.bytes
        else
          e.state, e.error = "error", tostring(img)
        end
      else
        e.state, e.error = "error", tostring(payload)
      end
    end
    if isData then payload:release() end
  end
  evict()
end

function C.shutdown()
  if not workers then return end
  for _ = 1, #workers do requests:push("quit") end
  for _, t in ipairs(workers) do t:wait() end
  workers = nil
end

function C.stats()
  local n = 0
  for _ in pairs(entries) do n = n + 1 end
  return { entries = n, usedBytes = usedBytes }
end

return C
