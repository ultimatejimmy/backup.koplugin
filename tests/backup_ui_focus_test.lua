require("tests/spec_helper")

local Device = require("device")
local FocusManager = require("ui/widget/focusmanager")
local ButtonDialog = require("ui/widget/buttondialog")
local UIManager = require("ui/uimanager")
local BackupUI = require("backup_ui")

describe("backup_ui non-touch selector / focus management", function()
    local last_dialog
    local shown_dialogs = {}
    local move_focus_calls = {}

    before_each(function()
        shown_dialogs = {}
        move_focus_calls = {}
        last_dialog = nil

        ButtonDialog.new = function(self, args)
            local o = args or {}
            o.selected = { x = 1, y = 1 }
            o.moveFocusTo = function(d, x, y, flags)
                table.insert(move_focus_calls, { x = x, y = y, flags = flags })
                d.selected.x = x
                d.selected.y = y
            end
            o.onFocusMove = function(d, args_move)
                return true
            end
            o.onPress = function(d)
                if d.action_callback then
                    d.action_callback()
                end
                return true
            end
            last_dialog = o
            return o
        end

        UIManager.show = function(self, d)
            table.insert(shown_dialogs, d)
        end
        UIManager.close = function(self, d) end
    end)

    it("does not show the non-touch selector when changing options on touch devices", function()
        Device.isTouchDevice = function() return true end

        BackupUI.showCreateDialog()
        assert.is_not_nil(last_dialog)
        assert.are.equal(0, #move_focus_calls) -- Initial show does not force focus

        -- Find the Format button
        local format_btn = nil
        for _, row in ipairs(last_dialog.buttons) do
            for _, btn in ipairs(row) do
                if btn.text and btn.text:match("^Format:") then
                    format_btn = btn
                    break
                end
            end
        end
        assert.is_not_nil(format_btn)

        -- Simulate tapping the format button via touch
        format_btn.callback()

        -- Verify a new dialog was created and moveFocusTo was called with NOT_FOCUS, NOT FORCED_FOCUS
        assert.is_true(#move_focus_calls >= 1)
        local last_call = move_focus_calls[#move_focus_calls]
        assert.are.equal(FocusManager.NOT_FOCUS, last_call.flags)
        assert.is_not_equal(FocusManager.FORCED_FOCUS, last_call.flags)
    end)

    it("shows the non-touch selector when arrow keys are used on touch devices", function()
        Device.isTouchDevice = function() return true end

        BackupUI.showCreateDialog()
        assert.is_not_nil(last_dialog)

        -- Simulate user pressing an arrow key (triggers onFocusMove)
        last_dialog:onFocusMove({0, 1})

        -- Find the Format button
        local format_btn = nil
        for _, row in ipairs(last_dialog.buttons) do
            for _, btn in ipairs(row) do
                if btn.text and btn.text:match("^Format:") then
                    format_btn = btn
                    break
                end
            end
        end
        assert.is_not_nil(format_btn)

        -- Simulate pressing Enter key (which triggers wrapped onPress)
        last_dialog.action_callback = function()
            format_btn.callback()
        end
        last_dialog:onPress()

        -- Because it was activated via key press, FORCED_FOCUS is applied
        local last_call = move_focus_calls[#move_focus_calls]
        assert.are.equal(FocusManager.FORCED_FOCUS, last_call.flags)
    end)

    it("dismisses the non-touch selector if touch is used after arrow keys", function()
        Device.isTouchDevice = function() return true end

        BackupUI.showCreateDialog()
        -- User navigated with arrow keys
        last_dialog:onFocusMove({0, 1})

        -- User then touches a button with their finger (not through onPress)
        local clear_all_btn = nil
        for _, row in ipairs(last_dialog.buttons) do
            for _, btn in ipairs(row) do
                if btn.text and btn.text == "Clear All" then
                    clear_all_btn = btn
                    break
                end
            end
        end
        assert.is_not_nil(clear_all_btn)

        -- Touch tap
        clear_all_btn.callback()

        local last_call = move_focus_calls[#move_focus_calls]
        assert.are.equal(FocusManager.NOT_FOCUS, last_call.flags)
        assert.is_not_equal(FocusManager.FORCED_FOCUS, last_call.flags)
    end)

    it("always preserves focus on non-touch devices", function()
        Device.isTouchDevice = function() return false end

        BackupUI.showCreateDialog()
        assert.is_not_nil(last_dialog)

        local format_btn = nil
        for _, row in ipairs(last_dialog.buttons) do
            for _, btn in ipairs(row) do
                if btn.text and btn.text:match("^Format:") then
                    format_btn = btn
                    break
                end
            end
        end
        assert.is_not_nil(format_btn)

        format_btn.callback()

        local last_call = move_focus_calls[#move_focus_calls]
        assert.are.equal(FocusManager.FORCED_FOCUS, last_call.flags)
    end)
end)
