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
        { name = "cardflux-windows.zip", browser_download_url = "https://x/c.zip", size = 1234 },
      } }
      t.eq(U.pickRelease(release, 6, "cardflux-windows.zip"), { tag = "v0.2.0+7", url = "https://x/c.zip", size = 1234 })
      t.isNil(U.pickRelease(release, 7, "cardflux-windows.zip"))
      t.isNil(U.pickRelease(release, 1, "missing.zip"))
      t.isNil(U.pickRelease({ message = "Not Found" }, 1, "cardflux-windows.zip"))
    end)

    t.it("excludes only library folders inside the install folder", function()
      local inside = U.pathsInside([[C:\Apps\Cardflux]], {
        [[C:\Apps\Cardflux\game_library]], "C:/apps/cardflux/deck_library/", [[C:\Apps\CardfluxOther\x]], [[D:\Libraries]],
      })
      t.eq(#inside, 2)
      t.eq(inside[1], [[C:\Apps\Cardflux\game_library]])
    end)

    t.it("quotes paths in the helper script", function()
      local s = U.helperScript({ installDir = [[C:\It's Here]], stagedDir = [[C:\T\staged]], excludeDirs = { [[C:\It's Here\game_library]] },
        logPath = [[C:\T\log.txt]], exeName = "Cardflux.exe" })
      t.ok(s:find([[robocopy 'C:\T\staged' 'C:\It''s Here' /MIR]], 1, true))
      t.ok(s:find([[$excludeDirs = @('C:\It''s Here\game_library')]], 1, true))
      t.ok(s:find([[Join-Path 'C:\It''s Here' 'Cardflux.exe']], 1, true))
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
  end)
end
