-- Name prompt with an "existing items -- tap to reuse a name" list and an
-- overwrite confirmation step. Shared port of save_game_dialog.dart and
-- save_deck_dialog.dart.
local ui = require("src.ui.kit.ui")
local theme = require("src.ui.kit.theme")
local overlays = require("src.ui.kit.overlays")
local decks = require("src.data.deck_library")

local D = {}

-- spec:
--   title, fieldLabel, emptyNameMessage, width (default 408)
--   existing = { {name=, trailing=}, ... }  (or a function returning it)
--   existingHint ("Existing saves -- tap to reuse a name"), emptyListText
--   exists(name) -> bool
--   overwriteTitle, overwriteMessage(name)
--   onSave(name)
--   footer(x, y, w), footerH  optional extra row under the list
function D.open(spec)
  local st = { name = "", error = nil, confirming = false }
  local existing = type(spec.existing) == "function" and spec.existing() or spec.existing or {}
  local dialog
  local function submit()
    local name = st.name:gsub("^%s+", ""):gsub("%s+$", "")
    local err = decks.validateName(name, spec.emptyNameMessage)
    if err then
      st.error = err
      return true
    end
    if spec.exists(name) then
      st.confirming = true
      st.pending = name
      ui.blur()
      return true
    end
    spec.onSave(name)
    return false
  end
  dialog = overlays.dialog({
    title = spec.title,
    width = spec.width or 408,
    content = function(d, x, y, w)
      local c = theme.c
      if st.confirming then
        d.title = spec.overwriteTitle
        local msg = spec.overwriteMessage(st.pending)
        ui.text(msg, x, y, { w = w, color = c.onSurfaceVariant })
        return ui.textHeight(msg, w, 14)
      end
      d.title = spec.title
      local yy = y + 8
      local name, _, submitted = ui.textField("savename:field", x, yy, w, st.name, {
        label = spec.fieldLabel, autofocus = true, error = st.error, labelBackground = c.surfaceContainerHigh,
      })
      if name ~= st.name then st.error = nil end
      st.name = name
      if submitted and not submit() then d:close() end
      yy = yy + ui.textFieldHeight({ error = st.error }) + 16
      ui.text(spec.existingHint, x, yy, { size = 12, color = c.onSurfaceVariant })
      yy = yy + 20
      ui.divider(x, yy, w)
      yy = yy + 4
      local footerH = spec.footer and (spec.footerH or 40) or 0
      local listH = 400 - footerH - (yy - y)
      if spec.footer then spec.footer(x, yy + listH + 8, w) end
      if #existing == 0 then
        ui.text(spec.emptyListText, x, yy, { w = w, h = listH, align = "center", valign = "middle", color = c.onSurfaceVariant })
      else
        local off = ui.beginScroll("savename:list", x, yy, w, listH)
        local ry = yy - off
        for i, e in ipairs(existing) do
          local r = ui.region("savename:item" .. i, x, ry, w, 40, { cursor = "hand" })
          if r.hovered then ui.rect("fill", x, ry, w, 40, 0, theme.alpha(c.onSurface, 0.08)) end
          ui.text(e.name, x + 16, ry, { h = 40, valign = "middle", w = w - 140, ellipsis = true })
          if e.trailing then ui.text(e.trailing, x, ry, { w = w - 16, h = 40, valign = "middle", align = "right", size = 12, color = c.onSurfaceVariant }) end
          if r.clicked then
            st.name = e.name
            st.error = nil
          end
          ry = ry + 40
        end
        ui.endScroll("savename:list", #existing * 40)
      end
      return 400
    end,
    actions = {
      { label = "Cancel", variant = "text", onClick = function()
        if st.confirming then
          st.confirming = false
          return true
        end
      end },
      { label = "Save", variant = "filled", onClick = function()
        if st.confirming then
          spec.onSave(st.pending)
          return false
        end
        return submit()
      end },
    },
  })
  -- The confirm step relabels the primary action.
  local base = dialog.content
  dialog.content = function(d, x, y, w)
    d.actions[2].label = st.confirming and "Overwrite" or "Save"
    return base(d, x, y, w)
  end
  return dialog
end

return D
