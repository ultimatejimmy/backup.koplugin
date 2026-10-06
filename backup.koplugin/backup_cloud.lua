--[[--
backup_cloud.lua
Central Cloud Storage Manager for KOReader Backup.
Coordinates provider drivers (WebDAV, FTP, SFTP, Google Drive),
credential storage, unified upload/download dispatch, and remote retention pruning.
--]]

local ok_ds, DataStorage = pcall(require, "datastorage")
local ok_util, util = pcall(require, "util")
local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
if not ok_lfs or not lfs then
    ok_lfs, lfs = pcall(require, "lfs")
end
local Localization = require("localization_backup")
local _ = Localization:getHelper()
local Constants = require("backup_constants")
local Sanitizer = require("backup_sanitizer")

local OAuth = require("backup_cloud_oauth")
local WebDAV = require("backup_cloud_webdav")
local FTP = require("backup_cloud_ftp")
local SFTP = require("backup_cloud_sftp")
local GDrive = require("backup_cloud_gdrive")
local OneDrive = require("backup_cloud_onedrive")
local Dropbox = require("backup_cloud_dropbox")

local Cloud = {}

local function getDataDir()
    return (ok_ds and DataStorage and DataStorage.getDataDir and DataStorage:getDataDir()) or "."
end

local function getCredsFilePath()
    return getDataDir() .. "/settings/backup_cloud_creds.lua"
end

local _creds_cache = nil

--- Loads all stored non-OAuth credentials (WebDAV, FTP, SFTP).
local function loadAllCredentials()
    if _creds_cache then return _creds_cache end
    local path = getCredsFilePath()
    local ok, data = pcall(dofile, path)
    if ok and type(data) == "table" then
        _creds_cache = data
    else
        _creds_cache = {}
    end
    return _creds_cache
end

--- Saves all non-OAuth credentials to disk.
local function saveAllCredentials(creds)
    _creds_cache = creds
    local path = getCredsFilePath()
    local settings_dir = getDataDir() .. "/settings"
    if util and util.makePath then util.makePath(settings_dir) end
    local dumped = Sanitizer.dumpSettings(creds)
    local f = io.open(path, "wb")
    if f then
        f:write(dumped)
        f:close()
        return true
    end
    return false
end

--- Loads credentials for a specific provider.
function Cloud.loadCredentials(provider)
    if not provider then return {} end
    local all = loadAllCredentials()
    return all[provider] or {}
end

--- Saves credentials for a specific provider.
function Cloud.saveCredentials(provider, creds)
    if not provider then return false end
    local all = loadAllCredentials()
    all[provider] = creds or {}
    return saveAllCredentials(all)
end

--- Clears credentials (and OAuth tokens if applicable) for a specific provider.
function Cloud.clearCredentials(provider)
    if not provider then return false end
    local all = loadAllCredentials()
    all[provider] = nil
    saveAllCredentials(all)
    OAuth.clearTokens(provider)
    return true
end

--- Human-readable display labels for cloud providers.
function Cloud.getProviderLabel(provider)
    if provider == Constants.CLOUD_PROVIDERS.GDRIVE then
        return _("Google Drive")
    elseif provider == Constants.CLOUD_PROVIDERS.WEBDAV then
        return _("WebDAV (Nextcloud / NAS)")
    elseif provider == Constants.CLOUD_PROVIDERS.FTP then
        return _("FTP / FTPS")
    elseif provider == Constants.CLOUD_PROVIDERS.SFTP then
        return _("SFTP (SSH)")
    elseif provider == Constants.CLOUD_PROVIDERS.ONEDRIVE then
        return _("Microsoft OneDrive")
    elseif provider == Constants.CLOUD_PROVIDERS.DROPBOX then
        return _("Dropbox")
    end
    return _("None")
end

--- Returns the active driver module for a given provider.
function Cloud.getDriver(provider)
    if provider == Constants.CLOUD_PROVIDERS.GDRIVE then
        return GDrive
    elseif provider == Constants.CLOUD_PROVIDERS.ONEDRIVE then
        return OneDrive
    elseif provider == Constants.CLOUD_PROVIDERS.DROPBOX then
        return Dropbox
    elseif provider == Constants.CLOUD_PROVIDERS.WEBDAV then
        return WebDAV
    elseif provider == Constants.CLOUD_PROVIDERS.FTP then
        return FTP
    elseif provider == Constants.CLOUD_PROVIDERS.SFTP then
        return SFTP
    end
    return nil
end

--- Checks if a provider has been configured with credentials or OAuth tokens.
function Cloud.isConfigured(provider)
    if not provider or provider == Constants.CLOUD_PROVIDERS.NONE or provider == "none" then
        return false
    end
    if provider == Constants.CLOUD_PROVIDERS.GDRIVE or provider == Constants.CLOUD_PROVIDERS.ONEDRIVE or provider == Constants.CLOUD_PROVIDERS.DROPBOX then
        local tok = OAuth.loadTokens(provider)
        return (tok and tok.access_token ~= nil and tok.access_token ~= "")
    elseif provider == Constants.CLOUD_PROVIDERS.WEBDAV then
        local c = Cloud.loadCredentials(provider)
        return (c.url and c.url ~= "")
    elseif provider == Constants.CLOUD_PROVIDERS.FTP then
        local c = Cloud.loadCredentials(provider)
        return (c.host and c.host ~= "")
    elseif provider == Constants.CLOUD_PROVIDERS.SFTP then
        local c = Cloud.loadCredentials(provider)
        return (c.host and c.host ~= "")
    end
    return false
end

--- Tests connection to a cloud provider.
-- Supports testing with either saved credentials or transient dialog credentials.
-- @param provider string (optional, defaults to active provider from settings)
-- @param opts_or_creds table|function (optional credentials table, or callback if omitted)
-- @param callback function(ok, msg_or_err)
function Cloud.testConnection(provider, opts_or_creds, callback)
    if type(provider) == "function" then
        callback = provider
        opts_or_creds = nil
        provider = nil
    elseif type(opts_or_creds) == "function" then
        callback = opts_or_creds
        opts_or_creds = nil
    end

    local s = Cloud.getPluginSettings()
    local target_provider = provider or s.cloud_provider
    if not target_provider or target_provider == "none" or target_provider == Constants.CLOUD_PROVIDERS.NONE then
        if callback then callback(false, _("No cloud provider is currently selected.")) end
        return
    end

    local driver = Cloud.getDriver(target_provider)
    if not driver or not driver.testConnection then
        if callback then callback(false, _("Selected provider driver is not available.")) end
        return
    end

    local creds = {}
    if opts_or_creds and type(opts_or_creds) == "table" then
        for k, v in pairs(opts_or_creds) do creds[k] = v end
    else
        creds = Cloud.loadCredentials(target_provider)
    end
    if not creds.remote_dir or creds.remote_dir == "" then
        creds.remote_dir = s.cloud_remote_dir or Constants.CLOUD_DEFAULT_REMOTE_DIR
    end

    driver.testConnection(creds, callback)
end

--- High-level upload of a local backup file to the active cloud provider.
-- @param local_path string: full path to local .zip or .tar.gz archive
-- @param opts table: optional overrides { provider, on_progress }
-- @param callback function(ok, result_or_err)
function Cloud.upload(local_path, opts, callback)
    opts = opts or {}
    local s = Cloud.getPluginSettings()
    local provider = opts.provider or s.cloud_provider

    if not Cloud.isConfigured(provider) then
        if callback then
            callback(false, string.format(_("%s is not configured. Please configure it in Settings."), Cloud.getProviderLabel(provider)))
        end
        return
    end

    local driver = Cloud.getDriver(provider)
    if not driver or not driver.upload then
        if callback then callback(false, "Driver upload method not implemented for: " .. tostring(provider)) end
        return
    end

    local creds = Cloud.loadCredentials(provider)
    for k, v in pairs(opts) do
        creds[k] = v
    end
    creds.remote_dir = opts.remote_dir or s.cloud_remote_dir or Constants.CLOUD_DEFAULT_REMOTE_DIR

    driver.upload(local_path, creds, function(ok, res)
        if ok and (s.cloud_prune_remote ~= false) and s.retention_limit and s.retention_limit > 0 then
            -- Prune remote archives in the background to match retention limit
            Cloud.pruneRemote(s.retention_limit, function() end)
        end
        if callback then callback(ok, res) end
    end)
end

--- High-level download of a remote backup archive to local storage.
-- @param remote_item table or string: remote file entry with .filename / .file_id or filename string
-- @param local_dest_path string: target local file path
-- @param opts table: optional overrides { provider, on_progress }
-- @param callback function(ok, local_path_or_err)
function Cloud.download(remote_item, local_dest_path, opts, callback)
    opts = opts or {}
    local s = Cloud.getPluginSettings()
    local provider = opts.provider or s.cloud_provider

    local driver = Cloud.getDriver(provider)
    if not driver or not driver.download then
        if callback then callback(false, "Driver download method not implemented for: " .. tostring(provider)) end
        return
    end

    local creds = Cloud.loadCredentials(provider)
    for k, v in pairs(opts) do
        creds[k] = v
    end
    creds.remote_dir = opts.remote_dir or s.cloud_remote_dir or Constants.CLOUD_DEFAULT_REMOTE_DIR

    local remote_id = (type(remote_item) == "table") and (remote_item.file_id or remote_item.filename) or tostring(remote_item)
    driver.download(remote_id, local_dest_path, creds, callback)
end

--- Retrieves the list of remote backup archives.
-- Returns items formatted with: { filename, size, size_str, mtime_str, file_id, is_cloud=true, provider=... }
-- @param callback function(ok, list_of_backups_or_err)
function Cloud.listRemoteBackups(callback)
    local s = Cloud.getPluginSettings()
    local provider = s.cloud_provider

    if not Cloud.isConfigured(provider) then
        if callback then callback(true, {}) end
        return
    end

    local driver = Cloud.getDriver(provider)
    if not driver or not driver.list then
        if callback then callback(false, "Driver list method not implemented for: " .. tostring(provider)) end
        return
    end

    local creds = Cloud.loadCredentials(provider)
    creds.remote_dir = s.cloud_remote_dir or Constants.CLOUD_DEFAULT_REMOTE_DIR

    driver.list(creds, function(ok, list)
        if not ok then
            if callback then callback(false, list) end
            return
        end

        local formatted = {}
        for _, item in ipairs(list or {}) do
            local sz = tonumber(item.size) or 0
            table.insert(formatted, {
                filename = item.filename,
                file_id = item.file_id or item.filename,
                size = sz,
                size_str = (util and util.getFriendlySize and sz > 0) and util.getFriendlySize(sz) or (sz .. " B"),
                mtime_str = item.mtime_str or "",
                is_cloud = true,
                provider = provider,
                provider_label = Cloud.getProviderLabel(provider),
            })
        end

        if callback then callback(true, formatted) end
    end)
end

--- Deletes a remote backup archive.
-- @param remote_item table or string
-- @param callback function(ok, err)
function Cloud.deleteRemote(remote_item, callback)
    local s = Cloud.getPluginSettings()
    local provider = (type(remote_item) == "table" and remote_item.provider) or s.cloud_provider

    local driver = Cloud.getDriver(provider)
    if not driver or not driver.delete then
        if callback then callback(false, "Driver delete method not implemented for: " .. tostring(provider)) end
        return
    end

    local creds = Cloud.loadCredentials(provider)
    creds.remote_dir = s.cloud_remote_dir or Constants.CLOUD_DEFAULT_REMOTE_DIR

    local remote_id = (type(remote_item) == "table") and (remote_item.file_id or remote_item.filename) or tostring(remote_item)
    driver.delete(remote_id, creds, callback)
end

--- Prunes remote backup files when count exceeds the retention limit.
-- @param limit number: max backups to keep (e.g. 5)
-- @param callback function(ok, count_pruned)
function Cloud.pruneRemote(limit, callback)
    limit = tonumber(limit) or 5
    if limit <= 0 then
        if callback then callback(true, 0) end
        return
    end

    Cloud.listRemoteBackups(function(ok, list)
        if not ok or not list or #list <= limit then
            if callback then callback(true, 0) end
            return
        end

        -- Sort newest to oldest
        table.sort(list, function(a, b)
            return (a.filename or "") > (b.filename or "")
        end)

        local to_delete = {}
        for i = limit + 1, #list do
            table.insert(to_delete, list[i])
        end

        local count = 0
        local function deleteNext(idx)
            if idx > #to_delete then
                if callback then callback(true, count) end
                return
            end

            Cloud.deleteRemote(to_delete[idx], function(ok_del)
                if ok_del then count = count + 1 end
                deleteNext(idx + 1)
            end)
        end

        deleteNext(1)
    end)
end

--- Helper to retrieve plugin settings cache.
function Cloud.getPluginSettings()
    local settings_file = getDataDir() .. "/settings/backup.lua"
    local ok, data = pcall(dofile, settings_file)
    if ok and type(data) == "table" then
        return data
    end
    return Constants.DEFAULT_SETTINGS
end

return Cloud
