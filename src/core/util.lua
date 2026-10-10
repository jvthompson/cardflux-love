-- Small shared helpers for the pure-Lua core (no love.* dependencies).
local util = {}

-- Sentinel for copyWith: assigning util.NIL clears a field (Dart's explicit
-- `null` as opposed to an omitted argument).
util.NIL = setmetatable({}, { __tostring = function() return "NIL" end })

-- Shallow copy of `obj` with `changes` applied. A change value of util.NIL
-- clears the field.
function util.copyWith(obj, changes)
  local out = {}
  for k, v in pairs(obj) do out[k] = v end
  if changes then
    for k, v in pairs(changes) do
      if v == util.NIL then out[k] = nil else out[k] = v end
    end
  end
  return out
end

function util.shallowCopy(t)
  local out = {}
  for k, v in pairs(t) do out[k] = v end
  return out
end

function util.map(list, fn)
  local out = {}
  for i, v in ipairs(list) do out[i] = fn(v, i) end
  return out
end

function util.filter(list, pred)
  local out = {}
  for _, v in ipairs(list) do
    if pred(v) then out[#out + 1] = v end
  end
  return out
end

function util.find(list, pred)
  for i, v in ipairs(list) do
    if pred(v) then return v, i end
  end
  return nil
end

function util.any(list, pred)
  for _, v in ipairs(list) do
    if pred(v) then return true end
  end
  return false
end

function util.concat(a, b)
  local out = {}
  for _, v in ipairs(a) do out[#out + 1] = v end
  for _, v in ipairs(b) do out[#out + 1] = v end
  return out
end

function util.contains(list, value)
  for _, v in ipairs(list) do
    if v == value then return true end
  end
  return false
end

-- Removes the first occurrence of value from list (in place).
function util.removeValue(list, value)
  for i, v in ipairs(list) do
    if v == value then
      table.remove(list, i)
      return true
    end
  end
  return false
end

function util.toSet(list)
  local s = {}
  for _, v in ipairs(list) do s[v] = true end
  return s
end

function util.setSize(s)
  local n = 0
  for _ in pairs(s) do n = n + 1 end
  return n
end

function util.clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

-- Fisher-Yates shuffle in place. `rng(n)` must return an integer in [1, n];
-- defaults to math.random.
function util.shuffle(list, rng)
  rng = rng or math.random
  for i = #list, 2, -1 do
    local j = rng(i)
    list[i], list[j] = list[j], list[i]
  end
  return list
end

-- Deterministic seeded RNG (Park-Miller) returning a function(n) -> [1, n],
-- used where Dart passes `Random(seed)`. Sequences differ from Dart's, which
-- is fine: seeds only exist for reproducible tests.
function util.seededRng(seed)
  local state = (seed % 2147483646) + 1
  return function(n)
    state = (state * 16807) % 2147483647
    return (state % n) + 1
  end
end

function util.startsWith(s, prefix)
  return s:sub(1, #prefix) == prefix
end

function util.endsWith(s, suffix)
  return suffix == "" or s:sub(-#suffix) == suffix
end

function util.trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Plain (non-pattern) substring search.
function util.containsText(haystack, needle)
  return haystack:find(needle, 1, true) ~= nil
end

function util.deepCopy(v)
  if type(v) ~= "table" then return v end
  local out = {}
  for k, x in pairs(v) do out[k] = util.deepCopy(x) end
  return setmetatable(out, getmetatable(v))
end

return util
