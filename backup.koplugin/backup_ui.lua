--[[--
backup_ui.lua
Native KOReader UI dialogs for backup creation, restoration, management, and settings.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local ButtonDialog = require("ui/widget/buttondialog")
local CenterContainer = require("ui/widget/container/centercontainer")
local CheckMark = require("ui/widget/checkmark")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local FocusManager = require("ui/widget/focusmanager")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local LineWidget = require("ui/widget/linewidget")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local ok_pbd, ProgressbarDialog = pcall(require, "ui/widget/progressbardialog")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local SpinWidget = require("ui/widget/spinwidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Localization = require("localization_backup")
local _ = Localization:getHelper()

local Constants = require("backup_constants")
local Manifest = require("backup_manifest")
local Sanitizer = require("backup_sanitizer")
local ArchiverMgr = require("backup_archiver")
local Retention = require("backup_retention")
local RestoreEngine = require("backup_restore")
local FolderPicker = require("backup_folder_picker")
local Beam = require("backup_beam")
local Cloud = require("backup_cloud")
local OAuth = require("backup_cloud_oauth")

local ok_size, Size = pcall(require, "ui/size")
if not ok_size or not Size then
    Size = { line = { thin = 1, medium = 2, thick = 3 }, span = { vertical_default = 6 } }
end

local ok_ds, DataStorage = pcall(require, "datastorage")
local ok_util, util = pcall(require, "util")
local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
if not ok_lfs or not lfs then
    ok_lfs, lfs = pcall(require, "lfs")
end
if not ok_lfs or type(lfs) ~= "table" then
    lfs = nil
end

local BackupUI = {}

local function sc(val)
    return (Device.screen and Device.screen.scaleBySize and Device.screen:scaleBySize(val)) or val
end

local function getDataDir()
    return (ok_ds and DataStorage and DataStorage.getDataDir and DataStorage:getDataDir()) or "."
end

local function isTouchDevice()
    if Device and type(Device.isTouchDevice) == "function" then
        return Device:isTouchDevice()
    elseif Device and Device.isTouchDevice ~= nil then
        return Device.isTouchDevice == true
    end
    return true
end

--- Helper to manage keyboard/arrow key focus across dialog refreshes.
-- On touch devices, visual focus (the non-touch selector) should ONLY appear
-- when keyboard / arrow keys were used to navigate or activate options.
local function createFocusState()
    local state = {
        has_key_focus = not isTouchDevice(),
        is_key_press = false,
    }

    function state:wrapDialog(d)
        if not d then return end
        local orig_onFocusMove = d.onFocusMove
        d.onFocusMove = function(self_d, ...)
            state.has_key_focus = true
            if orig_onFocusMove then
                return orig_onFocusMove(self_d, ...)
            end
        end

        local orig_onPress = d.onPress
        d.onPress = function(self_d, ...)
            state.is_key_press = true
            local ok, ret
            if orig_onPress then
                ok, ret = pcall(orig_onPress, self_d, ...)
            end
            state.is_key_press = false
            if not ok and ret ~= nil then
                error(ret)
            end
            return ret
        end

        local orig_onHold = d.onHold
        d.onHold = function(self_d, ...)
            state.is_key_press = true
            local ok, ret
            if orig_onHold then
                ok, ret = pcall(orig_onHold, self_d, ...)
            end
            state.is_key_press = false
            if not ok and ret ~= nil then
                error(ret)
            end
            return ret
        end
    end

    function state:onBeforeRefresh()
        if isTouchDevice() and not state.is_key_press then
            state.has_key_focus = false
        end
    end

    function state:applyFocus(d, focus_x, focus_y)
        if not d or not d.moveFocusTo or not focus_x or not focus_y then
            return
        end
        local FORCED_FOCUS = (FocusManager and FocusManager.FORCED_FOCUS) or 4
        local NOT_FOCUS = (FocusManager and FocusManager.NOT_FOCUS) or 2
        if state.has_key_focus then
            d:moveFocusTo(focus_x, focus_y, FORCED_FOCUS)
        else
            d:moveFocusTo(focus_x, focus_y, NOT_FOCUS)
        end
    end

    return state
end

local _asset_path_cache = {}
local function getAssetPath(filename)
    if _asset_path_cache[filename] then
        return _asset_path_cache[filename]
    end
    local data_dir = getDataDir()
    local info = debug.getinfo(1, "S")
    local dir = (info and info.source and info.source:match("^@(.*[/\\])")) or ""
    local candidates = {
        dir .. "assets/" .. filename,
        (data_dir ~= "") and (data_dir .. "/plugins/backup.koplugin/assets/" .. filename) or nil,
        "plugins/backup.koplugin/assets/" .. filename,
    }
    for idx, p in ipairs(candidates) do
        if p and lfs and lfs.attributes and lfs.attributes(p, "mode") == "file" then
            _asset_path_cache[filename] = p
            return p
        end
    end
    local fallback = dir .. "assets/" .. filename
    _asset_path_cache[filename] = fallback
    return fallback
end

--- Builds a clean, Feather-icon-driven checkbox row.
-- @param opts table:
--   - checked boolean
--   - label string
--   - subtitle string (optional)
--   - width number (optional)
--   - callback function
-- @return InputContainer widget
local function makeCheckboxRow(opts)
    local is_checked = (opts.checked == true)
    local label = opts.label or ""
    local subtitle = opts.subtitle
    local callback = opts.callback
    local row_width = opts.width or sc(360)

    local icon_file = opts.icon or (is_checked and "check-square.svg" or "square.svg")
    local check_icon = ImageWidget:new{
        file = getAssetPath(icon_file),
        width = sc(20),
        height = sc(20),
        scale_factor = 0,
        is_icon = true,
        alpha = true,
    }

    local text_elements = {
        TextWidget:new{
            text = label,
            face = Font:getFace("cfont", 14),
            bold = is_checked,
            fgcolor = Blitbuffer.COLOR_BLACK,
        }
    }
    if subtitle and subtitle ~= "" then
        table.insert(text_elements, VerticalSpan:new{ width = sc(1) })
        table.insert(text_elements, TextWidget:new{
            text = subtitle,
            face = Font:getFace("cfont", 11),
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        })
    end

    local text_group = VerticalGroup:new(text_elements)
    local check_w = check_icon:getSize().w
    local span_w = sc(10)
    local text_w = text_group:getSize().w
    local pad_h = sc(6)
    local fill_w = math.max(0, row_width - check_w - span_w - text_w - pad_h * 2)

    local row_group = HorizontalGroup:new{
        align = "center",
        check_icon,
        HorizontalSpan:new{ width = span_w },
        text_group,
        HorizontalSpan:new{ width = fill_w },
    }

    local row_frame = FrameContainer:new{
        padding = sc(4),
        padding_h = pad_h,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        width = row_width,
        row_group,
    }

    local item = InputContainer:new{ row_frame }
    item.frame = row_frame
    item.callback = callback
    item.ges_events = {
        Tap = {
            GestureRange:new{
                ges = "tap",
                range = function()
                    return item.dimen or (row_frame.getSize and row_frame:getSize()) or Geom:new{ w = row_width, h = sc(30) }
                end,
            }
        }
    }
    item.onTap = function()
        if callback then callback() end
        return true
    end
    item.isFocusable = function() return true end
    item.onFocus = function(self)
        if self.frame then
            self.frame.bordersize = sc(1)
            self.frame.color = Blitbuffer.COLOR_BLACK
            self.frame.background = Blitbuffer.Color8(235)
            UIManager:setDirty(self.show_parent or self, "fast")
        end
        return true
    end
    item.onUnfocus = function(self)
        if self.frame then
            self.frame.bordersize = 0
            self.frame.color = nil
            self.frame.background = Blitbuffer.COLOR_WHITE
            UIManager:setDirty(self.show_parent or self, "fast")
        end
        return true
    end
    item.onTapSelect = function(self)
        if self.callback then self.callback() end
        return true
    end

    return item
end

--- Creates a styled button with proper inverted text handling for primary buttons.
local function createButton(opts)
    opts = opts or {}
    local is_primary = (opts.primary == true)
    local btn = Button:new{
        text = opts.text or "",
        text_font_size = opts.text_font_size or 14,
        text_font_bold = (opts.bold ~= false),
        width = opts.width,
        height = opts.height,
        bordersize = opts.bordersize or sc(1),
        radius = opts.radius or sc(4),
        padding = opts.padding,
        padding_h = opts.padding_h,
        padding_v = opts.padding_v,
        preselect = is_primary,
        callback = opts.callback,
    }
    if is_primary and btn.frame then
        btn.frame.invert = true
    end
    return btn
end

-- Plugin-level settings storage
local _settings_cache = nil
local function getPluginSettings()
    if _settings_cache then return _settings_cache end
    local settings_file = getDataDir() .. "/settings/backup.lua"
    local ok, data = pcall(dofile, settings_file)
    if ok and type(data) == "table" then
        _settings_cache = data
    else
        _settings_cache = {
            default_format = "zip",
            custom_backup_dir = nil,
            retention_limit = 5,
            clean_slate_restore = false,
            beam_relay_url = Constants.BEAM_DEFAULT_RELAY_URL,
            cloud_provider = "none",
            cloud_remote_dir = Constants.CLOUD_DEFAULT_REMOTE_DIR or "koreader_backups",
            cloud_prune_remote = true,
        }
    end
    if not _settings_cache.cloud_provider then
        _settings_cache.cloud_provider = "none"
    end
    if not _settings_cache.cloud_remote_dir then
        _settings_cache.cloud_remote_dir = Constants.CLOUD_DEFAULT_REMOTE_DIR or "koreader_backups"
    end
    if _settings_cache.cloud_prune_remote == nil then
        _settings_cache.cloud_prune_remote = true
    end
    return _settings_cache
end

local function savePluginSettings()
    local s = getPluginSettings()
    local settings_dir = getDataDir() .. "/settings"
    if util and util.makePath then util.makePath(settings_dir) end
    local dumped = Sanitizer.dumpSettings(s)
    local f = io.open(settings_dir .. "/backup.lua", "wb")
    if f then
        f:write(dumped)
        f:close()
    end
end

local function getEffectiveBackupDir()
    local s = getPluginSettings()
    if s.custom_backup_dir and s.custom_backup_dir ~= "" then
        return s.custom_backup_dir
    end
    return Retention.getDefaultBackupDir()
end

--- Prompts the user to cleanly restart KOReader.
function BackupUI.showRestartConfirmation(message)
    local can_restart = true
    if Device and type(Device.canRestart) == "function" then
        can_restart = Device:canRestart()
    end

    local body_text = string.format("%s\n\n%s", message or _("Restore completed."), _("Restart KOReader now to apply all changes?"))
    local confirm
    confirm = ConfirmBox:new{
        text = body_text,
        ok_text = can_restart and _("Restart") or _("OK"),
        cancel_text = can_restart and _("Cancel") or nil,
        ok_callback = function()
            UIManager:close(confirm)
            if can_restart then
                if UIManager.restartKOReader then
                    UIManager:restartKOReader()
                else
                    UIManager:broadcastEvent(require("ui/event"):new("Restart"))
                end
            end
        end,
    }
    UIManager:show(confirm)
end

-- --------------------------------------------------------------------------
-- 1. Main Menu Dialog
-- --------------------------------------------------------------------------
function BackupUI.showMainMenu()
    local has_rollback = RestoreEngine.hasRollbackSnapshot()
    local s = getPluginSettings()

    local dialog
    local function closeMain()
        if dialog then
            local d = dialog
            dialog = nil
            UIManager:close(d)
        end
    end

    local buttons = {
        {
            {
                text = _("Create Backup"),
                callback = function()
                    BackupUI.showCreateDialog()
                end,
            },
        },
        {
            {
                text = _("Restore Backup"),
                callback = function()
                    BackupUI.showRestoreDialog()
                end,
            },
        },
        {
            {
                text = _("Beam to Device"),
                callback = function()
                    BackupUI.showBeamSelectBackupDialog()
                end,
            },
        },
        {
            {
                text = _("Receive via Beam Code"),
                callback = function()
                    BackupUI.showBeamReceiveDialog()
                end,
            },
        },
    }

    if has_rollback then
        table.insert(buttons, {
            {
                text = _("Undo Last Restore"),
                bold = true,
                callback = function()
                    BackupUI.showUndoRestoreConfirmation()
                end,
            },
        })
    end

    table.insert(buttons, {
        {
            text = _("Manage Backups"),
            callback = function()
                BackupUI.showManageBackupsDialog()
            end,
        },
    })

    table.insert(buttons, {
        {
            text = _("Backup & Restore Settings"),
            callback = function()
                BackupUI.showSettingsDialog()
            end,
        },
        {
            text = _("Close"),
            callback = function()
                closeMain()
            end,
        },
    })

    dialog = ButtonDialog:new{
        title = _("Device Backup & Restore"),
        buttons = buttons,
    }
    UIManager:show(dialog)
end

-- --------------------------------------------------------------------------
-- 2. Create Backup Wizard
-- --------------------------------------------------------------------------
-- --------------------------------------------------------------------------
-- 2. Create & Restore Sub-Dialogs (Components, Plugins, Patches, Fonts, Dictionaries)
-- --------------------------------------------------------------------------

local function showItemSelectionDialog(opts)
    opts = opts or {}
    local title = opts.title or ""
    local items = opts.items or {}
    local selected = opts.selected or {}
    local on_done = opts.on_done
    local empty_msg = opts.empty_msg or ""
    local focus_state = createFocusState()

    local dialog
    local refresh

    local function closeDlg()
        if dialog then
            local d = dialog
            dialog = nil
            UIManager:close(d)
        end
    end

    refresh = function(target_x, target_y)
        local focus_x, focus_y
        if target_x and target_y then
            focus_x = target_x
            focus_y = target_y
        elseif dialog and dialog.selected then
            focus_x = dialog.selected.x
            focus_y = dialog.selected.y
        end
        focus_state:onBeforeRefresh()
        if dialog then
            local d = dialog
            dialog = nil
            UIManager:close(d)
        end

        local buttons = {}
        if #items == 0 then
            table.insert(buttons, {
                {
                    text = (empty_msg and empty_msg ~= "") and empty_msg or _("No items found."),
                    enabled = false,
                }
            })
        else
            for item_idx, item_name in ipairs(items) do
                local row_idx = #buttons + 1
                table.insert(buttons, {
                    {
                        text = item_name,
                        align = "left",
                        checked_func = function()
                            return selected[item_name] == true
                        end,
                        callback = function()
                            selected[item_name] = not selected[item_name]
                            refresh(1, row_idx)
                        end,
                    }
                })
            end

            local preset_row_idx = #buttons + 1
            table.insert(buttons, {
                {
                    text = _("Select All"),
                    callback = function()
                        for _, name in ipairs(items) do selected[name] = true end
                        refresh(1, preset_row_idx)
                    end,
                },
                {
                    text = _("Clear All"),
                    callback = function()
                        for _, name in ipairs(items) do selected[name] = false end
                        refresh(2, preset_row_idx)
                    end,
                },
            })
        end

        table.insert(buttons, {
            {
                text = _("Done"),
                bold = true,
                callback = function()
                    closeDlg()
                    if on_done then
                        UIManager:nextTick(function()
                            on_done(selected)
                        end)
                    end
                end,
            }
        })

        local screen_w = (Device.screen and Device.screen.getWidth and Device.screen:getWidth()) or 600
        dialog = ButtonDialog:new{
            title = title,
            buttons = buttons,
            width = math.floor(screen_w * 0.94),
            tap_close_callback = function()
                closeDlg()
                if on_done then
                    UIManager:nextTick(function()
                        on_done(selected)
                    end)
                end
            end,
        }
        focus_state:wrapDialog(dialog)
        UIManager:show(dialog)
        focus_state:applyFocus(dialog, focus_x, focus_y)
    end

    refresh()
end

local function showComponentsSelectionDialog(opts)
    opts = opts or {}
    local title = opts.title or _("Create Backup")
    local components = opts.components or {}
    local allowed_components = opts.allowed_components
    local on_done = opts.on_done
    local focus_state = createFocusState()

    local available_plugins = opts.available_plugins or {}
    local selected_plugins = opts.selected_plugins or {}
    local available_patches = opts.available_patches or {}
    local selected_patches = opts.selected_patches or {}
    local available_fonts = opts.available_fonts or {}
    local selected_fonts = opts.selected_fonts or {}
    local available_dicts = opts.available_dicts or {}
    local selected_dicts = opts.selected_dicts or {}

    local dialog
    local refresh

    local function closeDlg()
        if dialog then
            local d = dialog
            dialog = nil
            UIManager:close(d)
        end
    end

    local function getSelectedCount(avail, sel)
        local count = 0
        for idx, name in ipairs(avail) do
            if sel[name] == true then count = count + 1 end
        end
        return count
    end

    refresh = function(target_x, target_y)
        local focus_x, focus_y
        if target_x and target_y then
            focus_x = target_x
            focus_y = target_y
        elseif dialog and dialog.selected then
            focus_x = dialog.selected.x
            focus_y = dialog.selected.y
        end
        focus_state:onBeforeRefresh()
        if dialog then
            local d = dialog
            dialog = nil
            UIManager:close(d)
        end

        local all_specs = {
            { key = Constants.COMPONENTS.SETTINGS, label = _("Settings & UI Gestures") },
            { key = Constants.COMPONENTS.PLUGINS, label = _("User Plugins"), is_drill = true, avail = available_plugins, sel = selected_plugins, dlg_title = _("User Plugins") },
            { key = Constants.COMPONENTS.PATCHES, label = _("Patches"), is_drill = true, avail = available_patches, sel = selected_patches, dlg_title = _("Patches") },
            { key = Constants.COMPONENTS.FONTS, label = _("Fonts"), is_drill = true, avail = available_fonts, sel = selected_fonts, dlg_title = _("Fonts") },
            { key = Constants.COMPONENTS.ICONS, label = _("Icons") },
            { key = Constants.COMPONENTS.SCREENSAVERS, label = _("Screensavers") },
            { key = Constants.COMPONENTS.STYLETWEAKS, label = _("Style Tweaks") },
            { key = Constants.COMPONENTS.DOCSETTINGS, label = _("Reading Progress & Notes") },
            { key = Constants.COMPONENTS.HISTORY, label = _("Reading History & Stats") },
            { key = Constants.COMPONENTS.DICTIONARIES, label = _("Dictionaries & OCR Data"), is_drill = true, avail = available_dicts, sel = selected_dicts, dlg_title = _("Dictionaries & OCR Data") },
        }

        local buttons = {}
        for spec_idx, spec in ipairs(all_specs) do
            local key = spec.key
            if not allowed_components or allowed_components[key] ~= nil then
                local row_idx = #buttons + 1
                if spec.is_drill then
                    local total = #(spec.avail)
                    local sel_count = getSelectedCount(spec.avail, spec.sel)
                    local drill_text = string.format("(%d/%d) ▸", sel_count, total)

                    table.insert(buttons, {
                        {
                            text = spec.label,
                            align = "left",
                            checked_func = function()
                                return components[key] == true
                            end,
                            callback = function()
                                components[key] = not components[key]
                                refresh(1, row_idx)
                            end,
                        },
                        {
                            text = drill_text,
                            width = sc(95),
                            callback = function()
                                closeDlg()
                                UIManager:nextTick(function()
                                    showItemSelectionDialog{
                                        title = spec.dlg_title,
                                        items = spec.avail,
                                        selected = spec.sel,
                                        empty_msg = _("No items found."),
                                        on_done = function(updated_sel)
                                            if spec.sel ~= updated_sel then
                                                for k, v in pairs(updated_sel) do spec.sel[k] = v end
                                            end
                                            if getSelectedCount(spec.avail, spec.sel) > 0 then
                                                components[key] = true
                                            end
                                            refresh(2, row_idx)
                                        end,
                                    }
                                end)
                            end,
                        }
                    })
                else
                    table.insert(buttons, {
                        {
                            text = spec.label,
                            align = "left",
                            checked_func = function()
                                return components[key] == true
                            end,
                            callback = function()
                                components[key] = not components[key]
                                refresh(1, row_idx)
                            end,
                        },
                    })
                end
            end
        end

        local preset_row_idx = #buttons + 1
        table.insert(buttons, {
            {
                text = _("Select All"),
                callback = function()
                    for k, _ in pairs(Constants.COMPONENTS) do
                        if not allowed_components or allowed_components[Constants.COMPONENTS[k]] ~= nil then
                            components[Constants.COMPONENTS[k]] = true
                        end
                    end
                    for _, name in ipairs(available_plugins) do selected_plugins[name] = true end
                    for _, name in ipairs(available_patches) do selected_patches[name] = true end
                    for _, name in ipairs(available_fonts) do selected_fonts[name] = true end
                    for _, name in ipairs(available_dicts) do selected_dicts[name] = true end
                    refresh(1, preset_row_idx)
                end,
            },
            {
                text = _("Recommended"),
                callback = function()
                    for k, _ in pairs(Constants.COMPONENTS) do
                        if not allowed_components or allowed_components[Constants.COMPONENTS[k]] ~= nil then
                            components[Constants.COMPONENTS[k]] = false
                        end
                    end
                    for k, v in pairs(Constants.DEFAULT_COMPONENT_SELECTION) do
                        if not allowed_components or allowed_components[k] ~= nil then
                            components[k] = v
                        end
                    end
                    refresh(2, preset_row_idx)
                end,
            },
            {
                text = _("Clear All"),
                callback = function()
                    for k, _ in pairs(Constants.COMPONENTS) do
                        if not allowed_components or allowed_components[Constants.COMPONENTS[k]] ~= nil then
                            components[Constants.COMPONENTS[k]] = false
                        end
                    end
                    refresh(3, preset_row_idx)
                end,
            },
        })

        table.insert(buttons, {
            {
                text = _("Done"),
                bold = true,
                callback = function()
                    closeDlg()
                    if on_done then
                        UIManager:nextTick(function()
                            on_done(components)
                        end)
                    end
                end,
            }
        })

        local screen_w = (Device.screen and Device.screen.getWidth and Device.screen:getWidth()) or 600
        dialog = ButtonDialog:new{
            title = title,
            buttons = buttons,
            width = math.floor(screen_w * 0.94),
            tap_close_callback = function()
                closeDlg()
                if on_done then
                    UIManager:nextTick(function()
                        on_done(components)
                    end)
                end
            end,
        }
        focus_state:wrapDialog(dialog)
        UIManager:show(dialog)
        focus_state:applyFocus(dialog, focus_x, focus_y)
    end

    refresh()
end

-- --------------------------------------------------------------------------
-- 2b. Create Backup Wizard
-- --------------------------------------------------------------------------
function BackupUI.showCreateDialog(wizard_state)
    local s = getPluginSettings()
    local data_dir = getDataDir()
    local now = os.time()

    local state = wizard_state
    if not state then
        local initial_components = {}
        for k, v in pairs(Constants.DEFAULT_COMPONENT_SELECTION) do
            initial_components[k] = v
        end
        local avail_plugins = ArchiverMgr.getAvailablePlugins(data_dir)
        local sel_plugins = {}
        for _, p in ipairs(avail_plugins) do sel_plugins[p] = true end

        local avail_patches = ArchiverMgr.getAvailablePatches(data_dir)
        local sel_patches = {}
        for _, pt in ipairs(avail_patches) do sel_patches[pt] = true end

        local avail_fonts = ArchiverMgr.getAvailableFonts(data_dir)
        local sel_fonts = {}
        for _, f in ipairs(avail_fonts) do sel_fonts[f] = true end

        local avail_dicts = ArchiverMgr.getAvailableDictionaries(data_dir)
        local sel_dicts = {}
        for _, d in ipairs(avail_dicts) do sel_dicts[d] = true end

        state = {
            current_name = "backup_" .. os.date("%Y-%m-%d_%H%M%S", now),
            chosen_format = s.default_format or "zip",
            components = initial_components,
            available_plugins = avail_plugins,
            selected_plugins = sel_plugins,
            available_patches = avail_patches,
            selected_patches = sel_patches,
            available_fonts = avail_fonts,
            selected_fonts = sel_fonts,
            available_dicts = avail_dicts,
            selected_dicts = sel_dicts,
        }
    end

    local focus_state = createFocusState()
    local dialog
    local refresh

    local function closeDialog(skip_dirty)
        if dialog then
            local d = dialog
            dialog = nil
            UIManager:close(d, "ui")
            if not skip_dirty then
                UIManager:setDirty("all", "ui")
            end
        end
    end

    local function startBackupCreation(name_input)
        closeDialog(true)
        local backup_dir = getEffectiveBackupDir()
        local archive_name = (name_input and name_input ~= "") and name_input or state.current_name
        local filename = archive_name .. "." .. state.chosen_format
        local full_archive_path = backup_dir .. "/" .. filename

        local is_canceled = false
        local pbar
        local info_msg
        local file_widget

        if ok_pbd and ProgressbarDialog then
            pbar = ProgressbarDialog:new{
                title = _("Creating Backup Archive"),
                subtitle = _("Preparing backup payload..."),
                progress_max = 100,
                refresh_time_seconds = 1,
                dismissable = false,
                cancel_text = _("Cancel"),
                cancel_callback = function()
                    is_canceled = true
                end,
            }
            pbar:show()
            if pbar[1] and pbar[1][1] then
                local vg = pbar[1][1]
                local max_w = (vg[2] and vg[2].max_width) or (Device.screen:getWidth() - Device.screen:scaleBySize(80))
                file_widget = TextWidget:new{
                    text = "",
                    face = Font:getFace("smallffont"),
                    max_width = max_w,
                    truncate_with_ellipsis = true,
                    truncate_left = true,
                }
                table.insert(vg, 3, file_widget)
            end
        else
            info_msg = InfoMessage:new{
                text = _("Creating backup archive...\nPlease wait."),
            }
            UIManager:show(info_msg)
        end

        local function setPbarProgress(curr_files, total_files, curr_bytes, total_bytes, current_path)
            if pbar and pbar.reportProgress then
                local pct = (total_bytes > 0) and math.min(100, math.floor((curr_bytes / total_bytes) * 100)) or 0
                pbar.progress_max = 100
                pbar:reportProgress(pct)
                local file_disp = current_path and current_path:match("([^/\\]+)$") or current_path or ""
                local template = _("Archiving (%d/%d - %s):\n%s")
                local info_text = string.format(template,
                    curr_files, math.max(total_files, 1), util.getFriendlySize(curr_bytes), file_disp)
                local line1, line2 = info_text:match("^(.-)\n(.*)$")
                if not line1 then
                    line1 = info_text
                    line2 = file_disp
                end

                if pbar[1] and pbar[1][1] then
                    local vg = pbar[1][1]
                    if vg[2] and type(vg[2].setText) == "function" then
                        vg[2]:setText(line1)
                    end
                    if file_widget and type(file_widget.setText) == "function" then
                        file_widget:setText(line2)
                    end
                    pbar[1]._size = nil
                    vg._size = nil
                end
            end
        end

        UIManager:nextTick(function()
            local ok, res = ArchiverMgr.createBackup{
                archive_path = full_archive_path,
                format = state.chosen_format,
                components = state.components,
                selected_plugins = state.selected_plugins,
                selected_patches = state.selected_patches,
                selected_fonts = state.selected_fonts,
                selected_dictionaries = state.selected_dicts,
                backup_name = archive_name,
                data_dir = data_dir,
                books_dir = s.custom_books_dir or ArchiverMgr.getEffectiveBooksDir(),
                is_canceled = function() return is_canceled end,
                on_progress = function(curr_files, total_files, curr_bytes, total_bytes, current_path)
                    setPbarProgress(curr_files, total_files, curr_bytes, total_bytes, current_path)
                end,
            }

            if pbar then
                if pbar.close then
                    pbar:close()
                else
                    UIManager:close(pbar, "ui")
                end
                pbar = nil
            elseif info_msg then
                UIManager:close(info_msg, "ui")
                info_msg = nil
            end
            UIManager:setDirty("all", "ui")

            local function showResultInfo(text, timeout)
                UIManager:show(InfoMessage:new{
                    text = text,
                    timeout = timeout,
                    dismiss_callback = function()
                        UIManager:setDirty("all", "ui")
                    end,
                })
            end

            if is_canceled or (not ok and tostring(res):find("canceled")) then
                showResultInfo(_("Backup creation canceled."), 3)
            elseif ok and type(res) == "table" then
                if s.retention_limit and s.retention_limit > 0 then
                    Retention.prune(backup_dir, s.retention_limit)
                end

                local sz_str = Retention.formatSize(res.size or 0)
                local file_count = res.file_count or 0
                showResultInfo(string.format(_("Backup created successfully!\n\nFile: %s\nSize: %s\nArchived files: %d"),
                    filename, sz_str, file_count), 5)
            else
                showResultInfo(string.format(_("Failed to create backup:\n%s"), tostring(res)), 6)
            end
        end)
    end

    local function getComponentSummary()
        local total = 0
        local active = 0
        for k, _ in pairs(Constants.DEFAULT_COMPONENT_SELECTION) do
            total = total + 1
            if state.components[k] then active = active + 1 end
        end
        return string.format("(%d/%d)", active, total)
    end

    refresh = function(target_x, target_y)
        local focus_x, focus_y
        if target_x and target_y then
            focus_x = target_x
            focus_y = target_y
        elseif dialog and dialog.selected then
            focus_x = dialog.selected.x
            focus_y = dialog.selected.y
        end
        focus_state:onBeforeRefresh()
        if dialog then
            local d = dialog
            dialog = nil
            UIManager:close(d)
        end

        local buttons = {
            {
                {
                    text = string.format(_("Components: %s ▸"), getComponentSummary()),
                    align = "left",
                    callback = function()
                        closeDialog()
                        showComponentsSelectionDialog{
                            title = _("Create Backup"),
                            components = state.components,
                            available_plugins = state.available_plugins,
                            selected_plugins = state.selected_plugins,
                            available_patches = state.available_patches,
                            selected_patches = state.selected_patches,
                            available_fonts = state.available_fonts,
                            selected_fonts = state.selected_fonts,
                            available_dicts = state.available_dicts,
                            selected_dicts = state.selected_dicts,
                            on_done = function(updated_components)
                                state.components = updated_components
                                BackupUI.showCreateDialog(state)
                            end,
                        }
                    end,
                }
            },
            {
                {
                    text = string.format(_("Format: .%s"), state.chosen_format:upper()),
                    callback = function()
                        state.chosen_format = (state.chosen_format == "zip") and "tar.gz" or "zip"
                        refresh(1, 2)
                    end,
                },
                {
                    text = _("Backup Name"),
                    callback = function()
                        local name_dialog
                        name_dialog = InputDialog:new{
                            title = _("Backup Name"),
                            description = _("Enter custom filename (without extension):"),
                            input = state.current_name,
                            buttons = {
                                {
                                    {
                                        text = _("Cancel"),
                                        callback = function() UIManager:close(name_dialog) end,
                                    },
                                    {
                                        text = _("Save"),
                                        is_enter_default = true,
                                        callback = function()
                                            local new_name = name_dialog:getInputText()
                                            UIManager:close(name_dialog)
                                            if new_name and new_name ~= "" then
                                                state.current_name = new_name:gsub("[/\\?%%*:|\"<>]", "_")
                                                refresh(2, 2)
                                            end
                                        end,
                                    },
                                },
                            },
                        }
                        UIManager:show(name_dialog)
                    end,
                }
            },
            {
                {
                    text = string.format(_("Archive: %s"), state.current_name),
                    callback = function()
                        -- Quick tap opens rename as well
                        refresh(2, 2)
                    end,
                }
            },
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        closeDialog()
                    end,
                },
                {
                    text = _("Create Backup"),
                    bold = true,
                    callback = function()
                        startBackupCreation(state.current_name)
                    end,
                },
            }
        }

        dialog = ButtonDialog:new{
            title = _("Create Backup"),
            buttons = buttons,
        }
        focus_state:wrapDialog(dialog)
        UIManager:show(dialog)
        focus_state:applyFocus(dialog, focus_x, focus_y)
    end

    refresh()
end

-- --------------------------------------------------------------------------
-- 3. Restore Backup Wizard
-- --------------------------------------------------------------------------
function BackupUI.showRestoreDialog()
    local backup_dir = getEffectiveBackupDir()
    local backups = Retention.listBackups(backup_dir)

    local dialog
    local function closeRestore()
        if dialog then
            local d = dialog
            dialog = nil
            UIManager:close(d)
        end
    end

    local s = getPluginSettings()
    local has_cloud = s.cloud_provider and s.cloud_provider ~= "none" and Cloud.isConfigured(s.cloud_provider)

    if #backups == 0 then
        local empty_buttons = {
            {
                {
                    text = _("Browse Folder"),
                    callback = function()
                        closeRestore()
                        FolderPicker.show{
                            title = _("Select Backup Folder"),
                            initial_path = backup_dir,
                            on_confirm = function(chosen)
                                if chosen and chosen ~= "" then
                                    s.custom_backup_dir = chosen
                                    savePluginSettings()
                                end
                                UIManager:nextTick(function()
                                    BackupUI.showRestoreDialog()
                                end)
                            end,
                            on_cancel = function()
                                UIManager:nextTick(function()
                                    BackupUI.showRestoreDialog()
                                end)
                            end,
                        }
                    end,
                },
            },
        }

        if has_cloud then
            table.insert(empty_buttons, 1, {
                {
                    text = string.format(_("Download from %s"), Cloud.getProviderLabel(s.cloud_provider)),
                    bold = true,
                    callback = function()
                        closeRestore()
                        BackupUI.showCloudDownloadDialog(function()
                            BackupUI.showRestoreDialog()
                        end)
                    end,
                },
            })
        end

        table.insert(empty_buttons, {
            {
                text = _("Cancel"),
                callback = function()
                    closeRestore()
                end,
            },
        })

        dialog = ButtonDialog:new{
            title = _("Restore Backup"),
            buttons = empty_buttons,
        }
        UIManager:show(dialog)
        return
    end

    local buttons = {}
    for idx, b in ipairs(backups) do
        local label = string.format("%s (%s)\n%s", b.filename, b.size_str, b.mtime_str)
        if b.is_rollback then
            label = "[Rollback] " .. label
        end
        table.insert(buttons, {
            {
                text = label,
                align = "left",
                callback = function()
                    closeRestore()
                    BackupUI.showArchiveDetailSheet(b.filepath, function()
                        BackupUI.showRestoreDialog()
                    end)
                end,
            },
        })
    end

    local action_row = {}
    if has_cloud then
        table.insert(action_row, {
            text = string.format(_("Download from %s"), Cloud.getProviderLabel(s.cloud_provider)),
            callback = function()
                closeRestore()
                BackupUI.showCloudDownloadDialog(function()
                    BackupUI.showRestoreDialog()
                end)
            end,
        })
    end
    table.insert(action_row, {
        text = _("Browse Folder"),
        callback = function()
            closeRestore()
            FolderPicker.show{
                title = _("Select Backup Folder"),
                initial_path = backup_dir,
                on_confirm = function(chosen)
                    if chosen and chosen ~= "" then
                        s.custom_backup_dir = chosen
                        savePluginSettings()
                    end
                    UIManager:nextTick(function()
                        BackupUI.showRestoreDialog()
                    end)
                end,
                on_cancel = function()
                    UIManager:nextTick(function()
                        BackupUI.showRestoreDialog()
                    end)
                end,
            }
        end,
    })
    table.insert(buttons, action_row)

    table.insert(buttons, {
        {
            text = _("Cancel"),
            callback = function()
                closeRestore()
            end,
        },
    })

    dialog = ButtonDialog:new{
        title = _("Restore Backup"),
        buttons = buttons,
    }
    UIManager:show(dialog)
end

--- Shows detailed inspection sheet for a chosen backup archive.
function BackupUI.showArchiveDetailSheet(filepath, on_back_cb)
    local inspect, err = RestoreEngine.inspectArchive(filepath)
    if not inspect then
        UIManager:show(InfoMessage:new{
            text = _("Failed to inspect archive:\n%s", tostring(err)),
            timeout = 4,
        })
        if on_back_cb then
            UIManager:nextTick(on_back_cb)
        end
        return
    end

    local manifest = inspect.manifest
    local is_same = inspect.is_same_device
    local s = getPluginSettings()

    local sanitize_toggle = not is_same
    local clean_slate_toggle = s.clean_slate_restore or false

    local allowed_components = inspect.components or {}
    local selected_components = {}
    for k, v in pairs(allowed_components) do
        if v then selected_components[k] = true end
    end

    local avail_plugins = inspect.available_plugins or {}
    local sel_plugins = {}
    for _, p in ipairs(avail_plugins) do sel_plugins[p] = true end

    local avail_patches = inspect.available_patches or {}
    local sel_patches = {}
    for _, pt in ipairs(avail_patches) do sel_patches[pt] = true end

    local avail_fonts = inspect.available_fonts or {}
    local sel_fonts = {}
    for _, f in ipairs(avail_fonts) do sel_fonts[f] = true end

    local avail_dicts = inspect.available_dictionaries or {}
    local sel_dicts = {}
    for _, d in ipairs(avail_dicts) do sel_dicts[d] = true end

    local dialog
    local focus_state = createFocusState()
    local refresh

    local function dismissDialog()
        if dialog then
            local d = dialog
            dialog = nil
            UIManager:close(d)
        end
    end

    local function closeSheet()
        dismissDialog()
        if on_back_cb then
            UIManager:nextTick(on_back_cb)
        end
    end

    local function confirmAndExecute()
        closeSheet()
        local mode = sanitize_toggle and Sanitizer.MODE_SANITIZED or Sanitizer.MODE_RAW

        local confirm
        confirm = ConfirmBox:new{
            text = _("Are you sure you want to restore this backup?\n\nAn automatic safety rollback snapshot will be created before any files are updated."),
            ok_text = _("Restore Backup"),
            cancel_text = _("Cancel"),
            ok_callback = function()
                UIManager:close(confirm)
                local info = InfoMessage:new{ text = _("Restoring backup...\nPlease wait.") }
                UIManager:show(info)

                UIManager:nextTick(function()
                    local ok, msg, details = RestoreEngine.executeRestore(filepath, {
                        mode = mode,
                        clean_slate = clean_slate_toggle,
                        books_dir = s.custom_books_dir or ArchiverMgr.getEffectiveBooksDir(),
                        selected_components = selected_components,
                        selected_plugins = sel_plugins,
                        selected_patches = sel_patches,
                        selected_fonts = sel_fonts,
                        selected_dictionaries = sel_dicts,
                    })
                    UIManager:close(info, "ui")
                    UIManager:setDirty("all", "ui")

                    if ok then
                        local stripped_count = (details and details.stripped_keys and #details.stripped_keys) or 0
                        local detail_msg = ""
                        if stripped_count > 0 then
                            detail_msg = string.format(_("\n\nSanitized %d hardware keys for device compatibility."), stripped_count)
                        end
                        BackupUI.showRestartConfirmation(_("Backup restored successfully!") .. detail_msg)
                    else
                        UIManager:show(InfoMessage:new{
                            text = _("Restore failed: %s", tostring(msg)),
                            timeout = 5,
                            dismiss_callback = function()
                                UIManager:setDirty("all", "ui")
                            end,
                        })
                    end
                end)
            end,
        }
        UIManager:show(confirm)
    end

    local function getRestoreComponentSummary()
        local total = 0
        local active = 0
        for k, v in pairs(allowed_components) do
            if v then
                total = total + 1
                if selected_components[k] then active = active + 1 end
            end
        end
        if active == total then
            return string.format("(%d/%d)", active, total)
        else
            return string.format("(%d/%d)", active, total)
        end
    end

    refresh = function(target_x, target_y)
        local focus_x, focus_y
        if target_x and target_y then
            focus_x = target_x
            focus_y = target_y
        elseif dialog and dialog.selected then
            focus_x = dialog.selected.x
            focus_y = dialog.selected.y
        end
        focus_state:onBeforeRefresh()
        if dialog then
            local d = dialog
            dialog = nil
            UIManager:close(d)
        end

        local archive_name = (manifest and manifest.backup_name) or filepath:match("([^/\\]+)%.[^.]+$") or "Backup Archive"
        local details_title = string.format(_("Archive: %s"), archive_name)

        local buttons = {
            {
                {
                    text = string.format(_("Components to Restore: %s ▸"), getRestoreComponentSummary()),
                    align = "left",
                    callback = function()
                        dismissDialog()
                        showComponentsSelectionDialog{
                            title = _("Restore Backup"),
                            components = selected_components,
                            allowed_components = allowed_components,
                            available_plugins = avail_plugins,
                            selected_plugins = sel_plugins,
                            available_patches = avail_patches,
                            selected_patches = sel_patches,
                            available_fonts = avail_fonts,
                            selected_fonts = sel_fonts,
                            available_dicts = avail_dicts,
                            selected_dicts = sel_dicts,
                            on_done = function(updated)
                                for k, v in pairs(updated) do
                                    selected_components[k] = v
                                end
                                refresh(1, 1)
                            end,
                        }
                    end,
                }
            },
            {
                {
                    text = _("Sanitize Hardware Settings"),
                    align = "left",
                    checked_func = function() return sanitize_toggle end,
                    callback = function()
                        sanitize_toggle = not sanitize_toggle
                        refresh(1, 2)
                    end,
                },
            },
            {
                {
                    text = _("Clean Slate (Remove unlisted plugins)"),
                    align = "left",
                    checked_func = function() return clean_slate_toggle end,
                    callback = function()
                        clean_slate_toggle = not clean_slate_toggle
                        refresh(1, 3)
                    end,
                },
            },
            {
                {
                    text = _("Beam to Device"),
                    callback = function()
                        dismissDialog()
                        BackupUI.showBeamSendDialog(filepath, function()
                            if on_back_cb then
                                UIManager:nextTick(on_back_cb)
                            end
                        end)
                    end,
                },
                {
                    text = _("Upload to Cloud"),
                    enabled_func = function()
                        local s_curr = getPluginSettings()
                        return s_curr.cloud_provider and s_curr.cloud_provider ~= "none" and Cloud.isConfigured(s_curr.cloud_provider)
                    end,
                    callback = function()
                        dismissDialog()
                        BackupUI.showCloudUploadDialog(filepath, function()
                            if on_back_cb then
                                UIManager:nextTick(on_back_cb)
                            end
                        end)
                    end,
                },
                {
                    text = _("Delete"),
                    callback = function()
                        local del_confirm
                        del_confirm = ConfirmBox:new{
                            text = string.format(_("Delete backup '%s'?\nThis action cannot be undone."), archive_name),
                            ok_text = _("Delete"),
                            cancel_text = _("Cancel"),
                            ok_callback = function()
                                UIManager:close(del_confirm)
                                Retention.deleteBackup(filepath)
                                if dialog then
                                    local d = dialog
                                    dialog = nil
                                    UIManager:close(d)
                                end
                                if on_back_cb then
                                    UIManager:nextTick(on_back_cb)
                                end
                            end,
                        }
                        UIManager:show(del_confirm)
                    end,
                },
            },
            {
                {
                    text = _("Cancel"),
                    callback = closeSheet,
                },
                {
                    text = _("Restore Backup"),
                    bold = true,
                    callback = confirmAndExecute,
                },
            },
        }

        dialog = ButtonDialog:new{
            title = details_title,
            buttons = buttons,
        }
        focus_state:wrapDialog(dialog)
        UIManager:show(dialog)
        focus_state:applyFocus(dialog, focus_x, focus_y)
    end

    refresh()
end

-- --------------------------------------------------------------------------
-- 4. Undo Last Restore Confirmation
-- --------------------------------------------------------------------------
function BackupUI.showUndoRestoreConfirmation()
    local confirm = ConfirmBox:new{
        text = _("Revert to the pre-restore rollback snapshot?\n\nThis will undo the last restore and return your settings and patches to their prior state.\n\nKOReader will restart immediately."),
        ok_text = _("Undo Last Restore"),
        cancel_text = _("Cancel"),
        ok_callback = function()
            local info = InfoMessage:new{ text = _("Reverting to rollback snapshot...") }
            UIManager:show(info)

            UIManager:nextTick(function()
                local ok, msg = RestoreEngine.undoLastRestore()
                UIManager:close(info)
                if ok then
                    BackupUI.showRestartConfirmation(_("Successfully reverted to rollback snapshot."))
                else
                    UIManager:show(InfoMessage:new{ text = _("Undo failed: %s", tostring(msg)), timeout = 4 })
                end
            end)
        end,
    }
    UIManager:show(confirm)
end

-- --------------------------------------------------------------------------
-- 5. Manage Backups Dialog
-- --------------------------------------------------------------------------
function BackupUI.showManageBackupsDialog()
    local backup_dir = getEffectiveBackupDir()
    local backups = Retention.listBackups(backup_dir)

    if #backups == 0 then
        UIManager:show(InfoMessage:new{
            text = string.format(_("No backup files found in:\n%s"), backup_dir),
            timeout = 3,
        })
        return
    end

    local dialog
    local focus_state = createFocusState()
    local refresh

    local function closeDialog()
        if dialog then
            local d = dialog
            dialog = nil
            UIManager:close(d)
        end
    end

    refresh = function(target_x, target_y)
        local focus_x, focus_y
        if target_x and target_y then
            focus_x = target_x
            focus_y = target_y
        elseif dialog and dialog.selected then
            focus_x = dialog.selected.x
            focus_y = dialog.selected.y
        end
        focus_state:onBeforeRefresh()
        if dialog then
            local d = dialog
            dialog = nil
            UIManager:close(d)
        end

        backups = Retention.listBackups(backup_dir)
        if #backups == 0 then
            UIManager:show(InfoMessage:new{
                text = string.format(_("No backup files found in:\n%s"), backup_dir),
                timeout = 3,
            })
            return
        end

        local buttons = {}
        for idx, b in ipairs(backups) do
            local label = string.format("%s (%s) • %s", b.filename, b.size_str, b.mtime_str)
            if b.is_rollback then
                label = "[Rollback] " .. label
            end

            table.insert(buttons, {
                {
                    text = label,
                    align = "left",
                    callback = function()
                        closeDialog()
                        UIManager:nextTick(function()
                            BackupUI.showArchiveDetailSheet(b.filepath, function()
                                BackupUI.showManageBackupsDialog()
                            end)
                        end)
                    end,
                },
            })
        end

        local s = getPluginSettings()
        if s.cloud_provider and s.cloud_provider ~= "none" and Cloud.isConfigured(s.cloud_provider) then
            table.insert(buttons, {
                {
                    text = string.format(_("Cloud Backups (%s) ▸"), Cloud.getProviderLabel(s.cloud_provider)),
                    callback = function()
                        closeDialog()
                        BackupUI.showManageCloudBackupsDialog(function()
                            BackupUI.showManageBackupsDialog()
                        end)
                    end,
                },
            })
        end

        table.insert(buttons, {
            {
                text = _("Browse Folder"),
                callback = function()
                    closeDialog()
                    FolderPicker.show{
                        title = _("Select Backup Folder"),
                        initial_path = backup_dir,
                        on_confirm = function(chosen)
                            if chosen and chosen ~= "" then
                                local s = getPluginSettings()
                                s.custom_backup_dir = chosen
                                savePluginSettings()
                            end
                            UIManager:nextTick(function()
                                BackupUI.showManageBackupsDialog()
                            end)
                        end,
                        on_cancel = function()
                            UIManager:nextTick(function()
                                BackupUI.showManageBackupsDialog()
                            end)
                        end,
                    }
                end,
            },
            {
                text = _("Close"),
                callback = closeDialog,
            },
        })

        dialog = ButtonDialog:new{
            title = _("Manage Backups"),
            buttons = buttons,
        }
        focus_state:wrapDialog(dialog)
        UIManager:show(dialog)
        focus_state:applyFocus(dialog, focus_x, focus_y)
    end

    refresh()
end

-- --------------------------------------------------------------------------
-- 6. Settings Dialog
-- --------------------------------------------------------------------------
function BackupUI.showSettingsDialog()
    local s = getPluginSettings()
    local dialog
    local focus_state = createFocusState()
    local refresh

    local function closeSettings()
        if dialog then
            local d = dialog
            dialog = nil
            UIManager:close(d)
        end
    end

    refresh = function(target_x, target_y)
        local focus_x, focus_y
        if target_x and target_y then
            focus_x = target_x
            focus_y = target_y
        elseif dialog and dialog.selected then
            focus_x = dialog.selected.x
            focus_y = dialog.selected.y
        end
        focus_state:onBeforeRefresh()
        if dialog then
            local d = dialog
            dialog = nil
            UIManager:close(d)
        end

        local current_dir = getEffectiveBackupDir()
        local current_books_dir = s.custom_books_dir or ArchiverMgr.getEffectiveBooksDir()

        local buttons = {
            {
                {
                    text = string.format(_("Backup Folder:\n%s"), current_dir),
                    callback = function()
                        closeSettings()
                        FolderPicker.show{
                            title = _("Select Backup Folder"),
                            initial_path = current_dir,
                            on_confirm = function(chosen)
                                if chosen and chosen ~= "" then
                                    s.custom_backup_dir = chosen
                                    savePluginSettings()
                                end
                                UIManager:nextTick(function()
                                    refresh(1, 1)
                                end)
                            end,
                            on_cancel = function()
                                UIManager:nextTick(function()
                                    refresh(1, 1)
                                end)
                            end,
                        }
                    end,
                },
            },
            {
                {
                    text = string.format(_("Books Folder:\n%s"), current_books_dir),
                    callback = function()
                        closeSettings()
                        FolderPicker.show{
                            title = _("Select Books Folder"),
                            initial_path = current_books_dir,
                            on_confirm = function(chosen)
                                if chosen and chosen ~= "" then
                                    s.custom_books_dir = chosen
                                    savePluginSettings()
                                end
                                UIManager:nextTick(function()
                                    refresh(1, 2)
                                end)
                            end,
                            on_cancel = function()
                                UIManager:nextTick(function()
                                    refresh(1, 2)
                                end)
                            end,
                        }
                    end,
                },
            },
            {
                {
                    text = string.format(_("Format: .%s"), (s.default_format or "zip"):upper()),
                    callback = function()
                        s.default_format = (s.default_format == "zip") and "tar.gz" or "zip"
                        savePluginSettings()
                        refresh(1, 3)
                    end,
                },
            },
            {
                {
                    text = string.format(_("Retention Limit: Keep newest %d backups"), s.retention_limit or 5),
                    callback = function()
                        closeSettings()
                        local spin_dialog
                        spin_dialog = InputDialog:new{
                            title = _("Retention Limit"),
                            description = _("Number of rolling backups to keep (0 = unlimited):"),
                            input = tostring(s.retention_limit or 5),
                            buttons = {
                                {
                                    {
                                        text = _("Cancel"),
                                        callback = function()
                                            UIManager:close(spin_dialog)
                                            UIManager:nextTick(function()
                                                refresh(1, 4)
                                            end)
                                        end,
                                    },
                                    {
                                        text = _("Save"),
                                        is_enter_default = true,
                                        callback = function()
                                            local num = tonumber(spin_dialog:getInputText())
                                            UIManager:close(spin_dialog)
                                            if num and num >= 0 then
                                                s.retention_limit = math.floor(num)
                                                savePluginSettings()
                                            end
                                            UIManager:nextTick(function()
                                                refresh(1, 4)
                                            end)
                                        end,
                                    },
                                },
                            },
                        }
                        UIManager:show(spin_dialog)
                    end,
                },
            },
            {
                {
                    text = string.format("%s:\n%s", _("Beam Relay Server"), s.beam_relay_url or Constants.BEAM_DEFAULT_RELAY_URL),
                    callback = function()
                        closeSettings()
                        local relay_dialog
                        relay_dialog = InputDialog:new{
                            title = _("Beam Relay Server"),
                            description = _("HTTPS address of the ephemeral Beam relay:"),
                            input = s.beam_relay_url or Constants.BEAM_DEFAULT_RELAY_URL,
                            buttons = {
                                {
                                    {
                                        text = _("Cancel"),
                                        callback = function()
                                            UIManager:close(relay_dialog)
                                            UIManager:nextTick(function() refresh(1, 5) end)
                                        end,
                                    },
                                    {
                                        text = _("Reset Default"),
                                        callback = function()
                                            s.beam_relay_url = Constants.BEAM_DEFAULT_RELAY_URL
                                            savePluginSettings()
                                            UIManager:close(relay_dialog)
                                            UIManager:nextTick(function() refresh(1, 5) end)
                                        end,
                                    },
                                    {
                                        text = _("Save"),
                                        is_enter_default = true,
                                        callback = function()
                                            local url = relay_dialog:getInputText()
                                            UIManager:close(relay_dialog)
                                            if url and url ~= "" then
                                                s.beam_relay_url = url
                                                savePluginSettings()
                                            end
                                            UIManager:nextTick(function() refresh(1, 5) end)
                                        end,
                                    },
                                },
                            },
                        }
                        UIManager:show(relay_dialog)
                    end,
                },
            },
            {
                {
                    text = string.format(_("Cloud Storage: %s"), Cloud.getProviderLabel(s.cloud_provider or "none")),
                    callback = function()
                        closeSettings()
                        BackupUI.showCloudProviderPicker(function()
                            BackupUI.showSettingsDialog()
                        end)
                    end,
                },
            },
            ((s.cloud_provider and s.cloud_provider ~= "none") and {
                {
                    text = (s.cloud_provider == "gdrive" and not Cloud.isConfigured("gdrive"))
                        and _("Connect Google Drive")
                        or string.format(_("Configure %s"), Cloud.getProviderLabel(s.cloud_provider)),
                    callback = function()
                        closeSettings()
                        BackupUI.showCloudConfigDialog(s.cloud_provider, function()
                            BackupUI.showSettingsDialog()
                        end)
                    end,
                },
                {
                    text = _("Test Cloud Connection"),
                    callback = function()
                        local info = InfoMessage:new{ text = _("Testing cloud connection...") }
                        UIManager:show(info)
                        UIManager:nextTick(function()
                            Cloud.testConnection(s.cloud_provider, function(ok, msg)
                                UIManager:close(info)
                                UIManager:show(InfoMessage:new{
                                    text = msg or (ok and _("Connection successful!") or _("Connection failed")),
                                    timeout = 4,
                                })
                            end)
                        end)
                    end,
                },
            } or nil),
            ((s.cloud_provider and s.cloud_provider ~= "none") and {
                {
                    text = string.format(_("Remote Folder: %s"), s.cloud_remote_dir or Constants.CLOUD_DEFAULT_REMOTE_DIR or "koreader_backups"),
                    callback = function()
                        closeSettings()
                        local folder_dlg
                        folder_dlg = InputDialog:new{
                            title = _("Remote Backup Folder"),
                            description = _("Name of folder on remote storage:"),
                            input = s.cloud_remote_dir or Constants.CLOUD_DEFAULT_REMOTE_DIR or "koreader_backups",
                            buttons = {
                                {
                                    {
                                        text = _("Cancel"),
                                        callback = function()
                                            UIManager:close(folder_dlg)
                                            UIManager:nextTick(function() refresh() end)
                                        end,
                                    },
                                    {
                                        text = _("Save"),
                                        is_enter_default = true,
                                        callback = function()
                                            local new_val = folder_dlg:getInputText()
                                            UIManager:close(folder_dlg)
                                            if new_val and new_val ~= "" then
                                                s.cloud_remote_dir = new_val:gsub("^/+", ""):gsub("/+$", "")
                                                savePluginSettings()
                                            end
                                            UIManager:nextTick(function() refresh() end)
                                        end,
                                    },
                                },
                            },
                        }
                        UIManager:show(folder_dlg)
                    end,
                },
            } or nil),
            {
                {
                    text = _("Close"),
                    callback = function()
                        closeSettings()
                    end,
                },
            },
        }

        -- Filter out nil rows
        local clean_buttons = {}
        for idx, row in ipairs(buttons) do
            if row ~= nil then
                table.insert(clean_buttons, row)
            end
        end
        buttons = clean_buttons

        dialog = ButtonDialog:new{
            title = _("Backup & Restore Settings"),
            buttons = buttons,
        }
        focus_state:wrapDialog(dialog)
        UIManager:show(dialog)
        focus_state:applyFocus(dialog, focus_x, focus_y)
    end

    refresh()
end

-- --------------------------------------------------------------------------
-- 7. Beam Cross-Device Transfer (Send & Receive)
-- --------------------------------------------------------------------------

--- Shows a backup archive selection dialog for Beaming to another device.
function BackupUI.showBeamSelectBackupDialog(on_back_cb)
    local backup_dir = getEffectiveBackupDir()
    local backups = Retention.listBackups(backup_dir)

    local dialog
    local function closeSelect()
        if dialog then
            local d = dialog
            dialog = nil
            UIManager:close(d)
        end
    end

    local function handleBack()
        closeSelect()
        if on_back_cb then
            UIManager:nextTick(on_back_cb)
        end
    end

    if #backups == 0 then
        local confirm
        confirm = ConfirmBox:new{
            text = string.format(_("No backup files found in:\n%s"), backup_dir),
            ok_text = _("Create Backup"),
            cancel_text = _("Cancel"),
            ok_callback = function()
                UIManager:close(confirm)
                BackupUI.showCreateDialog()
            end,
            cancel_callback = function()
                UIManager:close(confirm)
                handleBack()
            end,
        }
        UIManager:show(confirm)
        return
    end

    local buttons = {}
    for idx, b in ipairs(backups) do
        local label = string.format("%s (%s)\n%s", b.filename, b.size_str, b.mtime_str)
        if b.is_rollback then
            label = "[Rollback] " .. label
        end
        table.insert(buttons, {
            {
                text = label,
                align = "left",
                callback = function()
                    closeSelect()
                    BackupUI.showBeamSendDialog(b.filepath, function()
                        if on_back_cb then
                            UIManager:nextTick(on_back_cb)
                        end
                    end)
                end,
            },
        })
    end

    table.insert(buttons, {
        {
            text = _("Browse Folder"),
            callback = function()
                closeSelect()
                FolderPicker.show{
                    title = _("Select Backup Folder"),
                    initial_path = backup_dir,
                    on_confirm = function(chosen)
                        if chosen and chosen ~= "" then
                            local s = getPluginSettings()
                            s.custom_backup_dir = chosen
                            savePluginSettings()
                        end
                        UIManager:nextTick(function()
                            BackupUI.showBeamSelectBackupDialog(on_back_cb)
                        end)
                    end,
                    on_cancel = function()
                        UIManager:nextTick(function()
                            BackupUI.showBeamSelectBackupDialog(on_back_cb)
                        end)
                    end,
                }
            end,
        },
        {
            text = _("Cancel"),
            callback = handleBack,
        },
    })

    dialog = ButtonDialog:new{
        title = _("Beam to Device"),
        buttons = buttons,
    }
    UIManager:show(dialog)
end

--- Initiates sending a backup archive via a 6-digit Beam code.
function BackupUI.showBeamSendDialog(filepath, on_finish_cb)
    if not filepath then
        if on_finish_cb then UIManager:nextTick(on_finish_cb) end
        return
    end
    Beam.ensureNetwork(function()
        local s = getPluginSettings()
        local pin = Beam.generatePin()
        local formatted_pin = Beam.formatPin(pin)

        local file_size = 0
        if lfs and lfs.attributes then
            file_size = lfs.attributes(filepath, "size") or 0
        end

        local max_beam_size = 100 * 1024 * 1024 -- 100MB Cloudflare relay limit
        if file_size > max_beam_size then
            local size_str = Retention.formatSize(file_size)
            UIManager:show(InfoMessage:new{
                text = string.format(_("This backup is %s, which exceeds the 100MB Beam transfer limit.\n\nBeam is designed for fast wireless transfer of settings and plugins. For full backups with reading statistics, dictionaries, or fonts, please transfer via USB or create a lighter backup."), size_str),
                timeout = 8,
            })
            if on_finish_cb then UIManager:nextTick(on_finish_cb) end
            return
        end

        local function doStartUpload()
            local pbar = nil
            if ok_pbd and ProgressbarDialog then
                pbar = ProgressbarDialog:new{
                    title = _("Beam to Device"),
                    subtitle = _("Encrypting backup archive..."),
                    progress_max = 100,
                    refresh_time_seconds = 1,
                    dismissable = false,
                }
                pbar:show()
            else
                pbar = InfoMessage:new{
                    text = _("Encrypting backup archive..."),
                }
                UIManager:show(pbar)
            end

        local function closePbar()
            if pbar then
                if pbar.close then
                    pbar:close()
                else
                    UIManager:close(pbar, "ui")
                end
                pbar = nil
                UIManager:setDirty("all", "ui")
            end
        end

        local function setPbarSubtitle(text)
            if not pbar then return end
            pbar.subtitle = text
            if pbar[1] and pbar[1][1] then
                local vg = pbar[1][1]
                if vg[2] and type(vg[2].setText) == "function" then
                    vg[2]:setText(text)
                end
            end
        end

        local function setPbarProgress(val, force_redraw)
            if not pbar or not pbar.reportProgress then return end
            local clamped = math.min(100, math.max(0, math.floor(val or 0)))
            pbar.progress_max = 100
            pbar:reportProgress(clamped)
            if force_redraw and pbar.redrawProgressbar then
                pbar:redrawProgressbar()
            end
        end

        UIManager:nextTick(function()
            local upload_opts = {
                relay_url = s.beam_relay_url,
                on_progress = function(sent, total, stage)
                    if not pbar then return end
                    if stage == "encrypting" then
                        setPbarSubtitle(_("Encrypting backup archive..."))
                        setPbarProgress(5, true)
                    elseif stage == "connecting" then
                        setPbarSubtitle(_("Connecting to Beam relay..."))
                        setPbarProgress(10, true)
                    elseif stage == "finalizing" then
                        -- Payload uploaded; include relay server processing time in the loading bar
                        setPbarSubtitle(_("Registering code with Beam relay..."))
                        setPbarProgress(90, true)
                    elseif stage == "complete" then
                        setPbarSubtitle(_("Beam code ready!"))
                        setPbarProgress(100, true)
                    else
                        -- Uploading stage: map chunk transfer progress from 10% to 85%
                        local ratio = (total and total > 0) and (sent / total) or 0
                        ratio = math.min(1.0, math.max(0.0, ratio))
                        local pct = math.floor(10 + ratio * 75)
                        pct = math.min(85, math.max(10, pct))
                        if util and util.getFriendlySize and total and total > 0 then
                            setPbarSubtitle(string.format(_("Uploading: %s / %s (%d%%)"),
                                util.getFriendlySize(sent), util.getFriendlySize(total), pct))
                        else
                            setPbarSubtitle(_("Uploading backup archive..."))
                        end
                        setPbarProgress(pct, false)
                    end
                end,
            }
            Beam.upload(filepath, pin, upload_opts, function(ok, res)
                if not ok then
                    closePbar()
                    UIManager:show(ConfirmBox:new{
                        text = string.format(_("Beam upload failed:\n%s"), tostring(res)),
                        ok_text = _("Retry"),
                        cancel_text = _("Cancel"),
                        ok_callback = function()
                            BackupUI.showBeamSendDialog(filepath, on_finish_cb)
                        end,
                        cancel_callback = function()
                            if on_finish_cb then
                                UIManager:nextTick(on_finish_cb)
                            end
                        end,
                    })
                    return
                end

                -- Show 100% completion before transitioning to the code modal
                setPbarSubtitle(_("Beam code ready!"))
                setPbarProgress(100, true)

                local function showBeamModal()
                    closePbar()

                    local beam_dialog
                    local function closeBeam()
                        if beam_dialog then
                            local d = beam_dialog
                            beam_dialog = nil
                            UIManager:close(d)
                        end
                    end

                    local function finishBeam()
                        closeBeam()
                        if on_finish_cb then
                            UIManager:nextTick(on_finish_cb)
                        end
                    end

                    local filename = filepath:match("([^/\\]+)$") or "backup archive"
                    local display_code = formatted_pin

                    local buttons = {
                        {
                            {
                                text = _("Cancel"),
                                callback = function()
                                    finishBeam()
                                    Beam.cancelSession(pin, { relay_url = s.beam_relay_url })
                                    UIManager:show(InfoMessage:new{ text = _("Beam transfer canceled."), timeout = 3 })
                                end,
                            },
                            {
                                text = _("Done"),
                                bold = true,
                                callback = finishBeam,
                            },
                        },
                    }

                    beam_dialog = ButtonDialog:new{
                        title = _("Beam to Device"),
                        buttons = buttons,
                    }

                    local avail_w = beam_dialog:getAddedWidgetAvailableWidth()

                    local content = VerticalGroup:new{
                        align = "center",
                        not_focusable = true,
                        VerticalSpan:new{ width = sc(8) },
                        TextBoxWidget:new{
                            text = _("On the receiving device, open\n'Receive via Beam Code' and enter:"),
                            face = Font:getFace("cfont", 22),
                            alignment = "center",
                            width = avail_w,
                        },
                        VerticalSpan:new{ width = sc(14) },
                        FrameContainer:new{
                            bordersize = (Size and Size.line and Size.line.medium) or sc(2),
                            padding_top = sc(12),
                            padding_bottom = sc(12),
                            padding_left = sc(32),
                            padding_right = sc(32),
                            background = Blitbuffer.COLOR_WHITE,
                            TextWidget:new{
                                text = display_code,
                                face = Font:getFace("tfont", 36),
                                bold = true,
                            },
                        },
                        VerticalSpan:new{ width = sc(14) },
                        TextBoxWidget:new{
                            text = string.format(_("Archive: %s"), filename),
                            face = Font:getFace("cfont", 20),
                            alignment = "center",
                            width = avail_w,
                        },
                        VerticalSpan:new{ width = sc(6) },
                        TextBoxWidget:new{
                            text = _("Code expires in 15 minutes\nSingle-use end-to-end encrypted"),
                            face = Font:getFace("cfont", 19),
                            alignment = "center",
                            width = avail_w,
                        },
                        VerticalSpan:new{ width = sc(8) },
                    }

                    beam_dialog:addWidget(content)
                    UIManager:show(beam_dialog)
                end

                if UIManager and type(UIManager.scheduleIn) == "function" then
                    UIManager:scheduleIn(0.4, showBeamModal)
                elseif UIManager and type(UIManager.nextTick) == "function" then
                    UIManager:nextTick(showBeamModal)
                else
                    showBeamModal()
                end
            end)
        end)
    end

    local is_kindle = Device and type(Device.isKindle) == "function" and Device:isKindle()
        if is_kindle and file_size > 35 * 1024 * 1024 then
            local size_str = Retention.formatSize(file_size)
            local confirm
            confirm = ConfirmBox:new{
                text = string.format(_("This backup is %s. Large wireless transfers on Kindle can take several minutes.\n\nDo you want to proceed with Beaming?"), size_str),
                ok_text = _("Proceed"),
                cancel_text = _("Cancel"),
                ok_callback = function()
                    UIManager:close(confirm)
                    UIManager:nextTick(doStartUpload)
                end,
                cancel_callback = function()
                    UIManager:close(confirm)
                    if on_finish_cb then UIManager:nextTick(on_finish_cb) end
                end,
            }
            UIManager:show(confirm)
            return
        end

        doStartUpload()
    end, function()
        if on_finish_cb then
            UIManager:nextTick(on_finish_cb)
        end
    end)
end

--- Prompts user for a 6-digit Beam code and downloads/restores the archive.
function BackupUI.showBeamReceiveDialog()
    Beam.ensureNetwork(function()
        local s = getPluginSettings()
        local pin_dialog
        pin_dialog = InputDialog:new{
            title = _("Receive via Beam Code"),
            description = _("Enter the 6-digit Beam code from the sending device:"),
            input = "",
            buttons = {
                {
                    {
                        text = _("Cancel"),
                        callback = function()
                            UIManager:close(pin_dialog)
                        end,
                    },
                    {
                        text = _("Receive & Restore"),
                        is_enter_default = true,
                        callback = function()
                            local entered = pin_dialog:getInputText()
                            local clean_pin, err = Beam.cleanPin(entered)
                            if not clean_pin then
                                UIManager:show(InfoMessage:new{ text = tostring(err), timeout = 4 })
                                return
                            end
                            UIManager:close(pin_dialog)

                            local pbar = nil
                            if ok_pbd and ProgressbarDialog then
                                pbar = ProgressbarDialog:new{
                                    title = _("Receive via Beam Code"),
                                    subtitle = _("Connecting and downloading backup archive..."),
                                    progress_max = 100,
                                    refresh_time_seconds = 1,
                                    dismissable = false,
                                }
                                pbar:show()
                            else
                                pbar = InfoMessage:new{
                                    text = _("Connecting and downloading backup archive..."),
                                }
                                UIManager:show(pbar)
                            end

                            local function closePbar()
                                if pbar then
                                    if pbar.close then
                                        pbar:close()
                                    else
                                        UIManager:close(pbar, "ui")
                                    end
                                    pbar = nil
                                    UIManager:setDirty("all", "ui")
                                end
                            end

                            local function setPbarSubtitle(text)
                                if pbar and pbar[1] and pbar[1][1] then
                                    local vg = pbar[1][1]
                                    if vg[2] and type(vg[2].setText) == "function" then
                                        vg[2]:setText(text)
                                    end
                                end
                            end

                            local function setPbarProgress(val, force_redraw)
                                if not pbar or not pbar.reportProgress then return end
                                local clamped = math.min(100, math.max(0, math.floor(val or 0)))
                                pbar.progress_max = 100
                                pbar:reportProgress(clamped)
                                if force_redraw and pbar.redrawProgressbar then
                                    pbar:redrawProgressbar()
                                end
                            end

                            UIManager:nextTick(function()
                                local dest_dir = getEffectiveBackupDir()
                                local highest_pct = 0
                                local dl_opts = {
                                    relay_url = s.beam_relay_url,
                                    on_total = function(total)
                                        if total and total > 0 and util and util.getFriendlySize then
                                            setPbarSubtitle(string.format(_("Downloading backup archive (%s)..."), util.getFriendlySize(total)))
                                        end
                                    end,
                                    on_progress = function(received, total)
                                        if not pbar then return end
                                        if total and total > 0 then
                                            local pct = math.min(100, math.max(highest_pct, math.floor((received / total) * 100)))
                                            highest_pct = pct
                                            setPbarProgress(pct, false)
                                            if util and util.getFriendlySize then
                                                setPbarSubtitle(string.format(_("Downloading: %s / %s (%d%%)"),
                                                    util.getFriendlySize(received), util.getFriendlySize(total), pct))
                                            end
                                        else
                                            -- Total size unknown fallback: strictly monotonic estimation toward 90%
                                            local est_pct = math.min(90, math.floor(10 + 80 * (1 - 1 / (1 + received / 2097152))))
                                            if est_pct > highest_pct then
                                                highest_pct = est_pct
                                            end
                                            setPbarProgress(highest_pct, false)
                                            if util and util.getFriendlySize then
                                                setPbarSubtitle(string.format(_("Downloading: %s..."), util.getFriendlySize(received)))
                                            end
                                        end
                                    end,
                                }
                                Beam.download(clean_pin, dest_dir, dl_opts, function(ok, target_path, filename)
                                    if ok then
                                        setPbarSubtitle(_("Decrypting backup archive..."))
                                        setPbarProgress(100, true)
                                    end
                                    closePbar()
                                    if not ok then
                                        UIManager:show(ConfirmBox:new{
                                            text = string.format(_("Beam reception failed:\n%s"), tostring(target_path)),
                                            ok_text = _("Retry"),
                                            cancel_text = _("Cancel"),
                                            ok_callback = function()
                                                BackupUI.showBeamReceiveDialog()
                                            end,
                                        })
                                        return
                                    end

                                    UIManager:show(InfoMessage:new{
                                        text = string.format(_("Backup received successfully!\n\nFile: %s"), tostring(filename)),
                                        timeout = 3,
                                    })

                                    UIManager:nextTick(function()
                                        BackupUI.showArchiveDetailSheet(target_path)
                                    end)
                                end)
                            end)
                        end,
                    },
                },
            },
        }
        UIManager:show(pin_dialog)
    end)
end

-- --------------------------------------------------------------------------
-- 8. Cloud Storage Operations & Dialogs
-- --------------------------------------------------------------------------

--- Shows provider selection picker for Cloud Storage.
function BackupUI.showCloudProviderPicker(on_finish_cb)
    local s = getPluginSettings()
    local dialog

    local function closePicker()
        if dialog then
            local d = dialog
            dialog = nil
            UIManager:close(d)
        end
    end

    local providers = {
        { id = Constants.CLOUD_PROVIDERS.NONE, label = _("None (Disabled)") },
        { id = Constants.CLOUD_PROVIDERS.GDRIVE, label = _("Google Drive") },
        { id = Constants.CLOUD_PROVIDERS.WEBDAV, label = _("WebDAV (Nextcloud / NAS)") },
        { id = Constants.CLOUD_PROVIDERS.FTP, label = _("FTP / FTPS") },
        { id = Constants.CLOUD_PROVIDERS.SFTP, label = _("SFTP (SSH)") },
    }

    local buttons = {}
    for idx, p in ipairs(providers) do
        local pid = p.id
        local is_active = (s.cloud_provider == pid)
        table.insert(buttons, {
            {
                text = p.label,
                align = "left",
                checked_func = function() return is_active end,
                callback = function()
                    closePicker()
                    s.cloud_provider = pid
                    savePluginSettings()
                    if pid ~= Constants.CLOUD_PROVIDERS.NONE then
                        UIManager:nextTick(function()
                            BackupUI.showCloudConfigDialog(pid, on_finish_cb)
                        end)
                    else
                        if on_finish_cb then UIManager:nextTick(on_finish_cb) end
                    end
                end,
            },
        })
    end

    table.insert(buttons, {
        {
            text = _("Cancel"),
            callback = function()
                closePicker()
                if on_finish_cb then UIManager:nextTick(on_finish_cb) end
            end,
        },
    })

    dialog = ButtonDialog:new{
        title = _("Select Cloud Storage Provider"),
        buttons = buttons,
    }
    UIManager:show(dialog)
end

--- Shows the provider-specific configuration dialog.
function BackupUI.showCloudConfigDialog(provider, on_finish_cb)
    local s = getPluginSettings()
    provider = provider or s.cloud_provider

    if provider == Constants.CLOUD_PROVIDERS.GDRIVE then
        -- Google Drive: OAuth2 device-code authorization flow
        if Cloud.isConfigured(Constants.CLOUD_PROVIDERS.GDRIVE) then
            local gdialog
            local buttons = {
                {
                    {
                        text = _("Test Connection"),
                        callback = function()
                            local info = InfoMessage:new{ text = _("Testing Google Drive connection...") }
                            UIManager:show(info)
                            UIManager:nextTick(function()
                                Cloud.testConnection(Constants.CLOUD_PROVIDERS.GDRIVE, function(ok, msg)
                                    UIManager:close(info)
                                    UIManager:show(InfoMessage:new{
                                        text = msg or (ok and _("Connection successful!") or _("Connection failed")),
                                        timeout = 4,
                                    })
                                end)
                            end)
                        end,
                    },
                },
                {
                    {
                        text = _("Disconnect / Log Out"),
                        callback = function()
                            UIManager:close(gdialog)
                            OAuth.clearTokens(Constants.CLOUD_PROVIDERS.GDRIVE)
                            UIManager:show(InfoMessage:new{ text = _("Disconnected from Google Drive."), timeout = 3 })
                            if on_finish_cb then UIManager:nextTick(on_finish_cb) end
                        end,
                    },
                },
                {
                    {
                        text = _("Done"),
                        bold = true,
                        callback = function()
                            UIManager:close(gdialog)
                            if on_finish_cb then UIManager:nextTick(on_finish_cb) end
                        end,
                    },
                },
            }
            gdialog = ButtonDialog:new{
                title = _("Google Drive Account"),
                buttons = buttons,
            }
            UIManager:show(gdialog)
            return
        end

        -- Not authenticated yet: start device-code grant
        Beam.ensureNetwork(function()
            local req_info = InfoMessage:new{ text = _("Contacting Google Drive...") }
            UIManager:show(req_info)

            OAuth.requestDeviceCode(Constants.CLOUD_PROVIDERS.GDRIVE, {}, function(ok, info)
                UIManager:close(req_info)

                if not ok or not info then
                    UIManager:show(ConfirmBox:new{
                        text = string.format(_("Failed to start Google Drive authorization:\n%s"), tostring(info)),
                        ok_text = _("Retry"),
                        cancel_text = _("Cancel"),
                        ok_callback = function()
                            BackupUI.showCloudConfigDialog(Constants.CLOUD_PROVIDERS.GDRIVE, on_finish_cb)
                        end,
                        cancel_callback = function()
                            if on_finish_cb then UIManager:nextTick(on_finish_cb) end
                        end,
                    })
                    return
                end

                local flow_active = true
                local auth_dialog
                local function closeAuth()
                    flow_active = false
                    if auth_dialog then
                        local d = auth_dialog
                        auth_dialog = nil
                        UIManager:close(d)
                    end
                end

                local buttons = {
                    {
                        {
                            text = _("Cancel"),
                            callback = function()
                                closeAuth()
                                if on_finish_cb then UIManager:nextTick(on_finish_cb) end
                            end,
                        },
                    },
                }

                auth_dialog = ButtonDialog:new{
                    title = _("Connect Google Drive"),
                    buttons = buttons,
                }

                local avail_w = auth_dialog:getAddedWidgetAvailableWidth()
                local content = VerticalGroup:new{
                    align = "center",
                    not_focusable = true,
                    VerticalSpan:new{ width = sc(8) },
                    TextBoxWidget:new{
                        text = _("On your phone or computer, open:"),
                        face = Font:getFace("cfont", 20),
                        alignment = "center",
                        width = avail_w,
                    },
                    VerticalSpan:new{ width = sc(6) },
                    TextWidget:new{
                        text = info.verification_url or "https://www.google.com/device",
                        face = Font:getFace("cfont", 22),
                        bold = true,
                    },
                    VerticalSpan:new{ width = sc(12) },
                    TextBoxWidget:new{
                        text = _("And enter this code:"),
                        face = Font:getFace("cfont", 20),
                        alignment = "center",
                        width = avail_w,
                    },
                    VerticalSpan:new{ width = sc(6) },
                    FrameContainer:new{
                        bordersize = sc(2),
                        padding_top = sc(10),
                        padding_bottom = sc(10),
                        padding_left = sc(28),
                        padding_right = sc(28),
                        background = Blitbuffer.COLOR_WHITE,
                        TextWidget:new{
                            text = info.user_code or "",
                            face = Font:getFace("tfont", 34),
                            bold = true,
                        },
                    },
                    VerticalSpan:new{ width = sc(14) },
                    TextBoxWidget:new{
                        text = _("Waiting for authorization..."),
                        face = Font:getFace("cfont", 18),
                        alignment = "center",
                        width = avail_w,
                    },
                    VerticalSpan:new{ width = sc(8) },
                }

                auth_dialog:addWidget(content)
                UIManager:show(auth_dialog)

                -- Polling loop
                local poll_interval = math.max(3, info.interval or 5)
                local consecutive_errors = 0
                local MAX_CONSECUTIVE_ERRORS = 5

                local function pollStep()
                    if not flow_active then return end

                    OAuth.pollToken(Constants.CLOUD_PROVIDERS.GDRIVE, info.device_code, {}, function(poll_ok, token_data, raw_res)
                        if not flow_active then return end

                        if poll_ok and token_data and token_data.access_token then
                            closeAuth()
                            OAuth.saveTokens(Constants.CLOUD_PROVIDERS.GDRIVE, token_data)
                            UIManager:show(InfoMessage:new{
                                text = _("Connected to Google Drive successfully!"),
                                timeout = 3,
                            })
                            if on_finish_cb then UIManager:nextTick(on_finish_cb) end
                            return
                        end

                        if token_data == "authorization_pending" then
                            consecutive_errors = 0
                            if UIManager and UIManager.scheduleIn then
                                UIManager:scheduleIn(poll_interval, pollStep)
                            end
                        elseif token_data == "slow_down" then
                            consecutive_errors = 0
                            poll_interval = poll_interval + 5
                            if UIManager and UIManager.scheduleIn then
                                UIManager:scheduleIn(poll_interval, pollStep)
                            end
                        elseif token_data == "access_denied" then
                            closeAuth()
                            UIManager:show(InfoMessage:new{ text = _("Google Drive authorization was denied."), timeout = 4 })
                            if on_finish_cb then UIManager:nextTick(on_finish_cb) end
                        elseif token_data == "expired_token" then
                            closeAuth()
                            UIManager:show(InfoMessage:new{ text = _("Authorization code expired. Please try again."), timeout = 4 })
                            if on_finish_cb then UIManager:nextTick(on_finish_cb) end
                        elseif token_data == "invalid_request" or token_data == "invalid_client"
                            or token_data == "unauthorized_client" or token_data == "server_error"
                            or token_data == "relay_error" then
                            -- Fatal configuration or server error: do not loop infinitely
                            closeAuth()
                            local detail = (raw_res and (raw_res.error_description or raw_res.error)) or token_data
                            local err_msg = string.format(_("Google Drive authentication error: %s"), tostring(detail))
                            UIManager:show(InfoMessage:new{ text = err_msg, timeout = 6 })
                            if on_finish_cb then UIManager:nextTick(on_finish_cb) end
                        else
                            -- Network or transient error with retry limit
                            consecutive_errors = consecutive_errors + 1
                            if consecutive_errors >= MAX_CONSECUTIVE_ERRORS then
                                closeAuth()
                                local detail = (raw_res and (raw_res.error_description or raw_res.error)) or token_data or _("Connection timed out")
                                local err_msg = string.format(_("Google Drive authorization failed: %s"), tostring(detail))
                                UIManager:show(InfoMessage:new{ text = err_msg, timeout = 6 })
                                if on_finish_cb then UIManager:nextTick(on_finish_cb) end
                            else
                                if UIManager and UIManager.scheduleIn then
                                    UIManager:scheduleIn(poll_interval, pollStep)
                                end
                            end
                        end
                    end)
                end

                if UIManager and UIManager.scheduleIn then
                    UIManager:scheduleIn(poll_interval, pollStep)
                end
            end)
        end, function()
            if on_finish_cb then UIManager:nextTick(on_finish_cb) end
        end)

    elseif provider == Constants.CLOUD_PROVIDERS.WEBDAV then
        local creds = Cloud.loadCredentials(Constants.CLOUD_PROVIDERS.WEBDAV)
        local multi_dlg
        multi_dlg = MultiInputDialog:new{
            title = _("WebDAV Server Settings"),
            fields = {
                {
                    text = creds.url or "",
                    hint = _("Server URL (e.g. https://cloud.example.com/remote.php/dav/files/user)"),
                },
                {
                    text = creds.username or "",
                    hint = _("Username"),
                },
                {
                    text = creds.password or "",
                    hint = _("Password or App Token"),
                    text_type = "password",
                },
            },
            buttons = {
                {
                    {
                        text = _("Cancel"),
                        id = "close",
                        callback = function()
                            UIManager:close(multi_dlg)
                            if on_finish_cb then UIManager:nextTick(on_finish_cb) end
                        end,
                    },
                    {
                        text = _("Test"),
                        callback = function()
                            local fields = multi_dlg:getFields()
                            local test_creds = {
                                url = fields[1],
                                username = fields[2],
                                password = fields[3],
                                remote_dir = s.cloud_remote_dir,
                            }
                            local info = InfoMessage:new{ text = _("Testing WebDAV connection...") }
                            UIManager:show(info)
                            WebDAV.testConnection(test_creds, function(ok, msg)
                                UIManager:close(info)
                                UIManager:show(InfoMessage:new{
                                    text = msg or (ok and _("Connection successful!") or _("Connection failed")),
                                    timeout = 4,
                                })
                            end)
                        end,
                    },
                    {
                        text = _("Save"),
                        is_enter_default = true,
                        callback = function()
                            local fields = multi_dlg:getFields()
                            creds.url = fields[1]
                            creds.username = fields[2]
                            creds.password = fields[3]
                            Cloud.saveCredentials(Constants.CLOUD_PROVIDERS.WEBDAV, creds)
                            UIManager:close(multi_dlg)
                            UIManager:show(InfoMessage:new{ text = _("WebDAV settings saved."), timeout = 2 })
                            if on_finish_cb then UIManager:nextTick(on_finish_cb) end
                        end,
                    },
                },
            },
        }
        UIManager:show(multi_dlg)
        if multi_dlg.onShowKeyboard then multi_dlg:onShowKeyboard() end

    elseif provider == Constants.CLOUD_PROVIDERS.FTP then
        local creds = Cloud.loadCredentials(Constants.CLOUD_PROVIDERS.FTP)
        local multi_dlg
        multi_dlg = MultiInputDialog:new{
            title = _("FTP Server Settings"),
            fields = {
                {
                    text = creds.host or "",
                    hint = _("Host (e.g. ftp.example.com)"),
                },
                {
                    text = tostring(creds.port or 21),
                    hint = _("Port (default 21)"),
                },
                {
                    text = creds.username or "",
                    hint = _("Username (or 'anonymous')"),
                },
                {
                    text = creds.password or "",
                    hint = _("Password"),
                    text_type = "password",
                },
            },
            buttons = {
                {
                    {
                        text = _("Cancel"),
                        id = "close",
                        callback = function()
                            UIManager:close(multi_dlg)
                            if on_finish_cb then UIManager:nextTick(on_finish_cb) end
                        end,
                    },
                    {
                        text = _("Test"),
                        callback = function()
                            local fields = multi_dlg:getFields()
                            local test_creds = {
                                host = fields[1],
                                port = tonumber(fields[2]) or 21,
                                username = fields[3],
                                password = fields[4],
                                remote_dir = s.cloud_remote_dir,
                            }
                            local info = InfoMessage:new{ text = _("Testing FTP connection...") }
                            UIManager:show(info)
                            FTP.testConnection(test_creds, function(ok, msg)
                                UIManager:close(info)
                                UIManager:show(InfoMessage:new{
                                    text = msg or (ok and _("Connection successful!") or _("Connection failed")),
                                    timeout = 4,
                                })
                            end)
                        end,
                    },
                    {
                        text = _("Save"),
                        is_enter_default = true,
                        callback = function()
                            local fields = multi_dlg:getFields()
                            creds.host = fields[1]
                            creds.port = tonumber(fields[2]) or 21
                            creds.username = fields[3]
                            creds.password = fields[4]
                            Cloud.saveCredentials(Constants.CLOUD_PROVIDERS.FTP, creds)
                            UIManager:close(multi_dlg)
                            UIManager:show(InfoMessage:new{ text = _("FTP settings saved."), timeout = 2 })
                            if on_finish_cb then UIManager:nextTick(on_finish_cb) end
                        end,
                    },
                },
            },
        }
        UIManager:show(multi_dlg)
        if multi_dlg.onShowKeyboard then multi_dlg:onShowKeyboard() end

    elseif provider == Constants.CLOUD_PROVIDERS.SFTP then
        local creds = Cloud.loadCredentials(Constants.CLOUD_PROVIDERS.SFTP)
        local multi_dlg
        multi_dlg = MultiInputDialog:new{
            title = _("SFTP Server Settings"),
            fields = {
                {
                    text = creds.host or "",
                    hint = _("Host (e.g. sftp.example.com)"),
                },
                {
                    text = tostring(creds.port or 22),
                    hint = _("Port (default 22)"),
                },
                {
                    text = creds.username or "",
                    hint = _("Username"),
                },
                {
                    text = creds.password or creds.key_path or "",
                    hint = _("Password or Key Path (e.g. /path/id_rsa)"),
                    text_type = "password",
                },
            },
            buttons = {
                {
                    {
                        text = _("Cancel"),
                        id = "close",
                        callback = function()
                            UIManager:close(multi_dlg)
                            if on_finish_cb then UIManager:nextTick(on_finish_cb) end
                        end,
                    },
                    {
                        text = _("Test"),
                        callback = function()
                            local fields = multi_dlg:getFields()
                            local test_creds = {
                                host = fields[1],
                                port = tonumber(fields[2]) or 22,
                                username = fields[3],
                                password = fields[4],
                                remote_dir = s.cloud_remote_dir,
                            }
                            local info = InfoMessage:new{ text = _("Testing SFTP connection...") }
                            UIManager:show(info)
                            SFTP.testConnection(test_creds, function(ok, msg)
                                UIManager:close(info)
                                UIManager:show(InfoMessage:new{
                                    text = msg or (ok and _("Connection successful!") or _("Connection failed")),
                                    timeout = 4,
                                })
                            end)
                        end,
                    },
                    {
                        text = _("Save"),
                        is_enter_default = true,
                        callback = function()
                            local fields = multi_dlg:getFields()
                            creds.host = fields[1]
                            creds.port = tonumber(fields[2]) or 22
                            creds.username = fields[3]
                            creds.password = fields[4]
                            Cloud.saveCredentials(Constants.CLOUD_PROVIDERS.SFTP, creds)
                            UIManager:close(multi_dlg)
                            UIManager:show(InfoMessage:new{ text = _("SFTP settings saved."), timeout = 2 })
                            if on_finish_cb then UIManager:nextTick(on_finish_cb) end
                        end,
                    },
                },
            },
        }
        UIManager:show(multi_dlg)
        if multi_dlg.onShowKeyboard then multi_dlg:onShowKeyboard() end
    end
end

--- Uploads a local backup archive to the configured cloud provider.
function BackupUI.showCloudUploadDialog(filepath, on_finish_cb)
    if not filepath then
        if on_finish_cb then UIManager:nextTick(on_finish_cb) end
        return
    end

    local s = getPluginSettings()
    local provider = s.cloud_provider
    if not Cloud.isConfigured(provider) then
        UIManager:show(InfoMessage:new{
            text = string.format(_("%s is not configured. Please configure it in Settings."), Cloud.getProviderLabel(provider)),
            timeout = 4,
        })
        if on_finish_cb then UIManager:nextTick(on_finish_cb) end
        return
    end

    Beam.ensureNetwork(function()
        local pbar = nil
        if ok_pbd and ProgressbarDialog then
            pbar = ProgressbarDialog:new{
                title = string.format(_("Upload to %s"), Cloud.getProviderLabel(provider)),
                subtitle = _("Preparing upload..."),
                progress_max = 100,
                refresh_time_seconds = 1,
                dismissable = false,
            }
            pbar:show()
        else
            pbar = InfoMessage:new{ text = _("Uploading backup to cloud...") }
            UIManager:show(pbar)
        end

        local function closePbar()
            if pbar then
                if pbar.close then
                    pbar:close()
                else
                    UIManager:close(pbar, "ui")
                end
                pbar = nil
                UIManager:setDirty("all", "ui")
            end
        end

        local function setPbarSubtitle(text)
            if pbar and pbar[1] and pbar[1][1] then
                local vg = pbar[1][1]
                if vg[2] and type(vg[2].setText) == "function" then
                    vg[2]:setText(text)
                end
            end
        end

        local function setPbarProgress(val)
            if not pbar or not pbar.reportProgress then return end
            pbar.progress_max = 100
            pbar:reportProgress(math.min(100, math.max(0, math.floor(val or 0))))
        end

        UIManager:nextTick(function()
            local upload_opts = {
                on_progress = function(sent, total, stage)
                    if not pbar then return end
                    if stage == "connecting" then
                        setPbarSubtitle(_("Connecting to cloud..."))
                        setPbarProgress(5)
                    elseif stage == "finalizing" then
                        setPbarSubtitle(_("Finalizing upload..."))
                        setPbarProgress(95)
                    else
                        local pct = (total and total > 0) and math.floor((sent / total) * 100) or 0
                        setPbarProgress(pct)
                        if total and total > 0 and util and util.getFriendlySize then
                            setPbarSubtitle(string.format(_("Uploading: %s / %s (%d%%)"),
                                util.getFriendlySize(sent), util.getFriendlySize(total), pct))
                        else
                            setPbarSubtitle(_("Uploading backup archive..."))
                        end
                    end
                end,
            }

            Cloud.upload(filepath, upload_opts, function(ok, res)
                closePbar()
                if ok then
                    local filename = filepath:match("([^/\\]+)$") or "backup archive"
                    UIManager:show(InfoMessage:new{
                        text = string.format(_("Backup uploaded to %s successfully!\n\nFile: %s"), Cloud.getProviderLabel(provider), filename),
                        timeout = 4,
                    })
                    if on_finish_cb then UIManager:nextTick(on_finish_cb) end
                else
                    UIManager:show(ConfirmBox:new{
                        text = string.format(_("Cloud upload failed:\n%s"), tostring(res)),
                        ok_text = _("Retry"),
                        cancel_text = _("Cancel"),
                        ok_callback = function()
                            BackupUI.showCloudUploadDialog(filepath, on_finish_cb)
                        end,
                        cancel_callback = function()
                            if on_finish_cb then UIManager:nextTick(on_finish_cb) end
                        end,
                    })
                end
            end)
        end)
    end, function()
        if on_finish_cb then UIManager:nextTick(on_finish_cb) end
    end)
end

--- Shows a dialog listing remote cloud backups for download and restoration.
function BackupUI.showCloudDownloadDialog(on_finish_cb)
    local s = getPluginSettings()
    local provider = s.cloud_provider

    if not Cloud.isConfigured(provider) then
        UIManager:show(InfoMessage:new{
            text = string.format(_("%s is not configured. Please configure it in Settings."), Cloud.getProviderLabel(provider)),
            timeout = 4,
        })
        if on_finish_cb then UIManager:nextTick(on_finish_cb) end
        return
    end

    Beam.ensureNetwork(function()
        local fetch_info = InfoMessage:new{ text = string.format(_("Fetching backups from %s..."), Cloud.getProviderLabel(provider)) }
        UIManager:show(fetch_info)

        Cloud.listRemoteBackups(function(ok, list)
            UIManager:close(fetch_info)

            if not ok then
                UIManager:show(ConfirmBox:new{
                    text = string.format(_("Failed to fetch cloud backups:\n%s"), tostring(list)),
                    ok_text = _("Retry"),
                    cancel_text = _("Cancel"),
                    ok_callback = function()
                        BackupUI.showCloudDownloadDialog(on_finish_cb)
                    end,
                    cancel_callback = function()
                        if on_finish_cb then UIManager:nextTick(on_finish_cb) end
                    end,
                })
                return
            end

            if not list or #list == 0 then
                UIManager:show(InfoMessage:new{
                    text = string.format(_("No backup files found on %s."), Cloud.getProviderLabel(provider)),
                    timeout = 3,
                })
                if on_finish_cb then UIManager:nextTick(on_finish_cb) end
                return
            end

            local dialog
            local function closeDialog()
                if dialog then
                    local d = dialog
                    dialog = nil
                    UIManager:close(d)
                end
            end

            local buttons = {}
            for idx, b in ipairs(list) do
                local label = string.format("%s (%s)\n%s", b.filename, b.size_str, b.mtime_str)
                table.insert(buttons, {
                    {
                        text = label,
                        align = "left",
                        callback = function()
                            closeDialog()
                            local dest_dir = getEffectiveBackupDir()
                            if util and util.makePath then util.makePath(dest_dir) end
                            local local_path = dest_dir .. "/" .. b.filename

                            local pbar = nil
                            if ok_pbd and ProgressbarDialog then
                                pbar = ProgressbarDialog:new{
                                    title = string.format(_("Download from %s"), Cloud.getProviderLabel(provider)),
                                    subtitle = _("Downloading backup archive..."),
                                    progress_max = 100,
                                    refresh_time_seconds = 1,
                                    dismissable = false,
                                }
                                pbar:show()
                            else
                                pbar = InfoMessage:new{ text = _("Downloading backup from cloud...") }
                                UIManager:show(pbar)
                            end

                            local function closeDlPbar()
                                if pbar then
                                    if pbar.close then pbar:close() else UIManager:close(pbar, "ui") end
                                    pbar = nil
                                    UIManager:setDirty("all", "ui")
                                end
                            end

                            local dl_opts = {
                                on_progress = function(recv, total)
                                    if not pbar or not pbar.reportProgress then return end
                                    local pct = (total and total > 0) and math.floor((recv / total) * 100) or 0
                                    pbar.progress_max = 100
                                    pbar:reportProgress(pct)
                                    if pbar[1] and pbar[1][1] then
                                        local vg = pbar[1][1]
                                        if vg[2] and type(vg[2].setText) == "function" then
                                            local text = (total and total > 0 and util and util.getFriendlySize)
                                                and string.format(_("Downloading: %s / %s (%d%%)"), util.getFriendlySize(recv), util.getFriendlySize(total), pct)
                                                or string.format(_("Downloading: %s..."), (util and util.getFriendlySize and util.getFriendlySize(recv) or tostring(recv)))
                                            vg[2]:setText(text)
                                        end
                                    end
                                end,
                            }

                            Cloud.download(b, local_path, dl_opts, function(dl_ok, dl_res)
                                closeDlPbar()
                                if dl_ok then
                                    UIManager:show(InfoMessage:new{
                                        text = string.format(_("Downloaded %s successfully!"), b.filename),
                                        timeout = 2,
                                    })
                                    UIManager:nextTick(function()
                                        BackupUI.showArchiveDetailSheet(local_path, on_finish_cb)
                                    end)
                                else
                                    UIManager:show(ConfirmBox:new{
                                        text = string.format(_("Download failed:\n%s"), tostring(dl_res)),
                                        ok_text = _("Retry"),
                                        cancel_text = _("Cancel"),
                                        ok_callback = function()
                                            BackupUI.showCloudDownloadDialog(on_finish_cb)
                                        end,
                                        cancel_callback = function()
                                            if on_finish_cb then UIManager:nextTick(on_finish_cb) end
                                        end,
                                    })
                                end
                            end)
                        end,
                    },
                })
            end

            table.insert(buttons, {
                {
                    text = _("Cancel"),
                    callback = function()
                        closeDialog()
                        if on_finish_cb then UIManager:nextTick(on_finish_cb) end
                    end,
                },
            })

            dialog = ButtonDialog:new{
                title = string.format(_("Cloud Backups (%s)"), Cloud.getProviderLabel(provider)),
                buttons = buttons,
            }
            UIManager:show(dialog)
        end)
    end, function()
        if on_finish_cb then UIManager:nextTick(on_finish_cb) end
    end)
end

--- Shows a dialog to manage remote cloud backups (download or delete).
function BackupUI.showManageCloudBackupsDialog(on_finish_cb)
    local s = getPluginSettings()
    local provider = s.cloud_provider

    if not Cloud.isConfigured(provider) then
        UIManager:show(InfoMessage:new{
            text = string.format(_("%s is not configured."), Cloud.getProviderLabel(provider)),
            timeout = 3,
        })
        if on_finish_cb then UIManager:nextTick(on_finish_cb) end
        return
    end

    Beam.ensureNetwork(function()
        local fetch_info = InfoMessage:new{ text = string.format(_("Fetching backups from %s..."), Cloud.getProviderLabel(provider)) }
        UIManager:show(fetch_info)

        Cloud.listRemoteBackups(function(ok, list)
            UIManager:close(fetch_info)

            if not ok or not list or #list == 0 then
                UIManager:show(InfoMessage:new{
                    text = (not ok)
                        and string.format(_("Failed to fetch cloud backups:\n%s"), tostring(list))
                        or string.format(_("No backup files found on %s."), Cloud.getProviderLabel(provider)),
                    timeout = 3,
                })
                if on_finish_cb then UIManager:nextTick(on_finish_cb) end
                return
            end

            local dialog
            local function closeDialog()
                if dialog then
                    local d = dialog
                    dialog = nil
                    UIManager:close(d)
                end
            end

            local buttons = {}
            for idx, b in ipairs(list) do
                local label = string.format("%s (%s) • %s", b.filename, b.size_str, b.mtime_str)
                table.insert(buttons, {
                    {
                        text = label,
                        align = "left",
                        callback = function()
                            closeDialog()
                            -- Detail options for this remote backup: Download or Delete
                            local detail_dialog
                            local function closeDetail()
                                if detail_dialog then
                                    local dd = detail_dialog
                                    detail_dialog = nil
                                    UIManager:close(dd)
                                end
                            end

                            local detail_buttons = {
                                {
                                    {
                                        text = _("Download to Device"),
                                        bold = true,
                                        callback = function()
                                            closeDetail()
                                            local dest_dir = getEffectiveBackupDir()
                                            if util and util.makePath then util.makePath(dest_dir) end
                                            local local_path = dest_dir .. "/" .. b.filename
                                            local info = InfoMessage:new{ text = _("Downloading backup...") }
                                            UIManager:show(info)
                                            Cloud.download(b, local_path, {}, function(dl_ok, dl_res)
                                                UIManager:close(info)
                                                if dl_ok then
                                                    UIManager:show(InfoMessage:new{
                                                        text = string.format(_("Downloaded %s successfully!"), b.filename),
                                                        timeout = 2,
                                                    })
                                                    UIManager:nextTick(function()
                                                        BackupUI.showArchiveDetailSheet(local_path, function()
                                                            BackupUI.showManageCloudBackupsDialog(on_finish_cb)
                                                        end)
                                                    end)
                                                else
                                                    UIManager:show(InfoMessage:new{
                                                        text = string.format(_("Download failed: %s"), tostring(dl_res)),
                                                        timeout = 4,
                                                    })
                                                    UIManager:nextTick(function()
                                                        BackupUI.showManageCloudBackupsDialog(on_finish_cb)
                                                    end)
                                                end
                                            end)
                                        end,
                                    },
                                },
                                {
                                    {
                                        text = _("Delete from Cloud"),
                                        callback = function()
                                            closeDetail()
                                            local confirm = ConfirmBox:new{
                                                text = string.format(_("Delete remote backup '%s' from %s?\nThis action cannot be undone."), b.filename, Cloud.getProviderLabel(provider)),
                                                ok_text = _("Delete"),
                                                cancel_text = _("Cancel"),
                                                ok_callback = function()
                                                    local d_info = InfoMessage:new{ text = _("Deleting remote backup...") }
                                                    UIManager:show(d_info)
                                                    Cloud.deleteRemote(b, function(del_ok, del_err)
                                                        UIManager:close(d_info)
                                                        if del_ok then
                                                            UIManager:show(InfoMessage:new{ text = _("Backup deleted from cloud."), timeout = 2 })
                                                        else
                                                            UIManager:show(InfoMessage:new{ text = string.format(_("Delete failed: %s"), tostring(del_err)), timeout = 4 })
                                                        end
                                                        UIManager:nextTick(function()
                                                            BackupUI.showManageCloudBackupsDialog(on_finish_cb)
                                                        end)
                                                    end)
                                                end,
                                                cancel_callback = function()
                                                    BackupUI.showManageCloudBackupsDialog(on_finish_cb)
                                                end,
                                            }
                                            UIManager:show(confirm)
                                        end,
                                    },
                                },
                                {
                                    {
                                        text = _("Back"),
                                        callback = function()
                                            closeDetail()
                                            BackupUI.showManageCloudBackupsDialog(on_finish_cb)
                                        end,
                                    },
                                },
                            }

                            detail_dialog = ButtonDialog:new{
                                title = b.filename,
                                buttons = detail_buttons,
                            }
                            UIManager:show(detail_dialog)
                        end,
                    },
                })
            end

            table.insert(buttons, {
                {
                    text = _("Close"),
                    callback = function()
                        closeDialog()
                        if on_finish_cb then UIManager:nextTick(on_finish_cb) end
                    end,
                },
            })

            dialog = ButtonDialog:new{
                title = string.format(_("Manage %s Backups"), Cloud.getProviderLabel(provider)),
                buttons = buttons,
            }
            UIManager:show(dialog)
        end)
    end, function()
        if on_finish_cb then UIManager:nextTick(on_finish_cb) end
    end)
end

return BackupUI
