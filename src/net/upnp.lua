-- Port of lib/networking/upnp_port_mapper.dart: best-effort automatic port
-- forwarding via UPnP IGD (SSDP discovery + SOAP AddPortMapping /
-- DeletePortMapping), so hosting over the internet doesn't need a manual
-- router rule pinned to one LAN PC.
--
-- The network round-trips (several seconds of SSDP listening plus HTTP)
-- run on a worker thread (src/net/upnp_worker.lua); results are delivered
-- on the main thread from U.update(). Every failure resolves to "not
-- mapped" rather than an error.
local U = {}

U.ssdpAddress = "239.255.255.250"
U.ssdpPort = 1900
U.serviceTypes = {
  "urn:schemas-upnp-org:service:WANIPConnection:1",
  "urn:schemas-upnp-org:service:WANPPPConnection:1",
}

U.searchMessage = "M-SEARCH * HTTP/1.1\r\n"
  .. "HOST: 239.255.255.250:1900\r\n"
  .. "MAN: \"ssdp:discover\"\r\n"
  .. "MX: 2\r\n"
  .. "ST: upnp:rootdevice\r\n\r\n"

-- The LOCATION header of an SSDP response, or nil.
function U.parseLocation(response)
  for line in (response .. "\n"):gmatch("([^\r\n]*)\r?\n") do
    local v = line:match("^[Ll][Oo][Cc][Aa][Tt][Ii][Oo][Nn]:%s*(%S+)")
    if v then return v end
  end
  return nil
end

-- Splits "http://host:port/path" into scheme+authority ("http://host:port"),
-- host, and path ("/path", "/" when absent).
function U.splitUrl(url)
  local root, path = url:match("^(%a[%w+.-]*://[^/]+)(.*)$")
  if not root then return nil end
  local host = root:match("://%[?([^%]:/]+)")
  if path == "" then path = "/" end
  return root, host, path
end

-- Resolves a (possibly relative) controlURL against the description URL.
function U.resolveUrl(base, ref)
  if ref:match("^%a[%w+.-]*://") then return ref end
  local root, _, path = U.splitUrl(base)
  if not root then return ref end
  if ref:sub(1, 1) == "/" then return root .. ref end
  local dir = path:match("^(.*/)") or "/"
  return root .. dir .. ref
end

-- Scans a device description for a WANIPConnection/WANPPPConnection
-- service and returns its absolute control URL and service type. The
-- lookup is scoped to the matching <service> block so a controlURL of an
-- unrelated service is never picked up.
function U.findControlUrl(xml, location)
  for _, serviceType in ipairs(U.serviceTypes) do
    for block in xml:gmatch("<service>(.-)</service>") do
      local st = block:match("<serviceType>%s*(.-)%s*</serviceType>")
      if st == serviceType then
        local ctl = block:match("<controlURL>%s*(.-)%s*</controlURL>")
        if ctl and ctl ~= "" then return U.resolveUrl(location, ctl), serviceType end
      end
    end
  end
  return nil
end

function U.soapEnvelope(serviceType, action, fields)
  return '<?xml version="1.0"?>'
    .. '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
    .. 's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
    .. "<s:Body>"
    .. "<u:" .. action .. ' xmlns:u="' .. serviceType .. '">' .. fields .. "</u:" .. action .. ">"
    .. "</s:Body>"
    .. "</s:Envelope>"
end

function U.addFields(port, internalClient, description)
  return "<NewRemoteHost></NewRemoteHost>"
    .. "<NewExternalPort>" .. port .. "</NewExternalPort>"
    .. "<NewProtocol>TCP</NewProtocol>"
    .. "<NewInternalPort>" .. port .. "</NewInternalPort>"
    .. "<NewInternalClient>" .. internalClient .. "</NewInternalClient>"
    .. "<NewEnabled>1</NewEnabled>"
    .. "<NewPortMappingDescription>" .. description .. "</NewPortMappingDescription>"
    .. "<NewLeaseDuration>0</NewLeaseDuration>"
end

function U.deleteFields(port)
  return "<NewRemoteHost></NewRemoteHost>"
    .. "<NewExternalPort>" .. port .. "</NewExternalPort>"
    .. "<NewProtocol>TCP</NewProtocol>"
end

---------------------------------------------------------------------------
-- Main-thread API
---------------------------------------------------------------------------

local pending = {}

local function spawn(job, onDone)
  local channel = love.thread.newChannel()
  local thread = love.thread.newThread("src/net/upnp_worker.lua")
  thread:start(job, channel)
  pending[#pending + 1] = { channel = channel, thread = thread, onDone = onDone }
end

-- Asks the LAN's gateway to forward TCP `port` to this machine. Calls
-- onDone(mapping) with a mapping table (pass to U.releaseMapping) on
-- success, or onDone(nil) when there's no UPnP gateway or it refused.
function U.requestMapping(port, onDone, description)
  spawn({ op = "add", port = port, description = description or "Cardtable" }, function(r)
    if onDone then onDone(r and r.ok and r or nil) end
  end)
end

-- Fire-and-forget removal of a mapping requestMapping created.
function U.releaseMapping(mapping)
  if not mapping then return end
  spawn({ op = "delete", port = mapping.port, controlUrl = mapping.controlUrl, serviceType = mapping.serviceType })
end

function U.update()
  for i = #pending, 1, -1 do
    local p = pending[i]
    local v = p.channel:pop()
    if v ~= nil then
      table.remove(pending, i)
      if p.onDone then p.onDone(v) end
    elseif not p.thread:isRunning() then
      table.remove(pending, i)
      if p.onDone then p.onDone(nil) end
    end
  end
end

return U
