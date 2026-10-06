--[[--
backup_progress.lua
Unified, cancelable progress dialog for KOReader Backup operations.

Features:
- Title, subtitle, and detail line (for current filename/phase).
- Progress bar (0 - 100%) using KOReader's ProgressWidget.
- Working "Cancel" button using KOReader's ButtonTable.
- Safe lifecycle management (close, setProgress, setSubtitle, setDetail, setCancelable).
- Back key / hardware key handling to cancel active operations.
- Throttled repainting to keep high-speed transfers smooth and responsive.
- Fallback gracefully when native widgets are unavailable in headless test environments.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local InputContainer = require("ui/widget/container/inputcontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")

local ok_bt, ButtonTable = pcall(require, "ui/widget/buttontable")
if not ok_bt or not ButtonTable then ButtonTable = nil end

local ok_btn, Button = pcall(require, "ui/widget/button")
if not ok_btn or not Button then Button = nil end

local ok_pw, ProgressWidget = pcall(require, "ui/widget/progresswidget")
if not ok_pw or not ProgressWidget then ProgressWidget = nil end

local ok_size, Size = pcall(require, "ui/size")
if not ok_size or not Size then
    Size = {
        line = { thin = 1, medium = 2 },
        padding = { default = 10, large = 15 },
        margin = { tiny = 2, default = 10 },
        radius = { window = 0 },
        border = { window = 2 },
    }
end

local ok_time, time = pcall(require, "ui/time")
if not ok_time or not time then time = nil end

local Localization = require("localization_backup")
local _ = Localization:getHelper()

local function sc(n)
    if Device and Device.screen and Device.screen.scaleBySize then
        return Device.screen:scaleBySize(n)
    end
    return n
end

local BackupProgress
if InputContainer and type(InputContainer.extend) == "function" then
    BackupProgress = InputContainer:extend{
        align = "center",
        vertical_align = "center",
        modal = true,
        title = nil,
        subtitle = nil,
        detail = nil,
        progress = 0,
        cancel_text = nil,
        on_cancel = nil,
        cancelable = true,
        is_closed = false,
        is_canceled = false,
    }
else
    BackupProgress = {
        align = "center",
        vertical_align = "center",
        modal = true,
        title = nil,
        subtitle = nil,
        detail = nil,
        progress = 0,
        cancel_text = nil,
        on_cancel = nil,
        cancelable = true,
        is_closed = false,
        is_canceled = false,
    }
    BackupProgress.__index = BackupProgress
    function BackupProgress:new(opts)
        opts = opts or {}
        local o = setmetatable(opts, BackupProgress)
        o:init()
        return o
    end
end

function BackupProgress:init()
    local Screen = Device and Device.screen
    local screen_w = (Screen and Screen.getWidth and Screen:getWidth()) or 600
    local screen_h = (Screen and Screen.getHeight and Screen:getHeight()) or 800
    self.dimen = (Screen and Screen.getSize and Screen:getSize()) or { w = screen_w, h = screen_h }

    self.dialog_width = self.width or math.min(screen_w - sc(40), sc(420))
    local inner_width = self.dialog_width - sc(32)

    self.title = self.title or _("Operation in Progress")
    self.subtitle = self.subtitle or _("Please wait...")
    self.detail = self.detail or ""
    self.cancel_text = self.cancel_text or _("Cancel")
    self.cancelable = (self.cancelable ~= false)
    self.progress = self.progress or 0
    self.is_closed = false
    self.is_canceled = false
    self.last_redraw_time_ms = 0

    if TextWidget then
        self.title_widget = TextWidget:new{
            text = self.title,
            face = (Font and Font.getFace and Font:getFace("cfont", 16)),
            bold = true,
            max_width = inner_width,
        }

        self.subtitle_widget = TextWidget:new{
            text = self.subtitle,
            face = (Font and Font.getFace and Font:getFace("cfont", 14)),
            max_width = inner_width,
            fgcolor = (Blitbuffer and Blitbuffer.COLOR_BLACK),
        }

        self.detail_widget = TextWidget:new{
            text = self.detail,
            face = (Font and Font.getFace and Font:getFace("smallffont")),
            max_width = inner_width,
            fgcolor = (Blitbuffer and Blitbuffer.COLOR_BLACK),
            truncate_with_ellipsis = true,
            truncate_left = true,
        }
    end

    if ProgressWidget then
        local p_val = math.max(0, math.min(1, (self.progress or 0) / 100))
        self.pbar_widget = ProgressWidget:new{
            fillcolor = (Blitbuffer and Blitbuffer.COLOR_BLACK),
            width = inner_width,
            height = sc(14),
            padding = (Size and Size.padding and Size.padding.large) or sc(4),
            margin = (Size and Size.margin and Size.margin.tiny) or 0,
            percentage = p_val,
        }
    end

    if ButtonTable then
        self.button_table = ButtonTable:new{
            width = inner_width,
            buttons = {{
                {
                    text = self.cancel_text,
                    id = "cancel",
                    enabled = self.cancelable,
                    callback = function()
                        self:triggerCancel()
                    end,
                }
            }},
            zero_sep = true,
            show_parent = self,
        }
    elseif Button then
        self.cancel_button = Button:new{
            text = self.cancel_text,
            bordersize = (Size and Size.line and Size.line.thin) or 1,
            show_parent = self,
            callback = function()
                self:triggerCancel()
            end,
        }
    end

    local group_items = {}
    if self.title_widget then
        local title_item = self.title_widget
        if CenterContainer and self.title_widget.getSize then
            local t_size = self.title_widget:getSize()
            title_item = CenterContainer:new{
                dimen = { w = inner_width, h = (t_size and t_size.h) or sc(20) },
                self.title_widget,
            }
        end
        table.insert(group_items, title_item)
        if VerticalSpan then table.insert(group_items, VerticalSpan:new{ width = sc(8) }) end
    end
    if self.subtitle_widget then
        local sub_item = self.subtitle_widget
        if CenterContainer and self.subtitle_widget.getSize then
            local s_size = self.subtitle_widget:getSize()
            self.subtitle_container = CenterContainer:new{
                dimen = { w = inner_width, h = (s_size and s_size.h) or sc(16) },
                self.subtitle_widget,
            }
            sub_item = self.subtitle_container
        end
        table.insert(group_items, sub_item)
        if VerticalSpan then table.insert(group_items, VerticalSpan:new{ width = sc(4) }) end
    end
    if self.detail_widget then
        local det_item = self.detail_widget
        if CenterContainer and self.detail_widget.getSize then
            local d_size = self.detail_widget:getSize()
            self.detail_container = CenterContainer:new{
                dimen = { w = inner_width, h = (d_size and d_size.h) or sc(14) },
                self.detail_widget,
            }
            det_item = self.detail_container
        end
        table.insert(group_items, det_item)
        if VerticalSpan then table.insert(group_items, VerticalSpan:new{ width = sc(12) }) end
    end
    if self.pbar_widget then
        table.insert(group_items, self.pbar_widget)
        if VerticalSpan then table.insert(group_items, VerticalSpan:new{ width = sc(14) }) end
    end
    if self.button_table then
        table.insert(group_items, self.button_table)
    elseif self.cancel_button then
        table.insert(group_items, self.cancel_button)
    end

    if VerticalGroup then
        group_items.align = "center"
        self.content_group = VerticalGroup:new(group_items)
    else
        self.content_group = group_items
    end

    if FrameContainer then
        self.frame = FrameContainer:new{
            width = self.dialog_width,
            padding = sc(16),
            padding_bottom = self.button_table and 0 or sc(16),
            bordersize = (Size and Size.line and Size.line.medium) or 2,
            background = (Blitbuffer and Blitbuffer.COLOR_WHITE),
            self.content_group,
        }
    else
        self.frame = self.content_group
    end

    if CenterContainer then
        self[1] = CenterContainer:new{
            dimen = self.dimen,
            self.frame,
        }
    else
        self[1] = self.frame
    end

    if Device and Device.hasKeys and Device:hasKeys() and self.key_events then
        self.key_events.Close = { { Device.input.group.Back } }
    end
end

--- Dispatches pending input events (e.g. Cancel button tap) during long-running operations.
function BackupProgress:pumpEvents()
    if self.is_closed or self._pumping then return end
    self._pumping = true
    if UIManager and Device and Device.input and type(Device.input.waitEvent) == "function" and type(UIManager.getTime) == "function" and type(UIManager.handleInputEvent) == "function" then
        local now = UIManager:getTime()
        local input_events = Device.input:waitEvent(now, now)
        if input_events then
            for __, ev in ipairs(input_events) do
                UIManager:handleInputEvent(ev)
            end
        end
    end
    self._pumping = false
end

--- Shows the dialog on screen.
function BackupProgress:show()
    if self.is_closed then return end
    if UIManager and UIManager.show then
        UIManager:show(self)
    end
    self:redraw()
end

--- Updates the progress bar percentage (0 - 100).
function BackupProgress:setProgress(val, force_redraw)
    if self.is_closed then return end
    self:pumpEvents()
    val = math.min(100, math.max(0, math.floor(val or 0)))
    self.progress = val
    if self.pbar_widget and self.pbar_widget.setPercentage then
        self.pbar_widget:setPercentage(val / 100)
    end
    if force_redraw or val >= 100 then
        self:redraw()
    else
        self:redrawIfNeeded()
    end
end

--- Updates the subtitle text.
function BackupProgress:setSubtitle(text)
    if self.is_closed or not text then return end
    self:pumpEvents()
    self.subtitle = text
    if self.subtitle_widget and type(self.subtitle_widget.setText) == "function" then
        self.subtitle_widget:setText(text)
        if self.subtitle_container and self.subtitle_widget.getSize then
            local s_size = self.subtitle_widget:getSize()
            if self.subtitle_container.dimen and s_size and s_size.h and s_size.h > 0 then
                self.subtitle_container.dimen.h = s_size.h
            end
        end
        if self.content_group and self.content_group.resetLayout then
            self.content_group:resetLayout()
        end
        self:redrawIfNeeded()
    end
end

--- Updates the detail line (e.g. current filename or phase).
function BackupProgress:setDetail(text)
    if self.is_closed then return end
    self:pumpEvents()
    self.detail = text or ""
    if self.detail_widget and type(self.detail_widget.setText) == "function" then
        self.detail_widget:setText(self.detail)
        if self.detail_container and self.detail_widget.getSize then
            local d_size = self.detail_widget:getSize()
            if self.detail_container.dimen and d_size and d_size.h and d_size.h > 0 then
                self.detail_container.dimen.h = d_size.h
            end
        end
        if self.content_group and self.content_group.resetLayout then
            self.content_group:resetLayout()
        end
        self:redrawIfNeeded()
    end
end

--- Enables or disables the Cancel button (e.g. during non-cancelable critical stages).
function BackupProgress:setCancelable(enabled, disabled_text)
    if self.is_closed then return end
    self.cancelable = (enabled == true)
    if self.button_table and type(self.button_table.getButtonById) == "function" then
        local btn = self.button_table:getButtonById("cancel")
        if btn then
            if self.cancelable then
                if btn.setText then btn:setText(self.cancel_text) end
                if btn.enable then btn:enable() end
            else
                if btn.setText then btn:setText(disabled_text or _("Finalizing...")) end
                if btn.disable then btn:disable() end
            end
            self:redraw()
        end
    elseif self.cancel_button then
        if self.cancelable then
            if self.cancel_button.setText then self.cancel_button:setText(self.cancel_text) end
            if self.cancel_button.enable then self.cancel_button:enable() end
        else
            if self.cancel_button.setText then self.cancel_button:setText(disabled_text or _("Finalizing...")) end
            if self.cancel_button.disable then self.cancel_button:disable() end
        end
        self:redraw()
    end
end

--- Triggers user cancellation.
function BackupProgress:triggerCancel()
    if not self.cancelable or self.is_canceled or self.is_closed then return end
    self.is_canceled = true
    self:setSubtitle(_("Canceling..."))
    self:setDetail("")
    self:setCancelable(false, _("Canceling..."))
    if type(self.on_cancel) == "function" then
        pcall(self.on_cancel)
    end
    if UIManager and UIManager.setDirty then
        UIManager:setDirty(self, function() return "fast", self.dimen end)
        if UIManager.forceRePaint then
            UIManager:forceRePaint()
        end
    end
end

--- Returns true if the operation was canceled by the user.
function BackupProgress:isCanceled()
    if not self.is_canceled and not self.is_closed then
        self:pumpEvents()
    end
    return self.is_canceled == true
end

--- Handles hardware/Back key event.
function BackupProgress:onClose()
    if self.cancelable and not self.is_canceled and not self.is_closed then
        self:triggerCancel()
        return true
    end
    return true
end

--- Closes and dismisses the dialog.
function BackupProgress:close()
    if self.is_closed then return end
    self.is_closed = true
    if UIManager and UIManager.close then
        UIManager:close(self)
    end
end

--- Internal throttled redraw (at most once every 100ms) to ensure smooth transfer performance.
function BackupProgress:redrawIfNeeded()
    if self.is_closed then return end
    local now_us
    if time and time.now then
        now_us = time.now()
    else
        now_us = os.clock() * 1000000
    end
    if (now_us - self.last_redraw_time_ms) >= 100000 then
        self.last_redraw_time_ms = now_us
        self:redraw()
    end
end

--- Forces a redraw of the progress dialog.
function BackupProgress:redraw()
    if self.is_closed then return end
    if self.content_group and self.content_group.resetLayout then
        self.content_group:resetLayout()
    end
    if UIManager and UIManager.setDirty then
        UIManager:setDirty(self, function() return "fast", self.dimen end)
        if UIManager.forceRePaint then
            UIManager:forceRePaint()
        end
    end
end

return BackupProgress
