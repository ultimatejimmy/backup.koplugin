require("tests/spec_helper")

local UIManager = require("ui/uimanager")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local ButtonDialog = require("ui/widget/buttondialog")
local InfoMessage = require("ui/widget/infomessage")
local ArchiverMgr = require("backup_archiver")
local Constants = require("backup_constants")
local Cloud = require("backup_cloud")
local BackupUI = require("backup_ui")

describe("backup_ui cloud settings dialog tests", function()
    local last_dialog
    local shown_widgets = {}

    before_each(function()
        last_dialog = nil
        shown_widgets = {}

        local orig_multi_new = MultiInputDialog.new
        MultiInputDialog.new = function(self, args)
            local dlg = orig_multi_new(self, args)
            last_dialog = dlg
            return dlg
        end

        local orig_button_new = ButtonDialog.new
        ButtonDialog.new = function(self, args)
            local dlg = orig_button_new(self, args)
            last_dialog = dlg
            return dlg
        end

        UIManager.show = function(self, widget)
            table.insert(shown_widgets, widget)
        end
        UIManager.close = function(self, widget) end
        UIManager.nextTick = function(self, fn, ...) if fn then return fn(...) end end
    end)

    local function findButton(dialog, button_text)
        if not dialog or not dialog.buttons then return nil end
        for _, row in ipairs(dialog.buttons) do
            for _, btn in ipairs(row) do
                if btn.text == button_text then
                    return btn
                end
            end
        end
        return nil
    end

    local function findButtonMatching(dialog, pattern)
        if not dialog or not dialog.buttons then return nil end
        for _, row in ipairs(dialog.buttons) do
            for _, btn in ipairs(row) do
                if btn.text and btn.text:match(pattern) then
                    return btn
                end
            end
        end
        return nil
    end

    describe("WebDAV dialog 'Test' button", function()
        it("triggers Cloud.testConnection without crashing", function()
            local test_called = false
            local tested_provider = nil
            local tested_creds = nil

            local orig_test = Cloud.testConnection
            Cloud.testConnection = function(provider, creds, cb)
                test_called = true
                tested_provider = provider
                tested_creds = creds
                cb(true, "WebDAV Connection Successful")
            end

            BackupUI.showCloudConfigDialog(Constants.CLOUD_PROVIDERS.WEBDAV)
            assert.is_not_nil(last_dialog)

            local test_btn = findButton(last_dialog, "Test")
            assert.is_not_nil(test_btn, "Test button should exist in WebDAV dialog")

            -- Click the Test button
            test_btn.callback()

            assert.is_true(test_called)
            assert.equals(Constants.CLOUD_PROVIDERS.WEBDAV, tested_provider)
            assert.is_not_nil(tested_creds)

            Cloud.testConnection = orig_test
        end)
    end)

    describe("FTP dialog 'Test' button", function()
        it("triggers Cloud.testConnection without crashing", function()
            local test_called = false
            local tested_provider = nil
            local tested_creds = nil

            local orig_test = Cloud.testConnection
            Cloud.testConnection = function(provider, creds, cb)
                test_called = true
                tested_provider = provider
                tested_creds = creds
                cb(true, "FTP Connection Successful")
            end

            BackupUI.showCloudConfigDialog(Constants.CLOUD_PROVIDERS.FTP)
            assert.is_not_nil(last_dialog)

            local test_btn = findButton(last_dialog, "Test")
            assert.is_not_nil(test_btn, "Test button should exist in FTP dialog")

            -- Click the Test button
            test_btn.callback()

            assert.is_true(test_called)
            assert.equals(Constants.CLOUD_PROVIDERS.FTP, tested_provider)
            assert.is_not_nil(tested_creds)

            Cloud.testConnection = orig_test
        end)
    end)

    describe("SFTP dialog 'Test' button", function()
        it("triggers Cloud.testConnection without crashing", function()
            local test_called = false
            local tested_provider = nil
            local tested_creds = nil

            local orig_test = Cloud.testConnection
            Cloud.testConnection = function(provider, creds, cb)
                test_called = true
                tested_provider = provider
                tested_creds = creds
                cb(true, "SFTP Connection Successful")
            end

            BackupUI.showCloudConfigDialog(Constants.CLOUD_PROVIDERS.SFTP)
            assert.is_not_nil(last_dialog)

            local test_btn = findButton(last_dialog, "Test")
            assert.is_not_nil(test_btn, "Test button should exist in SFTP dialog")

            -- Click the Test button
            test_btn.callback()

            assert.is_true(test_called)
            assert.equals(Constants.CLOUD_PROVIDERS.SFTP, tested_provider)
            assert.is_not_nil(tested_creds)

            Cloud.testConnection = orig_test
        end)
    end)

    describe("Create Backup screen cloud upload option", function()
        it("displays 'Upload to Cloud on Creation: Yes (Provider)' and 'Create & Upload' when cloud is configured", function()
            local s = BackupUI.getPluginSettings()
            s.cloud_provider = Constants.CLOUD_PROVIDERS.GDRIVE
            s.upload_to_cloud = true

            local orig_isConfigured = Cloud.isConfigured
            Cloud.isConfigured = function(p)
                if p == Constants.CLOUD_PROVIDERS.GDRIVE then return true end
                return orig_isConfigured(p)
            end

            BackupUI.showCreateDialog()
            assert.is_not_nil(last_dialog)

            local cloud_btn = findButtonMatching(last_dialog, "^Upload to Cloud on Creation")
            assert.is_not_nil(cloud_btn)
            assert.is_true(cloud_btn.text:find("Google Drive") ~= nil)
            assert.is_true(cloud_btn.text:find("Yes") ~= nil)

            local action_btn = findButton(last_dialog, "Create & Upload")
            assert.is_not_nil(action_btn)

            -- Tap cloud_btn to toggle off
            cloud_btn.callback()
            assert.is_not_nil(last_dialog)
            local cloud_btn_after = findButtonMatching(last_dialog, "^Upload to Cloud on Creation")
            assert.is_not_nil(cloud_btn_after)
            assert.is_true(cloud_btn_after.text:find("No") ~= nil)
            assert.is_false(s.upload_to_cloud)

            local action_btn_after = findButton(last_dialog, "Create Backup")
            assert.is_not_nil(action_btn_after)

            Cloud.isConfigured = orig_isConfigured
        end)

        it("displays 'Upload to Cloud on Creation: Not Configured' and prompts to configure when tapped", function()
            local s = BackupUI.getPluginSettings()
            s.cloud_provider = Constants.CLOUD_PROVIDERS.NONE
            s.upload_to_cloud = true

            local orig_isConfigured = Cloud.isConfigured
            Cloud.isConfigured = function() return false end

            local picker_called = false
            local orig_picker = BackupUI.showCloudProviderPicker
            BackupUI.showCloudProviderPicker = function(cb)
                picker_called = true
                if cb then cb() end
            end

            BackupUI.showCreateDialog()
            assert.is_not_nil(last_dialog)

            local cloud_btn = findButtonMatching(last_dialog, "^Upload to Cloud on Creation.*Not Configured")
            assert.is_not_nil(cloud_btn)

            local action_btn = findButton(last_dialog, "Create Backup")
            assert.is_not_nil(action_btn)

            -- Tap cloud_btn when unconfigured
            cloud_btn.callback()

            -- A ConfirmBox should have been shown prompting to configure
            local confirm_widget = shown_widgets[#shown_widgets]
            assert.is_not_nil(confirm_widget)
            assert.equals("Configure", confirm_widget.ok_text)

            confirm_widget.ok_callback()
            assert.is_true(picker_called)

            Cloud.isConfigured = orig_isConfigured
            BackupUI.showCloudProviderPicker = orig_picker
        end)

        it("triggers showCloudUploadDialog upon successful backup creation if upload_to_cloud is true", function()
            local s = BackupUI.getPluginSettings()
            s.cloud_provider = Constants.CLOUD_PROVIDERS.GDRIVE
            s.upload_to_cloud = true

            local orig_isConfigured = Cloud.isConfigured
            Cloud.isConfigured = function() return true end

            local orig_createBackup = ArchiverMgr.createBackup
            ArchiverMgr.createBackup = function(opts)
                return true, { file_count = 10, size = 102400 }
            end

            local upload_called = false
            local uploaded_path = nil
            local orig_upload_dlg = BackupUI.showCloudUploadDialog
            BackupUI.showCloudUploadDialog = function(path)
                upload_called = true
                uploaded_path = path
            end

            BackupUI.showCreateDialog()
            local action_btn = findButton(last_dialog, "Create & Upload")
            assert.is_not_nil(action_btn)

            action_btn.callback()

            assert.is_true(upload_called)
            assert.is_not_nil(uploaded_path)
            assert.is_true(uploaded_path:find("%.zip$") ~= nil)

            Cloud.isConfigured = orig_isConfigured
            ArchiverMgr.createBackup = orig_createBackup
            BackupUI.showCloudUploadDialog = orig_upload_dlg
        end)

        it("does not trigger showCloudUploadDialog if upload_to_cloud is false", function()
            local s = BackupUI.getPluginSettings()
            s.cloud_provider = Constants.CLOUD_PROVIDERS.GDRIVE
            s.upload_to_cloud = false

            local orig_isConfigured = Cloud.isConfigured
            Cloud.isConfigured = function() return true end

            local orig_createBackup = ArchiverMgr.createBackup
            ArchiverMgr.createBackup = function(opts)
                return true, { file_count = 10, size = 102400 }
            end

            local upload_called = false
            local orig_upload_dlg = BackupUI.showCloudUploadDialog
            BackupUI.showCloudUploadDialog = function(path)
                upload_called = true
            end

            BackupUI.showCreateDialog()
            local action_btn = findButton(last_dialog, "Create Backup")
            assert.is_not_nil(action_btn)

            action_btn.callback()

            assert.is_false(upload_called)

            Cloud.isConfigured = orig_isConfigured
            ArchiverMgr.createBackup = orig_createBackup
            BackupUI.showCloudUploadDialog = orig_upload_dlg
        end)

        it("includes 'Upload to Cloud on Creation' toggle in Settings submenus", function()
            local s = BackupUI.getPluginSettings()
            s.cloud_provider = Constants.CLOUD_PROVIDERS.GDRIVE
            s.upload_to_cloud = true

            local orig_isConfigured = Cloud.isConfigured
            Cloud.isConfigured = function() return true end

            -- Verify in Cloud Settings submenu
            local cloud_items = BackupUI.getCloudSettingsSubmenu(function() end)
            local cloud_toggle = nil
            for _, item in ipairs(cloud_items) do
                if item.text == "Upload to Cloud on Creation" then
                    cloud_toggle = item
                    break
                end
            end
            assert.is_not_nil(cloud_toggle)
            assert.is_true(cloud_toggle.checked_func())

            -- Verify in Archive Settings submenu
            local archive_items = BackupUI.getArchiveSettingsSubmenu(function() end)
            local archive_toggle = nil
            for _, item in ipairs(archive_items) do
                if item.text == "Upload to Cloud on Creation" then
                    archive_toggle = item
                    break
                end
            end
            assert.is_not_nil(archive_toggle)
            assert.is_true(archive_toggle.checked_func())

            -- Toggle via menu callback
            cloud_toggle.callback()
            assert.is_false(s.upload_to_cloud)
            assert.is_false(cloud_toggle.checked_func())
            assert.is_false(archive_toggle.checked_func())

            Cloud.isConfigured = orig_isConfigured
        end)
    end)
end)
