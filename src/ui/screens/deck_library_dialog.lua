-- Port of widgets/deck_library_screen.dart, shown in-game as the 480x560
-- "Load Deck" dialog: the player's own + built-in decks for a game, with
-- validation against the zones being loaded.
local ui = require("src.ui.kit.ui")
local theme = require("src.ui.kit.theme")
local overlays = require("src.ui.kit.overlays")
local models = require("src.core.models")
local paths = require("src.data.paths")
local decks = require("src.data.deck_library")
local fileDialog = require("src.platform.file_dialog")
local sound = require("src.game.sound")
local CR = require("src.ui.table.card_render")
local util = require("src.core.util")
local saveNameDialog = require("src.ui.kit.save_name_dialog")

local D = {}

-- zones: the ZoneDefinitions being filled; onDeckChosen(deck)
-- opts.store: a src/data/deck_store.lua store (default: the local folder).
-- opts.ownedQty: collection mode (definitionId -> copies owned). When set,
-- the game's built-in starter decks (bought from the Card Shop instead) are
-- hidden, and decks the collection can't fully build are greyed out.
function D.open(game, zones, onDeckChosen, opts)
  local store = opts and opts.store
  local ownedQty = opts and opts.ownedQty
  local remote = store and store.kind == "server"
  local st = { directoryPath = remote and store.label or paths.decksDir(), busy = true }

  -- Every card the deck needs, owned in full? Unownable/free cards are
  -- always available; copies are tallied across every subdeck.
  local function isAffordable(deck)
    if not ownedQty then return true end
    local needed = {}
    for _, s in ipairs(deck.subdecks) do
      for _, e in ipairs(s.entries) do needed[e.definitionId] = (needed[e.definitionId] or 0) + e.quantity end
    end
    for id, qty in pairs(needed) do
      local def = models.GameDefinition.cardById(game, id)
      if not (def and (def.unownable or def.isFreeCard)) and (ownedQty[id] or 0) < qty then return false end
    end
    return true
  end

  local function filterScan(scan)
    if not ownedQty then return scan end
    local entries = {}
    for _, e in ipairs(scan.entries) do
      if not (e.isBuiltIn and e.deck.isStarter) then entries[#entries + 1] = e end
    end
    return { entries = entries, incompatible = scan.incompatible }
  end

  local function refresh()
    st.busy = true
    st.folderError = nil
    if remote then
      store:list(game, function(scan, err)
        scan = filterScan(scan)
        st.scan = scan
        if err then
          st.folderError = err
        elseif #scan.entries == 0 and #scan.incompatible == 0 then
          st.folderError = "You haven't saved any decks for " .. game.name .. " on this server yet."
        end
        if st.folderError then sound.play("error") end
        st.busy = false
      end)
      return
    end
    local ok, scan = pcall(decks.loadAllDecksForGame, st.directoryPath, game)
    if not ok then
      st.scan = { entries = {}, incompatible = {} }
      st.folderError = "Could not read that folder: " .. tostring(scan)
    else
      scan = filterScan(scan)
      st.scan = scan
      if #scan.entries == 0 and #scan.incompatible == 0 then
        st.folderError = "No decks found for " .. game.name .. " in that folder."
      end
    end
    if st.folderError then sound.play("error") end
    st.busy = false
  end
  refresh()

  local function missingRequired(deck)
    local out = {}
    for _, z in ipairs(zones) do
      if not z.deckOptional and models.DeckConfig.cardCountFor(deck, z.deckType) == 0 then out[#out + 1] = z.name end
    end
    return out
  end

  local dialog
  local function selectDeck(deck, displayName)
    local missing = missingRequired(deck)
    if #missing > 0 then
      sound.play("error")
      st.selectionError = "That deck is missing required cards for: " .. table.concat(missing, ", ") .. "."
      return
    end
    st.selectionError = nil
    st.chosenDeck, st.chosenName = deck, displayName
    dialog:close()
    onDeckChosen(deck)
  end

  local function browse()
    fileDialog.openFile({ title = "Choose a deck file", filters = fileDialog.jsonFilters }, function(path)
      if not path then return end
      local deck, reason = decks.readDeckFile(path)
      if not deck then
        sound.play("error")
        st.selectionError = reason == "legacy" and models.LegacyDeckFormatError.message or "That file is not a valid deck."
        return
      end
      if deck.gameId ~= game.id then
        sound.play("error")
        st.selectionError = "That deck is for a different game (" .. deck.gameId .. ")."
        return
      end
      selectDeck(deck, require("src.data.fs").basename(path))
    end)
  end

  -- Right-click a deck: Delete Deck, after a confirmation. Local decks are
  -- removed by file (the listed folder); server decks through the store.
  local function deleteDeck(entry)
    local function done(ok, err)
      if not ok then
        sound.play("error")
        overlays.alert("Couldn't Delete Deck", err or 'Could not delete "' .. entry.displayName .. '".')
        return
      end
      if st.chosenName == entry.displayName then st.chosenName, st.chosenDeck = nil, nil end
      st.selectionError = nil
      overlays.toast('Deleted "' .. entry.displayName .. '".')
      refresh()
    end
    if remote then
      store:remove(game, entry.displayName, done)
    else
      done(require("src.data.fs").remove(entry.filePath))
    end
  end

  local function openDeckMenu(entry)
    local mx, my = ui.mouse()
    overlays.menu(mx, my, {
      { label = "Delete Deck", icon = "delete_outline", onSelect = function()
        overlays.confirm("Delete Deck", 'Delete "' .. entry.displayName .. '"? This can\'t be undone.', "Delete",
          function() deleteDeck(entry) end, { danger = true })
      end },
    })
  end

  local function chooseDirectory()
    fileDialog.pickFolder({ title = "Choose your deck library folder", initialDir = st.directoryPath }, function(path)
      if not path then return end
      require("src.ui.screens.game_picker").maybeMoveLibraryFolder(st.directoryPath, path, "deck", function()
        paths.setDecksDir(path)
        st.directoryPath = path
        refresh()
      end)
    end)
  end

  -- Deck tiles match the Deck Editor's card pool: card backs a third larger,
  -- with up to three lines of deck name.
  local SCALE, NAME_LINES, GAP = 4 / 3, 3, 12
  local PW, PH = CR.cardWidth * SCALE, CR.cardHeight * SCALE
  local nameH = NAME_LINES * theme.font(11):getHeight()
  -- One extra caption line in collection mode, for "Missing cards".
  local TILE_H = 4 + PH + 4 + nameH + 2 + 28 + (ownedQty and 13 or 0)

  dialog = overlays.dialog({
    width = 760,
    content = function(d, x, y, w)
      local c = theme.c
      local h = 560 - 48
      ui.text("Load your deck for " .. game.name, x, y, { weight = "bold", w = w, align = "center" })
      local yy = y + 32
      ui.text(st.directoryPath, x, yy, { size = 12, color = c.onSurfaceVariant, w = w - 96, h = 40, valign = "middle", ellipsis = true })
      if ui.iconButton("refresh", x + w - 88, yy, { tooltip = "Refresh", disabled = st.busy, id = "dl:refresh" }) then refresh() end
      if not remote and ui.iconButton("folder_open", x + w - 44, yy, { tooltip = "Choose Deck Library Folder...", disabled = st.busy, id = "dl:folder" }) then
        chooseDirectory()
      end
      yy = yy + 52
      ui.divider(x, yy, w)
      yy = yy + 12
      local bodyH = y + h - yy
      local gridW = w - 240 - 24
      -- Deck grid.
      local entries = st.scan and st.scan.entries or {}
      local incompatible = st.scan and st.scan.incompatible or {}
      if st.busy and remote then
        ui.spinner(x + gridW / 2, yy + bodyH / 2, 14)
      elseif st.folderError then
        ui.text(st.folderError, x, yy, { w = gridW, h = bodyH, align = "center", valign = "middle", color = theme.fixed.red })
      else
        local cols = math.max(1, math.ceil((gridW + GAP) / (PW + 24 + GAP)))
        local TILE_W = (gridW - (cols - 1) * GAP) / cols
        local total = #entries + #incompatible
        local off = ui.beginScroll("dl:grid", x, yy, gridW, bodyH)
        for i = 1, total do
          local col, row = (i - 1) % cols, math.floor((i - 1) / cols)
          local tx, ty = x + col * (TILE_W + GAP), yy + 4 + row * (TILE_H + GAP) - off
          local isIncompat = i > #entries
          local entry = isIncompat and incompatible[i - #entries] or entries[i]
          local short = not isIncompat and not isAffordable(entry.deck)
          local dim = isIncompat and 0.35 or (short and 0.45 or 1)
          local r = ui.region("dl:tile" .. i, tx, ty, TILE_W, TILE_H, { cursor = "hand",
            tooltip = isIncompat and "Old format -- rebuild in the Deck Editor"
              or short and "You don't have all the cards in your collection to build this deck." or nil })
          if r.hovered then ui.rect("fill", tx, ty, TILE_W, TILE_H, 6, theme.alpha(c.onSurface, 0.06)) end
          if not isIncompat and st.chosenName == entry.displayName then
            ui.rect("line", tx + 1, ty + 1, TILE_W - 2, TILE_H - 2, 6, c.primary, 2)
          end
          love.graphics.push("all")
          CR.draw({ def = nil, faceUp = false, cx = tx + TILE_W / 2, cy = ty + 4 + PH / 2, scale = SCALE,
            cardBacks = game.cardBacks, alpha = dim })
          love.graphics.pop()
          local ny = ty + 4 + PH + 4
          ui.text(entry.displayName, tx, ny, { size = 11, w = TILE_W, align = "center", maxLines = NAME_LINES,
            color = short and c.onSurfaceVariant or nil })
          ny = ny + math.min(nameH, ui.textHeight(entry.displayName, TILE_W, 11)) + 2
          if isIncompat then
            ui.text("Old format", tx, ny, { size = 10, w = TILE_W, align = "center", color = theme.fixed.red })
          else
            ui.text(decks.cardCount(entry) .. " card(s)", tx, ny, { size = 10, w = TILE_W, align = "center", color = c.onSurfaceVariant })
            if entry.isBuiltIn then ui.text(entry.deck.isStarter and "Built-in · Starter" or "Built-in", tx, ny + 13, { size = 10, w = TILE_W, align = "center", color = c.primary }) end
            if short then ui.text("Missing cards", tx, ny + (entry.isBuiltIn and 26 or 13), { size = 10, w = TILE_W, align = "center", color = theme.fixed.red }) end
          end
          if r.clicked then
            if isIncompat then
              sound.play("error")
              st.selectionError = 'The deck "' .. entry.displayName .. '" was saved in an older format and needs to be rebuilt in the Deck Editor.'
            else
              selectDeck(entry.deck, entry.displayName)
            end
          end
          -- Built-in decks ship with the game, so they can't be deleted.
          if r.rightClicked and not entry.isBuiltIn then openDeckMenu(entry) end
        end
        ui.endScroll("dl:grid", math.ceil(total / cols) * (TILE_H + GAP) - GAP + 8)
      end
      -- Summary panel.
      local sx = x + gridW + 24
      ui.rect("fill", sx - 12, yy, 1, bodyH, 0, c.outlineVariant)
      local sy = yy
      -- The Deck Editor opens decks without zones to fill: no requirements.
      if #zones > 0 then
        ui.text("This game needs", sx, sy, { weight = "medium" })
        sy = sy + 28
        for _, z in ipairs(zones) do
          ui.text(z.name, sx, sy, { weight = "bold", w = 240, ellipsis = true })
          ui.text(z.deckType .. (z.deckOptional and " (optional)" or " (required)"), sx, sy + 18, { size = 12, color = c.onSurfaceVariant, w = 240, ellipsis = true })
          sy = sy + 44
        end
        ui.divider(sx, sy + 4, 240)
        sy = sy + 16
      end
      local hint = "Click a deck to load it. Right-click one of your decks to delete it."
      ui.text(hint, sx, sy, { size = 12, w = 240, color = c.onSurfaceVariant })
      sy = sy + ui.textHeight(hint, 240, 12) + 8
      if st.selectionError then
        local eh = ui.textHeight(st.selectionError, 240, 12)
        ui.text(st.selectionError, sx, sy, { size = 12, w = 240, color = theme.fixed.red })
        sy = sy + eh + 12
      end
      if not remote and ui.button("Browse for file...", sx - 12, sy, nil, nil, { variant = "text", id = "dl:browse" }) then browse() end
      return h
    end,
    actions = {},
  })
  return dialog
end

-- A checkbox toggling deck.isStarter directly, for promptSaveDeck's footer.
-- Starter decks are a built-in-deck concept (bought with tokens on a
-- collection-mode server instead of built by a player), so it's only
-- offered when the caller isn't a collection-mode deck editor.
local function starterFooter(deck)
  return function(x, y, w)
    deck.isStarter = ui.checkbox("savename:starter", x + 2, y + 7, deck.isStarter,
      { label = "Starter Deck (built-in; players get it free or buy it in collection mode)" })
  end
end

-- Save Deck dialog (save_deck_dialog.dart promptSaveDeckToLibrary).
-- opts.store: a deck_store store; a server store lists its decks first and
-- offers to keep a local copy too.
-- opts.showStarter: offer the "Starter Deck" checkbox (see starterFooter).
function D.promptSaveDeck(game, deck, onSaved, opts)
  local store = opts and opts.store
  local showStarter = opts and opts.showStarter
  if store and store.kind == "server" then return D.promptSaveServerDeck(game, deck, onSaved, store, showStarter) end
  local root = paths.decksDir()
  local scan = decks.loadDecksForGame(root, game)
  saveNameDialog.open({
    title = "Save Deck", width = 816, fieldLabel = "Deck Name", emptyNameMessage = "Enter a deck name.",
    existing = util.map(scan.entries, function(e) return { name = e.displayName, trailing = decks.cardCount(e) .. " card(s)" } end),
    existingHint = "Existing decks -- tap to reuse a name",
    emptyListText = "No decks found for " .. game.name .. ".",
    exists = function(name) return decks.deckExists(root, game.id, name) end,
    overwriteTitle = "Overwrite Deck?",
    overwriteMessage = function(name) return 'A deck named "' .. name .. '" already exists in the library. Overwrite it?' end,
    footerH = showStarter and 40 or nil,
    footer = showStarter and starterFooter(deck) or nil,
    onSave = function(name)
      local path, err = decks.writeDeck(root, game.id, name, deck)
      if path then
        overlays.toast("Saved to " .. path)
        if onSaved then onSaved(name, path) end
      else
        overlays.toast("Could not save the deck: " .. tostring(err))
      end
    end,
  })
end

function D.promptSaveServerDeck(game, deck, onSaved, store, showStarter)
  store:list(game, function(scan, err)
    if err then
      overlays.toast("Could not load your decks: " .. err)
      return
    end
    local mine, names = {}, {}
    for _, e in ipairs(scan.entries) do
      if not e.isBuiltIn then
        mine[#mine + 1] = { name = e.displayName, trailing = decks.cardCount(e) .. " card(s)" }
        names[e.displayName:lower()] = true
      end
    end
    saveNameDialog.open({
      title = "Save Deck to " .. store.label, width = 816, fieldLabel = "Deck Name", emptyNameMessage = "Enter a deck name.",
      existing = mine,
      existingHint = "Your decks on this server -- tap to reuse a name",
      emptyListText = "No decks saved on this server for " .. game.name .. ".",
      exists = function(name) return names[name:lower()] == true end,
      overwriteTitle = "Overwrite Deck?",
      overwriteMessage = function(name) return 'You already have a deck named "' .. name .. '" on this server. Overwrite it?' end,
      footerH = showStarter and 72 or 32,
      footer = function(x, y, w)
        store.alsoLocal = ui.checkbox("savename:local", x + 2, y + 7, store.alsoLocal, { label = "Also save a copy to my local deck library" })
        if showStarter then starterFooter(deck)(x, y + 40, w) end
      end,
      onSave = function(name)
        store:write(game, name, deck, function(ok, werr)
          if ok then
            overlays.toast(werr or ('Saved "' .. name .. '" to ' .. store.label))
            if onSaved then onSaved(name) end
          else
            overlays.toast("Could not save the deck: " .. tostring(werr))
          end
        end)
      end,
    })
  end)
end

return D
