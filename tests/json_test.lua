local json = require("lib.json")

return function(t)
  t.describe("json", function()
    t.it("round-trips ordinary nested data", function()
      -- A top-level/array null round-trips as json.null; inside an object it
      -- decodes as an absent key (documented behavior of json.decode).
      local data = { a = 1, b = { "x", "y", { c = true }, json.null }, e = "hé" }
      t.eq(json.decode(json.encode(data)), data)
    end)

    t.it("rejects a deeply nested array before it can blow the Lua stack", function()
      local deepArray = string.rep("[", 1000) .. "1" .. string.rep("]", 1000)
      t.errors(function() json.decode(deepArray) end)
    end)

    t.it("rejects a deeply nested object before it can blow the Lua stack", function()
      local deepObject = string.rep('{"a":', 1000) .. "1" .. string.rep("}", 1000)
      t.errors(function() json.decode(deepObject) end)
    end)

    t.it("still accepts nesting within the limit", function()
      local depth = 30
      local nested = string.rep("[", depth) .. "1" .. string.rep("]", depth)
      local v = json.decode(nested)
      for _ = 1, depth - 1 do v = v[1] end
      t.eq(v[1], 1)
    end)
  end)
end
