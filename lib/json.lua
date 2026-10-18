-- Minimal JSON encoder/decoder tuned for Cardflux file compatibility.
--
-- * Decoded arrays/objects carry a metatable marking their type, so an empty
--   `[]` round-trips as an array and `{}` as an object.
-- * Encoded objects keep key insertion order when built with json.object()
--   (or any table carrying an `__order` list in its metatable); otherwise keys
--   are sorted for deterministic output.
-- * Integral numbers are written without a fraction or exponent (ARGB colors
--   above 2^31 must stay plain integers); other numbers use the shortest
--   representation that round-trips.
-- * json.encode(v, {indent = "  "}) matches Dart's JsonEncoder.withIndent('  ').

local json = {}

local ARRAY_MT = { __jsontype = "array" }
local OBJECT_MT_KIND = "object"

json.null = setmetatable({}, { __tostring = function() return "null" end, __jsontype = "null" })

-- Ordered object: remembers the order keys are first assigned.
local function newObjectMeta()
  local order = {}
  local mt = { __jsontype = OBJECT_MT_KIND, __order = order }
  mt.__newindex = function(t, k, v)
    if v ~= nil then order[#order + 1] = k end
    rawset(t, k, v)
  end
  return mt
end

function json.object(pairsList)
  local t = setmetatable({}, newObjectMeta())
  if pairsList then
    for i = 1, #pairsList, 2 do
      local k, v = pairsList[i], pairsList[i + 1]
      if v ~= nil then t[k] = v end
    end
  end
  return t
end

function json.array(t)
  return setmetatable(t or {}, ARRAY_MT)
end

function json.isArray(t)
  local mt = getmetatable(t)
  if mt and mt.__jsontype then return mt.__jsontype == "array" end
  if next(t) == nil then return false end
  local n = #t
  for k in pairs(t) do
    if type(k) ~= "number" or k < 1 or k > n or k % 1 ~= 0 then return false end
  end
  return true
end

---------------------------------------------------------------------------
-- Encoding
---------------------------------------------------------------------------

local escapes = {
  ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f',
  ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t',
}

local function encodeString(s)
  return '"' .. s:gsub('[%c"\\]', function(c)
    return escapes[c] or string.format("\\u%04x", c:byte())
  end) .. '"'
end

local function encodeNumber(n)
  if n ~= n or n == math.huge or n == -math.huge then
    error("cannot encode non-finite number")
  end
  if n % 1 == 0 and math.abs(n) < 2 ^ 53 then
    return string.format("%d", n)
  end
  for p = 15, 17 do
    local s = string.format("%." .. p .. "g", n)
    if tonumber(s) == n then return s end
  end
  return string.format("%.17g", n)
end

local function objectKeys(t)
  local mt = getmetatable(t)
  local keys = {}
  if mt and mt.__order then
    local seen = {}
    for _, k in ipairs(mt.__order) do
      if not seen[k] and rawget(t, k) ~= nil then
        seen[k] = true
        keys[#keys + 1] = k
      end
    end
    -- Keys assigned via rawset (bypassing __newindex) still get written.
    local extra = {}
    for k in pairs(t) do
      if not seen[k] then extra[#extra + 1] = k end
    end
    table.sort(extra, function(a, b) return tostring(a) < tostring(b) end)
    for _, k in ipairs(extra) do keys[#keys + 1] = k end
  else
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  end
  return keys
end

local encodeValue

local function encodeTable(t, indent, depth, buf)
  local nl, pad, padIn, colon = "", "", "", ":"
  if indent then
    nl = "\n"
    pad = string.rep(indent, depth)
    padIn = string.rep(indent, depth + 1)
    colon = ": "
  end
  if json.isArray(t) then
    local n = #t
    if n == 0 then buf[#buf + 1] = "[]"; return end
    buf[#buf + 1] = "[" .. nl
    for i = 1, n do
      buf[#buf + 1] = padIn
      encodeValue(t[i], indent, depth + 1, buf)
      buf[#buf + 1] = (i < n and "," or "") .. nl
    end
    buf[#buf + 1] = pad .. "]"
  else
    local keys = objectKeys(t)
    if #keys == 0 then buf[#buf + 1] = "{}"; return end
    buf[#buf + 1] = "{" .. nl
    for i, k in ipairs(keys) do
      buf[#buf + 1] = padIn .. encodeString(tostring(k)) .. colon
      encodeValue(t[k], indent, depth + 1, buf)
      buf[#buf + 1] = (i < #keys and "," or "") .. nl
    end
    buf[#buf + 1] = pad .. "}"
  end
end

encodeValue = function(v, indent, depth, buf)
  local tv = type(v)
  if v == nil or v == json.null then
    buf[#buf + 1] = "null"
  elseif tv == "boolean" then
    buf[#buf + 1] = v and "true" or "false"
  elseif tv == "number" then
    buf[#buf + 1] = encodeNumber(v)
  elseif tv == "string" then
    buf[#buf + 1] = encodeString(v)
  elseif tv == "table" then
    encodeTable(v, indent, depth, buf)
  else
    error("cannot encode value of type " .. tv)
  end
end

function json.encode(v, opts)
  local buf = {}
  encodeValue(v, opts and opts.indent or nil, 0, buf)
  return table.concat(buf)
end

---------------------------------------------------------------------------
-- Decoding
---------------------------------------------------------------------------

local function decodeError(str, pos, msg)
  local line = 1
  for _ in str:sub(1, pos):gmatch("\n") do line = line + 1 end
  error(string.format("JSON error at line %d (pos %d): %s", line, pos, msg), 0)
end

local function skipWs(str, pos)
  return str:find("[^ \t\r\n]", pos) or #str + 1
end

local function codepointToUtf8(n)
  if n < 0x80 then return string.char(n) end
  if n < 0x800 then
    return string.char(0xC0 + math.floor(n / 0x40), 0x80 + n % 0x40)
  end
  if n < 0x10000 then
    return string.char(0xE0 + math.floor(n / 0x1000), 0x80 + math.floor(n / 0x40) % 0x40, 0x80 + n % 0x40)
  end
  return string.char(0xF0 + math.floor(n / 0x40000), 0x80 + math.floor(n / 0x1000) % 0x40,
    0x80 + math.floor(n / 0x40) % 0x40, 0x80 + n % 0x40)
end

local decodeValue

-- A deeply nested payload (e.g. from an untrusted peer or server client)
-- would otherwise recurse until it blows the Lua call stack; reject it with
-- a normal decode error well before that point instead.
local MAX_DEPTH = 64

local function decodeString(str, pos)
  -- pos is at the opening quote
  local buf = {}
  local i = pos + 1
  while true do
    local s, e = str:find('["\\]', i)
    if not s then decodeError(str, pos, "unterminated string") end
    buf[#buf + 1] = str:sub(i, s - 1)
    if str:sub(s, s) == '"' then
      return table.concat(buf), s + 1
    end
    local c = str:sub(s + 1, s + 1)
    if c == "u" then
      local hex = str:sub(s + 2, s + 5)
      local n = tonumber(hex, 16)
      if not n then decodeError(str, s, "bad unicode escape") end
      local nextPos = s + 6
      if n >= 0xD800 and n <= 0xDBFF and str:sub(nextPos, nextPos + 1) == "\\u" then
        local lo = tonumber(str:sub(nextPos + 2, nextPos + 5), 16)
        if lo and lo >= 0xDC00 and lo <= 0xDFFF then
          n = 0x10000 + (n - 0xD800) * 0x400 + (lo - 0xDC00)
          nextPos = nextPos + 6
        end
      end
      buf[#buf + 1] = codepointToUtf8(n)
      i = nextPos
    else
      local map = { b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }
      local r = map[c]
      if not r then decodeError(str, s, "bad escape") end
      buf[#buf + 1] = r
      i = s + 2
    end
  end
end

decodeValue = function(str, pos, depth)
  depth = depth or 1
  pos = skipWs(str, pos)
  local c = str:sub(pos, pos)
  if c == "{" then
    if depth > MAX_DEPTH then decodeError(str, pos, "too deeply nested") end
    local obj = setmetatable({}, newObjectMeta())
    pos = skipWs(str, pos + 1)
    if str:sub(pos, pos) == "}" then return obj, pos + 1 end
    while true do
      pos = skipWs(str, pos)
      if str:sub(pos, pos) ~= '"' then decodeError(str, pos, "expected key") end
      local key
      key, pos = decodeString(str, pos)
      pos = skipWs(str, pos)
      if str:sub(pos, pos) ~= ":" then decodeError(str, pos, "expected ':'") end
      local val
      val, pos = decodeValue(str, pos + 1, depth + 1)
      if val ~= json.null then obj[key] = val end
      pos = skipWs(str, pos)
      local d = str:sub(pos, pos)
      if d == "}" then return obj, pos + 1 end
      if d ~= "," then decodeError(str, pos, "expected ',' or '}'") end
      pos = pos + 1
    end
  elseif c == "[" then
    if depth > MAX_DEPTH then decodeError(str, pos, "too deeply nested") end
    local arr = setmetatable({}, ARRAY_MT)
    pos = skipWs(str, pos + 1)
    if str:sub(pos, pos) == "]" then return arr, pos + 1 end
    local n = 0
    while true do
      local val
      val, pos = decodeValue(str, pos, depth + 1)
      n = n + 1
      arr[n] = val
      pos = skipWs(str, pos)
      local d = str:sub(pos, pos)
      if d == "]" then return arr, pos + 1 end
      if d ~= "," then decodeError(str, pos, "expected ',' or ']'") end
      pos = pos + 1
    end
  elseif c == '"' then
    return decodeString(str, pos)
  elseif str:sub(pos, pos + 3) == "true" then
    return true, pos + 4
  elseif str:sub(pos, pos + 4) == "false" then
    return false, pos + 5
  elseif str:sub(pos, pos + 3) == "null" then
    return json.null, pos + 4
  else
    local num = str:match("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
    if not num or num == "" then decodeError(str, pos, "unexpected character '" .. c .. "'") end
    local n = tonumber(num)
    if not n then decodeError(str, pos, "bad number") end
    return n, pos + #num
  end
end

-- Decodes a JSON string. JSON null inside objects is dropped (absent key);
-- a top-level or array null decodes to json.null.
function json.decode(str)
  if str:sub(1, 3) == "\239\187\191" then str = str:sub(4) end -- strip UTF-8 BOM
  local v, pos = decodeValue(str, 1)
  pos = skipWs(str, pos)
  if pos <= #str then decodeError(str, pos, "trailing garbage") end
  return v
end

-- Protected decode: returns value or nil, err.
function json.tryDecode(str)
  local ok, v = pcall(json.decode, str)
  if ok then return v end
  return nil, v
end

return json
