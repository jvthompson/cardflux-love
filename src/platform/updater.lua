-- Port of lib/services/update/{update_checker,app_updater}.dart: checks
-- GitHub Releases once per launch and, on request, downloads the release
-- zip, extracts it, and hands off to a detached PowerShell helper that
-- waits for this process to exit, mirrors the new files over the install
-- folder (keeping the game/deck libraries), and relaunches the app.
--
-- Network/disk work runs on a worker thread (src/platform/update_worker.lua).
-- Only a fused (packaged) Windows build checks or installs: a dev run's
-- "install folder" is the source tree.
local fs = require("src.data.fs")
local version = require("src.version")

local U = {}

U.repo = version.releaseRepo
U.assetName = version.releaseAssetName
U.exeName = version.exeName

-- State read by the Home banner.
U.state = { available = false }

---------------------------------------------------------------------------
-- Pure helpers
---------------------------------------------------------------------------

-- Build number from a release tag like "v0.1.0+49".
function U.buildFromTag(tag)
  local n = type(tag) == "string" and tag:match("%+(%d+)$")
  return n and tonumber(n) or nil
end

-- From a decoded /releases/latest response: { tag, url, size } when it's
-- newer than localBuild and carries the expected asset, else nil.
function U.pickRelease(release, localBuild, assetName)
  if type(release) ~= "table" then return nil end
  local tag = release.tag_name
  local remote = U.buildFromTag(tag)
  if not remote or remote <= localBuild then return nil end
  for _, a in ipairs(release.assets or {}) do
    if type(a) == "table" and a.name == assetName and type(a.browser_download_url) == "string" then
      return { tag = tag, url = a.browser_download_url, size = tonumber(a.size) }
    end
  end
  return nil
end

local function lowerNorm(p) return fs.normalize(p):gsub("[/\\]+$", ""):lower() end

-- The candidate folders that sit inside installDir (so the mirror step
-- leaves them alone), normalized.
function U.pathsInside(installDir, candidates)
  local root = lowerNorm(installDir)
  local out = {}
  for _, c in ipairs(candidates) do
    if c and c ~= "" then
      local n = lowerNorm(c)
      if n:sub(1, #root + 1) == root .. "\\" or n:sub(1, #root + 1) == root .. "/" then
        out[#out + 1] = fs.normalize(c):gsub("[/\\]+$", "")
      end
    end
  end
  return out
end

local function psQuote(s) return "'" .. tostring(s):gsub("'", "''") .. "'" end
U.psQuote = psQuote

-- Checked up front by update_worker.lua so a locked-down install (one of
-- these stripped or blocked by policy) fails fast with something
-- actionable, before wasting a download on an update it can't apply
-- anyway. `exists` is injectable for testing; defaults to fs.isFile.
function U.missingTool(path, friendlyName, note, exists)
  exists = exists or fs.isFile
  if exists(path) then return nil end
  return friendlyName .. " (" .. path .. ") is missing from this Windows installation"
    .. (note and (" -- " .. note) or "") .. ". Download the update manually from https://github.com/"
    .. U.repo .. "/releases instead."
end

-- The detached helper: wait for us to exit, robocopy /MIR the staged build
-- over the install folder (excluding the libraries), relaunch, clean up.
function U.helperScript(o)
  local excludes = {}
  for _, d in ipairs(o.excludeDirs or {}) do excludes[#excludes + 1] = psQuote(d) end
  return table.concat({
    "param([int]$TargetPid)",
    "Start-Transcript -Path " .. psQuote(o.logPath) .. " -Append | Out-Null",
    "",
    "# Wait for the app to release its file/DLL locks before copying.",
    "Wait-Process -Id $TargetPid -Timeout 30 -ErrorAction SilentlyContinue",
    "",
    "$excludeDirs = @(" .. table.concat(excludes, ", ") .. ")",
    "robocopy " .. psQuote(o.stagedDir) .. " " .. psQuote(o.installDir) .. " /MIR /XD @excludeDirs /NFL /NDL /NJH /R:3 /W:1",
    "$rc = $LASTEXITCODE",
    "# Robocopy exit codes 0-7 are success bit flags; only >= 8 is a failure.",
    "if ($rc -ge 8) {",
    "  Write-Host \"robocopy failed with exit code $rc\"",
    "  Stop-Transcript | Out-Null",
    "  exit 1",
    "}",
    "",
    "Start-Process -FilePath (Join-Path " .. psQuote(o.installDir) .. " " .. psQuote(o.exeName) .. ") -WorkingDirectory " .. psQuote(o.installDir),
    "",
    "Stop-Transcript | Out-Null",
    "Remove-Item -Path " .. psQuote(o.stagedDir) .. " -Recurse -Force -ErrorAction SilentlyContinue",
    "Remove-Item -Path (Split-Path " .. psQuote(o.stagedDir) .. " -Parent) -Recurse -Force -ErrorAction SilentlyContinue",
    "Remove-Item -Path $MyInvocation.MyCommand.Path -Force -ErrorAction SilentlyContinue",
    "",
  }, "\r\n")
end

---------------------------------------------------------------------------
-- Main-thread API
---------------------------------------------------------------------------

function U.supported()
  return fs.isWindows and love.filesystem.isFused()
end

local jobs = {}

local function spawn(job, onMessage)
  local channel = love.thread.newChannel()
  local thread = love.thread.newThread("src/platform/update_worker.lua")
  thread:start(job, channel)
  jobs[#jobs + 1] = { channel = channel, thread = thread, onMessage = onMessage }
end

-- Best-effort: any failure just leaves U.state.available false.
-- `force` checks even in a dev run (used by --update-check).
function U.check(force)
  if not force and not U.supported() then return end
  spawn({ op = "check", repo = U.repo, assetName = U.assetName, build = version.build }, function(m)
    if m.done and m.found then
      U.state = { available = true, tag = m.tag, url = m.url, size = m.size }
    elseif m.done and m.error then
      print("Update check: " .. m.error)
    end
  end)
end

-- Downloads and stages U.state's release, then launches the helper.
-- onProgress(phase, fraction|nil) with phase "downloading", "extracting",
-- "verifying" or "launchingInstaller"; onDone(errorOrNil). On success the
-- caller must quit right away so the helper can replace the files.
function U.apply(onProgress, onDone)
  if not U.supported() then
    return onDone("Updates can only be installed from a packaged build.")
  end
  local paths = require("src.data.paths")
  local installDir = paths.appDir()
  spawn({
    op = "apply",
    url = U.state.url,
    size = U.state.size,
    installDir = installDir,
    excludeDirs = U.pathsInside(installDir, { paths.gamesDir(), paths.decksDir() }),
    exeName = U.exeName,
  }, function(m)
    if m.phase then onProgress(m.phase, m.progress) end
    if m.done then onDone(m.error) end
  end)
end

function U.update()
  for i = #jobs, 1, -1 do
    local j = jobs[i]
    while true do
      local m = j.channel:pop()
      if m == nil then break end
      j.onMessage(m)
      if m.done then j.finished = true end
    end
    if j.finished then
      table.remove(jobs, i)
    elseif not j.thread:isRunning() then
      table.remove(jobs, i)
      j.onMessage({ done = true, error = tostring(j.thread:getError() or "update worker stopped") })
    end
  end
end

return U
