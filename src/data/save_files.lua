-- Port of lib/data/save_game_file_ops.dart and game_log_file_ops.dart.
-- Saves live in <gameFolder>/savegames/<name>.json, logs in
-- <gameFolder>/gamelogs/<fileName>.
local json = require("lib.json")
local fs = require("src.data.fs")
local models = require("src.core.models")

local S = {}

local function savesDir(gameFolderPath) return fs.join(gameFolderPath, "savegames") end
local function savePath(gameFolderPath, name) return fs.join(savesDir(gameFolderPath), name .. ".json") end

function S.saveExists(gameFolderPath, name)
  return fs.isFile(savePath(gameFolderPath, name))
end

function S.writeSaveGame(gameFolderPath, name, save)
  fs.mkdirs(savesDir(gameFolderPath))
  local path = savePath(gameFolderPath, name)
  local ok, err = fs.writeFile(path, json.encode(models.SavedGame.toJson(save), { indent = "  " }))
  if not ok then return nil, err end
  return path
end

-- Returns SavedGame, or nil, error.
function S.readSaveGame(filePath)
  local data, err = fs.readFile(filePath)
  if not data then return nil, err end
  local ok, result = pcall(function() return models.SavedGame.fromJson(json.decode(data)) end)
  if not ok then return nil, tostring(result) end
  return result
end

-- Sortable key for an ISO-8601 timestamp (lexicographic order works for the
-- fixed-width "YYYY-MM-DDTHH:MM:SS.fff" form Dart writes).
local function sortKey(iso)
  local t = models.parseIso(iso)
  if not t then return "" end
  return string.format("%04d%02d%02d%02d%02d%02d", t.year, t.month, t.day, t.hour, t.min, t.sec)
    .. (iso:match("%d%d:%d%d:%d%d(%.%d+)") or "")
end

-- Newest first: { {displayName, filePath, savedAt, playerCount}, ... }.
-- Unreadable or foreign JSON files are skipped.
function S.listSaveGames(gameFolderPath)
  local items = fs.list(savesDir(gameFolderPath))
  local out = {}
  for _, e in ipairs(items or {}) do
    if not e.isDir and e.name:lower():sub(-5) == ".json" then
      local path = fs.join(savesDir(gameFolderPath), e.name)
      local save = S.readSaveGame(path)
      if save then
        out[#out + 1] = {
          displayName = fs.stripExtension(e.name),
          filePath = path,
          savedAt = save.savedAt,
          playerCount = #save.state.players,
          _key = sortKey(save.savedAt),
        }
      end
    end
  end
  table.sort(out, function(a, b) return a._key > b._key end)
  return out
end

-- "Saved YYYY-MM-DD HH:MM" text for list rows.
function S.formatSavedAt(iso)
  local t = models.parseIso(iso)
  if not t then return iso end
  return string.format("%04d-%02d-%02d %02d:%02d", t.year, t.month, t.day, t.hour, t.min)
end

-- Auto-generated log file name and contents, as the in-game Save Log
-- button writes them (table_screen.dart _saveLog).
function S.logFileName(nowSeconds)
  return os.date("gamelog_%Y-%m-%d_%H%M%S.txt", nowSeconds or os.time())
end

function S.formatLog(entries)
  local lines = {}
  for i, e in ipairs(entries) do
    lines[i] = "[" .. models.formatElapsedTime(e.elapsedMs) .. "] " .. e.message
  end
  return table.concat(lines, "\n")
end

function S.writeLog(gameFolderPath, fileName, contents)
  local dir = fs.join(gameFolderPath, "gamelogs")
  fs.mkdirs(dir)
  local path = fs.join(dir, fileName)
  local ok, err = fs.writeFile(path, contents)
  if not ok then return nil, err end
  return path
end

return S
