-- Card `types` entries are stored as "<Tag Group Name>|<Tag>" so filtering
-- and sorting can tell apart same-named tags that live in different tag
-- groups. A plain "<Tag>" entry (no "|") is the legacy format and matches
-- by tag name alone, regardless of group -- every function here preserves
-- that fallback.
local M = {}

-- "GroupName|Tag" -> "GroupName", "Tag". A legacy bare "Tag" -> nil, "Tag".
function M.parse(entry)
  local i = entry:find("|", 1, true)
  if i then return entry:sub(1, i - 1), entry:sub(i + 1) end
  return nil, entry
end

function M.encode(groupName, tagName)
  return groupName .. "|" .. tagName
end

-- True when `entry` refers to tagName within groupName. A legacy entry
-- (no group) matches by tag name alone.
function M.entryMatches(entry, groupName, tagName)
  local g, t = M.parse(entry)
  if t ~= tagName then return false end
  return g == nil or g == groupName
end

function M.hasTag(types, groupName, tagName)
  for _, entry in ipairs(types) do
    if M.entryMatches(entry, groupName, tagName) then return true end
  end
  return false
end

-- Removes the first entry matching (groupName, tagName) from `types`, in
-- place. Returns true if one was removed.
function M.removeTag(types, groupName, tagName)
  for i, entry in ipairs(types) do
    if M.entryMatches(entry, groupName, tagName) then
      table.remove(types, i)
      return true
    end
  end
  return false
end

return M
