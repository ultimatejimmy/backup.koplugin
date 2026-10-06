require("tests/spec_helper")

local UIManager = require("ui/uimanager")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local InfoMessage = require("ui/widget/infomessage")
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
end)
