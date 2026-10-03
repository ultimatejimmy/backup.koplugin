--[[--
backup_cloud_webdav.lua
Pure Lua WebDAV client for KOReader Backup.
Supports Nextcloud, ownCloud, Synology, QNAP, and standard WebDAV servers.
--]]

local ok_https, https = pcall(require, "ssl.https")
local ok_http, http = pcall(require, "socket.http")
local ok_ltn, ltn12 = pcall(require, "ltn12")
local ok_mime, mime = pcall(require, "mime")
local ok_su, socketutil = pcall(require, "socketutil")
local ok_util, util = pcall(require, "util")
local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
if not ok_lfs or not lfs then
    ok_lfs, lfs = pcall(require, "lfs")
end
local Localization = require("localization_backup")
local _ = Localization:getHelper()
local Constants = require("backup_constants")

local WebDAV = {}

-- --------------------------------------------------------------------------
-- Base64 Encoding Helper
-- --------------------------------------------------------------------------
local function toBase64(str)
    if ok_mime and mime and mime.b64 then
        return mime.b64(str)
    end
    -- Pure Lua fallback for Base64 encoding
    local b64chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    local result = {}
    for i = 1, #str, 3 do
        local a = string.byte(str, i)
        local b = string.byte(str, i + 1) or 0
        local c = string.byte(str, i + 2) or 0
        local n = (a * 65536) + (b * 256) + c

        local c1 = math.floor(n / 262144) % 64 + 1
        local c2 = math.floor(n / 4096) % 64 + 1
        local c3 = math.floor(n / 64) % 64 + 1
        local c4 = n % 64 + 1

        table.insert(result, b64chars:sub(c1, c1))
        table.insert(result, b64chars:sub(c2, c2))
        table.insert(result, (i + 1 <= #str) and b64chars:sub(c3, c3) or "=")
        table.insert(result, (i + 2 <= #str) and b64chars:sub(c4, c4) or "=")
    end
    return table.concat(result)
end
WebDAV._toBase64 = toBase64

--- Normalizes and cleans a server URL.
local function normalizeUrl(url)
    if not url then return "" end
    url = url:gsub("%s+", "")
    -- If no protocol specified, default to https://
    if not url:match("^https?://") then
        url = "https://" .. url
    end
    -- Strip trailing slashes
    return url:gsub("/+$", "")
end

--- Builds authorization header if credentials exist.
local function buildAuthHeader(username, password)
    if not username or username == "" then return nil end
    local creds = tostring(username) .. ":" .. tostring(password or "")
    return "Basic " .. toBase64(creds)
end

--- Creates a chunked LTN12 source from an open file handle that reports progress.
local function makeFileProgressSource(file_handle, total_expected, on_progress, is_canceled)
    local sent = 0
    local finalized = false
    local chunk_size = 65536
    return function()
        if is_canceled and is_canceled() then
            return nil, "canceled"
        end
        if sent >= total_expected then
            if on_progress and not finalized then
                finalized = true
                on_progress(total_expected, total_expected, "finalizing")
            end
            return nil
        end
        local chunk = file_handle:read(chunk_size)
        if not chunk or #chunk == 0 then
            if on_progress and not finalized then
                finalized = true
                on_progress(total_expected, total_expected, "finalizing")
            end
            return nil
        end
        sent = sent + #chunk
        if on_progress then
            on_progress(math.min(sent, total_expected), total_expected, "uploading")
        end
        if is_canceled and is_canceled() then
            return nil, "canceled"
        end
        return chunk
    end
end

--- Creates a progress-tracking sink for file downloads.
local function makeFileProgressSink(target_sink, on_progress, total_expected, is_canceled)
    local received = 0
    return function(chunk, err)
        if is_canceled and is_canceled() then
            return nil, "canceled"
        end
        if chunk then
            received = received + #chunk
            if on_progress then
                on_progress(received, total_expected)
            end
            if is_canceled and is_canceled() then
                return nil, "canceled"
            end
        end
        return target_sink(chunk, err)
    end
end

--- Performs an HTTP/HTTPS WebDAV request.
local function doRequest(req)
    if not ok_ltn or not ltn12 then
        return nil, "ltn12 module not available"
    end
    local url = req.url or ""
    local is_ssl = url:match("^https://")
    local client = is_ssl and https or http
    if is_ssl and not ok_https then
        return nil, "ssl.https module not available for HTTPS connection"
    end
    if not is_ssl and not ok_http then
        return nil, "socket.http module not available"
    end

    local resp_file_handle = nil
    local resp_body = {}
    local base_sink

    if req.sink_file_path then
        resp_file_handle = io.open(req.sink_file_path, "wb")
        if not resp_file_handle then
            return nil, "Could not open destination file: " .. tostring(req.sink_file_path)
        end
        base_sink = ltn12.sink.file(resp_file_handle)
    else
        base_sink = ltn12.sink.table(resp_body)
    end

    local sink = base_sink
    if req.on_download_progress or req.is_canceled then
        sink = makeFileProgressSink(base_sink, req.on_download_progress, req.total_expected, req.is_canceled)
    end

    local source = req.source
    local file_handle = nil
    local headers = req.headers or {}

    if not source then
        if req.file_path then
            file_handle = io.open(req.file_path, "rb")
            if not file_handle then
                if resp_file_handle then pcall(resp_file_handle.close, resp_file_handle) end
                return nil, "Could not open body file: " .. tostring(req.file_path)
            end
            local total_bytes = req.total_bytes or (file_handle:seek("end") or 0)
            file_handle:seek("set", 0)
            headers["Content-Length"] = tostring(total_bytes)
            if req.on_upload_progress or req.is_canceled then
                source = makeFileProgressSource(file_handle, total_bytes, req.on_upload_progress, req.is_canceled)
            else
                source = ltn12.source.file(file_handle)
            end
        elseif req.body then
            headers["Content-Length"] = tostring(#req.body)
            source = ltn12.source.string(req.body)
        end
    end

    local prev_block, prev_total
    if ok_su and socketutil and socketutil.set_timeout then
        prev_block = socketutil.block_timeout
        prev_total = socketutil.total_timeout
        local block = 30
        local total_bytes = req.total_bytes or req.total_expected or (req.body and #req.body) or 0
        local total = math.max(60, math.min(600, 60 + math.ceil(total_bytes / 50000)))
        pcall(function()
            socketutil:set_timeout(block, total)
        end)
    end

    local ok_call, r, code, resp_headers, status = pcall(client.request, {
        url = url,
        method = req.method or "GET",
        headers = headers,
        source = source,
        sink = sink,
    })

    if file_handle then
        pcall(file_handle.close, file_handle)
        file_handle = nil
    end
    if resp_file_handle then
        pcall(resp_file_handle.close, resp_file_handle)
        resp_file_handle = nil
    end

    if ok_su and socketutil then
        pcall(function()
            if prev_block and prev_total and socketutil.set_timeout then
                socketutil:set_timeout(prev_block, prev_total)
            elseif socketutil.reset_timeout then
                socketutil:reset_timeout()
            end
        end)
    end

    if not ok_call then
        code = tostring(r)
        r = nil
        resp_headers = nil
        status = nil
    end

    local body_str = ""
    if not req.sink_file_path then
        body_str = table.concat(resp_body)
    end

    return r, tonumber(code) or code, resp_headers, status, body_str
end

--- Builds full remote folder URL from server url and remote_dir.
local function getRemoteFolderUrl(opts)
    local base = normalizeUrl(opts.url)
    local dir = opts.remote_dir or Constants.CLOUD_DEFAULT_REMOTE_DIR or "koreader_backups"
    dir = dir:gsub("^/+", ""):gsub("/+$", "")
    if dir == "" then
        return base
    end
    return base .. "/" .. dir
end

--- Tests connectivity and credentials with the WebDAV server.
-- @param opts table: { url, username, password, remote_dir }
-- @param callback function(ok, err_or_msg)
function WebDAV.testConnection(opts, callback)
    local base_url = normalizeUrl(opts.url)
    if base_url == "" then
        if callback then callback(false, _("Server URL is required.")) end
        return
    end

    local auth = buildAuthHeader(opts.username, opts.password)
    local headers = {
        ["Depth"] = "0",
    }
    if auth then headers["Authorization"] = auth end

    -- Send PROPFIND Depth 0 to root
    local r, code, resp_headers, status, body = doRequest{
        url = base_url,
        method = "PROPFIND",
        headers = headers,
        body = '<?xml version="1.0" encoding="utf-8" ?><D:propfind xmlns:D="DAV:"><D:prop><D:resourcetype/></D:prop></D:propfind>',
    }

    if code == 207 or code == 200 then
        -- Also ensure the destination backup directory exists
        WebDAV.ensureFolder(opts, function(ok_folder, err_folder)
            if ok_folder then
                if callback then callback(true, _("Connection successful!")) end
            else
                if callback then callback(false, string.format(_("Connected to server, but could not create folder: %s"), tostring(err_folder))) end
            end
        end)
        return
    elseif code == 401 or code == 403 then
        if callback then callback(false, _("Authentication failed. Please verify your username and password.")) end
        return
    elseif code == 405 then
        -- Some servers don't allow PROPFIND on root; try GET / OPTIONS
        local r2, code2 = doRequest{
            url = base_url,
            method = "OPTIONS",
            headers = headers,
        }
        if code2 == 200 or code2 == 204 then
            WebDAV.ensureFolder(opts, function(ok_folder, err_folder)
                if ok_folder then
                    if callback then callback(true, _("Connection successful!")) end
                else
                    if callback then callback(false, tostring(err_folder)) end
                end
            end)
            return
        end
    end

    local err_msg = string.format(_("Could not connect to WebDAV server (HTTP %s)."), tostring(code))
    if callback then callback(false, err_msg) end
end

--- Ensures the remote folder exists, creating it with MKCOL if necessary.
-- @param opts table: { url, username, password, remote_dir }
-- @param callback function(ok, err)
function WebDAV.ensureFolder(opts, callback)
    local base_url = normalizeUrl(opts.url)
    local dir = opts.remote_dir or Constants.CLOUD_DEFAULT_REMOTE_DIR or "koreader_backups"
    dir = dir:gsub("^/+", ""):gsub("/+$", "")
    if dir == "" then
        if callback then callback(true) end
        return
    end

    local auth = buildAuthHeader(opts.username, opts.password)
    local segments = {}
    for seg in dir:gmatch("[^/]+") do
        table.insert(segments, seg)
    end

    local current_url = base_url
    local function createNext(idx)
        if idx > #segments then
            if callback then callback(true) end
            return
        end
        current_url = current_url .. "/" .. segments[idx]

        local headers = { ["Depth"] = "0" }
        if auth then headers["Authorization"] = auth end

        -- Check if exists via PROPFIND
        local r, code = doRequest{
            url = current_url,
            method = "PROPFIND",
            headers = headers,
        }

        if code == 207 or code == 200 then
            createNext(idx + 1)
        else
            -- Attempt MKCOL
            local r_mk, code_mk = doRequest{
                url = current_url,
                method = "MKCOL",
                headers = headers,
            }
            if code_mk == 201 or code_mk == 200 or code_mk == 405 then
                -- 405 Method Not Allowed means collection already exists
                createNext(idx + 1)
            else
                local err_msg = string.format("Failed to create folder '%s' (HTTP %s)", segments[idx], tostring(code_mk))
                if callback then callback(false, err_msg) end
            end
        end
    end

    createNext(1)
end

--- Uploads a local file to the WebDAV remote directory.
-- @param local_path string
-- @param opts table: { url, username, password, remote_dir, on_progress }
-- @param callback function(ok, result_or_err)
function WebDAV.upload(local_path, opts, callback)
    WebDAV.ensureFolder(opts, function(ok_folder, err_folder)
        if not ok_folder then
            if callback then callback(false, err_folder) end
            return
        end

        local filename = local_path:match("([^/\\]+)$") or "backup.zip"
        local folder_url = getRemoteFolderUrl(opts)
        local upload_url = folder_url .. "/" .. filename

        local file_size = 0
        if lfs and lfs.attributes then
            file_size = lfs.attributes(local_path, "size") or 0
        else
            local f = io.open(local_path, "rb")
            if f then file_size = f:seek("end") or 0; f:close() end
        end

        local auth = buildAuthHeader(opts.username, opts.password)
        local headers = {
            ["Content-Type"] = "application/zip",
        }
        if auth then headers["Authorization"] = auth end

        local r, code, resp_headers, status, body = doRequest{
            url = upload_url,
            method = "PUT",
            headers = headers,
            file_path = local_path,
            total_bytes = file_size,
            on_upload_progress = opts.on_progress,
            is_canceled = opts.is_canceled,
        }

        if (opts.is_canceled and opts.is_canceled()) or tostring(code):find("canceled") then
            if callback then callback(false, "canceled") end
            return
        end

        if code == 200 or code == 201 or code == 204 then
            if callback then callback(true, upload_url) end
        else
            local err_msg = string.format(_("WebDAV upload failed (HTTP %s): %s"), tostring(code), tostring(body))
            if callback then callback(false, err_msg) end
        end
    end)
end

--- Downloads a remote file from WebDAV to a local path.
-- @param remote_filename string
-- @param local_path string
-- @param opts table: { url, username, password, remote_dir, on_progress }
-- @param callback function(ok, local_path_or_err)
function WebDAV.download(remote_filename, local_path, opts, callback)
    local folder_url = getRemoteFolderUrl(opts)
    local file_url = folder_url .. "/" .. remote_filename
    local auth = buildAuthHeader(opts.username, opts.password)

    -- First probe file size via HEAD request if possible
    local head_headers = {}
    if auth then head_headers["Authorization"] = auth end
    local r_h, code_h, resp_h = doRequest{
        url = file_url,
        method = "HEAD",
        headers = head_headers,
    }
    local total_expected = 0
    if resp_h and resp_h["content-length"] then
        total_expected = tonumber(resp_h["content-length"]) or 0
    end

    local get_headers = {}
    if auth then get_headers["Authorization"] = auth end

    local r, code, headers, status = doRequest{
        url = file_url,
        method = "GET",
        headers = get_headers,
        sink_file_path = local_path,
        total_expected = total_expected,
        on_download_progress = opts.on_progress,
        is_canceled = opts.is_canceled,
    }

    if (opts.is_canceled and opts.is_canceled()) or tostring(code):find("canceled") then
        pcall(os.remove, local_path)
        if callback then callback(false, "canceled") end
        return
    end

    if code == 200 then
        if callback then callback(true, local_path) end
    else
        pcall(os.remove, local_path)
        local err_msg = string.format(_("WebDAV download failed (HTTP %s)"), tostring(code))
        if callback then callback(false, err_msg) end
    end
end

--- Parses WebDAV XML PROPFIND response to extract file entries.
local function parsePropfindXml(xml)
    local files = {}
    if not xml or xml == "" then return files end

    -- Match each <D:response> or <d:response> or <response>
    for response_block in xml:gmatch("<[%w_-]*:?response.->(.-)</[%w_-]*:?response>") do
        local href = response_block:match("<[%w_-]*:?href.->(.-)</[%w_-]*:?href>") or ""
        -- Decode URL-encoded href
        href = href:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end)
        local filename = href:match("([^/]+)/?$") or ""

        local is_collection = response_block:find("<[%w_-]*:?collection") ~= nil
        local size_str = response_block:match("<[%w_-]*:?getcontentlength.->(%d+)</[%w_-]*:?getcontentlength>")
        local size = tonumber(size_str) or 0
        local mtime_str = response_block:match("<[%w_-]*:?getlastmodified.->(.-)</[%w_-]*:?getlastmodified>") or ""

        -- Only include backup files (.zip or .tar.gz) and not the folder itself
        if not is_collection and filename ~= "" and (filename:match("%.zip$") or filename:match("%.tar%.gz$")) then
            table.insert(files, {
                filename = filename,
                size = size,
                mtime_str = mtime_str,
                url = href,
            })
        end
    end

    -- Sort newest first
    table.sort(files, function(a, b)
        return (a.filename or "") > (b.filename or "")
    end)
    return files
end
WebDAV._parsePropfindXml = parsePropfindXml

--- Lists all backup files in the remote WebDAV directory.
-- @param opts table: { url, username, password, remote_dir }
-- @param callback function(ok, list_of_backups_or_err)
function WebDAV.list(opts, callback)
    local folder_url = getRemoteFolderUrl(opts)
    local auth = buildAuthHeader(opts.username, opts.password)
    local headers = {
        ["Depth"] = "1",
    }
    if auth then headers["Authorization"] = auth end

    local propfind_body = '<?xml version="1.0" encoding="utf-8" ?>'
        .. '<D:propfind xmlns:D="DAV:">'
        .. '<D:prop>'
        .. '<D:displayname/>'
        .. '<D:resourcetype/>'
        .. '<D:getcontentlength/>'
        .. '<D:getlastmodified/>'
        .. '</D:prop>'
        .. '</D:propfind>'

    local r, code, resp_headers, status, body = doRequest{
        url = folder_url,
        method = "PROPFIND",
        headers = headers,
        body = propfind_body,
    }

    if code == 207 or code == 200 then
        local files = parsePropfindXml(body)
        if callback then callback(true, files) end
    elseif code == 404 then
        -- Folder does not exist yet; return empty list
        if callback then callback(true, {}) end
    else
        local err_msg = string.format(_("Failed to list remote backups (HTTP %s)"), tostring(code))
        if callback then callback(false, err_msg) end
    end
end

--- Deletes a remote backup file.
-- @param remote_filename string
-- @param opts table: { url, username, password, remote_dir }
-- @param callback function(ok, err)
function WebDAV.delete(remote_filename, opts, callback)
    local folder_url = getRemoteFolderUrl(opts)
    local file_url = folder_url .. "/" .. remote_filename
    local auth = buildAuthHeader(opts.username, opts.password)
    local headers = {}
    if auth then headers["Authorization"] = auth end

    local r, code = doRequest{
        url = file_url,
        method = "DELETE",
        headers = headers,
    }

    if code == 200 or code == 204 or code == 404 then
        if callback then callback(true) end
    else
        local err_msg = string.format(_("Failed to delete remote backup (HTTP %s)"), tostring(code))
        if callback then callback(false, err_msg) end
    end
end

return WebDAV
