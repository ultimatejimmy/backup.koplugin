--[[--
backup_retention.lua
Manages backup discovery, file statistics, metadata caching, and rolling retention pruning.
--]]

local Constants = require("backup_constants")
local ArchiverMgr = require("backup_archiver")

local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
if not ok_lfs or not lfs then
    ok_lfs, lfs = pcall(require, "lfs")
end

local ok_ds, DataStorage = pcall(require, "datastorage")

local Retention = {}

--- Returns the primary default backup directory.
function Retention.getDefaultBackupDir()
    local base = (ok_ds and DataStorage and DataStorage.getDataDir and DataStorage:getDataDir()) or "."
    return base .. "/" .. Constants.BACKUP_DIR_NAME
end

--- Returns potential SD card backup directories if present.
function Retention.getSDCardBackupDirs()
    local candidates = {
        "/mnt/sdcard/koreader/backups",
        "/mnt/extsd/koreader/backups",
        "/mnt/mxc_sdcard/koreader/backups",
        "/sdcard/koreader/backups",
    }
    local available = {}
    if not lfs or not lfs.attributes then return available end

    for _, dir in ipairs(candidates) do
        local parent = dir:match("^(.*)[/\\]koreader")
        if parent and lfs.attributes(parent, "mode") == "directory" then
            table.insert(available, dir)
        end
    end
    return available
end

--- Formats bytes to human-readable string (KB / MB).
function Retention.formatSize(bytes)
    bytes = tonumber(bytes) or 0
    if bytes < 1024 then
        return string.format("%d B", bytes)
    elseif bytes < 1024 * 1024 then
        return string.format("%.1f KB", bytes / 1024)
    else
        return string.format("%.1f MB", bytes / (1024 * 1024))
    end
end

--- Checks if a filename is a backup archive.
function Retention.isBackupFile(filename)
    if not filename or filename:sub(1, 1) == "." then return false end
    return filename:match("%.zip$") ~= nil or filename:match("%.tar%.gz$") ~= nil or filename:match("%.tgz$") ~= nil or filename:match("%.tar$") ~= nil
end

--- Scans a backup directory and returns list of backup files sorted newest first.
-- @param backup_dir string: optional path to scan, defaults to getDefaultBackupDir()
-- @return table: array of { filename, filepath, size, size_str, mtime, mtime_str, manifest }
function Retention.listBackups(backup_dir)
    backup_dir = backup_dir or Retention.getDefaultBackupDir()
    local backups = {}
    if not lfs or not lfs.attributes then return backups end
    if lfs.attributes(backup_dir, "mode") ~= "directory" then return backups end

    for file in lfs.dir(backup_dir) do
        if Retention.isBackupFile(file) then
            local full_path = backup_dir .. "/" .. file
            local attr = lfs.attributes(full_path)
            if attr and attr.mode == "file" then
                local mtime = attr.modification or 0
                local size = attr.size or 0
                local is_rollback = (file:match("^" .. Constants.ROLLBACK_FILE_NAME) ~= nil)

                local item = {
                    filename = file,
                    filepath = full_path,
                    size = size,
                    size_str = Retention.formatSize(size),
                    mtime = mtime,
                    mtime_str = os.date("%Y-%m-%d %H:%M:%S", mtime),
                    is_rollback = is_rollback,
                    manifest = nil,
                }
                table.insert(backups, item)
            end
        end
    end

    -- Sort by newest first
    table.sort(backups, function(a, b)
        return a.mtime > b.mtime
    end)

    return backups
end

--- Loads manifest for a specific backup item if not already loaded.
function Retention.loadManifestForBackup(backup_item)
    if not backup_item or backup_item.manifest then return backup_item end
    local manifest = ArchiverMgr.readManifest(backup_item.filepath)
    backup_item.manifest = manifest
    return backup_item
end

--- Enforces rolling retention limit by deleting oldest backups when limit is exceeded.
-- Does NOT delete rollback safety snapshots.
-- @param backup_dir string
-- @param max_count number: max backups to keep (0 = unlimited)
-- @return number: count of pruned backups
function Retention.prune(backup_dir, max_count)
    max_count = tonumber(max_count) or 0
    if max_count <= 0 then return 0 end

    local backups = Retention.listBackups(backup_dir)
    local standard_backups = {}
    for _, b in ipairs(backups) do
        if not b.is_rollback then
            table.insert(standard_backups, b)
        end
    end

    local pruned_count = 0
    if #standard_backups > max_count then
        for i = max_count + 1, #standard_backups do
            local old_backup = standard_backups[i]
            local ok = os.remove(old_backup.filepath)
            if ok then
                pruned_count = pruned_count + 1
            end
        end
    end

    return pruned_count
end

--- Deletes a backup file.
function Retention.deleteBackup(filepath)
    if not filepath then return false, "No filepath provided" end
    local ok, err = os.remove(filepath)
    return ok, err
end

return Retention
