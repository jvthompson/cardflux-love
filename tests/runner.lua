-- Minimal test runner. Run with:  lovec . --test [filter]
-- Each tests/*_test.lua file returns function(t) that registers tests via
-- t.describe / t.it and asserts via t.eq / t.ok / t.near / t.isNil / t.errors.
local T = {}

local results = { passed = 0, failed = 0, failures = {} }
local prefixStack = {}

local function fullName(name)
  local parts = {}
  for _, p in ipairs(prefixStack) do parts[#parts + 1] = p end
  parts[#parts + 1] = name
  return table.concat(parts, " > ")
end

local function serialize(v, depth)
  depth = depth or 0
  if type(v) == "string" then return string.format("%q", v) end
  if type(v) ~= "table" then return tostring(v) end
  if depth > 3 then return "{...}" end
  local parts = {}
  local n = #v
  for i = 1, n do parts[#parts + 1] = serialize(v[i], depth + 1) end
  local keys = {}
  for k in pairs(v) do
    if not (type(k) == "number" and k >= 1 and k <= n and k % 1 == 0) then keys[#keys + 1] = k end
  end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  for _, k in ipairs(keys) do parts[#parts + 1] = tostring(k) .. "=" .. serialize(v[k], depth + 1) end
  return "{" .. table.concat(parts, ", ") .. "}"
end

local function deepEqual(a, b)
  if a == b then return true end
  if type(a) ~= "table" or type(b) ~= "table" then return false end
  for k, v in pairs(a) do
    if not deepEqual(v, b[k]) then return false end
  end
  for k in pairs(b) do
    if a[k] == nil then return false end
  end
  return true
end
T.deepEqual = deepEqual

local function fail(msg, level)
  error({ testFailure = true, message = msg }, (level or 1) + 1)
end

function T.describe(name, fn)
  prefixStack[#prefixStack + 1] = name
  fn()
  prefixStack[#prefixStack] = nil
end

local filter
function T.it(name, fn)
  local fname = fullName(name)
  if filter and not fname:lower():find(filter:lower(), 1, true) then return end
  local ok, err = xpcall(fn, function(e)
    if type(e) == "table" and e.testFailure then return e.message .. "\n" .. debug.traceback("", 2) end
    return tostring(type(e) == "table" and (e.message or serialize(e)) or e) .. "\n" .. debug.traceback("", 2)
  end)
  if ok then
    results.passed = results.passed + 1
  else
    results.failed = results.failed + 1
    results.failures[#results.failures + 1] = { name = fname, err = err }
  end
end

function T.eq(actual, expected, msg)
  if not deepEqual(actual, expected) then
    fail(string.format("%sexpected %s, got %s", msg and (msg .. ": ") or "", serialize(expected), serialize(actual)), 2)
  end
end

function T.ok(v, msg)
  if not v then fail(msg or "expected truthy value", 2) end
end

function T.notOk(v, msg)
  if v then fail(msg or ("expected falsy value, got " .. serialize(v)), 2) end
end

function T.isNil(v, msg)
  if v ~= nil then fail(string.format("%sexpected nil, got %s", msg and (msg .. ": ") or "", serialize(v)), 2) end
end

function T.near(actual, expected, eps, msg)
  eps = eps or 1e-9
  if type(actual) ~= "number" or math.abs(actual - expected) > eps then
    fail(string.format("%sexpected ~%s, got %s", msg and (msg .. ": ") or "", tostring(expected), tostring(actual)), 2)
  end
end

function T.errors(fn, msg)
  local ok = pcall(fn)
  if ok then fail(msg or "expected an error", 2) end
end

function T.ids(list, key)
  key = key or "instanceId"
  local out = {}
  for i, v in ipairs(list) do out[i] = v[key] end
  return out
end

function T.run(files, filterArg)
  filter = filterArg
  for _, file in ipairs(files) do
    local chunk = love.filesystem.load(file)
    local register = chunk()
    prefixStack = { file:match("([^/]+)_test%.lua$") or file }
    local ok, err = pcall(register, T)
    if not ok then
      results.failed = results.failed + 1
      results.failures[#results.failures + 1] = { name = file .. " (load)", err = tostring(err) }
    end
  end
  for _, f in ipairs(results.failures) do
    print("FAIL: " .. f.name)
    print("  " .. tostring(f.err):gsub("\n", "\n  "))
  end
  print(string.format("\n%d passed, %d failed", results.passed, results.failed))
  return results.failed == 0
end

return T
