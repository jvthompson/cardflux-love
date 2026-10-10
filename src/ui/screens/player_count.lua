-- Ports of player_count_screen.dart (host: 2-4 players) and
-- practice_player_count_screen.dart (practice: 1-4 decks).
local ui = require("src.ui.kit.ui")

local S = {}
S.__index = S

local function app() return require("src.app") end

function S.new(title, question, counts, labelFor, onChoose)
  return setmetatable({ title = title, question = question, counts = counts, labelFor = labelFor, onChoose = onChoose }, S)
end

function S.practice()
  return S.new("Practice Offline", "How many decks?", { 1, 2, 3, 4 },
    function(n) return n == 1 and "1 Player" or (n .. " Players") end,
    function(n) app().push(require("src.ui.screens.practice_select").new(n)) end)
end

function S.host()
  return S.new("Host Game", "How many players?", { 2, 3, 4 },
    function(n) return n .. " Players" end,
    function(n) app().push(require("src.ui.screens.multiplayer").HostSetup.new(n)) end)
end

function S:draw(x, y, w, h)
  local colW = 312
  local total = 20 + 24 + #self.counts * 60
  local cx = math.floor(x + (w - colW) / 2)
  local yy = math.floor(y + (h - total) / 2)
  ui.text(self.question, cx, yy, { weight = "bold", w = colW, align = "center" })
  yy = yy + 20 + 24
  for _, n in ipairs(self.counts) do
    if ui.button(self.labelFor(n), cx, yy, colW, 48, { variant = "filled", id = "count" .. n }) then self.onChoose(n) end
    yy = yy + 60
  end
end

return S
