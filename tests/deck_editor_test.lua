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
  end)
end
