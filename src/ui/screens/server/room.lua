-- A server game before it starts: the seats (the creator can reorder them
-- and start the game) and the room's chat. When the game starts the server
-- sends gameData, and this screen hands over to the table.
local ui = require("src.ui.kit.ui")
local theme = require("src.ui.kit.theme")
local overlays = require("src.ui.kit.overlays")
local widgets = require("src.ui.kit.widgets")
local json = require("lib.json")
local common = require("src.ui.screens.server.common")

local R = {}
R.__index = R

local function app() return require("src.app") end

function R.new(sc, game)
  local room = sc:currentRoom()
  return setmetatable({ title = room and room.name or "Game", sc = sc, game = game, chatText = "", seenChat = 0 }, R)
end

function R:onBack()
  local sc = self.sc
  sc:request("roomLeave", json.object())
  sc.roomId, sc.spectating = nil, false
  sc:closeChannel()
  app().pop()
end

function R:update()
  local sc = self.sc
  local ch = sc.channel
  -- The game started: gameData arrives first, then fullState.
  if ch and ch.lastGameData and not self.started then
    self.started = true
    app().replace(common.gameScreen(sc, self.game, sc.spectating))
  end
end

function R:moveSeat(room, i, delta)
  local order = {}
  for _, s in ipairs(room.seats) do order[#order + 1] = s.id end
  local j = i + delta
  if j < 1 or j > #order then return end
  order[i], order[j] = order[j], order[i]
  self.sc:request("roomSeats", json.object({ "order", json.array(order) }), function(r)
    if not r.ok then overlays.toast(r.message or "Couldn't change seats.") end
  end)
end

function R:start()
  self.starting = true
  self.sc:request("roomStart", json.object(), function(r)
    if not r.ok then
      self.starting = false
      overlays.alert("Couldn't Start", r.message or "Something went wrong.")
    end
  end)
end

function R:drawSeats(room, x, y, w, h)
  local c = theme.c
  local sc = self.sc
  local isOwner = room.ownerId == sc.self.id and not sc.spectating
  ui.text(room.gameName, x, y, { size = 22, w = w, ellipsis = true })
  ui.text(#room.seats .. " of " .. room.maxPlayers .. " players" .. (room.spectators > 0 and ("  ·  " .. room.spectators .. " watching") or "")
    .. (room.collectionMode and "  ·  Collection mode" or ""), x, y + 32, { size = 13, color = c.onSurfaceVariant })
  local yy = y + 68
  local rowH = 56
  for i = 1, room.maxPlayers do
    local s = room.seats[i]
    ui.rect("fill", x, yy, w, rowH - 8, 10, c.surfaceContainer)
    ui.text(tostring(i), x + 12, yy, { w = 20, h = rowH - 8, valign = "middle", align = "center", color = c.onSurfaceVariant })
    if s then
      local user = { name = s.name, color = s.color }
      for _, u in ipairs(sc.users) do if u.id == s.id then user = u end end
      common.userRow(sc, user, x + 44, yy + 6, w - 44 - 120, { size = 36, h = 36, bold = s.id == sc.self.id })
      local bx = x + w - 12
      if isOwner then
        bx = bx - 40
        if ui.iconButton("expand_more", bx, yy + 4, { id = "rm:down" .. i, disabled = i == #room.seats, tooltip = "Move down" }) then
          self:moveSeat(room, i, 1)
        end
        bx = bx - 40
        if ui.iconButton("expand_less", bx, yy + 4, { id = "rm:up" .. i, disabled = i == 1, tooltip = "Move up" }) then
          self:moveSeat(room, i, -1)
        end
      end
      if s.id == room.ownerId then
        local label = "Creator"
        local lw = ui.textWidth(label, 11, "medium") + 16
        bx = bx - lw - 8
        ui.rect("fill", bx, yy + 14, lw, 20, 10, theme.alpha(c.primary, 0.15))
        ui.text(label, bx, yy + 14, { size = 11, weight = "medium", w = lw, h = 20, align = "center", valign = "middle", color = c.primary })
      end
    else
      ui.text("Open seat", x + 44, yy, { h = rowH - 8, valign = "middle", color = c.onSurfaceVariant })
    end
    yy = yy + rowH
  end
  yy = yy + 12
  if isOwner then
    if ui.button(self.starting and "Starting..." or "Start Game", x, yy, w, 48, { disabled = self.starting or #room.seats == 0,
      icon = "sports_esports", id = "rm:start" }) then
      self:start()
    end
    yy = yy + 56
    ui.text("Seat order is turn order. Players can't join once the game starts, but anyone can watch.", x, yy,
      { w = w, size = 12, color = c.onSurfaceVariant })
  else
    local owner
    for _, s in ipairs(room.seats) do if s.id == room.ownerId then owner = s.name end end
    ui.spinner(x + 14, yy + 14, 10)
    ui.text((sc.spectating and "Watching. " or "") .. "Waiting for " .. (owner or "the creator") .. " to start the game...", x + 36, yy,
      { h = 28, valign = "middle", w = w - 36, color = c.onSurfaceVariant })
  end
  local _ = h
end

function R:drawChat(x, y, w, h)
  local c = theme.c
  local sc = self.sc
  ui.rect("fill", x, y, w, h, 12, c.surfaceContainer)
  ui.text("Game chat", x + 16, y + 12, { weight = "bold" })
  local inputH = 48
  local ly, lh = y + 40, h - 40 - inputH - 24
  local off = ui.beginScroll("rm:chat", x + 8, ly, w - 16, lh)
  local cy = ly - off
  local textW = w - 32
  for _, line in ipairs(sc.roomChat) do
    ui.text(common.timeLabel(line.at) .. "  " .. line.name, x + 16, cy, { size = 12, weight = "bold", color = c.onSurfaceVariant })
    cy = cy + 18
    ui.text(line.text, x + 16, cy, { w = textW })
    cy = cy + ui.textHeight(line.text, textW) + 10
  end
  ui.endScroll("rm:chat", cy + off - ly)
  if #sc.roomChat ~= self.seenChat then
    self.seenChat = #sc.roomChat
    ui.scrollToEnd("rm:chat")
  end
  local text, _, submitted = ui.textField("rm:chatinput", x + 12, y + h - inputH - 12, w - 24 - 44, self.chatText,
    { label = "Message", labelBackground = c.surfaceContainer, maxLength = 500 })
  self.chatText = text
  local send = ui.iconButton("send", x + w - 12 - 40, y + h - inputH - 12 + 4, { id = "rm:send", disabled = text:match("^%s*$") ~= nil })
  if (submitted or send) and not text:match("^%s*$") then
    sc:send("chatSend", json.object({ "text", text, "roomId", sc.roomId }))
    self.chatText = ""
    ui.focusField("rm:chatinput")
  end
end

function R:draw(x, y, w, h)
  local room = self.sc:currentRoom()
  if not room then
    ui.spinner(x + w / 2, y + h / 2, 18)
    return
  end
  self.title = room.name
  local pad = 32
  local chatW = math.min(380, math.floor(w * 0.36))
  local seatsW = math.min(560, w - 3 * pad - chatW)
  local sx = x + pad + math.max(0, (w - 3 * pad - chatW - seatsW) / 2)
  local off = ui.beginScroll("rm:seats", x, y, sx + seatsW + pad - x, h)
  self:drawSeats(room, sx, y + pad - off, seatsW, h - 2 * pad)
  ui.endScroll("rm:seats", 68 + room.maxPlayers * 56 + 120 + 2 * pad)
  self:drawChat(x + w - pad - chatW, y + pad, chatW, h - 2 * pad)
  local _ = widgets
end

return R
