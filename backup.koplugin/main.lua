--[[--
main.lua
Device Backup & Restore Plugin for KOReader.
Provides full disaster recovery, modular component backup,
and intelligent cross-device configuration cloning.
--]]

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Localization = require("localization_backup")
local _ = Localization:getHelper()

local BackupUI = require("backup_ui")
local RestoreEngine = require("backup_restore")

local function calculateOptimalPos(order_tools)
    local pos = 2
    for idx, id in ipairs(order_tools) do
        if id == "Storefront" or id == "xray" then
            if idx >= pos then
                pos = idx + 1
            end
        end
    end
    return pos
end

local function injectIntoToolsMenu()
    local menu_orders = {
        "ui/elements/reader_menu_order",
        "ui/elements/filemanager_menu_order",
        "apps/reader/modules/readermenuorder",
    }
    for _, order_path in ipairs(menu_orders) do
        local ok, order = pcall(require, order_path)
        if ok and type(order) == "table" and type(order.tools) == "table" then
            for i = #order.tools, 1, -1 do
                if order.tools[i] == "backup" or order.tools[i] == "Backup" then
                    table.remove(order.tools, i)
                end
            end
            local pos = calculateOptimalPos(order.tools)
            table.insert(order.tools, pos, "backup")
        end
    end

    -- Hook MenuSorter:sort to guarantee proper position even when user customized menu orders exist
    local ok_ms, MenuSorter = pcall(require, "ui/menusorter")
    if ok_ms and MenuSorter and not MenuSorter._backup_hooked then
        MenuSorter._backup_hooked = true
        local orig_sort = MenuSorter.sort
        MenuSorter.sort = function(this, item_table, order)
            if order and type(order.tools) == "table" and item_table and (item_table.backup or item_table.Backup) then
                for i = #order.tools, 1, -1 do
                    if order.tools[i] == "backup" or order.tools[i] == "Backup" then
                        table.remove(order.tools, i)
                    end
                end
                local pos = calculateOptimalPos(order.tools)
                table.insert(order.tools, pos, "backup")
            end
            return orig_sort(this, item_table, order)
        end
    end
end

local Backup = WidgetContainer:extend{
    name = "backup",
}

function Backup:init()
    injectIntoToolsMenu()
    self:onDispatcherRegisterActions()
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
end

function Backup:onDispatcherRegisterActions()
    local Dispatcher = require("dispatcher")
    Dispatcher:registerAction("backup_open", {
        category = "none",
        event = "BackupOpen",
        title = string.format("%s: %s", _("Device Backup & Restore"), _("Manage Backups")),
        general = true,
    })
    Dispatcher:registerAction("backup_create", {
        category = "none",
        event = "BackupCreate",
        title = string.format("%s: %s", _("Device Backup & Restore"), _("Create Backup")),
        general = true,
    })
    Dispatcher:registerAction("backup_restore", {
        category = "none",
        event = "BackupRestore",
        title = string.format("%s: %s", _("Device Backup & Restore"), _("Restore Backup")),
        general = true,
    })
    Dispatcher:registerAction("backup_beam_send", {
        category = "none",
        event = "BackupBeamSend",
        title = string.format("%s: %s", _("Device Backup & Restore"), _("Beam to Device")),
        general = true,
    })
    Dispatcher:registerAction("backup_beam_receive", {
        category = "none",
        event = "BackupBeamReceive",
        title = string.format("%s: %s", _("Device Backup & Restore"), _("Receive via Beam Code")),
        general = true,
    })
end

function Backup:onBackupOpen()
    BackupUI.showManageBackupsDialog()
    return true
end

function Backup:onBackupCreate()
    BackupUI.showCreateDialog()
    return true
end

function Backup:onBackupRestore()
    BackupUI.showRestoreDialog()
    return true
end

function Backup:onBackupBeamSend()
    BackupUI.showBeamSelectBackupDialog()
    return true
end

function Backup:onBackupBeamReceive()
    BackupUI.showBeamReceiveDialog()
    return true
end

function Backup:getSubMenuItems()
    return {
        {
            text = _("Create Backup"),
            keep_menu_open = true,
            callback = function()
                BackupUI.showCreateDialog()
            end,
        },
        {
            text = _("Restore Backup"),
            keep_menu_open = true,
            callback = function()
                BackupUI.showRestoreDialog()
            end,
        },
        {
            text = _("Beam to Device"),
            keep_menu_open = true,
            callback = function()
                BackupUI.showBeamSelectBackupDialog()
            end,
        },
        {
            text = _("Receive via Beam Code"),
            keep_menu_open = true,
            callback = function()
                BackupUI.showBeamReceiveDialog()
            end,
        },
        {
            text = _("Manage Backups"),
            keep_menu_open = true,
            callback = function()
                BackupUI.showManageBackupsDialog()
            end,
        },
        {
            text = _("Undo Last Restore"),
            keep_menu_open = true,
            enabled_func = function()
                return RestoreEngine.hasRollbackSnapshot()
            end,
            callback = function()
                BackupUI.showUndoRestoreConfirmation()
            end,
        },
        {
            text = _("Backup & Restore Settings"),
            keep_menu_open = true,
            callback = function()
                BackupUI.showSettingsDialog()
            end,
        },
    }
end

function Backup:addToMainMenu(menu_items)
    injectIntoToolsMenu()
    local items = self:getSubMenuItems()
    menu_items.backup = {
        sorting_hint = "tools",
        text = _("Device Backup & Restore"),
        sub_item_table = items,
        sub_item_table_func = function()
            return self:getSubMenuItems()
        end,
    }
end

-- Re-enforce ordering when reader opens a document
function Backup:onReaderReady()
    injectIntoToolsMenu()
end

return Backup
