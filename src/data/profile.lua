-- Player profile, reconnect, Discord-token and theme settings, plus avatar
-- file handling. Ports of player_profile_settings.dart,
-- player_avatar_file_ops.dart, avatar_image_utils.dart,
-- reconnect_settings.dart, discord_auth_settings.dart and
-- theme_mode_settings.dart.
local fs = require("src.data.fs")
local settings = require("src.data.settings")
local paths = require("src.data.paths")

local P = {}
local K = settings.keys

function P.getName() return settings.get(K.playerName) end
function P.setName(name) settings.set(K.playerName, name) end
function P.getColor() return settings.get(K.playerColor) end
function P.setColor(c) settings.set(K.playerColor, c) end
function P.getAvatarPath() return settings.get(K.playerAvatarPath) end

function P.setAvatarPath(path)
  if path == nil then settings.remove(K.playerAvatarPath) else settings.set(K.playerAvatarPath, path) end
end

-- Reconnect: only the most recent host and the id it assigned are kept.
function P.getReconnectPlayerIdFor(hostKey)
  if settings.get(K.reconnectHostKey) ~= hostKey then return nil end
  return settings.get(K.reconnectPlayerId)
end

function P.saveReconnect(hostKey, playerId)
  settings.set(K.reconnectHostKey, hostKey)
  settings.set(K.reconnectPlayerId, playerId)
end

-- Recently joined hosts/servers, most recent first: { {host=, port=}, ... }.
local MAX_RECENT_SERVERS = 5

function P.getRecentServers()
  local out = {}
  local list = settings.get(K.recentServers)
  if type(list) ~= "table" then return out end
  for _, e in ipairs(list) do
    if type(e) == "table" and type(e.host) == "string" and tonumber(e.port) then
      out[#out + 1] = { host = e.host, port = tonumber(e.port) }
    end
  end
  return out
end

function P.addRecentServer(host, port)
  local list = { { host = host, port = port } }
  for _, e in ipairs(P.getRecentServers()) do
    if #list >= MAX_RECENT_SERVERS then break end
    if not (e.host == host and e.port == port) then list[#list + 1] = e end
  end
  settings.set(K.recentServers, list)
end

function P.removeRecentServer(host, port)
  local list = {}
  for _, e in ipairs(P.getRecentServers()) do
    if not (e.host == host and e.port == port) then list[#list + 1] = e end
  end
  settings.set(K.recentServers, list)
end

function P.getDiscordRefreshToken() return settings.get(K.discordRefreshToken) end
function P.saveDiscordRefreshToken(token) settings.set(K.discordRefreshToken, token) end
function P.clearDiscordRefreshToken() settings.remove(K.discordRefreshToken) end

function P.getDarkMode() return settings.get(K.darkMode, false) end
function P.setDarkMode(v) settings.set(K.darkMode, v) end

---------------------------------------------------------------------------
-- Avatar files
---------------------------------------------------------------------------

P.avatarMaxDimension = 256

-- Any image -> PNG bytes with the longer side capped at 256px.
function P.resizeAvatarBytes(sourceBytes)
  local imageUtils = require("src.data.image_utils")
  local data, err = imageUtils.decodeBytes(sourceBytes, "avatar")
  if not data then return nil, err end
  return imageUtils.encodePng(imageUtils.downscaleToFit(data, P.avatarMaxDimension))
end

local function clearExisting(dir)
  for _, e in ipairs(fs.list(dir) or {}) do
    if not e.isDir and e.name:sub(1, 7) == "avatar." then fs.remove(fs.join(dir, e.name)) end
  end
end

-- Resizes and stores the picked image as <supportDir>/avatar/avatar.png,
-- returning that path (or nil, error). `dir` overrides the folder (tests).
function P.saveAvatar(sourcePath, dir)
  dir = dir or paths.avatarDir()
  local bytes, err = fs.readFile(sourcePath)
  if not bytes then return nil, err end
  local png, rerr = P.resizeAvatarBytes(bytes)
  if not png then return nil, rerr end
  fs.mkdirs(dir)
  clearExisting(dir)
  local dest = fs.join(dir, "avatar.png")
  local ok, werr = fs.writeFile(dest, png)
  if not ok then return nil, werr end
  return dest
end

function P.deleteAvatar(dir)
  clearExisting(dir or paths.avatarDir())
end

-- Raw PNG bytes of the current avatar, or nil.
function P.readAvatarBytes()
  local p = P.getAvatarPath()
  if not p then return nil end
  return fs.readFile(p)
end

return P
