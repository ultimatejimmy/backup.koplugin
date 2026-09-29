--[[--
backup_sanitizer.lua
Settings sanitizer and cross-device hardware normalizer.
Filters hardware-tied settings and storage paths from settings.reader.lua
to prevent boot loops and display issues across different device models.
--]]

local Constants = require("backup_constants")

local Sanitizer = {}

Sanitizer.MODE_RAW = "raw"
Sanitizer.MODE_SANITIZED = "sanitized"
Sanitizer.MODE_MERGE = "merge"

local function deepCopy(orig)
    if type(orig) ~= "table" then
        return orig
    end
    local copy = {}
    for k, v in pairs(orig) do
        copy[k] = deepCopy(v)
    end
    return copy
end

--- Checks if a key in settings is hardware-tied.
function Sanitizer.isHardwareKey(key)
    if not key or type(key) ~= "string" then return false end
    if Constants.HARDWARE_KEYS[key] then return true end
    -- Catch dynamic hardware prefixes
    if key:match("^dev_") or key:match("^hw_") or key:match("^mxcfb_") then
        return true
    end
    return false
end

--- Checks if a key in settings is a device-bound storage path.
function Sanitizer.isDevicePathKey(key)
    if not key or type(key) ~= "string" then return false end
    return Constants.DEVICE_PATH_KEYS[key] == true
end

local function hasColorScreen()
    local ok_dev, Device = pcall(require, "device")
    if ok_dev and Device and type(Device.hasColorScreen) == "function" then
        return Device:hasColorScreen()
    end
    return nil
end

local function getTargetHomeDir(current_settings, target_options)
    if current_settings and current_settings.home_dir and current_settings.home_dir ~= "" then
        return current_settings.home_dir
    end
    if target_options and target_options.books_dir and target_options.books_dir ~= "" then
        return target_options.books_dir
    end
    local ok_dev, Device = pcall(require, "device")
    if ok_dev and Device and Device.home_dir and Device.home_dir ~= "" then
        return Device.home_dir
    end
    return nil
end

--- Sanitizes a settings table based on specified mode.
-- @param backup_settings table: the settings table from the backup
-- @param mode string: "raw", "sanitized", or "merge"
-- @param current_settings table: optional, the current device's settings
-- @param target_options table: optional, target options such as { books_dir = "..." }
-- @return table, table, table: sanitized_settings, stripped_keys, reset_paths
function Sanitizer.sanitize(backup_settings, mode, current_settings, target_options)
    mode = mode or Sanitizer.MODE_SANITIZED
    if type(backup_settings) ~= "table" then
        return {}, {}, {}
    end

    local stripped_keys = {}
    local reset_paths = {}

    -- RAW MODE: Exact bit-for-bit restore (Disaster Recovery on identical device)
    if mode == Sanitizer.MODE_RAW then
        return deepCopy(backup_settings), {}, {}
    end

    -- CROSS-DEVICE NORMALIZATION (sanitized and merge modes)
    local result = deepCopy(backup_settings)

    for key, _ in pairs(backup_settings) do
        if Sanitizer.isHardwareKey(key) then
            table.insert(stripped_keys, key)
            if current_settings and current_settings[key] ~= nil then
                result[key] = deepCopy(current_settings[key])
            else
                if key == "color_rendering" then
                    local is_color = hasColorScreen()
                    if is_color ~= nil then
                        result[key] = is_color
                    else
                        result[key] = nil
                    end
                else
                    result[key] = nil
                end
            end
        elseif Sanitizer.isDevicePathKey(key) then
            table.insert(reset_paths, key)
            if key == "home_dir" then
                result.home_dir = getTargetHomeDir(current_settings, target_options)
            elseif key == "folder_shortcuts" then
                -- Handled in post-processing below
            elseif key == "lastdir" or key == "lastfile" then
                result[key] = nil
            else
                if current_settings and current_settings[key] and current_settings[key] ~= "" then
                    result[key] = deepCopy(current_settings[key])
                else
                    result[key] = nil
                end
            end
        end
    end

    -- Post-processing: ensure target hardware/path settings are preserved even if not present in backup
    -- 1. color_rendering: must never be nil on color screens, and never true on grayscale screens
    if result.color_rendering == nil then
        if current_settings and current_settings.color_rendering ~= nil then
            result.color_rendering = current_settings.color_rendering
        else
            local is_color = hasColorScreen()
            if is_color ~= nil then
                result.color_rendering = is_color
            end
        end
    end

    -- 2. home_dir: preserve target device's books folder
    if result.home_dir == nil then
        local target_home = getTargetHomeDir(current_settings, target_options)
        if target_home then
            result.home_dir = target_home
        end
    end

    -- 3. folder_shortcuts: prune foreign roots and guarantee target home_dir shortcut
    local shortcuts = {}
    if current_settings and type(current_settings.folder_shortcuts) == "table" then
        shortcuts = deepCopy(current_settings.folder_shortcuts)
    elseif type(backup_settings.folder_shortcuts) == "table" then
        shortcuts = deepCopy(backup_settings.folder_shortcuts)
    end

    local ok_dev, Device = pcall(require, "device")
    local is_kindle = ok_dev and Device and type(Device.isKindle) == "function" and Device:isKindle()
    local is_kobo = ok_dev and Device and type(Device.isKobo) == "function" and Device:isKobo()
    local is_android = ok_dev and Device and type(Device.isAndroid) == "function" and Device:isAndroid()

    for path, _ in pairs(shortcuts) do
        if type(path) == "string" then
            if path:match("^/mnt/us") and not is_kindle then
                shortcuts[path] = nil
            elseif path:match("^/mnt/onboard") and not is_kobo then
                shortcuts[path] = nil
            elseif (path:match("^/storage/emulated") or path:match("^/sdcard")) and not is_android then
                shortcuts[path] = nil
            end
        end
    end

    if result.home_dir and result.home_dir ~= "" then
        shortcuts[result.home_dir] = shortcuts[result.home_dir] or {
            providers = { home_dir = true },
            time = os.time(),
        }
    end

    if next(shortcuts) ~= nil or (current_settings and current_settings.folder_shortcuts) or backup_settings.folder_shortcuts then
        result.folder_shortcuts = shortcuts
    end

    -- 4. device_id: always preserve target device_id or leave nil for KOReader to generate fresh uuid
    if current_settings and current_settings.device_id then
        result.device_id = current_settings.device_id
    else
        result.device_id = nil
    end

    -- 5. sink_sync: preserve target device sync ID if available
    if result.sink_sync and type(result.sink_sync) == "table" then
        if current_settings and current_settings.sink_sync and current_settings.sink_sync.device_id then
            result.sink_sync.device_id = current_settings.sink_sync.device_id
        end
    end

    table.sort(stripped_keys)
    table.sort(reset_paths)
    return result, stripped_keys, reset_paths
end

--- Sanitizes an on-disk Lua settings file.
-- Parses the file into a Lua table, runs sanitization, and formats it back to Lua table code.
-- @param file_path string: path to settings file
-- @param mode string: "raw", "sanitized", or "merge"
-- @param current_settings table: current device settings
-- @param target_options table: optional target options
-- @return table, table, table: sanitized_settings, stripped_keys, reset_paths
function Sanitizer.sanitizeFile(file_path, mode, current_settings, target_options)
    local ok, data = pcall(dofile, file_path)
    if not ok or type(data) ~= "table" then
        return nil, {}, {}, "Failed to load settings file: " .. tostring(data)
    end
    local sanitized, stripped, reset = Sanitizer.sanitize(data, mode, current_settings, target_options)
    return sanitized, stripped, reset
end

--- Serializes a Lua table to clean Lua code compatible with luasettings.
function Sanitizer.dumpSettings(tbl)
    local ok_dump, dump = pcall(require, "dump")
    if ok_dump and dump then
        return "return " .. dump(tbl, nil, true) .. "\n"
    end
    -- Fallback serializer
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
                local key_str
                if type(k) == "string" and k:match("^[%a_][%a%d_]*$") then
                    key_str = k
                else
                    key_str = "[" .. serialize(k) .. "]"
                end
                table.insert(lines, string.format("%s%s = %s,\n", next_indent, key_str, serialize(v, next_indent)))
            end
            table.insert(lines, indent .. "}")
            return table.concat(lines)
        else
            return "nil"
        end
    end
    return "return " .. serialize(tbl) .. "\n"
end

return Sanitizer
