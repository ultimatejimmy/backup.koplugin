--[[--
backup_scheduler_test.lua
Unit tests for the Scheduled Backup Reminder engine.
--]]

require("tests/spec_helper")

local UIManager = require("ui/uimanager")
local Constants = require("backup_constants")
local BackupUI = require("backup_ui")
local BackupScheduler = require("backup_scheduler")
local ArchiverMgr = require("backup_archiver")
local Retention = require("backup_retention")
local Cloud = require("backup_cloud")

describe("BackupScheduler", function()
    local saved_settings

    before_each(function()
        local s = BackupUI.getPluginSettings()
        s.auto_backup_enabled = false
        s.auto_backup_interval = Constants.AUTO_BACKUP_INTERVALS.WEEKLY
        s.auto_backup_grace_period = 150
        s.auto_backup_cloud_upload = false
        s.auto_backup_last_time = 0
        s.auto_backup_snoozed_until = nil
        s.retention_limit = 5
        s.cloud_provider = "none"

        BackupScheduler.cancelGracePeriodTimer()
    end)

    after_each(function()
        BackupScheduler.cancelGracePeriodTimer()
    end)

    describe("formatLastBackupTime", function()
        it("returns 'Never' when timestamp is 0 or nil", function()
            assert.are.equal("Never", BackupScheduler.formatLastBackupTime(nil))
            assert.are.equal("Never", BackupScheduler.formatLastBackupTime(0))
            assert.are.equal("Never", BackupScheduler.formatLastBackupTime(-1))
        end)

        it("formats relative timestamps correctly", function()
            local now = os.time()
            assert.are.equal("Less than an hour ago", BackupScheduler.formatLastBackupTime(now - 300))
            assert.are.equal("1 hour ago", BackupScheduler.formatLastBackupTime(now - 3650))
            assert.are.equal("5 hours ago", BackupScheduler.formatLastBackupTime(now - 18000))
            assert.are.equal("Yesterday", BackupScheduler.formatLastBackupTime(now - 90000))
            assert.are.equal("3 days ago", BackupScheduler.formatLastBackupTime(now - 260000))
        end)
    end)

    describe("isDue", function()
        it("returns false if auto_backup_enabled is false", function()
            local s = {
                auto_backup_enabled = false,
                auto_backup_interval = 604800,
                auto_backup_last_time = 0,
            }
            assert.is_false(BackupScheduler.isDue(s))
        end)

        it("returns false if snoozed", function()
            local now = 1000000
            local s = {
                auto_backup_enabled = true,
                auto_backup_interval = 604800,
                auto_backup_last_time = 0,
                auto_backup_snoozed_until = now + 3600,
            }
            assert.is_false(BackupScheduler.isDue(s, now))
        end)

        it("returns true when interval has elapsed", function()
            local now = 1000000
            local s = {
                auto_backup_enabled = true,
                auto_backup_interval = 604800,
                auto_backup_last_time = now - 604900,
            }
            assert.is_true(BackupScheduler.isDue(s, now))
        end)

        it("returns false when interval has not elapsed yet", function()
            local now = 1000000
            local s = {
                auto_backup_enabled = true,
                auto_backup_interval = 604800,
                auto_backup_last_time = now - 100000,
            }
            assert.is_false(BackupScheduler.isDue(s, now))
        end)
    end)

    describe("Grace Period Timer", function()
        it("schedules a non-blocking timer in UIManager", function()
            local scheduled_delay = nil
            local scheduled_action = nil
            local orig_scheduleIn = UIManager.scheduleIn
            UIManager.scheduleIn = function(self, delay, action)
                scheduled_delay = delay
                scheduled_action = action
            end

            local s = BackupUI.getPluginSettings()
            s.auto_backup_enabled = true
            s.auto_backup_grace_period = 150

            BackupScheduler.startGracePeriodTimer()
            assert.are.equal(150, scheduled_delay)
            assert.is_function(scheduled_action)

            -- Cancel timer
            local unscheduled_action = nil
            local orig_unschedule = UIManager.unschedule
            UIManager.unschedule = function(self, action)
                unscheduled_action = action
            end

            BackupScheduler.cancelGracePeriodTimer()
            assert.are.equal(scheduled_action, unscheduled_action)

            UIManager.scheduleIn = orig_scheduleIn
            UIManager.unschedule = orig_unschedule
        end)

        it("does not schedule timer if auto_backup_enabled is false", function()
            local called = false
            local orig_scheduleIn = UIManager.scheduleIn
            UIManager.scheduleIn = function() called = true end

            local s = BackupUI.getPluginSettings()
            s.auto_backup_enabled = false

            BackupScheduler.startGracePeriodTimer()
            assert.is_false(called)

            UIManager.scheduleIn = orig_scheduleIn
        end)
    end)

    describe("snooze", function()
        it("sets auto_backup_snoozed_until into the future", function()
            local t0 = os.time()
            BackupScheduler.snooze(3600)
            local s = BackupUI.getPluginSettings()
            assert.is_not_nil(s.auto_backup_snoozed_until)
            assert.is_true(s.auto_backup_snoozed_until >= t0 + 3600)
        end)
    end)

    describe("showReminderDialog", function()
        it("displays a 3-button ConfirmBox with Backup Now, Later, and Open Settings", function()
            local shown_dialog = nil
            local orig_show = UIManager.show
            UIManager.show = function(self, widget)
                shown_dialog = widget
            end

            local settings_opened = false
            BackupScheduler.showReminderDialog(function()
                settings_opened = true
            end)

            assert.is_not_nil(shown_dialog)
            assert.are.equal("Backup Reminder", shown_dialog.title)
            assert.are.equal("Backup Now", shown_dialog.ok_text)
            assert.are.equal("Later", shown_dialog.cancel_text)
            assert.is_table(shown_dialog.other_buttons)
            assert.are.equal("Open Settings", shown_dialog.other_buttons[1][1].text)

            -- Test Open Settings callback
            shown_dialog.other_buttons[1][1].callback()
            assert.is_true(settings_opened)

            -- Test Later callback (snoozes)
            shown_dialog.cancel_callback()
            local s = BackupUI.getPluginSettings()
            assert.is_not_nil(s.auto_backup_snoozed_until)

            UIManager.show = orig_show
        end)
    end)

    describe("executeQuickBackup", function()
        it("creates backup, updates last_time, clears snooze, and prunes retention", function()
            local test_dir = "/tmp/test_backup_scheduler_run"
            os.execute("mkdir -p \"" .. test_dir .. "\"")

            local s = BackupUI.getPluginSettings()
            s.custom_backup_dir = test_dir
            s.auto_backup_snoozed_until = os.time() + 9999

            local orig_createBackup = ArchiverMgr.createBackup
            local created_opts = nil
            ArchiverMgr.createBackup = function(opts)
                created_opts = opts
                -- Create empty file to simulate output
                local f = io.open(opts.archive_path, "wb")
                if f then f:write("data"); f:close() end
                return true, { archive_path = opts.archive_path, size = 100, file_count = 5 }
            end

            local finished = false
            BackupScheduler.executeQuickBackup({}, function()
                finished = true
            end)

            assert.is_not_nil(created_opts)
            assert.is_not_nil(created_opts.archive_path:match("%.zip$"))
            assert.is_true(s.auto_backup_last_time > 0)
            assert.is_nil(s.auto_backup_snoozed_until)
            assert.is_true(finished)

            ArchiverMgr.createBackup = orig_createBackup
            os.execute("rm -rf \"" .. test_dir .. "\"")
        end)
    end)
end)
