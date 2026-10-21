-- Port of lib/data/game_definition_file_ops.dart (Game Definition Editor
-- file helpers) and library_folder_migration.dart.
local json = require("lib.json")
local fs = require("src.data.fs")
local models = require("src.core.models")
local tagMatch = require("src.core.tag_match")

local O = {}

O.imageExtensions = { [".jpg"] = true, [".jpeg"] = true, [".png"] = true, [".webp"] = true }
O.imageFilterList = { "jpg", "jpeg", "png", "webp" }

function O.basenameOf(path)
  local trimmed = path:gsub("[/\\]+$", "")
  return trimmed:match("([^/\\]*)$")
end

O.deriveIdFromFolderPath = O.basenameOf
O.stripExtension = fs.stripExtension

-- Appends _001, _002, ... until the id is unused. takenIds is a set.
function O.uniqueCardId(baseId, takenIds)
  if not takenIds[baseId] then return baseId end
  local suffix = 1
  local candidate
  repeat
    candidate = string.format("%s_%03d", baseId, suffix)
    suffix = suffix + 1
  until not takenIds[candidate]
  return candidate
end

function O.isImageFile(fileName)
  local ext = fileName:match("^.*(%.[^.]*)$")
  return ext ~= nil and O.imageExtensions[ext:lower()] == true
end

local function absolute(p)
  p = fs.normalize(p)
  if fs.isWindows then return p:lower():gsub("\\+$", "") end
  return (p:gsub("/+$", ""))
end

function O.isSamePath(a, b) return absolute(a) == absolute(b) end

function O.findGameDefFile(folderPath)
  for _, e in ipairs(fs.list(folderPath) or {}) do
    if not e.isDir and e.name:lower() == "gamedef.json" then return fs.join(folderPath, e.name) end
  end
  return nil
end

local function imageUtils() return require("src.data.image_utils") end

-- Copies sourcePath to destFolder/fileName (no-op if they're the same
-- file), optionally rotating landscape art to portrait.
function O.copyIntoFolder(sourcePath, destFolderPath, fileName, correctCardOrientation)
  local destPath = fs.join(destFolderPath, fileName)
  if O.isSamePath(sourcePath, destPath) then return destPath end
  fs.mkdirs(destFolderPath)
  if not fs.copy(sourcePath, destPath) then return nil, "could not copy " .. sourcePath end
  if correctCardOrientation then imageUtils().rotateLandscapeImages({ destPath }) end
  return destPath
end

-- Copies a picked image into the game folder; returns its bare file name.
function O.copyPickedImage(sourcePath, destFolderPath, correctCardOrientation)
  local fileName = O.basenameOf(sourcePath)
  local ok, err = O.copyIntoFolder(sourcePath, destFolderPath, fileName, correctCardOrientation)
  if not ok then return nil, err end
  return fileName
end

-- Copies every image in a folder (rotating landscape ones), batching the
-- rotation so JPEGs need a single helper process.
function O.copySetImages(sourceFolderPath, destFolderPath)
  if O.isSamePath(sourceFolderPath, destFolderPath) then return end
  local items = fs.list(sourceFolderPath)
  if not items then return end
  fs.mkdirs(destFolderPath)
  local copied = {}
  for _, e in ipairs(items) do
    if not e.isDir and O.isImageFile(e.name) then
      local dest = fs.join(destFolderPath, e.name)
      if fs.copy(fs.join(sourceFolderPath, e.name), dest) then copied[#copied + 1] = dest end
    end
  end
  imageUtils().rotateLandscapeImages(copied)
end

-- One CardDefinition per image (sorted by name), skipping *_BACK art.
-- existingCardIds is a list or set of ids already in the game.
function O.buildCardsFromImageFolder(sourceFolderPath, setId, existingCardIds)
  local items = fs.list(sourceFolderPath)
  if not items then return {} end
  local names = {}
  for _, e in ipairs(items) do
    if not e.isDir and O.isImageFile(e.name) then
      local stem = fs.stripExtension(e.name)
      if stem:sub(-#models.cardBackFileSuffix) ~= models.cardBackFileSuffix then names[#names + 1] = e.name end
    end
  end
  table.sort(names) -- byte order, like Dart's String.compareTo for ASCII names
  local taken = {}
  for k, v in pairs(existingCardIds or {}) do
    if type(k) == "number" then taken[v] = true else taken[k] = true end
  end
  local cards = {}
  for _, name in ipairs(names) do
    local title = fs.stripExtension(name)
    local id = O.uniqueCardId(title, taken)
    taken[id] = true
    cards[#cards + 1] = models.CardDefinition.new({ id = id, cardTitle = title, imagePath = name, setId = setId })
  end
  return cards
end

-- Writes gamedef.json (2-space indent). `game` must hold bare image file
-- names (the editor keeps them bare), not resolved absolute paths.
function O.writeGameDefinition(folderPath, game)
  fs.mkdirs(folderPath)
  return fs.writeFile(fs.join(folderPath, "gamedef.json"),
    json.encode(models.GameDefinition.toJson(game), { indent = "  " }))
end

---------------------------------------------------------------------------
-- Editor entry (game_definition_editor_entry_screen.dart)
---------------------------------------------------------------------------

-- Validates a typed game id as a folder name; returns an error or nil.
function O.validateGameId(id)
  if id == "" then return "Enter a game ID." end
  if id == "." or id == ".." then return "Invalid ID." end
  if id:find('[/\\:*?"<>|]') then return 'ID cannot contain: / \\ : * ? " < > |' end
  return nil
end

-- Loads a gamedef.json WITHOUT resolving image paths: the editor needs the
-- bare file names so saving writes them back unchanged. Errors on bad JSON.
function O.loadGameDefFile(jsonPath, folderPath)
  local raw = assert(fs.readFile(jsonPath))
  local game = models.GameDefinition.fromJson(json.decode(raw))
  game.folderPath = folderPath
  return game
end

-- Every direct subfolder of root holding a gamedef.json, loaded unresolved
-- and sorted by name (case-insensitive). Unparsable files are skipped.
function O.scanGameLibrary(root)
  local out = {}
  for _, e in ipairs(fs.list(root) or {}) do
    if e.isDir then
      local folder = fs.join(root, e.name)
      local path = O.findGameDefFile(folder)
      if path then
        local ok, game = pcall(O.loadGameDefFile, path, folder)
        if ok then out[#out + 1] = { folderPath = folder, game = game } end
      end
    end
  end
  table.sort(out, function(a, b) return a.game.name:lower() < b.game.name:lower() end)
  return out
end

-- Writes a stub gamedef.json under root/id; returns folderPath, game.
function O.createGameDefinition(root, id)
  local folderPath = fs.join(root, id)
  local game = models.GameDefinition.new({ id = id, name = id, folderPath = folderPath })
  assert(O.writeGameDefinition(folderPath, game))
  return folderPath, game
end

---------------------------------------------------------------------------
-- Duplicate checks (duplicate_card_ids_dialog.dart,
-- duplicate_card_images_dialog.dart)
---------------------------------------------------------------------------

-- Groups card indices by keyOf(card) (nil = skip), keeping only groups of
-- two or more, in first-seen order: { {key=, indices={...}}, ... }.
local function groupBy(cards, keyOf)
  local groups, byKey = {}, {}
  for i, c in ipairs(cards) do
    local k = keyOf(c)
    if k ~= nil then
      local g = byKey[k]
      if not g then
        g = { key = k, indices = {} }
        byKey[k] = g
        groups[#groups + 1] = g
      end
      g.indices[#g.indices + 1] = i
    end
  end
  local out = {}
  for _, g in ipairs(groups) do
    if #g.indices > 1 then out[#out + 1] = g end
  end
  return out
end

-- Ids shared by more than one card.
function O.duplicateIdGroups(cards)
  return groupBy(cards, function(c) return c.id end)
end

-- Cards sharing both set and exact imagePath (cards without an image are
-- never duplicates). NUL can't appear in a set id or file name, so the two
-- key parts can't run together.
function O.duplicateImageGroups(cards)
  return groupBy(cards, function(c)
    if c.imagePath == nil then return nil end
    return (c.setId or "") .. "\0" .. c.imagePath
  end)
end

-- Union of the group's types, first-seen order.
function O.unionTypes(cards, indices)
  local out, seen = {}, {}
  for _, i in ipairs(indices) do
    for _, t in ipairs(cards[i].types) do
      if not seen[t] then
        seen[t] = true
        out[#out + 1] = t
      end
    end
  end
  return out
end

-- Merges each same-set/same-image group into its first card (types
-- unioned); later group members are dropped. Returns a new list.
function O.mergeDuplicateImageCards(cards)
  local merged, drop = {}, {}
  for _, g in ipairs(O.duplicateImageGroups(cards)) do
    local first = g.indices[1]
    local copy = {}
    for k, v in pairs(cards[first]) do copy[k] = v end
    copy.types = O.unionTypes(cards, g.indices)
    merged[first] = copy
    for j = 2, #g.indices do drop[g.indices[j]] = true end
  end
  local out = {}
  for i, c in ipairs(cards) do
    if not drop[i] then out[#out + 1] = merged[i] or c end
  end
  return out
end

-- Cards a save would drop: with sets declared, gamedef.json stores cards
-- only inside their set, so a card with no set (or an unknown one) is lost.
function O.cardsOutsideSets(game)
  if #game.sets == 0 then return {} end
  local ids = {}
  for _, s in ipairs(game.sets) do ids[s.id] = true end
  local out = {}
  for _, c in ipairs(game.cards) do
    if c.setId == nil or not ids[c.setId] then out[#out + 1] = c end
  end
  return out
end

-- Tags a Pack Setting may use: those of the tag group named "Rarity"
-- (case-insensitive), or none.
function O.rarityTags(tagGroups)
  for _, g in ipairs(tagGroups) do
    if g.name:match("^%s*(.-)%s*$"):lower() == "rarity" then return g.tags end
  end
  return {}
end

-- Rewrites every card's "oldName|Tag" types entries to "newName|Tag", so a
-- Tag Group rename doesn't silently orphan already-tagged cards. Entries
-- belonging to other groups, and legacy bare entries, are untouched.
function O.renameTagGroupInCards(cards, oldName, newName)
  for _, card in ipairs(cards) do
    for i, entry in ipairs(card.types) do
      local g, t = tagMatch.parse(entry)
      if g == oldName then card.types[i] = tagMatch.encode(newName, t) end
    end
  end
end

---------------------------------------------------------------------------
-- Library folder migration
---------------------------------------------------------------------------

function O.directoryHasEntries(path)
  local items = fs.list(path)
  return items ~= nil and #items > 0
end

-- Copies everything from fromPath into toPath (overwriting), then deletes
-- fromPath.
function O.moveDirectoryContents(fromPath, toPath)
  fs.copyTree(fromPath, toPath)
  fs.removeTree(fromPath)
end

return O
