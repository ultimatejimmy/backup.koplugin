--[[--
backup_ui_settings_menu_test.lua
Unit tests for the KOReader native hierarchical settings submenus.
--]]

require("tests/spec_helper")

local UIManager = require("ui/uimanager")
local Constants = require("backup_constants")
local Cloud = require("backup_cloud")
local BackupUI = require("backup_ui")

describe("backup_ui native settings submenus", function()
    local refreshed = false
    local refresh_cb = function() refreshed = true end

    before_each(function()
        refreshed = false
        -- Reset plugin settings
        local s = BackupUI.getPluginSettings()
        s.default_format = "zip"
        s.custom_backup_dir = nil
        s.custom_books_dir = nil
        s.retention_limit = 5
        s.clean_slate_restore = false
        s.beam_relay_url = Constants.BEAM_DEFAULT_RELAY_URL
        s.cloud_provider = "none"
        s.cloud_remote_dir = "koreader_backups"
    end)

    describe("getSettingsMenuTable", function()
        it("returns the 4 top-level settings categories with sub_item_table_func", function()
            local menu_table = BackupUI.getSettingsMenuTable(refresh_cb)
            assert.is_table(menu_table)
            assert.are.equal(4, #menu_table)

            for _, cat in ipairs(menu_table) do
                assert.is_true(cat.keep_menu_open)
                assert.is_function(cat.sub_item_table_func)
                local sub = cat.sub_item_table_func()
                assert.is_table(sub)
                assert.is_true(#sub > 0)
            end
        end)
    end)

    describe("Storage Settings Submenu", function()
        it("provides Backup and Books folder items with dynamic text_func", function()
            local items = BackupUI.getStorageSettingsSubmenu(refresh_cb)
            assert.is_table(items)
            assert.are.equal(2, #items)

            local backup_item = items[1]
            local books_item = items[2]

            assert.is_function(backup_item.text_func)
            assert.is_function(backup_item.callback)
            assert.is_true(backup_item.keep_menu_open)
            assert.is_not_nil(backup_item.text_func():match("Backup Folder:"))

            assert.is_function(books_item.text_func)
            assert.is_function(books_item.callback)
            assert.is_true(books_item.keep_menu_open)
            assert.is_not_nil(books_item.text_func():match("Books Folder:"))
        end)
    end)

    describe("Archive Format & Retention Submenu", function()
        it("provides format radios and allows switching between zip and tar.gz", function()
            local items = BackupUI.getArchiveSettingsSubmenu(refresh_cb)
            assert.is_table(items)
            assert.are.equal(3, #items)

            local format_item = items[1]
            assert.is_function(format_item.text_func)
            assert.is_table(format_item.sub_item_table)
            assert.are.equal(2, #format_item.sub_item_table)

            local zip_opt = format_item.sub_item_table[1]
            local targz_opt = format_item.sub_item_table[2]

            assert.is_true(zip_opt.radio)
            assert.is_true(targz_opt.radio)
            assert.is_true(zip_opt.checked_func())
            assert.is_false(targz_opt.checked_func())

            -- Select TAR.GZ
            targz_opt.callback()
            assert.is_true(refreshed)
            assert.is_true(targz_opt.checked_func())
            assert.is_false(zip_opt.checked_func())

            -- Switch back to ZIP
            refreshed = false
            zip_opt.callback()
            assert.is_true(refreshed)
            assert.is_true(zip_opt.checked_func())
        end)

        it("provides retention presets and toggles clean slate restore", function()
            local items = BackupUI.getArchiveSettingsSubmenu(refresh_cb)
            local retention_item = items[2]
            local clean_slate_item = items[3]

            assert.is_function(retention_item.text_func)
            assert.is_function(retention_item.sub_item_table_func)

            local presets = retention_item.sub_item_table_func()
            assert.are.equal(5, #presets)

            -- Select preset: 10 backups
            refreshed = false
            local preset_10 = presets[3]
            preset_10.callback()
            assert.is_true(refreshed)
            assert.is_true(preset_10.checked_func())

            -- Select preset: Unlimited (0)
            refreshed = false
            local preset_unlimited = presets[4]
            preset_unlimited.callback()
            assert.is_true(refreshed)
            assert.is_true(preset_unlimited.checked_func())

            -- Clean slate restore toggle
            refreshed = false
            assert.is_false(clean_slate_item.checked_func())
            clean_slate_item.callback()
            assert.is_true(refreshed)
            assert.is_true(clean_slate_item.checked_func())
        end)
    end)

    describe("Cloud Storage Submenu", function()
        it("lists all supported cloud providers with radio choices", function()
            local items = BackupUI.getCloudSettingsSubmenu(refresh_cb)
            assert.is_table(items)
            local provider_item = items[1]

            assert.is_table(provider_item.sub_item_table)
            assert.are.equal(7, #provider_item.sub_item_table)

            -- Initially "none"
            local none_opt = provider_item.sub_item_table[1]
            assert.is_true(none_opt.checked_func())

            -- Select WebDAV
            refreshed = false
            local webdav_opt = nil
            for _, opt in ipairs(provider_item.sub_item_table) do
                if opt.text == Cloud.getProviderLabel(Constants.CLOUD_PROVIDERS.WEBDAV) then
                    webdav_opt = opt
                    break
                end
            end
            assert.is_not_nil(webdav_opt)
            webdav_opt.callback()
            assert.is_true(refreshed)
            assert.is_true(webdav_opt.checked_func())
            assert.is_false(none_opt.checked_func())

            -- Re-query cloud submenu when WebDAV is active
            local webdav_items = BackupUI.getCloudSettingsSubmenu(refresh_cb)
            assert.is_true(#webdav_items >= 4) -- Provider, Connect/Configure, Test, Remote Folder
        end)
    end)

    describe("Beam Wireless Relay Submenu", function()
        it("provides relay URL editing and reset default action", function()
            local items = BackupUI.getBeamSettingsSubmenu(refresh_cb)
            assert.is_table(items)
            assert.are.equal(2, #items)

            local relay_item = items[1]
            local reset_item = items[2]

            assert.is_function(relay_item.text_func)
            assert.is_function(relay_item.callback)
            assert.is_function(reset_item.enabled_func)

            assert.is_true(reset_item.keep_menu_open)
            assert.is_true(relay_item.keep_menu_open)

            -- By default relay is default, so reset is disabled
            assert.is_false(reset_item.enabled_func())

            -- Change relay url
            local s = BackupUI.getPluginSettings()
            s.beam_relay_url = "https://custom.relay.workers.dev"
            assert.is_true(reset_item.enabled_func())

            -- Reset relay
            local mock_menu = { updated = false, updateItems = function(m) m.updated = true end }
            refreshed = false
            reset_item.callback(mock_menu)
            assert.is_true(refreshed)
            assert.is_true(mock_menu.updated)
            assert.are.equal(Constants.BEAM_DEFAULT_RELAY_URL, s.beam_relay_url)
            assert.is_false(reset_item.enabled_func())
        end)
    end)

    describe("showSettingsDialog", function()
        it("instantiates a fullscreen Menu without errors", function()
            local shown_menu = nil
            local orig_show = UIManager.show
            UIManager.show = function(self, widget)
                shown_menu = widget
            end

            BackupUI.showSettingsDialog()
            assert.is_not_nil(shown_menu)
            assert.are.equal("Backup & Restore Settings", shown_menu.title)
            assert.is_true(shown_menu.covers_fullscreen)
            assert.is_table(shown_menu.item_table)
            assert.are.equal(4, #shown_menu.item_table)

            UIManager.show = orig_show
        end)
    end)
end)
