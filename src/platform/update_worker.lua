-- Worker thread body for src/platform/updater.lua. Receives a job and a
-- channel; pushes { phase, progress } updates and finally { done = true,
-- release = ... } (check) or { done = true, error = msgOrNil } (apply).
local job, out = ...

require("love.filesystem")
require("love.data")
require("love.timer")
local ffi = require("ffi")
local json = require("lib.json")
local fs = require("src.data.fs")
local http = require("src.platform.winhttp")
local proc = require("src.platform.winproc")
local U = require("src.platform.updater")

local function check()
  local status, body = http.get("https://api.github.com/repos/" .. job.repo .. "/releases/latest", {
    -- GitHub rejects requests without a User-Agent (WinHttpOpen sets one).
    headers = { "Accept: application/vnd.github+json" },
    timeoutMs = 10000,
  })
  if status ~= 200 then return { done = true, error = status and ("HTTP " .. status) or body } end
  local release = json.tryDecode(body)
  local r = U.pickRelease(release, job.build, job.assetName)
  -- Flat fields: channel messages shouldn't rely on nested tables.
  return { done = true, found = r ~= nil, tag = r and r.tag, url = r and r.url, size = r and r.size }
end

local function system32(exe)
  return fs.join(os.getenv("SystemRoot") or "C:\\Windows", "System32", exe)
end

-- PowerShell -EncodedCommand takes base64 of UTF-16LE, which sidesteps
-- every layer of command-line quoting.
local function encodePs(script)
  local w = fs._impl.toWide(script)
  local n = 0
  while w[n] ~= 0 do n = n + 1 end
  return love.data.encode("string", "base64", ffi.string(w, n * 2))
end

local function apply()
  local tempDir = fs.join(fs.tempDir(), "cardflux_update_" .. os.time())
  fs.mkdirs(tempDir)

  -- Download (kept in memory, then written once: fs.writeFile handles
  -- non-ASCII temp paths, io.open wouldn't).
  out:push({ phase = "downloading", progress = 0 })
  local parts, lastPush = {}, 0
  local status, err = http.get(job.url, {
    timeoutMs = 30000,
    -- A retry restarts the download from byte 0, so whatever this attempt
    -- had already buffered must be discarded first.
    onRetry = function() parts, lastPush = {}, 0 end,
    onChunk = function(chunk, received, total)
      parts[#parts + 1] = chunk
      total = total or job.size
      local now = love.timer.getTime()
      if total and total > 0 and now - lastPush > 0.1 then
        lastPush = now
        out:push({ phase = "downloading", progress = received / total })
      end
    end,
  })
  if status ~= 200 then
    return status and ("Update download failed with HTTP " .. status .. ".") or ("Update download failed: " .. tostring(err))
  end
  local zipPath = fs.join(tempDir, "update.zip")
  if not fs.writeFile(zipPath, table.concat(parts)) then return "Couldn't save the downloaded update." end
  parts = nil

  out:push({ phase = "extracting" })
  local stagedDir = fs.join(tempDir, "staged")
  fs.mkdirs(stagedDir)
  -- Windows' bundled bsdtar reads zip archives.
  local code, perr = proc.run(proc.quoteArg(system32("tar.exe")) .. " -xf " .. proc.quoteArg(zipPath) .. " -C " .. proc.quoteArg(stagedDir),
    { wait = true, timeoutMs = 300000 })
  if code ~= 0 then return "Failed to extract update package (" .. tostring(code or perr) .. ")." end

  out:push({ phase = "verifying" })
  if not fs.isFile(fs.join(stagedDir, job.exeName)) then
    return "Downloaded update package is missing " .. job.exeName .. " -- aborting."
  end

  local scriptPath = fs.join(tempDir, "apply_update.ps1")
  local script = U.helperScript({
    installDir = job.installDir, stagedDir = stagedDir, excludeDirs = job.excludeDirs,
    logPath = fs.join(tempDir, "apply_update.log"), exeName = job.exeName,
  })
  -- BOM so Windows PowerShell reads non-ASCII paths as UTF-8.
  if not fs.writeFile(scriptPath, "\239\187\191" .. script) then return "Couldn't write the update helper script." end

  out:push({ phase = "launchingInstaller" })
  -- Spawned through WMI so the helper is a child of the WMI host, not of
  -- this process: a plain child doesn't reliably survive our exit (Flutter
  -- port finding). The exit code carries WMI's ReturnValue (0 = success).
  local helperCmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" .. scriptPath
    .. "\" -TargetPid " .. proc.currentPid()
  local wmi = "$r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = "
    .. U.psQuote(helperCmd) .. " }; exit [int]$r.ReturnValue"
  local rc, lerr = proc.run(proc.quoteArg(fs.join(system32("WindowsPowerShell"), "v1.0", "powershell.exe"))
    .. " -NoProfile -NonInteractive -EncodedCommand " .. encodePs(wmi), { wait = true, timeoutMs = 60000 })
  if rc ~= 0 then return "Failed to launch update helper (WMI ReturnValue=" .. tostring(rc or lerr) .. ")." end
  return nil
end

local ok, result = pcall(function()
  if job.op == "check" then return check() end
  return { done = true, error = apply() }
end)
out:push(ok and result or { done = true, error = tostring(result) })
