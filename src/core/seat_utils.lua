-- Port of lib/game/seat_utils.dart. Seat indices are 0-based like Dart's.
local S = {}

function S.isFarMirrorSeat(seatIndex, playerCount)
  if playerCount == 2 then return seatIndex == 1 end
  if playerCount == 3 then return seatIndex >= 1 end
  if playerCount == 4 then return seatIndex >= 2 end
  return seatIndex >= math.ceil(playerCount / 2)
end

local function reversed(list)
  local out = {}
  for i = #list, 1, -1 do out[#out + 1] = list[i] end
  return out
end

-- Returns { bottomRow = {...players}, topRow = {...players} } for the viewer.
function S.computeHandRowLayout(players, localPlayerId)
  local n = #players
  if n <= 1 then return { bottomRow = players, topRow = {} } end
  local mySeat = -1
  for i, p in ipairs(players) do
    if p.id == localPlayerId then mySeat = i - 1 break end
  end
  local near, far = {}, {}
  for seat = 0, n - 1 do
    local list = S.isFarMirrorSeat(seat, n) and far or near
    list[#list + 1] = players[seat + 1]
  end
  if S.isFarMirrorSeat(mySeat, n) then
    return { bottomRow = reversed(far), topRow = reversed(near) }
  end
  return { bottomRow = near, topRow = far }
end

-- Whether the local viewer sees the shared table mirrored (both axes).
function S.isViewerMirrored(players, localPlayerId)
  local n = #players
  if n <= 1 then return false end
  for i, p in ipairs(players) do
    if p.id == localPlayerId then return S.isFarMirrorSeat(i - 1, n) end
  end
  return false
end

return S
