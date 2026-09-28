--[[--
backup_manifest.lua
Manifest generator, parser, and device compatibility comparator.
--]]

local Constants = require("backup_constants")

local ok_json, json = pcall(require, "json")
if not ok_json or not json then
    -- Fallback simple JSON serializer/deserializer if json module isn't loaded yet
    json = {
        encode = function(val)
            local ok_dump, dump = pcall(require, "dump")
            if ok_dump and dump then return dump(val, nil, true) end
            return "{}"
        end,
        decode = function(str)
            return {}
        end,
    }
end

local Manifest = {}

function Manifest.getPlatformName()
    local ok_dev, Device = pcall(require, "device")
    if not ok_dev or not Device then
        return "generic"
    end
    if type(Device.isAndroid) == "function" and Device:isAndroid() then return "android" end
    if type(Device.isKobo) == "function" and Device:isKobo() then return "kobo" end
    if type(Device.isKindle) == "function" and Device:isKindle() then return "kindle" end
    if type(Device.isPocketBook) == "function" and Device:isPocketBook() then return "pocketbook" end
    if type(Device.isCervantes) == "function" and Device:isCervantes() then return "cervantes" end
    if type(Device.isRemarkable) == "function" and Device:isRemarkable() then return "remarkable" end
    if type(Device.isSonyPRSTux) == "function" and Device:isSonyPRSTux() then return "sony" end
    return "desktop"
end

function Manifest.getDeviceModel()
    local ok_dev, Device = pcall(require, "device")
    if ok_dev and Device and type(Device.getModel) == "function" then
        return Device:getModel() or "Generic"
    end
    return "Generic"
end

function Manifest.getKOReaderVersion()
    local ok_ver, Version = pcall(require, "version")
    if ok_ver and Version then
        if type(Version.getVersion) == "function" then
            return Version:getVersion()
        elseif type(Version.version) == "string" then
            return Version.version
        end
    end
    return "unknown"
end

function Manifest.getScreenInfo()
    local ok_dev, Device = pcall(require, "device")
    if ok_dev and Device and Device.screen then
        local w = type(Device.screen.getWidth) == "function" and Device.screen:getWidth() or 600
        local h = type(Device.screen.getHeight) == "function" and Device.screen:getHeight() or 800
        local dpi = Device.screen.dpi or 300
        return { width = w, height = h, dpi = dpi }
    end
    return { width = 600, height = 800, dpi = 300 }
end

--- Generates a new manifest table.
-- @param options table: { backup_name, backup_type, components, plugins, patches, description }
function Manifest.create(options)
    options = options or {}
    local now = os.time()
    local date_str = os.date("%Y-%m-%d %H:%M:%S", now)
    local date_iso = os.date("!%Y-%m-%dT%H:%M:%SZ", now)

    local manifest = {
        manifest_version = 1,
        created_at = now,
        created_at_str = date_str,
        created_at_iso = date_iso,
        backup_name = options.backup_name or ("Backup " .. os.date("%Y-%m-%d_%H%M%S", now)),
        backup_type = options.backup_type or "modular", -- "full", "modular", "rollback"
        description = options.description or "",
        device = {
            model = Manifest.getDeviceModel(),
            platform = Manifest.getPlatformName(),
            koreader_version = Manifest.getKOReaderVersion(),
            screen = Manifest.getScreenInfo(),
        },
        components = options.components or Constants.DEFAULT_COMPONENT_SELECTION,
        installed_plugins = options.plugins or {},
        installed_patches = options.patches or {},
    }

    return manifest
end

--- Serializes manifest table to JSON string.
function Manifest.serialize(manifest)
    if not manifest then return "{}" end
    return json.encode(manifest)
end

--- Parses JSON string into manifest table.
function Manifest.parse(json_str)
    if not json_str or json_str == "" then
        return nil, "Empty manifest content"
    end
    local ok, data = pcall(json.decode, json_str)
    if not ok or type(data) ~= "table" then
        return nil, "Failed to parse JSON manifest"
    end
    return data
end

--- Compares a manifest against current device to check if they match.
-- @param manifest table: parsed manifest table
-- @return boolean: true if created on identical device model & platform
function Manifest.isSameDevice(manifest)
    if not manifest or not manifest.device then
        return false
    end
    local cur_model = Manifest.getDeviceModel()
    local cur_platform = Manifest.getPlatformName()

    local backup_model = manifest.device.model or ""
    local backup_platform = manifest.device.platform or ""

    if cur_model:lower() ~= backup_model:lower() then
        return false
    end
    if cur_platform:lower() ~= backup_platform:lower() then
        return false
    end

    return true
end

return Manifest
