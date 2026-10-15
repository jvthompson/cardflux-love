-- Rulebook viewer scroll position, persisted per game id (not folderPath,
-- which can change if the user repoints their games directory).
local settings = require("src.data.settings")

local R = {}

local function key(gameId) return "rulebook_scroll_" .. tostring(gameId) end

function R.getScroll(gameId) return tonumber(settings.get(key(gameId))) or 0 end
function R.setScroll(gameId, y) settings.set(key(gameId), y) end

return R
