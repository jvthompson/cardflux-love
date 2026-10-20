-- Deck Editor slot/quantity logic (deck_editor_screen.dart).
local H = require("tests.helpers")
local models = require("src.core.models")
local DE = require("src.ui.screens.deck_editor")

return function(t)
  local function zone(f)
    f.dealsBuiltDeck = f.dealsBuiltDeck ~= false
    return models.ZoneDefinition.new(f)
  end
  local function game(zones)
    return models.GameDefinition.new({ id = "g", name = "G", zones = zones or {},
      cards = { H.cardDef("a"), H.cardDef("b"), H.cardDef("c") } })
  end

  t.describe("deck slots", function()
    t.it("uses a single main_deck slot when no zone builds a deck", function()
      local slots = DE.buildSlots(game())
      t.eq(#slots, 1)
      t.eq(slots[1].deckType, "main_deck")
      t.eq(slots[1].label, "Deck")
      t.ok(slots[1].required)
    end)
    t.it("groups zones by deck type, labeled by the first zone", function()
      local slots = DE.buildSlots(game({
        zone({ id = "z1", name = "Library", deckType = "main", deckOptional = true }),
        zone({ id = "z2", name = "Sideboard", deckType = "side", deckOptional = true }),
        zone({ id = "z3", name = "Second Library", deckType = "main" }),
      }))
      t.eq(#slots, 2)
      t.eq(slots[1].label, "Library")
      t.ok(slots[1].required, "required when any zone of the type is required")
      t.notOk(slots[2].required)
    end)
  end)

  t.describe("editing", function()
    t.it("adds and removes copies in insertion order", function()
      local e = DE.Editor.new(game())
      e:addCopy("b")
      e:addCopy("a")
      e:addCopy("b")
      e:removeCopy("a")
      e:removeCopy("c")
      e:addCopy("c")
      local deck = e:buildDeckConfig()
      t.eq(deck.gameId, "g")
      local entries = models.DeckConfig.entriesFor(deck, "main_deck")
      t.eq(#entries, 2)
      t.eq(entries[1].definitionId, "b")
      t.eq(entries[1].quantity, 2)
      t.eq(entries[2].definitionId, "c")
    end)
    t.it("keeps each slot separate and loads decks, dropping unknown cards", function()
      local e = DE.Editor.new(game({
        zone({ id = "z1", name = "Main", deckType = "main" }),
        zone({ id = "z2", name = "Side", deckType = "side", deckOptional = true }),
      }))
      e:addCopy("a")
      e.activeDeckType = "side"
      e:addCopy("b")
      local deck = e:buildDeckConfig()
      t.eq(models.DeckConfig.cardCountFor(deck, "main"), 1)
      t.eq(models.DeckConfig.cardCountFor(deck, "side"), 1)

      local loaded = models.DeckConfig.new("g", {
        models.SubDeck.new("main", { models.DeckEntry.new("c", 3), models.DeckEntry.new("gone", 2) }),
      })
      e:loadDeck(loaded)
      local after = e:buildDeckConfig()
      t.eq(models.DeckConfig.cardCountFor(after, "main"), 3)
      t.eq(models.DeckConfig.cardCountFor(after, "side"), 0)
    end)
    t.it("defaults isStarter to false and carries it through load/build", function()
      local e = DE.Editor.new(game())
      t.eq(e:buildDeckConfig().isStarter, false)
      e:loadDeck(models.DeckConfig.new("g", {}, true))
      t.ok(e.isStarter)
      t.ok(e:buildDeckConfig().isStarter)
    end)
  end)
  t.describe("collection limits", function()
    local function owned(qty)
      local g = game({ zone({ id = "z1", name = "Main", deckType = "main" }), zone({ id = "z2", name = "Side", deckType = "side", deckOptional = true }) })
      g.cards[3].unownable = true
      return DE.Editor.new(g, { ownedQty = qty })
    end
    t.it("caps copies at the owned count across every slot", function()
      local e = owned({ a = 2 })
      e:addCopy("a"); e:addCopy("a"); e:addCopy("a")
      t.eq(e:copiesInDeck("a"), 2)
      e.activeDeckType = "side"
      e:addCopy("a")
      t.eq(e:copiesInDeck("a"), 2)
      e:addCopy("b")
      t.eq(e:copiesInDeck("b"), 0)
    end)
    t.it("treats unownable cards as unlimited", function()
      local e = owned({})
      for _ = 1, 5 do e:addCopy("c") end
      t.eq(e:copiesInDeck("c"), 5)
    end)
    t.it("pool shows only owned and unownable cards", function()
      local ids = {}
      for _, d in ipairs(owned({ a = 1 }):visibleCards()) do ids[#ids + 1] = d.id end
      table.sort(ids)
      t.eq(table.concat(ids, ","), "a,c")
    end)
    t.it("loading a deck trims copies the collection lacks", function()
      local e = owned({ a = 1, b = 3 })
      e:loadDeck(models.DeckConfig.new("g", {
        models.SubDeck.new("main", { models.DeckEntry.new("a", 3), models.DeckEntry.new("b", 2) }),
        models.SubDeck.new("side", { models.DeckEntry.new("b", 2), models.DeckEntry.new("c", 4) }),
      }))
      t.eq(e:copiesInDeck("a"), 1)
      t.eq(e:copiesInDeck("b"), 3)
      t.eq(e:copiesInDeck("c"), 4)
      t.eq(e.quantitiesBySlot.main.qty.b, 2) -- later slots give way first
    end)
    t.it("treats free cards as always owned and unlimited", function()
      local e = owned({ a = 1 })
      e.game.cards[2].isFreeCard = true
      for _ = 1, 6 do e:addCopy("b") end
      t.eq(e:copiesInDeck("b"), 6)
      local ids = {}
      for _, d in ipairs(e:visibleCards()) do ids[#ids + 1] = d.id end
      table.sort(ids)
      t.eq(table.concat(ids, ","), "a,b,c")
      e:loadDeck(models.DeckConfig.new("g", { models.SubDeck.new("main", { models.DeckEntry.new("b", 20) }) }))
      t.eq(e:copiesInDeck("b"), 20)
    end)
  end)
end
