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
    for _, p in ipairs(candidates) do
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
        }
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
                    closeMain()
                    BackupUI.showCreateDialog()
                end,
            },
        },
        {
            {
                text = _("Restore Backup"),
                callback = function()
                    closeMain()
                    BackupUI.showRestoreDialog()
                end,
            },
        },
        {
            {
                text = _("Beam to Device"),
                callback = function()
                    closeMain()
                    BackupUI.showBeamSelectBackupDialog()
                end,
            },
        },
        {
            {
                text = _("Receive via Beam Code"),
                callback = function()
                    closeMain()
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
                    closeMain()
                    BackupUI.showUndoRestoreConfirmation()
                end,
            },
        })
    end

    table.insert(buttons, {
        {
            text = _("Manage Backups"),
            callback = function()
                closeMain()
                BackupUI.showManageBackupsDialog()
            end,
        },
    })

    table.insert(buttons, {
        {
            text = _("Backup & Restore Settings"),
            callback = function()
                closeMain()
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
-- 2. Create Backup Wizard
-- --------------------------------------------------------------------------
function BackupUI.showCreateDialog()
    local s = getPluginSettings()
    local now = os.time()
    local current_name = "backup_" .. os.date("%Y-%m-%d_%H%M%S", now)
    local components = {}
    for k, v in pairs(Constants.DEFAULT_COMPONENT_SELECTION) do
        components[k] = v
    end
    local chosen_format = s.default_format or "zip"
    local focus_state = createFocusState()

    local dialog
    local refresh

    local function closeDialog()
        if dialog then
            local d = dialog
            dialog = nil
            UIManager:close(d)
        end
    end

    local function startBackupCreation(name_input)
        closeDialog()
        local backup_dir = getEffectiveBackupDir()
        local archive_name = (name_input and name_input ~= "") and name_input or current_name
        local filename = archive_name .. "." .. chosen_format
        local full_archive_path = backup_dir .. "/" .. filename

        local info_msg = InfoMessage:new{
            text = _("Creating backup archive...\nPlease wait."),
        }
        UIManager:show(info_msg)

        UIManager:nextTick(function()
            local ok, res = ArchiverMgr.createBackup{
                archive_path = full_archive_path,
                format = chosen_format,
                components = components,
                backup_name = archive_name,
                data_dir = getDataDir(),
            }

            UIManager:close(info_msg)

            if ok and type(res) == "table" then
                if s.retention_limit and s.retention_limit > 0 then
                    Retention.prune(backup_dir, s.retention_limit)
                end

                local sz_str = Retention.formatSize(res.size or 0)
                local file_count = res.file_count or 0
                UIManager:show(InfoMessage:new{
                    text = string.format(_("Backup created successfully!\n\nFile: %s\nSize: %s\nArchived files: %d"),
                        filename, sz_str, file_count),
                    timeout = 5,
                })
            else
                UIManager:show(InfoMessage:new{
                    text = string.format(_("Failed to create backup:\n%s"), tostring(res)),
                    timeout = 6,
                })
            end
        end)
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

        local component_specs = {
            { key = Constants.COMPONENTS.SETTINGS, label = _("Settings & UI Gestures") },
            { key = Constants.COMPONENTS.PLUGINS, label = _("User Plugins") },
            { key = Constants.COMPONENTS.PATCHES, label = _("Patches") },
            { key = Constants.COMPONENTS.FONTS, label = _("Fonts") },
            { key = Constants.COMPONENTS.SCREENSAVERS, label = _("Screensavers") },
            { key = Constants.COMPONENTS.STYLETWEAKS, label = _("Style Tweaks") },
            { key = Constants.COMPONENTS.DOCSETTINGS, label = _("Reading Progress & Notes") },
            { key = Constants.COMPONENTS.HISTORY, label = _("Reading History & Stats") },
            { key = Constants.COMPONENTS.DICTIONARIES, label = _("Dictionaries & OCR Data") },
        }

        local buttons = {}
        for _, spec in ipairs(component_specs) do
            local key = spec.key
            local row_idx = #buttons + 1
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

        local select_all_row_idx = #buttons + 1
        table.insert(buttons, {
            {
                text = _("Select All"),
                callback = function()
                    for k, _ in pairs(Constants.COMPONENTS) do components[Constants.COMPONENTS[k]] = true end
                    refresh(1, select_all_row_idx)
                end,
            },
            {
                text = _("Recommended"),
                callback = function()
                    for k, _ in pairs(Constants.COMPONENTS) do components[Constants.COMPONENTS[k]] = false end
                    for k, v in pairs(Constants.DEFAULT_COMPONENT_SELECTION) do components[k] = v end
                    refresh(2, select_all_row_idx)
                end,
            },
            {
                text = _("Clear All"),
                callback = function()
                    for k, _ in pairs(Constants.COMPONENTS) do components[Constants.COMPONENTS[k]] = false end
                    refresh(3, select_all_row_idx)
                end,
            },
        })

        local format_row_idx = #buttons + 1
        table.insert(buttons, {
            {
                text = string.format(_("Format: .%s"), chosen_format:upper()),
                callback = function()
                    chosen_format = (chosen_format == "zip") and "tar.gz" or "zip"
                    refresh(1, format_row_idx)
                end,
            },
            {
                text = string.format(_("Name: %s"), current_name),
                callback = function()
                    local name_dialog
                    name_dialog = InputDialog:new{
                        title = _("Backup Name"),
                        description = _("Enter custom filename (without extension):"),
                        input = current_name,
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
                                            current_name = new_name:gsub("[/\\?%%*:|\"<>]", "_")
                                            refresh(2, format_row_idx)
                                        end
                                    end,
                                },
                            },
                        },
                    }
                    UIManager:show(name_dialog)
                end,
            },
        })

        table.insert(buttons, {
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
                    startBackupCreation(current_name)
                end,
            },
        })

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

    if #backups == 0 then
        local confirm
        confirm = ConfirmBox:new{
            text = string.format(_("No backup files found in:\n%s"), backup_dir),
            ok_text = _("Browse Folder"),
            cancel_text = _("Cancel"),
            ok_callback = function()
                UIManager:close(confirm)
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
            cancel_callback = function()
                UIManager:close(confirm)
            end,
        }
        UIManager:show(confirm)
        return
    end

    local buttons = {}
    for _, b in ipairs(backups) do
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

    table.insert(buttons, {
        {
            text = _("Browse Folder"),
            callback = function()
                closeRestore()
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
                    })
                    UIManager:close(info)

                    if ok then
                        local stripped_count = (details and details.stripped_keys and #details.stripped_keys) or 0
                        local detail_msg = ""
                        if stripped_count > 0 then
                            detail_msg = string.format(_("\n\nSanitized %d hardware keys for device compatibility."), stripped_count)
                        end
                        BackupUI.showRestartConfirmation(_("Backup restored successfully!") .. detail_msg)
                    else
                        UIManager:show(InfoMessage:new{ text = _("Restore failed: %s", tostring(msg)), timeout = 5 })
                    end
                end)
            end,
        }
        UIManager:show(confirm)
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
                    text = _("Sanitize Hardware Settings"),
                    align = "left",
                    checked_func = function() return sanitize_toggle end,
                    callback = function()
                        sanitize_toggle = not sanitize_toggle
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
        for _, b in ipairs(backups) do
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
                    text = string.format(_("Format: .%s"), (s.default_format or "zip"):upper()),
                    callback = function()
                        s.default_format = (s.default_format == "zip") and "tar.gz" or "zip"
                        savePluginSettings()
                        refresh(1, 2)
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
                                                refresh(1, 3)
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
                                                refresh(1, 3)
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
                                            UIManager:nextTick(function() refresh(1, 4) end)
                                        end,
                                    },
                                    {
                                        text = _("Reset Default"),
                                        callback = function()
                                            s.beam_relay_url = Constants.BEAM_DEFAULT_RELAY_URL
                                            savePluginSettings()
                                            UIManager:close(relay_dialog)
                                            UIManager:nextTick(function() refresh(1, 4) end)
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
                                            UIManager:nextTick(function() refresh(1, 4) end)
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
                    text = _("Close"),
                    callback = function()
                        closeSettings()
                    end,
                },
            },
        }

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
    for _, b in ipairs(backups) do
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
                    UIManager:close(pbar)
                end
                pbar = nil
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
                        setPbarSubtitle(_("Uploading backup archive..."))
                        setPbarProgress(pct, false)
                    end
                end,
            }
            Beam.upload(filepath, pin, upload_opts, function(ok, res)
                if not ok then
                    closePbar()
                    UIManager:show(InfoMessage:new{
                        text = string.format(_("Beam upload failed:\n%s"), tostring(res)),
                        timeout = 6,
                    })
                    if on_finish_cb then
                        UIManager:nextTick(on_finish_cb)
                    end
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
                    local display_code = formatted_pin:gsub("%-", " - ")

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
                                        UIManager:close(pbar)
                                    end
                                    pbar = nil
                                end
                            end

                            UIManager:nextTick(function()
                                local dest_dir = getEffectiveBackupDir()
                                local dl_opts = {
                                    relay_url = s.beam_relay_url,
                                    on_progress = function(received, total)
                                        if pbar and pbar.reportProgress then
                                            if total and total > 0 then
                                                if pbar.progress_max ~= total then
                                                    pbar.progress_max = total
                                                end
                                                pbar:reportProgress(math.min(received, total))
                                            else
                                                if received > pbar.progress_max then
                                                    pbar.progress_max = received * 2
                                                end
                                                pbar:reportProgress(math.min(received, pbar.progress_max))
                                            end
                                        end
                                    end,
                                }
                                Beam.download(clean_pin, dest_dir, dl_opts, function(ok, target_path, filename)
                                    closePbar()
                                    if not ok then
                                        UIManager:show(InfoMessage:new{
                                            text = string.format(_("Beam reception failed:\n%s"), tostring(target_path)),
                                            timeout = 6,
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

return BackupUI
