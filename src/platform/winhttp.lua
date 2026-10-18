-- Minimal HTTPS GET over WinHTTP (LuaJIT FFI). LÖVE's luasocket has no TLS,
-- and GitHub (API + release downloads) is HTTPS-only. WinHTTP follows
-- https->https redirects (GitHub's asset URLs redirect to a CDN) on its own.
-- Blocking: call it from a worker thread.
local ffi = require("ffi")
local fs = require("src.data.fs")
require("love.timer")

local H = {}

pcall(ffi.cdef, [[
  void* WinHttpOpen(const WCHAR* agent, DWORD accessType, const WCHAR* proxy, const WCHAR* bypass, DWORD flags);
  void* WinHttpConnect(void* session, const WCHAR* server, uint16_t port, DWORD reserved);
  void* WinHttpOpenRequest(void* connect, const WCHAR* verb, const WCHAR* object, const WCHAR* version,
                           const WCHAR* referrer, const WCHAR** acceptTypes, DWORD flags);
  BOOL WinHttpSetTimeouts(void* h, int resolve, int connect, int send, int receive);
  BOOL WinHttpSendRequest(void* h, const WCHAR* headers, DWORD headersLen, void* optional, DWORD optionalLen,
                          DWORD totalLen, uintptr_t context);
  BOOL WinHttpReceiveResponse(void* h, void* reserved);
  BOOL WinHttpQueryHeaders(void* h, DWORD infoLevel, const WCHAR* name, void* buffer, DWORD* bufferLen, DWORD* index);
  BOOL WinHttpReadData(void* h, void* buffer, DWORD toRead, DWORD* read);
  BOOL WinHttpCloseHandle(void* h);
]])
pcall(ffi.cdef, "DWORD GetLastError(void);")

local ACCESS_AUTOMATIC_PROXY = 4 -- Windows 8.1+
local ACCESS_DEFAULT_PROXY = 0
local FLAG_SECURE = 0x00800000
local QUERY_STATUS_CODE = 19
local QUERY_CONTENT_LENGTH = 5
local QUERY_FLAG_NUMBER = 0x20000000

local lib
local function winhttp()
  lib = lib or ffi.load("winhttp")
  return lib
end

local toWide = fs._impl.toWide

-- "https://host[:port]/path?q" -> host, port, path
function H.parseUrl(url)
  local scheme, host, port, path = url:match("^(%a+)://([^/:]+):?(%d*)(.*)$")
  if not scheme or scheme:lower() ~= "https" then return nil end
  if path == "" then path = "/" end
  return host, tonumber(port) or 443, path
end

local function queryNumber(w, req, level)
  local v = ffi.new("DWORD[1]")
  local len = ffi.new("DWORD[1]", 4)
  if w.WinHttpQueryHeaders(req, bit.bor(level, QUERY_FLAG_NUMBER), nil, v, len, nil) == 0 then return nil end
  return tonumber(v[0])
end

-- Returns status, body, aborted (aborted is true only when opts.onChunk
-- itself returned false -- a deliberate cancel, which H.get below must not
-- retry; every other nil-returning failure is a transport-level one that's
-- worth retrying).
local function getOnce(url, opts)
  local host, port, path = H.parseUrl(url)
  if not host then return nil, "unsupported URL: " .. tostring(url) end
  local w = winhttp()
  local handles = {}
  local function close()
    for i = #handles, 1, -1 do w.WinHttpCloseHandle(handles[i]) end
  end
  local function fail(what)
    local code = tonumber(ffi.C.GetLastError())
    close()
    return nil, what .. " failed (error " .. code .. ")"
  end

  local agent = toWide("Cardflux-Updater")
  local session = w.WinHttpOpen(agent, ACCESS_AUTOMATIC_PROXY, nil, nil, 0)
  if session == nil then session = w.WinHttpOpen(agent, ACCESS_DEFAULT_PROXY, nil, nil, 0) end
  if session == nil then return fail("WinHttpOpen") end
  handles[#handles + 1] = session
  local t = opts.timeoutMs or 15000
  w.WinHttpSetTimeouts(session, t, t, t, t)

  local conn = w.WinHttpConnect(session, toWide(host), port, 0)
  if conn == nil then return fail("connect to " .. host) end
  handles[#handles + 1] = conn
  local req = w.WinHttpOpenRequest(conn, toWide("GET"), toWide(path), nil, nil, nil, FLAG_SECURE)
  if req == nil then return fail("WinHttpOpenRequest") end
  handles[#handles + 1] = req

  local headers = opts.headers and #opts.headers > 0 and toWide(table.concat(opts.headers, "\r\n")) or nil
  if w.WinHttpSendRequest(req, headers, headers and 0xFFFFFFFF or 0, nil, 0, 0, 0) == 0 then return fail("request to " .. host) end
  if w.WinHttpReceiveResponse(req, nil) == 0 then return fail("response from " .. host) end

  local status = queryNumber(w, req, QUERY_STATUS_CODE) or 0
  local total = queryNumber(w, req, QUERY_CONTENT_LENGTH)
  local parts, received = {}, 0
  local buf = ffi.new("uint8_t[?]", 65536)
  local n = ffi.new("DWORD[1]")
  while true do
    if w.WinHttpReadData(req, buf, 65536, n) == 0 then return fail("download") end
    local got = tonumber(n[0])
    if got == 0 then break end
    received = received + got
    local chunk = ffi.string(buf, got)
    if opts.onChunk then
      local ok, err = opts.onChunk(chunk, received, total)
      if ok == false then
        close()
        return nil, err or "aborted", true
      end
    else
      parts[#parts + 1] = chunk
    end
  end
  close()
  if total and received ~= total then
    return nil, "download was incomplete (" .. received .. " of " .. total .. " bytes)"
  end
  return status, (not opts.onChunk) and table.concat(parts) or nil
end

-- Calls attemptFn() (status, body, aborted) up to opts.retries+1 times,
-- stopping early on success (status ~= nil) or a deliberate abort. Kept
-- separate from H.get so the retry/backoff logic can be unit tested with a
-- fake attemptFn instead of a real network call.
local function withRetries(attemptFn, opts)
  local attempts = (opts.retries or 2) + 1
  local lastErr
  for attempt = 1, attempts do
    if attempt > 1 then
      if opts.onRetry then opts.onRetry(attempt, lastErr) end
      love.timer.sleep(opts.retryDelaySeconds or 1)
    end
    local status, body, aborted = attemptFn()
    if status ~= nil or aborted then return status, body end
    lastErr = body
  end
  return nil, lastErr
end
H._withRetries = withRetries

-- GET `url`. opts:
--   headers          { "Name: value", ... }
--   onChunk          function(data, received, total) -- streams the body
--                     instead of collecting it (total nil when unknown)
--   onRetry          function(attempt, lastError) -- called before each
--                     retry, so a streaming caller can discard whatever it
--                     buffered from the failed attempt before the next one
--                     starts
--   retries          extra attempts after a transient transport-level
--                     failure (default 2, i.e. 3 attempts total); not
--                     retried: a deliberate abort (onChunk returning false)
--                     or a completed response of any HTTP status, which is
--                     the caller's to interpret
--   retryDelaySeconds  pause before each retry (default 1)
--   timeoutMs        receive timeout (default 15000)
-- Returns status, body (nil when streamed) -- or nil, error message.
function H.get(url, opts)
  opts = opts or {}
  return withRetries(function() return getOnce(url, opts) end, opts)
end

return H
