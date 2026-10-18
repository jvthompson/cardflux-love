-- Stack (pile) chain resolution (src/core/stack_utils.lua).
local S = require("src.core.stack_utils")
local H = require("tests.helpers")

return function(t)
  t.describe("stack_utils", function()
    t.it("rootIdOf: a card with no parent is its own root", function()
      local c = H.card({ id = "a" })
      t.eq(S.rootIdOf({ c }, c), "a")
    end)

    t.it("rootIdOf: walks the chain up to the bottom card", function()
      local a = H.card({ id = "a" })
      local b = H.card({ id = "b", stackParentId = "a" })
      local c = H.card({ id = "c", stackParentId = "b" })
      local cards = { a, b, c }
      t.eq(S.rootIdOf(cards, c), "a")
      t.eq(S.rootIdOf(cards, b), "a")
      t.eq(S.rootIdOf(cards, a), "a")
    end)

    t.it("rootIdOf: stops at a dangling parent id instead of erroring", function()
      local c = H.card({ id = "c", stackParentId = "gone" })
      t.eq(S.rootIdOf({ c }, c), "c")
    end)

    t.it("rootIdOf: a cycle terminates instead of looping forever", function()
      local a = H.card({ id = "a", stackParentId = "b" })
      local b = H.card({ id = "b", stackParentId = "a" })
      -- The visited guard trips back at the starting card once both nodes
      -- in the cycle have been seen.
      t.eq(S.rootIdOf({ a, b }, a), "a")
    end)

    t.it("stackOf: every card whose chain resolves to the given root, original order", function()
      local a = H.card({ id = "a" })
      local b = H.card({ id = "b", stackParentId = "a" })
      local other = H.card({ id = "x" })
      local c = H.card({ id = "c", stackParentId = "b" })
      local cards = { a, other, b, c }
      t.eq(t.ids(S.stackOf(cards, "a")), { "a", "b", "c" })
      t.eq(t.ids(S.stackOf(cards, "x")), { "x" })
    end)

    t.it("groupByStack: groups by root, root ids in first-seen order", function()
      local a1 = H.card({ id = "a1" })
      local b1 = H.card({ id = "b1", stackParentId = "a1" })
      local x1 = H.card({ id = "x1" })
      local a2 = H.card({ id = "a2", stackParentId = "a1" })
      local cards = { a1, x1, b1, a2 }
      local groups, order = S.groupByStack(cards)
      t.eq(order, { "a1", "x1" })
      t.eq(t.ids(groups["a1"]), { "a1", "b1", "a2" })
      t.eq(t.ids(groups["x1"]), { "x1" })
    end)

    t.it("topOf: highest zIndex wins, ties keep the earlier card", function()
      local a = H.card({ id = "a", zIndex = 1 })
      local b = H.card({ id = "b", zIndex = 3 })
      local c = H.card({ id = "c", zIndex = 2 })
      t.eq(S.topOf({ a, b, c }).instanceId, "b")
      local d = H.card({ id = "d", zIndex = 5 })
      local e = H.card({ id = "e", zIndex = 5 })
      t.eq(S.topOf({ d, e }).instanceId, "d")
      t.eq(S.topOf({ a }).instanceId, "a")
    end)
  end)
end
