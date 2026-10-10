-- UUID v4 generator. Uses love.math's RNG when available (seeded from the OS
-- at startup), falling back to math.random.
local U = {}

local rand
if love and love.math then
  local rng = love.math.newRandomGenerator(os.time() + math.floor((os.clock() % 1) * 1e6))
  rand = function(n) return rng:random(0, n) end
else
  math.randomseed(os.time())
  rand = function(n) return math.random(0, n) end
end

function U.v4()
  local b = {}
  for i = 1, 16 do b[i] = rand(255) end
  b[7] = (b[7] % 16) + 0x40 -- version 4
  b[9] = (b[9] % 64) + 0x80 -- RFC 4122 variant
  return string.format("%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
    b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15], b[16])
end

return U
