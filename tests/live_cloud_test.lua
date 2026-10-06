-- live_cloud_test.lua
-- On-demand live integration test for WebDAV and FTP against real local servers.

local AppDir = os.getenv("KOREADER_APP_DIR") or "/home/jimmy/squashfs-root/usr/lib/koreader"
package.path = package.path .. ";./backup.koplugin/?.lua;backup.koplugin/backup.koplugin/?.lua;./?.lua"
package.path = package.path .. ";" .. AppDir .. "/?.lua"
package.path = package.path .. ";" .. AppDir .. "/common/?.lua"
package.path = package.path .. ";" .. AppDir .. "/libs/?.lua"
package.path = package.path .. ";" .. AppDir .. "/frontend/?.lua"

package.cpath = package.cpath .. ";" .. AppDir .. "/libs/?.so"
package.cpath = package.cpath .. ";" .. AppDir .. "/libs/libkoreader-?.so"
package.cpath = package.cpath .. ";" .. AppDir .. "/common/?.so"
package.cpath = package.cpath .. ";" .. AppDir .. "/?.so"

-- Lightweight mocks for KOReader globals (keeping real socket networking)
package.loaded["gettext"] = function(str) return str end
package.loaded["logger"] = {
    info = function(...) end,
    warn = function(...) end,
    dbg = function(...) end,
    error = function(...) end,
}
package.loaded["datastorage"] = {
    getDataDir = function() return "/tmp/koreader_live_test" end,
}
package.loaded["util"] = {
    makePath = function(p) os.execute("mkdir -p \"" .. p .. "\" 2>/dev/null") return true end,
    removeFile = os.remove,
}
_G.G_reader_settings = {
    data = {},
    readSetting = function(s, k) return s.data[k] end,
    saveSetting = function(s, k, v) s.data[k] = v end,
    flush = function() end,
}

local ok_dk, dkjson = pcall(require, "dkjson")
if ok_dk and dkjson then
    package.loaded["json"] = dkjson
end

local WebDAV = require("backup_cloud_webdav")
local FTP = require("backup_cloud_ftp")
local Constants = require("backup_constants")
local Cloud = require("backup_cloud")

local webdav_port = os.getenv("TEST_WEBDAV_PORT") or "8080"
local ftp_port = tonumber(os.getenv("TEST_FTP_PORT")) or 2121

print("=== Running Live Cloud Integration Tests ===")
print("WebDAV target: http://127.0.0.1:" .. webdav_port)
print("FTP target:    127.0.0.1:" .. tostring(ftp_port))

local function create_temp_file(name, content)
    local path = "/tmp/" .. name
    local f = io.open(path, "wb")
    if f then
        f:write(content or "KOReader Backup Test Payload\n")
        f:close()
        return path
    end
    return nil
end

local function run_async(desc, fn)
    local done = false
    local res_ok, res_val
    io.write("  Testing " .. desc .. "... ")
    io.flush()
    fn(function(ok, val)
        res_ok = ok
        res_val = val
        done = true
    end)
    if not done then
        print("FAILED (Callback not called synchronously)")
        return false
    end
    if res_ok then
        print("PASSED (" .. tostring(res_val or "OK") .. ")")
        return true
    else
        print("FAILED: " .. tostring(res_val))
        return false
    end
end

local all_passed = true

-- 1. WebDAV Live Tests
local webdav_creds = {
    url = "http://127.0.0.1:" .. webdav_port,
    username = "testuser",
    password = "testpassword",
    remote_dir = "koreader_backups",
}

all_passed = run_async("WebDAV testConnection", function(cb)
    WebDAV.testConnection(webdav_creds, cb)
end) and all_passed

local sample_file = create_temp_file("koreader_live_backup.zip", "DUMMY_ZIP_DATA_FOR_INTEGRATION_TEST")

all_passed = run_async("WebDAV upload", function(cb)
    WebDAV.upload(sample_file, webdav_creds, cb)
end) and all_passed

all_passed = run_async("WebDAV list", function(cb)
    WebDAV.list(webdav_creds, function(ok, items)
        if not ok or not items then
            cb(false, "List failed")
            return
        end
        local found = false
        for _, item in ipairs(items) do
            if item.filename == "koreader_live_backup.zip" then
                found = true
                break
            end
        end
        if found then
            cb(true, string.format("Found %d items", #items))
        else
            cb(false, "Uploaded file not found in listing")
        end
    end)
end) and all_passed

local download_dest = "/tmp/koreader_downloaded.zip"
all_passed = run_async("WebDAV download", function(cb)
    WebDAV.download("koreader_live_backup.zip", download_dest, webdav_creds, function(ok, res)
        if not ok then
            cb(false, res)
            return
        end
        local f = io.open(download_dest, "rb")
        if f then
            local data = f:read("*a")
            f:close()
            os.remove(download_dest)
            if data == "DUMMY_ZIP_DATA_FOR_INTEGRATION_TEST" then
                cb(true, "Data matches (" .. #data .. " bytes)")
            else
                cb(false, "Data mismatch")
            end
        else
            cb(false, "Could not open downloaded file")
        end
    end)
end) and all_passed

all_passed = run_async("WebDAV delete", function(cb)
    WebDAV.delete("koreader_live_backup.zip", webdav_creds, cb)
end) and all_passed

-- 2. FTP Live Tests
local ftp_creds = {
    host = "127.0.0.1",
    port = ftp_port,
    username = "testuser",
    password = "testpassword",
    remote_dir = "koreader_backups",
}

all_passed = run_async("FTP testConnection", function(cb)
    FTP.testConnection(ftp_creds, cb)
end) and all_passed

all_passed = run_async("FTP upload", function(cb)
    FTP.upload(sample_file, ftp_creds, cb)
end) and all_passed

all_passed = run_async("FTP list", function(cb)
    FTP.list(ftp_creds, function(ok, items)
        if not ok or not items then
            cb(false, "FTP list failed")
            return
        end
        local found = false
        for _, item in ipairs(items) do
            if item.filename == "koreader_live_backup.zip" then
                found = true
                break
            end
        end
        if found then
            cb(true, string.format("Found %d items", #items))
        else
            cb(false, "Uploaded file not found in FTP listing")
        end
    end)
end) and all_passed

local ftp_download_dest = "/tmp/koreader_ftp_downloaded.zip"
all_passed = run_async("FTP download", function(cb)
    FTP.download("koreader_live_backup.zip", ftp_download_dest, ftp_creds, function(ok, res)
        if not ok then
            cb(false, res)
            return
        end
        local f = io.open(ftp_download_dest, "rb")
        if f then
            local data = f:read("*a")
            f:close()
            os.remove(ftp_download_dest)
            if data == "DUMMY_ZIP_DATA_FOR_INTEGRATION_TEST" then
                cb(true, "Data matches (" .. #data .. " bytes)")
            else
                cb(false, "Data mismatch")
            end
        else
            cb(false, "Could not open downloaded file")
        end
    end)
end) and all_passed

all_passed = run_async("FTP delete", function(cb)
    FTP.delete("koreader_live_backup.zip", ftp_creds, cb)
end) and all_passed

if sample_file then os.remove(sample_file) end

print("\n=== Live Integration Results ===")
if all_passed then
    print("ALL LIVE INTEGRATION TESTS PASSED SUCCESSFULLY!")
    os.exit(0)
else
    print("SOME LIVE INTEGRATION TESTS FAILED.")
    os.exit(1)
end
