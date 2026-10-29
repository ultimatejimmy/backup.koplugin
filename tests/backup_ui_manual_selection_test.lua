--[[--
backup_ui_manual_selection_test.lua
Unit tests verifying component selection persistence for manual backups.
--]]

require("tests/spec_helper")

local UIManager = require("ui/uimanager")
local ButtonDialog = require("ui/widget/buttondialog")
local ArchiverMgr = require("backup_archiver")
local Constants = require("backup_constants")
local BackupUI = require("backup_ui")

describe("backup_ui manual backup component selection persistence", function()
    local last_dialog
    local shown_dialogs = {}

    before_each(function()
        last_dialog = nil
        shown_dialogs = {}

        local orig_button_new = ButtonDialog.new
        ButtonDialog.new = function(self, args)
            local dlg = orig_button_new(self, args)
            last_dialog = dlg
            return dlg
        end

        UIManager.show = function(self, widget)
            table.insert(shown_dialogs, widget)
        end
        UIManager.close = function(self, widget) end
        UIManager.nextTick = function(self, fn, ...) if fn then return fn(...) end end

        -- Clear settings
        local s = BackupUI.getPluginSettings()
        s.manual_backup_components = nil
        s.manual_backup_selected_plugins = nil
        s.manual_backup_selected_patches = nil
        s.manual_backup_selected_fonts = nil
        s.manual_backup_selected_dicts = nil
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

    it("defaults to Constants.DEFAULT_COMPONENT_SELECTION and selects all sub-items when no preset is saved", function()
        BackupUI.showCreateDialog()
        assert.is_not_nil(last_dialog)

        -- Check the summary button text matches 8 default active out of 10 total
        local comp_btn = findButtonMatching(last_dialog, "Components:")
        assert.is_not_nil(comp_btn)
        assert.is_truthy(comp_btn.text:match("%(8/10%)"))
    end)

    it("loads saved manual_backup_components when present", function()
        local s = BackupUI.getPluginSettings()
        s.manual_backup_components = {
            [Constants.COMPONENTS.SETTINGS] = true,
            [Constants.COMPONENTS.PLUGINS] = false,
            [Constants.COMPONENTS.PATCHES] = false,
            [Constants.COMPONENTS.FONTS] = false,
            [Constants.COMPONENTS.ICONS] = false,
            [Constants.COMPONENTS.SCREENSAVERS] = false,
            [Constants.COMPONENTS.STYLETWEAKS] = false,
            [Constants.COMPONENTS.DOCSETTINGS] = false,
            [Constants.COMPONENTS.HISTORY] = false,
            [Constants.COMPONENTS.DICTIONARIES] = false,
        }

        BackupUI.showCreateDialog()
        local comp_btn = findButtonMatching(last_dialog, "Components:")
        assert.is_not_nil(comp_btn)
        assert.is_truthy(comp_btn.text:match("%(1/10%)"))
    end)

    it("respects saved sub-selections and does NOT select newly found sub-items unless explicitly saved", function()
        -- Mock available plugins
        local orig_getPlugins = ArchiverMgr.getAvailablePlugins
        ArchiverMgr.getAvailablePlugins = function()
            return { "old_plugin", "new_plugin" }
        end

        local s = BackupUI.getPluginSettings()
        s.manual_backup_components = {
            [Constants.COMPONENTS.PLUGINS] = true,
        }
        -- User only previously selected old_plugin; new_plugin was installed later
        s.manual_backup_selected_plugins = {
            ["old_plugin"] = true,
        }

        BackupUI.showCreateDialog()

        -- Open components selection dialog
        local comp_btn = findButtonMatching(last_dialog, "Components:")
        assert.is_not_nil(comp_btn)
        comp_btn.callback()

        -- In components dialog, User Plugins row has a drill-down button showing (1/2) ▸
        local drill_btn = findButtonMatching(last_dialog, "%(%d+/%d+%)")
        assert.is_not_nil(drill_btn)
        assert.is_truthy(drill_btn.text:match("%(1/2%)"))

        ArchiverMgr.getAvailablePlugins = orig_getPlugins
    end)

    it("persists manual_backup_components and sub-selections when backup creation starts", function()
        local orig_createBackup = ArchiverMgr.createBackup
        local captured_opts = nil
        ArchiverMgr.createBackup = function(opts)
            captured_opts = opts
            return true, { size = 100, file_count = 5 }
        end

        local s = BackupUI.getPluginSettings()
        assert.is_nil(s.manual_backup_components)

        -- Launch wizard
        BackupUI.showCreateDialog()

        -- Open components dialog
        local comp_btn = findButtonMatching(last_dialog, "Components:")
        comp_btn.callback()

        -- Tap "Clear All"
        local clear_all = findButton(last_dialog, "Clear All")
        assert.is_not_nil(clear_all)
        clear_all.callback()

        -- Done with selection
        local done_btn = findButton(last_dialog, "Done")
        assert.is_not_nil(done_btn)
        done_btn.callback()

        -- Back in Create Backup dialog, trigger "Create Backup"
        local create_btn = findButton(last_dialog, "Create Backup")
        assert.is_not_nil(create_btn)
        create_btn.callback()

        -- Settings should now be persisted
        assert.is_not_nil(s.manual_backup_components)
        assert.are.equal(false, s.manual_backup_components[Constants.COMPONENTS.SETTINGS])
        assert.are.equal(false, s.manual_backup_components[Constants.COMPONENTS.PLUGINS])
        assert.is_not_nil(s.manual_backup_selected_plugins)

        ArchiverMgr.createBackup = orig_createBackup
    end)
end)
