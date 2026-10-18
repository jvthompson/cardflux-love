-- Port of lib/game/sound_service.dart: fire-and-forget sound effects with up
-- to 4 overlapping voices per effect. Playback failures are silent; a load
-- failure is logged once and remembered (pools[effect] = false) so a
-- missing/corrupt file doesn't retry the disk load/decode on every play.
local S = {}

local FILES = {
  draw = "assets/audio/draw.wav",
  playCard = "assets/audio/playcard.wav",
  shuffle = "assets/audio/shuffle.wav",
  tap = "assets/audio/tap.wav",
  untap = "assets/audio/untap.wav",
  error = "assets/audio/error.wav",
}
local VOICES = 4
local pools = {}

function S.play(effect)
  if not love.audio then return end
  local pool = pools[effect]
  if pool == false then return false end -- load already failed; don't keep retrying
  if not pool then
    local ok, base = pcall(love.audio.newSource, FILES[effect], "static")
    if not ok then
      print("sound: couldn't load " .. tostring(effect) .. " (" .. tostring(FILES[effect]) .. "): " .. tostring(base))
      pools[effect] = false
      return false
    end
    pool = { base, next = 1 }
    for i = 2, VOICES do pool[i] = base:clone() end
    pools[effect] = pool
  end
  return pcall(function()
    local src = pool[pool.next]
    pool.next = pool.next % VOICES + 1
    src:stop()
    src:play()
  end)
end

return S
