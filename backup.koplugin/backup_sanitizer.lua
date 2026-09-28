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

--- Sanitizes a settings table based on specified mode.
-- @param backup_settings table: the settings table from the backup
-- @param mode string: "raw", "sanitized", or "merge"
-- @param current_settings table: optional, the current device's settings (used in merge mode)
-- @return table, table, table: sanitized_settings, stripped_keys, reset_paths
function Sanitizer.sanitize(backup_settings, mode, current_settings)
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

    -- SANITIZED MODE: Strip all hardware keys and reset platform paths
    if mode == Sanitizer.MODE_SANITIZED then
        local result = deepCopy(backup_settings)
        for key, _ in pairs(backup_settings) do
            if Sanitizer.isHardwareKey(key) then
                result[key] = nil
                table.insert(stripped_keys, key)
            elseif Sanitizer.isDevicePathKey(key) then
                result[key] = nil
                table.insert(reset_paths, key)
            end
        end
        table.sort(stripped_keys)
        table.sort(reset_paths)
        return result, stripped_keys, reset_paths
    end

    -- MERGE MODE: Preserve current device's hardware & paths, overlay portable backup settings
    if mode == Sanitizer.MODE_MERGE then
        local result = deepCopy(current_settings or {})
        for key, val in pairs(backup_settings) do
            if not Sanitizer.isHardwareKey(key) and not Sanitizer.isDevicePathKey(key) then
                result[key] = deepCopy(val)
            else
                if Sanitizer.isHardwareKey(key) then
                    table.insert(stripped_keys, key)
                else
                    table.insert(reset_paths, key)
                end
            end
        end
        table.sort(stripped_keys)
        table.sort(reset_paths)
        return result, stripped_keys, reset_paths
    end

    return deepCopy(backup_settings), {}, {}
end

--- Sanitizes an on-disk Lua settings file.
-- Parses the file into a Lua table, runs sanitization, and formats it back to Lua table code.
-- @param file_path string: path to settings file
-- @param mode string: "raw", "sanitized", or "merge"
-- @param current_settings table: current device settings
-- @return table, table, table: sanitized_settings, stripped_keys, reset_paths
function Sanitizer.sanitizeFile(file_path, mode, current_settings)
    local ok, data = pcall(dofile, file_path)
    if not ok or type(data) ~= "table" then
        return nil, {}, {}, "Failed to load settings file: " .. tostring(data)
    end
    local sanitized, stripped, reset = Sanitizer.sanitize(data, mode, current_settings)
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
