-- Pure parts of src/platform/updater.lua (release selection, helper script)
-- and the hidden-process command-line quoting.
local U = require("src.platform.updater")
local proc = require("src.platform.winproc")
local http = require("src.platform.winhttp")

return function(t)
  t.describe("updater", function()
    t.it("reads the build number from a release tag", function()
      t.eq(U.buildFromTag("v0.1.0+49"), 49)
      t.isNil(U.buildFromTag("v0.1.0"))
      t.isNil(U.buildFromTag(nil))
    end)

    t.it("picks a newer release carrying the asset", function()
      local release = { tag_name = "v0.2.0+7", assets = {
        { name = "other.zip", browser_download_url = "https://x/other.zip", size = 1 },
        { name = "cardtable-windows.zip", browser_download_url = "https://x/c.zip", size = 1234 },
      } }
      t.eq(U.pickRelease(release, 6, "cardtable-windows.zip"), { tag = "v0.2.0+7", url = "https://x/c.zip", size = 1234 })
      t.isNil(U.pickRelease(release, 7, "cardtable-windows.zip"))
      t.isNil(U.pickRelease(release, 1, "missing.zip"))
      t.isNil(U.pickRelease({ message = "Not Found" }, 1, "cardtable-windows.zip"))
    end)

    t.it("excludes only library folders inside the install folder", function()
      local inside = U.pathsInside([[C:\Apps\CardTable]], {
        [[C:\Apps\CardTable\game_library]], "C:/apps/cardtable/deck_library/", [[C:\Apps\CardTableOther\x]], [[D:\Libraries]],
      })
      t.eq(#inside, 2)
      t.eq(inside[1], [[C:\Apps\CardTable\game_library]])
    end)

    t.it("quotes paths in the helper script", function()
      local s = U.helperScript({ installDir = [[C:\It's Here]], stagedDir = [[C:\T\staged]], excludeDirs = { [[C:\It's Here\game_library]] },
        logPath = [[C:\T\log.txt]], exeName = "CardTable.exe" })
      t.ok(s:find([[robocopy 'C:\T\staged' 'C:\It''s Here' /MIR]], 1, true))
      t.ok(s:find([[$excludeDirs = @('C:\It''s Here\game_library')]], 1, true))
      t.ok(s:find([[Join-Path 'C:\It''s Here' 'CardTable.exe']], 1, true))
    end)

    t.it("quotes process arguments", function()
      t.eq(proc.quoteArg("plain"), "plain")
      t.eq(proc.quoteArg([[C:\a b\]]), [["C:\a b\\"]])
      t.eq(proc.quoteArg([[say "hi"]]), [["say \"hi\""]])
    end)

    t.it("parses https URLs only", function()
      t.eq({ http.parseUrl("https://api.github.com/repos/a/b") }, { "api.github.com", 443, "/repos/a/b" })
      t.eq({ http.parseUrl("https://h:8443") }, { "h", 8443, "/" })
      t.isNil(http.parseUrl("http://h/x"))
    end)

    t.it("retries a transient failure and succeeds, calling onRetry each time", function()
      local calls, retries = 0, {}
      local status, body = http._withRetries(function()
        calls = calls + 1
        if calls < 3 then return nil, "read failed" end
        return 200, "ok"
      end, { retryDelaySeconds = 0, onRetry = function(attempt, lastErr) retries[#retries + 1] = { attempt, lastErr } end })
      t.eq(calls, 3)
      t.eq(status, 200)
      t.eq(body, "ok")
      t.eq(retries, { { 2, "read failed" }, { 3, "read failed" } })
    end)

    t.it("gives up after retries are exhausted, returning the last error", function()
      local calls = 0
      local status, err = http._withRetries(function()
        calls = calls + 1
        return nil, "attempt " .. calls .. " failed"
      end, { retries = 2, retryDelaySeconds = 0 })
      t.eq(calls, 3) -- the initial attempt plus 2 retries
      t.isNil(status)
      t.eq(err, "attempt 3 failed")
    end)

    t.it("flags a missing system tool with an actionable, repo-specific message", function()
      local msg = U.missingTool([[C:\Windows\System32\tar.exe]], "tar.exe", "needs Windows 10 1803+", function() return false end)
      t.ok(msg:find("tar.exe", 1, true))
      t.ok(msg:find([[C:\Windows\System32\tar.exe]], 1, true))
      t.ok(msg:find("needs Windows 10 1803+", 1, true))
      t.ok(msg:find("https://github.com/" .. U.repo .. "/releases", 1, true))
    end)

    t.it("returns nil when the tool is present", function()
      t.isNil(U.missingTool([[C:\Windows\System32\tar.exe]], "tar.exe", nil, function() return true end))
    end)

    t.it("does not retry a deliberate abort", function()
      local calls = 0
      local status, err = http._withRetries(function()
        calls = calls + 1
        return nil, "cancelled", true
      end, { retryDelaySeconds = 0 })
      t.eq(calls, 1)
      t.isNil(status)
      t.eq(err, "cancelled")
    end)
  end)
end
