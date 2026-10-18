-- Filesystem (FFI) and uuid checks against a scratch folder in the save dir.
local fs = require("src.data.fs")
local uuid = require("src.core.uuid")
local paths = require("src.data.paths")

return function(t)
  t.describe("uuid", function()
    t.it("v4 format and uniqueness", function()
      local seen = {}
      for _ = 1, 200 do
        local id = uuid.v4()
        t.ok(id:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-4%x%x%x%-[89ab]%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$"), id)
        t.notOk(seen[id])
        seen[id] = true
      end
    end)
  end)

  t.describe("file dialog paths", function()
    t.it("isAbsolute recognizes absolute paths", function()
      local fd = require("src.platform.file_dialog")
      if not fs.isWindows then return end
      local dir = fs.join(love.filesystem.getSaveDirectory(), "dlg_test_dir")
      t.ok(fd.isAbsolute(dir))
      t.notOk(fd.isAbsolute("game_library"))
    end)
    t.it("a non-absolute saved library path falls back to the default", function()
      local paths = require("src.data.paths")
      local settings = require("src.data.settings")
      local key = settings.keys.gamesDirectoryPath
      local before = settings.get(key)
      settings.set(key, "game_library")
      t.eq(paths.gamesDir(), paths.defaultGamesDir())
      settings.set(key, "C:\\Somewhere\\game_library")
      t.eq(paths.gamesDir(), "C:\\Somewhere\\game_library")
      t.errors(function() paths.setGamesDir("relative") end)
      if before == nil then settings.remove(key) else settings.set(key, before) end
    end)
  end)

  t.describe("paths migration", function()
    t.it("does nothing when there's no legacy identity folder", function()
      t.ok(pcall(paths.migrateLegacyIdentity, "cardtable_tests_no_such_legacy_id"))
    end)

    t.it("never overwrites an identity folder that already has settings.json", function()
      local settings = require("src.data.settings")
      settings.set(settings.keys.playerName, settings.get(settings.keys.playerName, "unchanged"))
      local newDir = love.filesystem.getSaveDirectory()
      t.ok(fs.isFile(fs.join(newDir, "settings.json")))

      local legacyName = "cardtable_tests_legacy_fixture"
      local legacyDir = fs.join(fs.dirname(newDir), legacyName)
      fs.removeTree(legacyDir)
      fs.mkdirs(legacyDir)
      fs.writeFile(fs.join(legacyDir, "marker.txt"), "should not be copied")

      paths.migrateLegacyIdentity(legacyName)
      t.notOk(fs.exists(fs.join(newDir, "marker.txt")))

      fs.removeTree(legacyDir)
    end)
  end)

  t.describe("fs", function()
    t.it("path helpers", function()
      t.eq(fs.basename("C:\\a\\b\\card.PNG"), "card.PNG")
      t.eq(fs.extension("C:/a/b/card.PNG"), ".png")
      t.eq(fs.stripExtension("x.y.png"), "x.y")
      t.eq(fs.stripExtension("noext"), "noext")
    end)
    t.it("mkdirs / write / list / copyTree / removeTree (with unicode names)", function()
      love.filesystem.createDirectory("fs_test_tmp")
      local root = fs.join(love.filesystem.getSaveDirectory(), "fs_test_tmp")
      fs.removeTree(root)
      local deep = fs.join(root, "a", "bé")
      t.ok(fs.mkdirs(deep))
      t.ok(fs.writeFile(fs.join(deep, "ünï.txt"), "hi"))
      t.ok(fs.isFile(fs.join(deep, "ünï.txt")))
      t.ok(fs.isDir(deep))
      local items = fs.list(deep)
      t.eq(#items, 1)
      t.eq(items[1].name, "ünï.txt")
      t.eq(items[1].size, 2)
      t.ok(fs.copyTree(fs.join(root, "a"), fs.join(root, "copy")))
      t.eq(fs.readFile(fs.join(root, "copy", "bé", "ünï.txt")), "hi")
      t.ok(fs.removeTree(root))
      t.notOk(fs.exists(root))
      t.isNil(fs.list(root))
    end)

    t.it("mkdirs / write / read / list / exists work past the legacy MAX_PATH limit", function()
      if not fs.isWindows then return end
      love.filesystem.createDirectory("fs_long_tmp")
      local root = fs.join(love.filesystem.getSaveDirectory(), "fs_long_tmp")
      fs.removeTree(root)
      local deep = root
      for i = 1, 12 do deep = fs.join(deep, "segment_" .. i .. "_abcdefghij") end
      t.ok(#deep > 260, "test path should exceed the legacy MAX_PATH limit: " .. #deep .. " chars")
      t.ok(fs.mkdirs(deep))
      t.ok(fs.writeFile(fs.join(deep, "f.txt"), "hi"))
      t.ok(fs.exists(fs.join(deep, "f.txt")))
      t.eq(fs.readFile(fs.join(deep, "f.txt")), "hi")
      local items = fs.list(deep)
      t.eq(#items, 1)
      t.eq(items[1].name, "f.txt")
      t.ok(fs.removeTree(root))
      t.notOk(fs.exists(root))
    end)
  end)
end
