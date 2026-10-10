-- Port of lib/ui/home_screen.dart.
local ui = require("src.ui.kit.ui")
local theme = require("src.ui.kit.theme")
local overlays = require("src.ui.kit.overlays")
local widgets = require("src.ui.kit.widgets")
local colorpicker = require("src.ui.kit.colorpicker")
local fileDialog = require("src.platform.file_dialog")
local imageCache = require("src.data.image_cache")
local profile = require("src.data.profile")
local version = require("src.version")
local updater = require("src.platform.updater")

local Home = {}
Home.__index = Home

function Home.new(message)
  return setmetatable({ title = "Cardflux", showBack = false, message = message }, Home)
end

local function app() return require("src.app") end

-- Edit Player Settings dialog (home_screen.dart _promptEditPlayerSettings).
function Home.openEditPlayerSettings()
  local A = app()
  local st = {
    name = A.profile.name,
    color = A.profile.color,
    avatarPath = A.profile.avatarPath, -- what the dialog shows
    avatarChanged = false,
    newSource = nil,
  }
  overlays.dialog({
    title = "Edit Player Settings",
    width = 400,
    content = function(d, x, y, w)
      local yy = y
      local size = 200
      local ax = x + (w - size) / 2
      local r = ui.region("eps:avatar", ax, yy, size, size, { cursor = "hand", tooltip = "Choose an image" })
      widgets.avatar(ax, yy, size, st.color, st.avatarPath and { path = st.avatarPath } or nil)
      if r.hovered then ui.rect("fill", ax, yy, size, size, 0, { 1, 1, 1, 0.08 }) end
      if r.clicked then
        local path = fileDialog.openFile({ title = "Choose an avatar image", filters = fileDialog.imageFilters })
        if path then
          st.avatarPath = path
          st.avatarChanged = true
          st.newSource = path
        end
      end
      yy = yy + size + 4
      if st.avatarPath then
        local bw = ui.buttonWidth("Remove Image", { icon = "delete_outline" })
        if ui.button("Remove Image", x + (w - bw) / 2, yy, bw, nil, { variant = "text", icon = "delete_outline" }) then
          st.avatarPath = nil
          st.avatarChanged = true
          st.newSource = nil
        end
        yy = yy + 44
      end
      yy = yy + 16
      st.name = ui.textField("eps:name", x, yy, w, st.name, { label = "Your name", autofocus = true, labelBackground = theme.c.surfaceContainerHigh })
      yy = yy + 48 + 16
      ui.text("Your color", x, yy)
      yy = yy + 28
      local newColor, ch = colorpicker.field("eps:color", x, yy, w, st.color, { labelBackground = theme.c.surfaceContainerHigh })
      st.color = newColor
      yy = yy + ch
      return yy - y
    end,
    actions = {
      { label = "Cancel", variant = "text" },
      { label = "Save", variant = "filled", onClick = function()
        local name = st.name:gsub("^%s+", ""):gsub("%s+$", "")
        A.profile.name = name
        A.profile.color = st.color
        profile.setName(name)
        profile.setColor(st.color)
        if st.avatarChanged then
          if st.newSource then
            local saved, err = profile.saveAvatar(st.newSource)
            if saved then
              imageCache.invalidate(saved)
              A.profile.avatarPath = saved
              profile.setAvatarPath(saved)
            else
              overlays.toast("Could not use that image: " .. tostring(err))
            end
          else
            profile.deleteAvatar()
            if A.profile.avatarPath then imageCache.invalidate(A.profile.avatarPath) end
            A.profile.avatarPath = nil
            profile.setAvatarPath(nil)
          end
        end
      end },
    },
  })
end

---------------------------------------------------------------------------
-- Updates (ports of update_confirm_dialog.dart / update_progress_dialog.dart)
---------------------------------------------------------------------------

function Home.confirmUpdate()
  local tag = updater.state.tag
  if not tag then return end
  overlays.confirm("Update Available", "Version " .. tag .. " is available. Would you like to update now?", "Update",
    function() Home.runUpdate() end, { cancelLabel = "Later" })
end

local PHASE_LABELS = {
  extracting = "Extracting update...",
  verifying = "Verifying update...",
  launchingInstaller = "Installing — Cardflux will restart shortly...",
}

-- Download -> extract -> verify -> launch helper, then quit so the helper
-- can swap the files. Nothing touches the install folder until the helper
-- runs, so a failure leaves the current install intact.
function Home.runUpdate()
  local st = { phase = "downloading", progress = 0 }
  local d = overlays.dialog({
    title = "Updating Cardflux",
    width = 420,
    dismissible = false,
    content = function(_, x, y, w)
      if st.error then
        ui.text(st.error, x, y, { w = w })
        return ui.textHeight(st.error, w)
      end
      ui.progressBar(x, y + 4, w, 4, st.progress)
      local label = PHASE_LABELS[st.phase]
        or ("Downloading update" .. (st.progress and (" (" .. math.floor(st.progress * 100 + 0.5) .. "%)") or "") .. "...")
      ui.text(label, x, y + 24, { w = w })
      return 48
    end,
    actions = {},
  })
  updater.apply(function(phase, progress)
    st.phase, st.progress = phase, progress
  end, function(err)
    if err then
      st.error = tostring(err)
      d.title = "Update Failed"
      d.dismissible = true
      d.actions = { { label = "Close", variant = "text" } }
      return
    end
    -- Let the final frame render, then exit so the helper can proceed.
    st.quitAt = love.timer.getTime() + 0.3
  end)
  Home.pendingUpdateQuit = st
end

function Home:update()
  local st = Home.pendingUpdateQuit
  if st and st.quitAt and love.timer.getTime() >= st.quitAt then
    Home.pendingUpdateQuit = nil
    love.event.quit()
  end
end

function Home:draw(x, y, w, h)
  local A = app()
  local colW = 360 - 48
  local c = theme.c
  -- Measure the column first so it can be vertically centered.
  local bannerH = 0
  local upd = updater.state
  local updateText = upd.available and ("Update available: " .. upd.tag .. " — click to install") or nil
  if updateText then bannerH = bannerH + ui.textHeight(updateText, colW - 24, 14) + 24 + 24 end
  if self.message then bannerH = bannerH + ui.textHeight(self.message, colW - 24, 14) + 24 + 24 end
  local total = bannerH + 16 + 200 + 12 + 30 + 24 + 64 + 12 + 64 + 24 + 40 * 4
  local cx = math.floor(x + (w - colW) / 2)
  local yy = math.floor(y + math.max(24, (h - total) / 2))

  if updateText then
    yy = yy + widgets.banner(updateText, cx, yy, colW, "info", function() Home.confirmUpdate() end) + 24
  end
  if self.message then
    yy = yy + widgets.banner(self.message, cx, yy, colW, "warning") + 24
  end

  -- Avatar + name (click to edit).
  local nameText = A.playerName()
  local r = ui.region("home:profile", cx, yy, colW, 16 + 200 + 12 + 30, { cursor = "hand" })
  if r.hovered then ui.rect("fill", cx, yy, colW, 16 + 200 + 12 + 30, 8, theme.alpha(c.onSurface, 0.05)) end
  widgets.avatar(cx + (colW - 200) / 2, yy + 8, 200, A.profile.color, A.profile.avatarPath and { path = A.profile.avatarPath } or nil)
  ui.text(nameText, cx, yy + 8 + 200 + 12, { size = 22, w = colW, align = "center", ellipsis = true })
  if r.clicked then Home.openEditPlayerSettings() end
  yy = yy + 16 + 200 + 12 + 30 + 24

  if ui.button("Host Game", cx, yy, colW, 48, { variant = "filled" }) then
    A.push(require("src.ui.screens.player_count").host())
  end
  yy = yy + 48 + 12
  if ui.button("Join Game", cx, yy, colW, 48, { variant = "outlined" }) then
    A.push(require("src.ui.screens.multiplayer").Join.new())
  end
  yy = yy + 48 + 24
  if ui.button("Practice Offline", cx, yy, colW, 40, { variant = "text" }) then
    A.push(require("src.ui.screens.player_count").practice())
  end
  yy = yy + 40
  if ui.button("Deck Editor", cx, yy, colW, 40, { variant = "text" }) then
    A.push(require("src.ui.screens.deck_editor").GameSelect.new())
  end
  yy = yy + 40
  if ui.button("Game Definition Editor", cx, yy, colW, 40, { variant = "text" }) then
    A.push(require("src.ui.screens.gamedef_editor").Entry.new())
  end
  yy = yy + 40
  if ui.button("Settings", cx, yy, colW, 40, { variant = "text", icon = "settings" }) then
    require("src.ui.screens.settings_dialog").open()
  end

  ui.text("Build " .. version.build, x + 8, y + h - 8 - 16, { size = 12, color = c.disabled })
end

return Home
