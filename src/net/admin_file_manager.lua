-- Admin-only browsing/upload/delete of a game's folder on the server. List
-- and delete are plain requests on the main connection; upload streams over
-- the asset channel (src/net/admin_upload_worker.lua, on a worker thread) so
-- large files don't block the UI.
local P = require("src.net.protocol")
local fs = require("src.data.fs")

local M = {}

function M.list(sc, gameId, path, onDone)
  sc:request("adminFileList", { gameId = gameId, path = path }, onDone)
end

function M.delete(sc, gameId, path, onDone)
  sc:request("adminFileDelete", { gameId = gameId, path = path }, onDone)
end

-- Jobs in flight, polled from the protocol loop (same shape as asset_sync.lua's Job).
local Job = {}
Job.__index = Job

function Job:update()
  while true do
    local msg = self.channel:pop()
    if msg == nil then break end
    if msg.kind == "progress" then
      if self.onProgress then self.onProgress(msg.bytes, self.total) end
    elseif msg.kind == "done" then
      return self:finish(nil)
    elseif msg.kind == "error" then
      return self:finish(msg.message)
    end
  end
  if not self.thread:isRunning() and self.channel:getCount() == 0 then
    local terr = self.thread:getError()
    self:finish(terr or "The upload stopped unexpectedly.")
  end
end

function Job:finish(err)
  if self.finished then return end
  self.finished = true
  P.unregister(self)
  self.onDone(err)
end

-- Looks up the file's size via a directory listing rather than reading it
-- (the worker thread reads the content itself); 0 on non-Windows, where
-- fs.list can't report sizes (see src/net/asset_worker.lua).
local function localFileSize(path)
  local base = fs.basename(path):lower()
  for _, e in ipairs(fs.list(fs.dirname(path)) or {}) do
    if not e.isDir and e.name:lower() == base then return e.size end
  end
  return 0
end

-- Uploads the local file at `localPath` to `destPath` (slash-separated,
-- relative to the game's folder) in gameId's folder on the server.
-- onProgress(bytesSent, totalBytes) reports progress; onDone(err) is called
-- once, err nil on success.
function M.upload(sc, gameId, destPath, localPath, onProgress, onDone)
  local total = localFileSize(localPath)
  local saved = require("src.net.server_client").savedSession(sc.key)
  local job = setmetatable({ total = total, onProgress = onProgress, onDone = onDone, channel = love.thread.newChannel() }, Job)
  job.thread = love.thread.newThread("src/net/admin_upload_worker.lua")
  job.thread:start({ host = sc.host, port = sc.port, token = sc.token or (saved and saved.token),
    gameId = gameId, path = destPath, localPath = localPath }, job.channel)
  P.register(job)
end

return M
