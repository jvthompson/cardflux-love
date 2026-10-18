-- Well-known locations. Port of lib/data/app_directory.dart and the
-- games/decks directory settings.
local fs = require("src.data.fs")
local settings = require("src.data.settings")

local P = {}

-- Folder holding the executable (fused build) or the project source folder
-- (running `love .` during development).
function P.appDir()
  if love.filesystem.isFused() then
    return fs.normalize(love.filesystem.getSourceBaseDirectory())
  end
  return fs.normalize(love.filesystem.getSource())
end

-- LÖVE's per-user save directory (absolute), the analog of Flutter's
-- application-support directory.
function P.supportDir()
  -- LÖVE creates the save directory lazily; make sure it exists before
  -- anything writes into it by absolute path.
  local dir = fs.normalize(love.filesystem.getSaveDirectory())
  fs.mkdirs(dir)
  return dir
end

function P.defaultGamesDir() return fs.join(P.appDir(), "game_library") end
function P.defaultDecksDir() return fs.join(P.appDir(), "deck_library") end

local function isAbsolute(p)
  if type(p) ~= "string" then return false end
  if fs.isWindows then return p:match("^%a:[/\\]") ~= nil or p:match("^[/\\][/\\]") ~= nil end
  return p:sub(1, 1) == "/"
end
P.isAbsolute = isAbsolute

-- A saved library path is only used when it's absolute; anything else
-- (e.g. a bare folder name from an earlier file-dialog bug) falls back to
-- the default.
local function savedDir(key, default)
  local v = settings.get(key)
  if isAbsolute(v) then return v end
  return default
end

function P.gamesDir() return savedDir(settings.keys.gamesDirectoryPath, P.defaultGamesDir()) end

function P.setGamesDir(path)
  assert(isAbsolute(path), "library path must be absolute: " .. tostring(path))
  settings.set(settings.keys.gamesDirectoryPath, path)
end

function P.decksDir() return savedDir(settings.keys.decksDirectoryPath, P.defaultDecksDir()) end

function P.setDecksDir(path)
  assert(isAbsolute(path), "library path must be absolute: " .. tostring(path))
  settings.set(settings.keys.decksDirectoryPath, path)
end

function P.avatarDir() return fs.join(P.supportDir(), "avatar") end

-- One-time carry-over from a previous app identity (e.g. after a rename):
-- copies settings.json/avatar/etc. from the old save folder into the new
-- one. No-ops once the new folder has its own settings.json, and never
-- deletes the old folder.
function P.migrateLegacyIdentity(oldIdentity)
  local newDir = P.supportDir()
  if fs.exists(fs.join(newDir, "settings.json")) then return end
  local oldDir = fs.join(fs.dirname(newDir), oldIdentity)
  if not fs.exists(oldDir) then return end
  fs.copyTree(oldDir, newDir)
end

return P
