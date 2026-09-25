--[[--
backup_main_menu_test.lua
Unit tests for Backup plugin main menu registration and Tools menu ordering.
--]]

require("tests/spec_helper")

describe("backup_main_menu", function()
    local Backup
    local reader_order
    local filemanager_order
    local MenuSorter

    before_each(function()
        reader_order = {
            tools = { "read_timer", "calibre", "exporter" },
        }
        filemanager_order = {
            tools = { "read_timer", "calibre", "exporter" },
        }
        package.loaded["ui/elements/reader_menu_order"] = reader_order
        package.loaded["ui/elements/filemanager_menu_order"] = filemanager_order

        MenuSorter = {
            sort = function(self, item_table, order)
                return order
            end,
            mergeAndSort = function(self, prefix, item_table, order)
                return self:sort(item_table, order)
            end,
        }
        package.loaded["ui/menusorter"] = MenuSorter

        -- Clear Backup from package cache to force re-require
        package.loaded["main"] = nil
        Backup = require("main")
    end)

    it("injects 'backup' into reader and filemanager tools menu at index 2 by default", function()
        local mock_menu = {
            registered = {},
            registerToMainMenu = function(self, w)
                table.insert(self.registered, w)
            end,
        }
        local instance = Backup:new{
            ui = { menu = mock_menu },
        }

        assert.are.equal("backup", reader_order.tools[2])
        assert.are.equal("backup", filemanager_order.tools[2])
        assert.are.equal(1, #mock_menu.registered)
    end)

    it("places 'backup' after 'Storefront' and 'xray' when they are present", function()
        reader_order.tools = { "xray", "Storefront", "read_timer", "calibre" }
        filemanager_order.tools = { "Storefront", "read_timer", "calibre" }

        local instance = Backup:new{
            ui = { menu = { registerToMainMenu = function() end } },
        }

        -- In reader_order: xray (1), Storefront (2) -> backup should be at index 3
        assert.are.equal("xray", reader_order.tools[1])
        assert.are.equal("Storefront", reader_order.tools[2])
        assert.are.equal("backup", reader_order.tools[3])

        -- In filemanager_order: Storefront (1) -> backup should be at index 2
        assert.are.equal("Storefront", filemanager_order.tools[1])
        assert.are.equal("backup", filemanager_order.tools[2])
    end)

    it("does not duplicate 'backup' on multiple addToMainMenu or onReaderReady calls", function()
        local mock_menu = {
            registered = {},
            registerToMainMenu = function(self, w)
                table.insert(self.registered, w)
            end,
        }
        local instance = Backup:new{
            ui = { menu = mock_menu },
        }

        local menu_items = {}
        instance:addToMainMenu(menu_items)
        instance:addToMainMenu(menu_items)
        instance:onReaderReady()

        local count = 0
        for _, id in ipairs(reader_order.tools) do
            if id == "backup" then count = count + 1 end
        end
        assert.are.equal(1, count)

        -- onReaderReady must NOT double-register to menu
        assert.are.equal(1, #mock_menu.registered)
    end)

    it("ensures MenuSorter:sort places 'backup' even when user custom order overwrote order.tools", function()
        local instance = Backup:new{
            ui = { menu = { registerToMainMenu = function() end } },
        }

        -- Simulate a user order that lacked 'backup'
        local custom_order = {
            tools = { "read_timer", "calibre", "profiles" },
        }
        local menu_items = {
            backup = { text = "Device Backup & Restore" },
        }

        MenuSorter:sort(menu_items, custom_order)

        assert.are.equal("backup", custom_order.tools[2])
    end)

    it("constructs valid menu_items.backup with sub_item_table and sub_item_table_func", function()
        local instance = Backup:new{
            ui = { menu = { registerToMainMenu = function() end } },
        }

        local menu_items = {}
        instance:addToMainMenu(menu_items)

        assert.is_table(menu_items.backup)
        assert.are.equal("tools", menu_items.backup.sorting_hint)
        assert.is_string(menu_items.backup.text)
        assert.is_table(menu_items.backup.sub_item_table)
        assert.is_function(menu_items.backup.sub_item_table_func)

        local dynamic_sub = menu_items.backup.sub_item_table_func()
        assert.is_table(dynamic_sub)
        assert.is_true(#dynamic_sub >= 5)
    end)
end)
