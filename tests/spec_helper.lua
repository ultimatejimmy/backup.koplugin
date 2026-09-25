--[[--
spec_helper.lua
Test harness and environment mocks for backup.koplugin Busted test suite.
--]]

package.path = package.path .. ";./?.lua"
package.path = package.path .. ";../?.lua"
package.path = package.path .. ";/mnt/c/Users/jpautz/squashfs-root/usr/lib/koreader/?.lua"
package.path = package.path .. ";c:/Users/jpautz/squashfs-root/usr/lib/koreader/?.lua"

-- Mock gettext
package.loaded["gettext"] = function(str) return str end

-- Mock logger
package.loaded["logger"] = {
    info = function(...) end,
    warn = function(...) end,
    dbg = function(...) end,
    error = function(...) end,
}

-- Mock JSON using dkjson if available
local ok_dk, dkjson = pcall(require, "dkjson")
if ok_dk and dkjson then
    package.loaded["json"] = dkjson
else
    package.loaded["json"] = {
        encode = function(tbl)
            return "{}"
        end,
        decode = function(str)
            return {}
        end,
    }
end

-- Mock dump
package.loaded["dump"] = function(val, _, _)
    local function serialize(o, indent)
        indent = indent or ""
        local next_indent = indent .. "    "
        local t = type(o)
        if t == "number" or t == "boolean" then
            return tostring(o)
        elseif t == "string" then
            return string.format("%q", o)
        elseif t == "table" then
            local lines = {}
            table.insert(lines, "{\n")
            for k, v in pairs(o) do
                local key_str = (type(k) == "string" and k:match("^[%a_][%a%d_]*$")) and k or ("[" .. serialize(k) .. "]")
                table.insert(lines, string.format("%s%s = %s,\n", next_indent, key_str, serialize(v, next_indent)))
            end
            table.insert(lines, indent .. "}")
            return table.concat(lines)
        else
            return "nil"
        end
    end
    return serialize(val)
end

-- Mock device
package.loaded["device"] = {
    model = "Kobo Clara 2E",
    getModel = function(self) return self.model end,
    isKobo = function() return true end,
    isKindle = function() return false end,
    isAndroid = function() return false end,
    isTouchDevice = function() return true end,
    hasDPad = function() return false end,
    canRestart = function() return true end,
    screen = {
        getWidth = function() return 1072 end,
        getHeight = function() return 1448 end,
        dpi = 300,
        scaleBySize = function(_, val) return val end,
    },
}

-- Mock version
package.loaded["version"] = {
    version = "v2026.07",
    getVersion = function() return "v2026.07" end,
}

-- Mock datastorage
local _test_data_dir = "/tmp/koreader_test_backup"
package.loaded["datastorage"] = {
    getDataDir = function() return _test_data_dir end,
}

-- Mock util
package.loaded["util"] = {
    makePath = function(path)
        os.execute("mkdir -p \"" .. path .. "\" 2>/dev/null")
        return true
    end,
    removeFile = function(path)
        return os.remove(path)
    end,
}

-- Mock global G_reader_settings
_G.G_reader_settings = {
    data = {},
    readSetting = function(self, key) return self.data[key] end,
    saveSetting = function(self, key, val) self.data[key] = val end,
    flush = function(self) return true end,
}

-- Mock lfs
local ok_real_lfs, real_lfs = pcall(require, "lfs")
if ok_real_lfs and real_lfs then
    package.loaded["libs/libkoreader-lfs"] = real_lfs
    package.loaded["lfs"] = real_lfs
end

-- Mock UI and Blitbuffer
package.loaded["ffi/blitbuffer"] = {
    COLOR_BLACK = 0,
    COLOR_WHITE = 1,
    COLOR_GRAY = 2,
    COLOR_LIGHT_GRAY = 3,
    COLOR_DARK_GRAY = 4,
    COLOR_GRAY_B = 5,
    Color8 = function(g) return g end,
}
package.loaded["ui/font"] = {
    getFace = function() return {} end,
}
package.loaded["ui/geometry"] = {
    new = function(self, args)
        local o = args or {}
        setmetatable(o, { __index = self })
        return o
    end,
}
package.loaded["ui/gesturerange"] = {
    new = function(self, args) return args or {} end,
}
package.loaded["ui/widget/focusmanager"] = {
    NOT_UNFOCUS = 1,
    NOT_FOCUS = 2,
    FOCUS_ONLY_ON_NT = 2,
    FORCED_FOCUS = 4,
    new = function(self, args)
        local o = args or {}
        setmetatable(o, { __index = self })
        return o
    end,
}
package.loaded["ui/widget/imagewidget"] = {
    new = function(self, args) return args or {} end,
}
package.loaded["ui/widget/textboxwidget"] = {
    new = function(self, args) return args or {} end,
}
package.loaded["ui/widget/textwidget"] = {
    new = function(self, args)
        local o = args or {}
        o.getSize = function() return { w = #(o.text or "") * 8, h = 16 } end
        return o
    end,
}
package.loaded["ui/widget/button"] = {
    new = function(self, args)
        local o = args or {}
        o.frame = { invert = false }
        return o
    end,
}
package.loaded["ui/widget/container/framecontainer"] = {
    new = function(self, args) return args or {} end,
}
package.loaded["ui/widget/container/inputcontainer"] = {
    new = function(self, args) return args or {} end,
}
package.loaded["ui/widget/container/centercontainer"] = {
    new = function(self, args) return args or {} end,
}
package.loaded["ui/widget/container/widgetcontainer"] = {
    extend = function(self, tbl)
        local o = tbl or {}
        setmetatable(o, { __index = self })
        o.new = function(cls, args)
            local inst = args or {}
            setmetatable(inst, { __index = cls })
            if inst.init then inst:init() end
            return inst
        end
        return o
    end,
}
package.loaded["ui/widget/verticalgroup"] = { new = function(self, args) return args or {} end }
package.loaded["ui/widget/horizontalgroup"] = { new = function(self, args) return args or {} end }
package.loaded["ui/widget/verticalspan"] = { new = function(self, args) return args or {} end }
package.loaded["ui/widget/horizontalspan"] = { new = function(self, args) return args or {} end }
package.loaded["ui/widget/linewidget"] = { new = function(self, args) return args or {} end }
package.loaded["ui/uimanager"] = {
    show = function(self, widget) end,
    close = function(self, widget) end,
    setDirty = function(self, widget) end,
}
package.loaded["ui/widget/inputdialog"] = {
    new = function(self, args)
        local o = args or {}
        o.getInputText = function() return "test_folder" end
        return o
    end,
}
package.loaded["ui/widget/buttondialog"] = {
    new = function(self, args)
        local o = args or {}
        o.selected = { x = 1, y = 1 }
        o.moveFocusTo = function(d, x, y, flags)
            d.selected.x = x
            d.selected.y = y
        end
        return o
    end,
}
package.loaded["ui/widget/confirmbox"] = {
    new = function(self, args) return args or {} end,
}
package.loaded["ui/widget/checkmark"] = {
    new = function(self, args) return args or {} end,
}
package.loaded["ui/widget/multiinputdialog"] = {
    new = function(self, args) return args or {} end,
}
package.loaded["ui/widget/container/scrollablecontainer"] = {
    new = function(self, args) return args or {} end,
}
package.loaded["ui/widget/spinwidget"] = {
    new = function(self, args) return args or {} end,
}
package.loaded["ui/widget/infomessage"] = {
    new = function(self, args) return args or {} end,
}
package.loaded["dispatcher"] = {
    actions = {},
    registerAction = function(self, name, action)
        self.actions[name] = action
    end,
}

