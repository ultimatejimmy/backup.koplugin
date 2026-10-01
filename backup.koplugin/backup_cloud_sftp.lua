--[[--
backup_cloud_sftp.lua
SFTP (SSH File Transfer Protocol) driver for KOReader Backup.
Uses system sftp / ssh binaries when available (e.g. Linux desktop / Android termux / chroot),
with a graceful detection and fallback when binaries are unavailable.
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

local SFTP = {}

local function getDataDir()
    return (ok_ds and DataStorage and DataStorage.getDataDir and DataStorage:getDataDir()) or "."
end

--- Checks if the sftp command-line client is available on the device.
local _cached_available = nil
function SFTP.isAvailable()
    if _cached_available ~= nil then
        return _cached_available
    end
    -- Check via which or where
    local check_cmd = (package.config:sub(1, 1) == "\\") and "where sftp >nul 2>nul" or "which sftp >/dev/null 2>&1"
    local res = os.execute(check_cmd)
    _cached_available = (res == 0 or res == true)
    return _cached_available
end

--- Builds command-line invocation for sftp batch mode.
local function runSftpBatch(opts, commands)
    if not SFTP.isAvailable() then
        return false, _("SFTP client ('sftp' binary) is not installed on this system.")
    end

    local host = opts.host
    if not host or host == "" then
        return false, _("SFTP host is required.")
    end
    local port = tonumber(opts.port) or 22
    local user = (opts.username and opts.username ~= "") and opts.username or "root"

    local staging_dir = getDataDir() .. "/cache"
    if util and util.makePath then util.makePath(staging_dir) end
    local batch_file = staging_dir .. "/sftp_batch_" .. tostring(os.time()) .. ".txt"
    local out_file = staging_dir .. "/sftp_out_" .. tostring(os.time()) .. ".txt"

    local f_b, err_b = io.open(batch_file, "w")
    if not f_b then
        return false, "Could not create SFTP batch file: " .. tostring(err_b)
    end
    for _, cmd in ipairs(commands) do
        f_b:write(cmd .. "\n")
    end
    f_b:close()

    local args = {
        "sftp",
        "-b", string.format("%q", batch_file),
        "-P", tostring(port),
        "-o", "BatchMode=yes",
        "-o", "StrictHostKeyChecking=no",
        "-o", "ConnectTimeout=15",
    }

    if opts.key_path and opts.key_path ~= "" then
        table.insert(args, "-i")
        table.insert(args, string.format("%q", opts.key_path))
    end

    local target = string.format("%s@%s", user, host)
    table.insert(args, target)

    local full_cmd = table.concat(args, " ") .. " > " .. string.format("%q", out_file) .. " 2>&1"

    -- Support sshpass if password is provided and sshpass exists
    if opts.password and opts.password ~= "" then
        local check_pass = (package.config:sub(1, 1) == "\\") and "where sshpass >nul 2>nul" or "which sshpass >/dev/null 2>&1"
        if os.execute(check_pass) == 0 then
            full_cmd = "sshpass -p " .. string.format("%q", opts.password) .. " " .. full_cmd
        end
    end

    local code = os.execute(full_cmd)
    local output = ""
    local f_out = io.open(out_file, "r")
    if f_out then
        output = f_out:read("*a") or ""
        f_out:close()
    end

    pcall(os.remove, batch_file)
    pcall(os.remove, out_file)

    local success = (code == 0 or code == true)
    return success, output
end

--- Normalizes the remote directory path.
local function getRemoteDir(opts)
    local dir = opts.remote_dir or Constants.CLOUD_DEFAULT_REMOTE_DIR or "koreader_backups"
    dir = dir:gsub("^/+", ""):gsub("/+$", "")
    return dir ~= "" and dir or "koreader_backups"
end

--- Tests SFTP connectivity.
function SFTP.testConnection(opts, callback)
    if not SFTP.isAvailable() then
        if callback then
            callback(false, _("SFTP is not available on this device.\nPlease use WebDAV, FTP, or Google Drive instead."))
        end
        return
    end

    local dir = getRemoteDir(opts)
    local cmds = {
        "-mkdir " .. dir,
        "cd " .. dir,
        "pwd",
        "bye",
    }

    local ok, out = runSftpBatch(opts, cmds)
    if ok then
        if callback then callback(true, _("Connection successful!")) end
    else
        local err_msg = string.format(_("SFTP connection failed: %s"), out:match("[^\r\n]+") or out)
        if callback then callback(false, err_msg) end
    end
end

--- Uploads a backup archive via SFTP.
function SFTP.upload(local_path, opts, callback)
    local dir = getRemoteDir(opts)
    local filename = local_path:match("([^/\\]+)$") or "backup.zip"
    local cmds = {
        "-mkdir " .. dir,
        "cd " .. dir,
        string.format("put %q %q", local_path, filename),
        "bye",
    }

    if opts.on_progress then
        opts.on_progress(10, 100, "uploading")
    end

    local ok, out = runSftpBatch(opts, cmds)
    if ok then
        if opts.on_progress then
            opts.on_progress(100, 100, "complete")
        end
        if callback then callback(true, filename) end
    else
        if callback then callback(false, string.format(_("SFTP upload failed: %s"), out:match("[^\r\n]+") or out)) end
    end
end

--- Downloads a remote backup archive via SFTP.
function SFTP.download(remote_filename, local_path, opts, callback)
    local dir = getRemoteDir(opts)
    local cmds = {
        "cd " .. dir,
        string.format("get %q %q", remote_filename, local_path),
        "bye",
    }

    if opts.on_progress then
        opts.on_progress(10, 100, "downloading")
    end

    local ok, out = runSftpBatch(opts, cmds)
    if ok and lfs and lfs.attributes and lfs.attributes(local_path, "mode") == "file" then
        if opts.on_progress then
            opts.on_progress(100, 100, "complete")
        end
        if callback then callback(true, local_path) end
    else
        pcall(os.remove, local_path)
        if callback then callback(false, string.format(_("SFTP download failed: %s"), out:match("[^\r\n]+") or out)) end
    end
end

--- Lists backup archives on the remote SFTP server.
function SFTP.list(opts, callback)
    local dir = getRemoteDir(opts)
    local cmds = {
        "cd " .. dir,
        "ls -l",
        "bye",
    }

    local ok, out = runSftpBatch(opts, cmds)
    if not ok then
        -- Directory may not exist yet
        if callback then callback(true, {}) end
        return
    end

    local files = {}
    for line in out:gmatch("[^\r\n]+") do
        local fn = line:match("([^%s]+%.zip)$") or line:match("([^%s]+%.tar%.gz)$")
        if fn then
            -- Attempt to extract file size (column 5 in standard ls -l)
            local sz = tonumber(line:match("%S+%s+%d+%s+%S+%s+%S+%s+(%d+)")) or 0
            table.insert(files, {
                filename = fn,
                size = sz,
                mtime_str = "",
            })
        end
    end

    table.sort(files, function(a, b)
        return (a.filename or "") > (b.filename or "")
    end)

    if callback then callback(true, files) end
end

--- Deletes a remote backup file on the SFTP server.
function SFTP.delete(remote_filename, opts, callback)
    local dir = getRemoteDir(opts)
    local cmds = {
        "cd " .. dir,
        string.format("rm %q", remote_filename),
        "bye",
    }

    local ok, out = runSftpBatch(opts, cmds)
    if ok or out:find("No such file") then
        if callback then callback(true) end
    else
        if callback then callback(false, "SFTP rm failed: " .. tostring(out)) end
    end
end

return SFTP
