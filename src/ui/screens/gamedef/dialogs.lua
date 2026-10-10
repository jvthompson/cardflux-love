-- Ports of duplicate_card_ids_dialog.dart and
-- duplicate_card_images_dialog.dart.
local ui = require("src.ui.kit.ui")
local theme = require("src.ui.kit.theme")
local overlays = require("src.ui.kit.overlays")
local models = require("src.core.models")
local ops = require("src.data.gamedef_ops")

local D = {}

local function setNames(game)
  local names = {}
  for _, s in ipairs(game.sets) do names[s.id] = s.name end
  return names
end

-- Lets the user re-key every card whose id collides with another's. Edits
-- stay in the dialog until Save; the groups are fixed when it opens so a
-- row doesn't vanish as soon as its id becomes unique.
function D.showDuplicateCardIds(editor)
  local game = editor.game
  local groups = ops.duplicateIdGroups(game.cards)
  if #groups == 0 then
    overlays.toast("No duplicate card IDs found.")
    return
  end
  local names = setNames(game)
  local ids = {}
  for _, g in ipairs(groups) do
    for _, i in ipairs(g.indices) do ids[i] = game.cards[i].id end
  end
  local c = theme.c
  overlays.dialog({
    title = "Duplicate Card IDs",
    width = 480 + 48,
    content = function(_, x, y, w)
      local yy = y
      for gi, g in ipairs(groups) do
        ui.text('"' .. g.key .. '" -- ' .. #g.indices .. " cards", x, yy, { weight = "bold", w = w, ellipsis = true })
        yy = yy + 20 + 8
        for _, i in ipairs(g.indices) do
          local card = game.cards[i]
          local leftW = (w - 8) * 2 / 5
          ui.text(card.cardTitle, x, yy + 4, { w = leftW, ellipsis = true })
          ui.text(card.setId and names[card.setId] or "(no set)", x, yy + 24, { w = leftW, size = 12, ellipsis = true, color = c.onSurfaceVariant })
          ids[i] = ui.textField("dupids:" .. gi .. ":" .. i, x + leftW + 8, yy, w - leftW - 8, ids[i],
            { label = "Card ID", h = 44, labelBackground = c.surfaceContainerHigh })
          yy = yy + 44 + 8
        end
        yy = yy + 12
      end
      return yy - y
    end,
    actions = {
      { label = "Cancel", variant = "text" },
      { label = "Save", variant = "filled", onClick = function()
        for i, id in pairs(ids) do game.cards[i].id = id end
        models.GameDefinition.invalidateIndex(game)
      end },
    },
  })
end

-- Offers to merge each group of same-set, same-image cards into its first
-- card (tags combined); the others are deleted.
function D.showMergeDuplicateImages(editor)
  local game = editor.game
  local groups = ops.duplicateImageGroups(game.cards)
  if #groups == 0 then
    overlays.toast("No duplicate card images found.")
    return
  end
  local names = setNames(game)
  local n = #groups
  local plural = n == 1 and "" or "s"
  local c = theme.c
  overlays.dialog({
    title = "Merge Duplicate Card Images",
    width = 480 + 48,
    content = function(_, x, y, w)
      local intro = "These cards share a set and an image, and will be merged into one entry each, keeping the "
        .. "first one's data and combining their tags. The others will be deleted."
      ui.text(intro, x, y, { w = w, size = 12, color = c.onSurfaceVariant })
      local yy = y + ui.textHeight(intro, w, 12) + 12
      for _, g in ipairs(groups) do
        local first = game.cards[g.indices[1]]
        local setName = first.setId and names[first.setId]
        ui.text(first.cardTitle .. " (" .. (setName or "no set") .. ")", x, yy, { weight = "bold", w = w, ellipsis = true })
        ui.text(#g.indices .. " cards will merge into one.", x, yy + 20, { w = w })
        local types = ops.unionTypes(game.cards, g.indices)
        local tags = #types == 0 and "Tags: (none)" or ("Tags: " .. table.concat(types, ", "))
        ui.text(tags, x, yy + 40, { w = w })
        yy = yy + 40 + ui.textHeight(tags, w, 14) + 12
      end
      return yy - y
    end,
    actions = {
      { label = "Cancel", variant = "text" },
      { label = "Merge " .. n .. " Duplicate Group" .. plural, variant = "filled", onClick = function()
        game.cards = ops.mergeDuplicateImageCards(game.cards)
        models.GameDefinition.invalidateIndex(game)
        overlays.toast("Merged " .. n .. " duplicate group" .. plural .. ".")
      end },
    },
  })
end

return D
