-- Group-qualified card type matching (src/core/tag_match.lua).
local M = require("src.core.tag_match")

return function(t)
  t.describe("tag_match", function()
    t.it("parses qualified and legacy entries", function()
      t.eq({ M.parse("Type|Character") }, { "Type", "Character" })
      t.eq({ M.parse("Character") }, { nil, "Character" })
    end)

    t.it("encodes group and tag", function()
      t.eq(M.encode("Type", "Character"), "Type|Character")
    end)

    t.it("a qualified entry matches only its own group", function()
      t.ok(M.entryMatches("Type|Character", "Type", "Character"))
      t.notOk(M.entryMatches("Type|Character", "Faction", "Character"))
      t.notOk(M.entryMatches("Type|Character", "Type", "Vehicle"))
    end)

    t.it("a legacy bare entry matches by tag name alone", function()
      t.ok(M.entryMatches("Character", "Type", "Character"))
      t.ok(M.entryMatches("Character", "Faction", "Character"))
      t.notOk(M.entryMatches("Character", "Type", "Vehicle"))
    end)

    t.it("hasTag: same tag name in two different groups doesn't cross-match once qualified", function()
      local types = { "Type|Character" }
      t.ok(M.hasTag(types, "Type", "Character"))
      t.notOk(M.hasTag(types, "Faction", "Character"))
    end)

    t.it("removeTag: removes the first matching entry, qualified or legacy", function()
      local types = { "Faction|Character", "Type|Character", "Common" }
      t.ok(M.removeTag(types, "Type", "Character"))
      t.eq(types, { "Faction|Character", "Common" })
      t.ok(M.removeTag(types, "Rarity", "Common"))
      t.eq(types, { "Faction|Character" })
      t.notOk(M.removeTag(types, "Rarity", "Common"))
    end)
  end)
end
