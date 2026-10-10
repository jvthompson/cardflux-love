-- Port of lib/networking/network_info.dart.
local socket = require("socket")

local N = {}

local function isIPv4(s)
  if type(s) ~= "string" then return false end
  local a, b, c, d = s:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  if not a then return false end
  for _, x in ipairs({ a, b, c, d }) do
    if tonumber(x) > 255 then return false end
  end
  return true
end
N.isIPv4 = isIPv4

-- Every non-loopback IPv4 address of this machine (best effort, without
-- native interface enumeration): the host name's addresses plus the one
-- the OS would route outward with.
function N.localIPv4Addresses()
  local seen, out = {}, {}
  local function add(ip)
    if isIPv4(ip) and not ip:match("^127%.") and ip ~= "0.0.0.0" and not seen[ip] then
      seen[ip] = true
      out[#out + 1] = ip
    end
  end
  local udp = socket.udp()
  if udp then
    -- No packet is sent; connecting a UDP socket just picks a route.
    if udp:setpeername("8.8.8.8", 53) then add((udp:getsockname())) end
    udp:close()
  end
  local ok, name = pcall(socket.dns.gethostname)
  if ok and name then
    local _, info = socket.dns.toip(name)
    if type(info) == "table" and info.ip then
      for _, ip in ipairs(info.ip) do add(ip) end
    end
  end
  return out
end

-- Fetches the public IPv4 from api.ipify.org on a worker thread. LÖVE's
-- luasocket has no TLS, so this uses ipify's plain-HTTP endpoint (the
-- answer is just our own address, so nothing sensitive travels).
-- onDone(ipOrNil) runs on the main thread from N.update().
local pending = {}

function N.fetchPublicIPv4(onDone)
  local channel = love.thread.newChannel()
  local thread = love.thread.newThread([[
    local ch = ...
    local http = require("socket.http")
    http.TIMEOUT = 5
    local ok, body, code = pcall(http.request, "http://api.ipify.org")
    ch:push((ok and code == 200 and body) or "")
  ]])
  thread:start(channel)
  pending[#pending + 1] = { channel = channel, onDone = onDone, thread = thread }
end

function N.update()
  for i = #pending, 1, -1 do
    local p = pending[i]
    local v = p.channel:pop()
    if v ~= nil then
      table.remove(pending, i)
      local ip = v:gsub("%s+", "")
      p.onDone(isIPv4(ip) and ip or nil)
    elseif not p.thread:isRunning() and p.thread:getError() then
      table.remove(pending, i)
      p.onDone(nil)
    end
  end
end

return N
