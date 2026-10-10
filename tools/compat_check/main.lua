-- File-format compatibility check against an existing Cardflux (Flutter)
-- library. Usage:
--   lovec tools/compat_check <libraryRoot>
-- where <libraryRoot> contains game_library/ and deck_library/.
--
-- For every game definition, deck and save it reports: load errors, missing
-- or undecodable images (one sample decode per extension per game), and
-- (every image with --all-images) and whether re-saving reproduces the original file (byte-identical, identical
-- apart from Dart's "1.0"-style number formatting, or a real data change).

local projectRoot = love.filesystem.getSource():gsub("[/\\]tools[/\\]compat_check[/\\]?$", "")
package.path = projectRoot .. "/?.lua;" .. package.path

local json = require("lib.json")
local fs = require("src.data.fs")
local models = require("src.core.models")
local loader = require("src.data.game_loader")
local resolver = require("src.data.image_resolver")
local decks = require("src.data.deck_library")
local saves = require("src.data.save_files")
local imageUtils = require("src.data.image_utils")

DECODE_ALL = false
local out = {}
local function say(fmt, ...) local s = string.format(fmt, ...) print(s) out[#out + 1] = s end
local problems = 0
local function problem(fmt, ...) problems = problems + 1 say("  PROBLEM: " .. fmt, ...) end

-- Structural diff of two decoded JSON values; returns list of path strings.
local function diff(a, b, path, acc)
  acc = acc or {}
  path = path or "$"
  if #acc >= 8 then return acc end
  if type(a) ~= type(b) then
    acc[#acc + 1] = string.format("%s: %s vs %s", path, tostring(a), tostring(b))
  elseif type(a) == "table" then
    local keys = {}
    for k in pairs(a) do keys[k] = true end
    for k in pairs(b) do keys[k] = true end
    for k in pairs(keys) do diff(a[k], b[k], path .. "." .. tostring(k), acc) end
  elseif a ~= b then
    acc[#acc + 1] = string.format("%s: %s vs %s", path, tostring(a), tostring(b))
  end
  return acc
end

local function norm(s)
  s = s:gsub("\r\n", "\n"):gsub("%s+$", "")
  return s
end

-- Dart writes whole doubles as "1.0"; Lua can't tell 1 from 1.0.
local function stripDotZero(s)
  return (s:gsub("(%d)%.0([,%s%]}])", "%1%2"))
end

-- Compares original file text with our re-encoding. Returns a verdict.
local function compare(label, originalText, ourText)
  local a, b = norm(originalText), norm(ourText)
  if a == b then return "identical" end
  if stripDotZero(a) == stripDotZero(b) then return "identical except number formatting (1.0 vs 1)" end
  local da, db = json.decode(a), json.decode(b)
  -- Pre-multiple-card-backs files: both Flutter and this port turn the old
  -- cardBackImagePath into a one-entry cardBacks list on save.
  if da.cardBackImagePath ~= nil and da.cardBacks == nil and db.cardBacks ~= nil then
    local migrated = json.decode(a)
    migrated.cardBackImagePath = nil
    migrated.cardBacks = db.cardBacks
    if #diff(migrated, db) == 0 then
      return "legacy cardBackImagePath migrated to cardBacks (Flutter does the same on save)"
    end
  end
  local d = diff(da, db)
  if #d == 0 then return "same data, different layout/key order" end
  problem("%s re-saves differently:", label)
  for _, line in ipairs(d) do say("      %s", line) end
  return "DATA DIFFERS"
end

local function checkGames(gamesRoot)
  say("== Games in %s", gamesRoot)
  local games, errors = loader.loadGamesFromDirectory(gamesRoot)
  for _, e in ipairs(errors) do problem("could not load %s: %s", e.path, e.error) end
  for _, g in ipairs(games) do
    say("\n-- %s (%s): %d cards, %d sets, %d zones, %d tag groups, %d card backs",
      g.name, g.id, #g.cards, #g.sets, #g.zones, #g.tagGroups, #g.cardBacks)
    -- Round trip the raw file (bare paths) rather than the resolved model.
    local path = fs.join(g.folderPath, "gamedef.json")
    for _, e in ipairs(fs.list(g.folderPath)) do
      if e.name:lower() == "gamedef.json" then path = fs.join(g.folderPath, e.name) end
    end
    local raw = fs.readFile(path)
    local reencoded = json.encode(models.GameDefinition.toJson(models.GameDefinition.fromJson(json.decode(raw))), { indent = "  " })
    say("  gamedef.json round trip: %s", compare("gamedef.json", raw, reencoded))

    -- Images
    local missing, byExt, sampled = {}, {}, {}
    local uniqueMissing = 0
    local decodedCount = 0
    for _, c in ipairs(g.cards) do
      if c.imagePath then
        local ext = fs.extension(c.imagePath)
        byExt[ext] = (byExt[ext] or 0) + 1
        if not fs.isFile(c.imagePath) then
          missing[#missing + 1] = c.id .. " -> " .. c.imagePath
        elseif DECODE_ALL then
          local data, err = imageUtils.decodeFile(c.imagePath)
          if data then
            data:release()
            decodedCount = decodedCount + 1
          else
            problem("image fails to decode: %s (%s)", c.imagePath, tostring(err))
          end
        elseif not sampled[ext] then
          sampled[ext] = true
          local data, err = imageUtils.decodeFile(c.imagePath)
          if data then
            say("  sample %s decodes OK (%dx%d): %s", ext, data:getWidth(), data:getHeight(), fs.basename(c.imagePath))
          else
            problem("%s image fails to decode: %s (%s)", ext, c.imagePath, tostring(err))
          end
        end
      end
      if c.cardBackId == models.uniqueCardBackId then
        local _, isMissing = resolver.resolveCardBackImagePath(g.cardBacks, c)
        if isMissing then uniqueMissing = uniqueMissing + 1 end
      end
    end
    local exts = {}
    for ext, n in pairs(byExt) do exts[#exts + 1] = string.format("%s x%d", ext == "" and "(none)" or ext, n) end
    table.sort(exts)
    say("  card images by type: %s", #exts > 0 and table.concat(exts, ", ") or "none (code-drawn cards)")
    if DECODE_ALL then say("  decoded all %d existing card images", decodedCount) end
    if #missing > 0 then
      problem("%d card image(s) missing on disk, e.g.:", #missing)
      for i = 1, math.min(5, #missing) do say("      %s", missing[i]) end
    end
    if uniqueMissing > 0 then say("  note: %d card(s) use a Unique back with no _BACK file (Flutter shows an error placeholder too)", uniqueMissing) end
    for _, b in ipairs(g.cardBacks) do
      if b.imagePath and not fs.isFile(b.imagePath) then problem("card back '%s' image missing: %s", b.name, b.imagePath) end
    end
    say("  logo: %s, pack generator image: %s",
      resolver.resolveGameLogoImagePath(g.folderPath) and "yes" or "no",
      resolver.resolvePackGeneratorImagePath(g.folderPath) and "yes" or "no")

    -- Built-in decks and saves inside the game folder
    local builtIn = decks.loadBuiltInDecksForGame(g)
    if #builtIn.entries + #builtIn.incompatible > 0 then
      say("  built-in decks: %d (%d old-format)", #builtIn.entries, #builtIn.incompatible)
    end
    for _, s in ipairs(saves.listSaveGames(g.folderPath)) do
      local rawSave = fs.readFile(s.filePath)
      local save = saves.readSaveGame(s.filePath)
      local unknown = 0
      for _, c in ipairs(save.state.cards) do
        if not models.GameDefinition.cardById(g, c.definitionId) then unknown = unknown + 1 end
      end
      say("  save '%s' (%s, %d players, %d cards, %d widgets, %d log lines): round trip %s",
        s.displayName, saves.formatSavedAt(s.savedAt), s.playerCount, #save.state.cards, #save.state.widgets,
        #save.state.log, compare("save " .. s.displayName, rawSave, json.encode(models.SavedGame.toJson(save), { indent = "  " })))
      if unknown > 0 then problem("save '%s' references %d card(s) not in the game", s.displayName, unknown) end
    end
    local saveDir = fs.join(g.folderPath, "savegames")
    for _, e in ipairs(fs.list(saveDir) or {}) do
      if e.name:lower():match("%.json$") and not saves.readSaveGame(fs.join(saveDir, e.name)) then
        problem("save file unreadable: %s", e.name)
      end
    end
  end
  return games
end

local function checkDecks(decksRoot, games)
  say("\n== Decks in %s", decksRoot)
  local byId = {}
  for _, g in ipairs(games) do byId[g.id] = g end
  for _, dir in ipairs(fs.list(decksRoot) or {}) do
    if dir.isDir then
      local g = byId[dir.name]
      if not g then
        say("\n-- folder '%s': no loaded game has this id", dir.name)
      end
      for _, e in ipairs(fs.list(fs.join(decksRoot, dir.name)) or {}) do
        if not e.isDir and e.name:lower():match("%.json$") then
          local path = fs.join(decksRoot, dir.name, e.name)
          local deck, reason = decks.readDeckFile(path)
          if not deck then
            if reason == "legacy" then
              say("  %s/%s: old format (Flutter also rejects it)", dir.name, e.name)
            else
              problem("%s/%s: %s", dir.name, e.name, reason)
            end
          else
            local unknown = 0
            if g then
              for _, s in ipairs(deck.subdecks) do
                for _, en in ipairs(s.entries) do
                  if not models.GameDefinition.cardById(g, en.definitionId) then unknown = unknown + 1 end
                end
              end
            end
            say("  %s/%s: %d cards in %d subdeck(s), gameId %s%s; round trip %s", dir.name, e.name,
              models.DeckConfig.totalCardCount(deck), #deck.subdecks, deck.gameId,
              (g and deck.gameId ~= g.id) and " (MISMATCH: not listed for this game)" or "",
              compare("deck " .. e.name, fs.readFile(path), json.encode(models.DeckConfig.toJson(deck))))
            if unknown > 0 then problem("%s/%s references %d unknown card id(s)", dir.name, e.name, unknown) end
          end
        end
      end
    end
  end
end

function love.load(args)
  local root
  for _, a in ipairs(args) do
    if a == "--all-images" then DECODE_ALL = true elseif not root then root = a end
  end
  if not root then
    print("usage: lovec tools/compat_check <libraryRoot>")
    love.event.quit(2)
    return
  end
  local t0 = love.timer.getTime()
  local games = checkGames(fs.join(root, "game_library"))
  checkDecks(fs.join(root, "deck_library"), games)
  say("\n== Done in %.1fs: %d game(s), %d problem(s)", love.timer.getTime() - t0, #games, problems)
  love.filesystem.write("compat_report.txt", table.concat(out, "\n"))
  love.event.quit(problems == 0 and 0 or 1)
end
