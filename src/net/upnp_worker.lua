-- Worker thread body for src/net/upnp.lua. Receives a job table and a
-- result channel; pushes one result table:
--   add:    { ok = true, port, controlUrl, serviceType } or { ok = false }
--   delete: { ok = bool }
local job, out = ...

require("love.filesystem")
require("love.timer")
local socket = require("socket")
local http = require("socket.http")
local ltn12 = require("ltn12")
local U = require("src.net.upnp")

-- SSDP M-SEARCH, listening the whole window: the first responder isn't
-- necessarily a gateway (TVs and printers speak SSDP too).
local function discoverLocations(timeout)
  local locations, seen = {}, {}
  local udp = socket.udp()
  if not udp then return locations end
  udp:setsockname("*", 0)
  udp:settimeout(0.25)
  udp:sendto(U.searchMessage, U.ssdpAddress, U.ssdpPort)
  local deadline = socket.gettime() + timeout
  while socket.gettime() < deadline do
    local data = udp:receivefrom()
    if data then
      local loc = U.parseLocation(data)
      if loc and not seen[loc] then
        seen[loc] = true
        locations[#locations + 1] = loc
      end
    end
  end
  udp:close()
  return locations
end

local function httpGet(url)
  local chunks = {}
  local ok, _, code = pcall(http.request, { url = url, sink = ltn12.sink.table(chunks) })
  if not ok or code ~= 200 then return nil end
  return table.concat(chunks)
end

local function soap(controlUrl, serviceType, action, fields)
  local body = U.soapEnvelope(serviceType, action, fields)
  local ok, _, code = pcall(http.request, {
    url = controlUrl,
    method = "POST",
    headers = {
      ["content-type"] = 'text/xml; charset="utf-8"',
      ["content-length"] = tostring(#body),
      ["soapaction"] = '"' .. serviceType .. "#" .. action .. '"',
    },
    source = ltn12.source.string(body),
    sink = ltn12.sink.null(),
  })
  -- A refusal is a SOAP Fault under HTTP 500; only the status matters.
  return ok and code == 200
end

-- The local address the OS would route through to reach the gateway --
-- what the router should forward to. Connecting a UDP socket sends nothing.
local function localAddressFor(host)
  local ip = socket.dns.toip(host)
  if not ip then return nil end
  local udp = socket.udp()
  if not udp then return nil end
  local addr
  if udp:setpeername(ip, 1900) then addr = udp:getsockname() end
  udp:close()
  if addr == "0.0.0.0" then addr = nil end
  return addr
end

local function add()
  for _, location in ipairs(discoverLocations(3)) do
    local xml = httpGet(location)
    local controlUrl, serviceType
    if xml then controlUrl, serviceType = U.findControlUrl(xml, location) end
    if controlUrl then
      local _, host = U.splitUrl(controlUrl)
      local internal = host and localAddressFor(host)
      if internal and soap(controlUrl, serviceType, "AddPortMapping", U.addFields(job.port, internal, job.description)) then
        return { ok = true, port = job.port, controlUrl = controlUrl, serviceType = serviceType }
      end
      -- First real gateway decides, like the Dart original.
      return { ok = false }
    end
  end
  return { ok = false }
end

http.TIMEOUT = 4
local ok, result = pcall(function()
  if job.op == "add" then return add() end
  return { ok = soap(job.controlUrl, job.serviceType, "DeletePortMapping", U.deleteFields(job.port)) }
end)
out:push(ok and result or { ok = false })
