-- Admin-only "Remove Game" and "Upload New Game" for the Games tab. Removal
-- is a plain request; a new game's .zip is validated locally (so a malformed
-- zip never wastes time uploading), then uploaded to the server's flat
-- staging area (gameId: "" on the existing chunked upload channel -- see
-- src/net/admin_file_manager.lua and server/internal/server/assets.go) and
-- installed there with a follow-up request.
local fs = require("src.data.fs")
local json = require("lib.json")
local proc = require("src.platform.winproc")
local AFM = require("src.net.admin_file_manager")

local M = {}

function M.remove(sc, gameId, onDone)
  sc:request("adminGameDelete", { gameId = gameId }, onDone)
end

local function system32(exe) return fs.join(os.getenv("SystemRoot") or "C:\\Windows", "System32", exe) end

-- Extracts the zip to a throwaway temp folder and checks: exactly one
-- top-level folder, a gamedef.json inside it, and that its "id" matches the
-- folder's name. Returns the id on success, or nil plus an error message.
local function validateZip(zipPath)
  if not fs.isWindows then
    return nil, "Uploading a game from a zip isn't supported on this platform yet."
  end
  local tempDir = fs.join(fs.tempDir(), "cardflux_gamecheck_" .. os.time() .. "_" .. math.random(1000000))
  fs.mkdirs(tempDir)
  local code = proc.run(proc.quoteArg(system32("tar.exe")) .. " -xf " .. proc.quoteArg(zipPath) .. " -C " .. proc.quoteArg(tempDir),
    { wait = true, timeoutMs = 60000 })
  if code ~= 0 then
    fs.removeTree(tempDir)
    return nil, "Couldn't read that zip file."
  end
  local entries = fs.list(tempDir) or {}
  if #entries ~= 1 or not entries[1].isDir then
    fs.removeTree(tempDir)
    return nil, "The zip must contain exactly one folder at its root."
  end
  local folder = entries[1].name
  local raw = fs.readFile(fs.join(tempDir, folder, "gamedef.json"))
  fs.removeTree(tempDir)
  if not raw then
    return nil, "No gamedef.json found inside the folder."
  end
  local def = json.tryDecode(raw)
  if type(def) ~= "table" or type(def.id) ~= "string" or def.id == "" then
    return nil, "gamedef.json is missing an id."
  end
  if def.id ~= folder then
    return nil, string.format('The folder name ("%s") must match the game\'s id ("%s").', folder, def.id)
  end
  return def.id
end

-- Validates the zip locally, then uploads it and asks the server to install
-- it. onProgress(bytesSent, totalBytes); onDone(err, gameId) fires once, err
-- nil on success.
function M.installFromZip(sc, zipPath, onProgress, onDone)
  local id, err = validateZip(zipPath)
  if not id then
    onDone(err)
    return
  end
  for _, g in ipairs(sc.games) do
    if g.id == id then
      onDone('A game with id "' .. id .. '" already exists. Remove it first to replace it.')
      return
    end
  end
  local uploadName = "install_" .. id .. "_" .. os.time() .. ".zip"
  AFM.upload(sc, "", uploadName, zipPath, onProgress, function(upErr)
    if upErr then
      onDone(upErr)
      return
    end
    sc:request("adminGameInstall", { upload = uploadName }, function(r)
      if r.ok then onDone(nil, r.gameId) else onDone(r.message or "Something went wrong.") end
    end)
  end)
end

return M
