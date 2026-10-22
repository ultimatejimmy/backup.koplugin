--[[--
backup_scheduler.lua
Scheduled Backup Reminder engine for KOReader.
Handles interval checking across sleep/wake cycles, post-wake grace period timers,
3-action reminder dialogs, and one-tap quick backup execution.
--]]

local Constants = require("backup_constants")
local Localization = require("localization_backup")
local _ = Localization:getHelper()
local ArchiverMgr = require("backup_archiver")
local Retention = require("backup_retention")
local Cloud = require("backup_cloud")
local BackupProgress = require("backup_progress")

local ok_ui, UIManager = pcall(require, "ui/uimanager")
if not ok_ui or not UIManager then UIManager = _G.UIManager end

local ok_confirm, ConfirmBox = pcall(require, "ui/widget/confirmbox")
if not ok_confirm or not ConfirmBox then ConfirmBox = _G.ConfirmBox end

local ok_info, InfoMessage = pcall(require, "ui/widget/infomessage")
if not ok_info or not InfoMessage then InfoMessage = _G.InfoMessage end

local ok_net, NetworkMgr = pcall(require, "ui/network/manager")
if not ok_net or not NetworkMgr then NetworkMgr = _G.NetworkMgr end

local ok_util, util = pcall(require, "util")
if not ok_util or not util then util = _G.util end

local BackupScheduler = {
    _timer_action = nil,
    _active_reminder_dialog = nil,
}

--- Retrieves active plugin settings.
function BackupScheduler.getSettings()
    local ok_ui_mod, BackupUI = pcall(require, "backup_ui")
    if ok_ui_mod and BackupUI and BackupUI.getPluginSettings then
        return BackupUI.getPluginSettings()
    end
    return Constants.DEFAULT_SETTINGS
end

--- Saves active plugin settings.
function BackupScheduler.saveSettings()
    local ok_ui_mod, BackupUI = pcall(require, "backup_ui")
    if ok_ui_mod and BackupUI and BackupUI.savePluginSettings then
        BackupUI.savePluginSettings()
    end
end

--- Formats the timestamp of the last backup into a user-friendly string.
function BackupScheduler.formatLastBackupTime(last_time)
    if not last_time or last_time <= 0 then
        return _("Never")
    end

    local now = os.time()
    local diff = now - last_time
    if diff < 0 then
        return os.date("%Y-%m-%d %H:%M", last_time)
    elseif diff < 3600 then
        return _("Less than an hour ago")
    elseif diff < 86400 then
        local hours = math.floor(diff / 3600)
        if hours <= 1 then
            return _("1 hour ago")
        else
            return string.format(_("%d hours ago"), hours)
        end
    elseif diff < 172800 then
        return _("Yesterday")
    else
        local days = math.floor(diff / 86400)
        return string.format(_("%d days ago"), days)
    end
end

--- Checks if a scheduled backup reminder is currently due.
-- @param s table: plugin settings (optional, loads from getSettings if nil)
-- @param now number: current timestamp (optional, defaults to os.time())
-- @return boolean
function BackupScheduler.isDue(s, now)
    s = s or BackupScheduler.getSettings()
    if not s or not s.auto_backup_enabled then
        return false
    end

    now = now or os.time()

    -- Check if snoozed
    if s.auto_backup_snoozed_until and now < s.auto_backup_snoozed_until then
        return false
    end

    local interval = s.auto_backup_interval or Constants.AUTO_BACKUP_INTERVALS.WEEKLY
    if interval <= 0 then
        return false
    end

    local last_time = s.auto_backup_last_time or 0
    return (now - last_time) >= interval
end

--- Starts the non-blocking post-wake / post-launch grace period timer.
-- Cancels any existing timer before starting a new one.
-- @param delay number: optional delay in seconds (defaults to s.auto_backup_grace_period or 150)
function BackupScheduler.startGracePeriodTimer(delay)
    BackupScheduler.cancelGracePeriodTimer()

    local s = BackupScheduler.getSettings()
    if not s or not s.auto_backup_enabled then
        return
    end

    delay = delay or s.auto_backup_grace_period or 150
    if delay < 0 then delay = 0 end

    if not UIManager or not UIManager.scheduleIn then
        return
    end

    local action
    action = function()
        BackupScheduler._timer_action = nil
        if BackupScheduler.isDue() then
            BackupScheduler.showReminderDialog()
        end
    end

    BackupScheduler._timer_action = action
    UIManager:scheduleIn(delay, action)
end

--- Cancels any pending grace period timer cleanly.
function BackupScheduler.cancelGracePeriodTimer()
    if BackupScheduler._timer_action and UIManager and UIManager.unschedule then
        pcall(function() UIManager:unschedule(BackupScheduler._timer_action) end)
    end
    BackupScheduler._timer_action = nil
end

--- Snoozes the scheduled reminder.
-- @param seconds number: optional snooze duration in seconds (defaults to 24 hours / 86400s)
function BackupScheduler.snooze(seconds)
    local s = BackupScheduler.getSettings()
    seconds = seconds or 86400 -- 24 hours
    s.auto_backup_snoozed_until = os.time() + seconds
    BackupScheduler.saveSettings()
end

--- Displays the 3-action reminder dialog (Backup Now, Later, Open Settings).
-- @param on_settings_cb function: callback to open scheduled backup settings
function BackupScheduler.showReminderDialog(on_settings_cb)
    if not ConfirmBox or not UIManager then return end

    local s = BackupScheduler.getSettings()
    local last_str = BackupScheduler.formatLastBackupTime(s.auto_backup_last_time)

    local confirm
    confirm = ConfirmBox:new{
        title = _("Backup Reminder"),
        text = string.format(_("Your scheduled backup is due.\nLast backup: %s\n\nWould you like to back up your device now?"), last_str),
        ok_text = _("Backup Now"),
        cancel_text = _("Later"),
        other_buttons = {
            {
                {
                    text = _("Open Settings"),
                    callback = function()
                        if on_settings_cb then
                            on_settings_cb()
                        else
                            local ok_ui_mod, BackupUI = pcall(require, "backup_ui")
                            if ok_ui_mod and BackupUI and BackupUI.showScheduledBackupSettingsDialog then
                                BackupUI.showScheduledBackupSettingsDialog()
                            end
                        end
                    end,
                },
            },
        },
        ok_callback = function()
            BackupScheduler._active_reminder_dialog = nil
            BackupScheduler.executeQuickBackup()
        end,
        cancel_callback = function()
            BackupScheduler._active_reminder_dialog = nil
            BackupScheduler.snooze()
        end,
    }

    BackupScheduler._active_reminder_dialog = confirm
    UIManager:show(confirm)
end

--- Executes one-tap quick backup using saved settings and progress tracking.
-- @param opts table: optional overrides { components, format, backup_dir }
-- @param on_finish_cb function: callback when backup finishes
function BackupScheduler.executeQuickBackup(opts, on_finish_cb)
    opts = opts or {}
    local s = BackupScheduler.getSettings()

    local ok_ui_mod, BackupUI = pcall(require, "backup_ui")
    local getEffectiveBackupDir = (ok_ui_mod and BackupUI and BackupUI.getEffectiveBackupDir)
        or function() return (s.custom_backup_dir and s.custom_backup_dir ~= "" and s.custom_backup_dir) or Retention.getDefaultBackupDir() end

    local backup_dir = opts.backup_dir or getEffectiveBackupDir()
    local format = opts.format or s.default_format or "zip"
    local timestamp = os.date("%Y-%m-%d_%H%M%S")
    local archive_name = "backup_" .. timestamp
    local filename = archive_name .. "." .. format
    local full_archive_path = backup_dir .. "/" .. filename

    -- Default to saved auto-backup components or standard default components
    local components = opts.components or s.auto_backup_components or Constants.DEFAULT_COMPONENT_SELECTION

    local ok_ds, DataStorage = pcall(require, "datastorage")
    local data_dir = opts.data_dir or (ok_ds and DataStorage and DataStorage.getDataDir and DataStorage:getDataDir()) or "."

    local selected_plugins = opts.selected_plugins or s.auto_backup_selected_plugins
    local selected_patches = opts.selected_patches or s.auto_backup_selected_patches
    local selected_fonts = opts.selected_fonts or s.auto_backup_selected_fonts
    local selected_dicts = opts.selected_dictionaries or s.auto_backup_selected_dicts

    local progress_dlg
    if BackupProgress then
        progress_dlg = BackupProgress:new{
            title = _("Creating Scheduled Backup"),
            subtitle = _("Preparing payload..."),
            detail = "",
            cancel_text = _("Cancel"),
        }
        progress_dlg:show()
    end

    local last_pbar_update = 0
    local function setPbarProgress(curr_files, total_files, curr_bytes, total_bytes, current_path)
        if not progress_dlg or progress_dlg.is_closed then return end
        local now_t = os.clock()
        local is_done = (curr_files >= total_files and total_files > 0) or (curr_bytes >= total_bytes and total_bytes > 0)
        if not is_done and (now_t - last_pbar_update) < 1.0 then
            return
        end
        last_pbar_update = now_t

        local pct = (total_bytes > 0) and math.min(100, math.floor((curr_bytes / total_bytes) * 100)) or 0
        local file_disp = current_path and current_path:match("([^/\\]+)$") or current_path or ""
        local sub = string.format(_("Archiving (%d/%d - %s)"),
            curr_files, math.max(total_files, 1), (util and util.getFriendlySize and util.getFriendlySize(curr_bytes) or tostring(curr_bytes)))
        progress_dlg:update{
            progress = pct,
            subtitle = sub,
            detail = file_disp,
        }
    end

    local function runArchiving()
        local ok, res = ArchiverMgr.createBackup{
            archive_path = full_archive_path,
            format = format,
            components = components,
            selected_plugins = selected_plugins,
            selected_patches = selected_patches,
            selected_fonts = selected_fonts,
            selected_dictionaries = selected_dicts,
            backup_name = archive_name,
            data_dir = data_dir,
            books_dir = s.custom_books_dir or ArchiverMgr.getEffectiveBooksDir(),
            is_canceled = function() return progress_dlg and progress_dlg:isCanceled() end,
            on_progress = function(curr_files, total_files, curr_bytes, total_bytes, current_path)
                setPbarProgress(curr_files, total_files, curr_bytes, total_bytes, current_path)
            end,
        }

        local was_canceled = progress_dlg and progress_dlg:isCanceled()
        if progress_dlg then
            progress_dlg:close()
        end

        local function showResultInfo(text, timeout, cb)
            if InfoMessage and UIManager then
                UIManager:show(InfoMessage:new{
                    text = text,
                    timeout = timeout or 4,
                    dismiss_callback = function()
                        if UIManager.setDirty then UIManager:setDirty("all", "ui") end
                    end,
                })
            end
            if cb then
                if UIManager and UIManager.nextTick then
                    UIManager:nextTick(cb)
                else
                    cb()
                end
            end
        end

        if was_canceled or (not ok and tostring(res):find("canceled")) then
            pcall(os.remove, full_archive_path)
            showResultInfo(_("Scheduled backup canceled."), 3, on_finish_cb)
            return
        end

        if not ok then
            showResultInfo(string.format(_("Scheduled backup failed:\n%s"), tostring(res)), 5, on_finish_cb)
            return
        end

        -- Update last backup time and clear snooze
        s.auto_backup_last_time = os.time()
        s.auto_backup_snoozed_until = nil
        BackupScheduler.saveSettings()

        -- Prune local retention
        if s.retention_limit and s.retention_limit > 0 then
            Retention.prune(backup_dir, s.retention_limit)
        end

        local sz_str = Retention.formatSize(res.size or 0)
        local file_count = res.file_count or 0

        -- Check if cloud upload is requested
        local is_cloud_enabled = s.auto_backup_cloud_upload and Cloud.isConfigured(s.cloud_provider)
        local is_online = NetworkMgr and NetworkMgr.isOnline and NetworkMgr:isOnline()

        if is_cloud_enabled and is_online then
            if ok_ui_mod and BackupUI and BackupUI.showCloudUploadDialog then
                UIManager:nextTick(function()
                    BackupUI.showCloudUploadDialog(full_archive_path, on_finish_cb)
                end)
            else
                Cloud.upload(full_archive_path, {}, function()
                    showResultInfo(string.format(_("Scheduled backup created and uploaded to %s!\n\nFile: %s\nSize: %s"),
                        Cloud.getProviderLabel(s.cloud_provider), filename, sz_str), 5, on_finish_cb)
                end)
            end
        elseif is_cloud_enabled and not is_online then
            showResultInfo(string.format(_("Backup created successfully!\n\nFile: %s\nSize: %s\nArchived files: %d\n\n(Cloud upload skipped: Wi-Fi offline)"),
                filename, sz_str, file_count), 5, on_finish_cb)
        else
            showResultInfo(string.format(_("Backup created successfully!\n\nFile: %s\nSize: %s\nArchived files: %d"),
                filename, sz_str, file_count), 4, on_finish_cb)
        end
    end

    if UIManager and UIManager.nextTick then
        UIManager:nextTick(runArchiving)
    else
        runArchiving()
    end
end

return BackupScheduler
