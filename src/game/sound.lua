-- Port of lib/game/sound_service.dart: fire-and-forget sound effects with up
-- to 4 overlapping voices per effect. Failures are silent.
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
  local ok = pcall(function()
    local pool = pools[effect]
    if not pool then
      local base = love.audio.newSource(FILES[effect], "static")
      pool = { base, next = 1 }
      for i = 2, VOICES do pool[i] = base:clone() end
      pools[effect] = pool
    end
    local src = pool[pool.next]
    pool.next = pool.next % VOICES + 1
    src:stop()
    src:play()
  end)
  return ok
end

return S
