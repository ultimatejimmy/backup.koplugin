--[[--
backup_cloud_dropbox.lua
Dropbox (Dropbox API v2) driver for KOReader Backup.
Uses OAuth2 Bearer tokens with streamed uploads and downloads.
Supports App Folder mode (sandboxed under /Apps/<AppName>/) and Full Dropbox mode.
--]]

local ok_https, https = pcall(require, "ssl.https")
local ok_http, http = pcall(require, "socket.http")
local ok_ltn, ltn12 = pcall(require, "ltn12")
local ok_json, json = pcall(require, "json")
if not ok_json or not json then
    ok_json, json = pcall(require, "dkjson")
end
local ok_su, socketutil = pcall(require, "socketutil")
local ok_util, util = pcall(require, "util")
local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
if not ok_lfs or not lfs then
    ok_lfs, lfs = pcall(require, "lfs")
end
local Localization = require("localization_backup")
local _ = Localization:getHelper()
local Constants = require("backup_constants")
local OAuth = require("backup_cloud_oauth")

local Dropbox = {}

local DROPBOX_API_BASE = "https://api.dropboxapi.com/2"
local DROPBOX_CONTENT_BASE = "https://content.dropboxapi.com/2"

--- Resolves remote folder path for Dropbox API v2.
-- In App Folder mode, root is "" (empty string).
-- Subfolders are represented as "/subfolder".
local function resolveFolderPath(folder_name)
    if not folder_name or folder_name == "" or folder_name == "/" then
        return ""
    end
    local clean = folder_name:gsub("^/+", ""):gsub("/+$", "")
    if clean == "" then return "" end
    return "/" .. clean
end

--- Resolves remote file path for Dropbox API v2.
-- Must always start with a forward slash.
local function resolveFilePath(folder_name, filename)
    filename = filename:match("([^/\\]+)$") or filename
    local folder_path = resolveFolderPath(folder_name)
    if folder_path == "" then
        return "/" .. filename
    else
        return folder_path .. "/" .. filename
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

--- Creates a progress-tracking source for file uploads.
local function makeUploadProgressSource(file_handle, file_size, on_progress, is_canceled)
    local sent = 0
    return function()
        if is_canceled and is_canceled() then
            return nil, "canceled"
        end
        local chunk = file_handle:read(32768) -- 32 KB chunks
        if chunk and #chunk > 0 then
            sent = sent + #chunk
            if on_progress then
                on_progress(sent, file_size, "uploading")
            end
            if is_canceled and is_canceled() then
                return nil, "canceled"
            end
            return chunk
        end
        return nil
    end
end

--- Executes an HTTP/HTTPS request to Dropbox API.
local function doDropboxRequest(req)
    if not ok_ltn or not ltn12 then
        return nil, "ltn12 module not available"
    end
    if not ok_https then
        return nil, "ssl.https module not available for HTTPS connection"
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
    local headers = req.headers or {}

    if not source and req.body then
        headers["Content-Length"] = tostring(#req.body)
        source = ltn12.source.string(req.body)
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

    local url = req.url
    local is_ssl = url:match("^https://")
    local client = is_ssl and https or http

    local ok_call, r, code, resp_headers, status = pcall(client.request, {
        url = url,
        method = req.method or "POST",
        headers = headers,
        source = source,
        sink = sink,
    })

    if resp_file_handle then
        pcall(function() resp_file_handle:close() end)
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

    return r, code, resp_headers, status, body_str
end

--- Checks if Dropbox credentials/tokens are configured.
function Dropbox.isConfigured()
    local tok = OAuth.loadTokens(Constants.CLOUD_PROVIDERS.DROPBOX)
    return (tok and tok.access_token ~= nil and tok.access_token ~= "")
end

--- Uploads a local backup archive to Dropbox.
-- @param local_path string
-- @param opts table: { remote_dir, on_progress, is_retry }
-- @param callback function(ok, file_id_or_err)
function Dropbox.upload(local_path, opts, callback)
    opts = opts or {}
    OAuth.getValidAccessToken(Constants.CLOUD_PROVIDERS.DROPBOX, function(ok_tok, token_or_err)
        if not ok_tok then
            if callback then callback(false, token_or_err) end
            return
        end

        local token = token_or_err
        local filename = local_path:match("([^/\\]+)$") or "backup.zip"
        local folder_name = opts.remote_dir or Constants.CLOUD_DEFAULT_REMOTE_DIR or ""
        local remote_path = resolveFilePath(folder_name, filename)

        local file_size = 0
        if lfs and lfs.attributes then
            file_size = lfs.attributes(local_path, "size") or 0
        else
            local f = io.open(local_path, "rb")
            if f then file_size = f:seek("end") or 0; f:close() end
        end

        if file_size <= 0 then
            if callback then callback(false, "Cannot upload empty or non-existent file") end
            return
        end

        if opts.on_progress then
            opts.on_progress(0, file_size, "connecting")
        end

        local f_upload = io.open(local_path, "rb")
        if not f_upload then
            if callback then callback(false, "Could not read file: " .. tostring(local_path)) end
            return
        end

        local upload_url = DROPBOX_CONTENT_BASE .. "/files/upload"
        local arg_json = (json and json.encode and json.encode({
            path = remote_path,
            mode = "overwrite",
            autorename = false,
            mute = false,
        })) or string.format('{"path":%q,"mode":"overwrite","autorename":false,"mute":false}', remote_path)

        if opts.is_canceled and opts.is_canceled() then
            f_upload:close()
            if callback then callback(false, "canceled") end
            return
        end

        local source = makeUploadProgressSource(f_upload, file_size, opts.on_progress, opts.is_canceled)
        local r, code, headers, status, body = doDropboxRequest{
            url = upload_url,
            method = "POST",
            headers = {
                ["Authorization"] = "Bearer " .. token,
                ["Dropbox-API-Arg"] = arg_json,
                ["Content-Type"] = "application/octet-stream",
                ["Content-Length"] = tostring(file_size),
            },
            source = source,
            total_bytes = file_size,
            is_canceled = opts.is_canceled,
        }
        f_upload:close()

        if (opts.is_canceled and opts.is_canceled()) or tostring(code):find("canceled") then
            if callback then callback(false, "canceled") end
            return
        end

        local num_code = tonumber(code) or code
        if (num_code == 200 or num_code == 201) and body and body ~= "" then
            local data = nil
            if json and json.decode then pcall(function() data = json.decode(body) end) end
            if callback then callback(true, (data and (data.id or data.path_display)) or remote_path) end
            return
        elseif num_code == 401 and not opts.is_retry then
            -- Token expired; refresh and retry once
            OAuth.refreshToken(Constants.CLOUD_PROVIDERS.DROPBOX, nil, function(ok_ref, ref_res)
                if ok_ref then
                    local retry_opts = {}
                    for k, v in pairs(opts) do retry_opts[k] = v end
                    retry_opts.is_retry = true
                    Dropbox.upload(local_path, retry_opts, callback)
                else
                    local err_msg = string.format(_("Upload failed (HTTP %s): %s"), tostring(code), tostring(body))
                    if callback then callback(false, err_msg) end
                end
            end)
            return
        else
            local err_msg = string.format(_("Upload failed (HTTP %s): %s"), tostring(code), tostring(body))
            if callback then callback(false, err_msg) end
        end
    end)
end

--- Downloads a remote backup file from Dropbox.
-- @param remote_item table or string: { path, filename, size } or remote path
-- @param local_path string
-- @param opts table: { remote_dir, on_progress, is_retry }
-- @param callback function(ok, local_path_or_err)
function Dropbox.download(remote_item, local_path, opts, callback)
    opts = opts or {}
    OAuth.getValidAccessToken(Constants.CLOUD_PROVIDERS.DROPBOX, function(ok_tok, token_or_err)
        if not ok_tok then
            if callback then callback(false, token_or_err) end
            return
        end

        local token = token_or_err
        local remote_path = ""
        local total_size = 0

        if type(remote_item) == "table" then
            remote_path = remote_item.path or remote_item.file_id or resolveFilePath(opts.remote_dir, remote_item.filename)
            total_size = tonumber(remote_item.size) or 0
        else
            remote_path = tostring(remote_item)
            if not remote_path:match("^/") and not remote_path:match("^id:") then
                remote_path = resolveFilePath(opts.remote_dir, remote_path)
            end
        end

        local dl_url = DROPBOX_CONTENT_BASE .. "/files/download"
        local arg_json = (json and json.encode and json.encode({ path = remote_path }))
            or string.format('{"path":%q}', remote_path)

        local r_d, code_d, headers_d, status_d = doDropboxRequest{
            url = dl_url,
            method = "POST",
            headers = {
                ["Authorization"] = "Bearer " .. token,
                ["Dropbox-API-Arg"] = arg_json,
            },
            sink_file_path = local_path,
            total_expected = total_size,
            on_download_progress = opts.on_progress,
            is_canceled = opts.is_canceled,
        }

        if (opts.is_canceled and opts.is_canceled()) or tostring(code_d):find("canceled") then
            pcall(os.remove, local_path)
            if callback then callback(false, "canceled") end
            return
        end

        local num_code_d = tonumber(code_d) or code_d
        if num_code_d == 200 then
            if callback then callback(true, local_path) end
            return
        elseif num_code_d == 401 and not opts.is_retry then
            pcall(os.remove, local_path)
            OAuth.refreshToken(Constants.CLOUD_PROVIDERS.DROPBOX, nil, function(ok_ref, ref_res)
                if ok_ref then
                    local retry_opts = {}
                    for k, v in pairs(opts) do retry_opts[k] = v end
                    retry_opts.is_retry = true
                    Dropbox.download(remote_item, local_path, retry_opts, callback)
                else
                    local err_msg = string.format(_("Download failed (HTTP %s): %s"), tostring(code_d), tostring(ref_res))
                    if callback then callback(false, err_msg) end
                end
            end)
            return
        else
            pcall(os.remove, local_path)
            local err_msg = string.format(_("Download failed (HTTP %s): %s"), tostring(code_d), tostring(status_d or ""))
            if callback then callback(false, err_msg) end
        end
    end)
end

--- Lists backup archives in the Dropbox backup folder.
-- @param opts table: { remote_dir, is_retry }
-- @param callback function(ok, list_or_err)
function Dropbox.list(opts, callback)
    opts = opts or {}
    OAuth.getValidAccessToken(Constants.CLOUD_PROVIDERS.DROPBOX, function(ok_tok, token_or_err)
        if not ok_tok then
            if callback then callback(false, token_or_err) end
            return
        end

        local token = token_or_err
        local folder_name = opts.remote_dir or Constants.CLOUD_DEFAULT_REMOTE_DIR or ""
        local folder_path = resolveFolderPath(folder_name)

        local list_url = DROPBOX_API_BASE .. "/files/list_folder"
        local req_body = (json and json.encode and json.encode({
            path = folder_path,
            recursive = false,
            include_deleted = false,
        })) or string.format('{"path":%q,"recursive":false,"include_deleted":false}', folder_path)

        local r, code, headers, status, body = doDropboxRequest{
            url = list_url,
            method = "POST",
            headers = {
                ["Authorization"] = "Bearer " .. token,
                ["Content-Type"] = "application/json",
            },
            body = req_body,
        }

        local num_code = tonumber(code) or code
        if (num_code == 200 or num_code == 201) and body and body ~= "" then
            local data = nil
            if json and json.decode then pcall(function() data = json.decode(body) end) end
            local files = {}
            for _, item in ipairs(data and data.entries or {}) do
                local fn = item.name or ""
                if item[".tag"] == "file" and (fn:match("%.zip$") or fn:match("%.tar%.gz$")) then
                    local sz = tonumber(item.size) or 0
                    table.insert(files, {
                        filename = fn,
                        file_id = item.id or item.path_lower or ("/" .. fn),
                        path = item.path_lower or item.path_display or ("/" .. fn),
                        size = sz,
                        size_str = (util and util.getFriendlySize and sz > 0) and util.getFriendlySize(sz) or (sz .. " B"),
                        mtime_str = item.client_modified or item.server_modified or "",
                    })
                end
            end
            table.sort(files, function(a, b)
                return (a.mtime_str or "") > (b.mtime_str or "")
            end)
            if callback then callback(true, files) end
            return
        elseif num_code == 409 then
            -- Folder does not exist yet; return empty list cleanly
            if callback then callback(true, {}) end
            return
        elseif num_code == 401 and not opts.is_retry then
            OAuth.refreshToken(Constants.CLOUD_PROVIDERS.DROPBOX, nil, function(ok_ref, ref_res)
                if ok_ref then
                    local retry_opts = {}
                    for k, v in pairs(opts) do retry_opts[k] = v end
                    retry_opts.is_retry = true
                    Dropbox.list(retry_opts, callback)
                else
                    local err_msg = string.format(_("Download failed (HTTP %s): %s"), tostring(code), tostring(body))
                    if callback then callback(false, err_msg) end
                end
            end)
            return
        else
            local err_msg = string.format(_("Download failed (HTTP %s): %s"), tostring(code), tostring(body))
            if callback then callback(false, err_msg) end
        end
    end)
end

--- Deletes a remote backup file in Dropbox.
-- @param file_id_or_name string
-- @param opts table: { remote_dir, is_retry }
-- @param callback function(ok, err)
function Dropbox.delete(file_id_or_name, opts, callback)
    opts = opts or {}
    OAuth.getValidAccessToken(Constants.CLOUD_PROVIDERS.DROPBOX, function(ok_tok, token_or_err)
        if not ok_tok then
            if callback then callback(false, token_or_err) end
            return
        end

        local token = token_or_err
        local path_to_del = file_id_or_name
        if type(file_id_or_name) == "table" then
            path_to_del = file_id_or_name.path or file_id_or_name.file_id or resolveFilePath(opts.remote_dir, file_id_or_name.filename)
        elseif not path_to_del:match("^/") and not path_to_del:match("^id:") then
            path_to_del = resolveFilePath(opts.remote_dir, file_id_or_name)
        end

        local del_url = DROPBOX_API_BASE .. "/files/delete_v2"
        local req_body = (json and json.encode and json.encode({ path = path_to_del }))
            or string.format('{"path":%q}', path_to_del)

        local r, code, headers, status, body = doDropboxRequest{
            url = del_url,
            method = "POST",
            headers = {
                ["Authorization"] = "Bearer " .. token,
                ["Content-Type"] = "application/json",
            },
            body = req_body,
        }

        local num_code = tonumber(code) or code
        if num_code == 200 or num_code == 201 then
            if callback then callback(true) end
            return
        elseif num_code == 401 and not opts.is_retry then
            OAuth.refreshToken(Constants.CLOUD_PROVIDERS.DROPBOX, nil, function(ok_ref, ref_res)
                if ok_ref then
                    local retry_opts = {}
                    for k, v in pairs(opts) do retry_opts[k] = v end
                    retry_opts.is_retry = true
                    Dropbox.delete(file_id_or_name, retry_opts, callback)
                else
                    if callback then callback(false, tostring(body)) end
                end
            end)
            return
        else
            if callback then callback(false, string.format("Dropbox delete failed (HTTP %s): %s", tostring(code), tostring(body))) end
        end
    end)
end

--- Tests connectivity and verifies account credentials with Dropbox.
-- @param opts table or callback
-- @param callback function(ok, message)
function Dropbox.testConnection(opts, callback)
    if type(opts) == "function" then
        callback = opts
        opts = {}
    end
    opts = opts or {}

    OAuth.getValidAccessToken(Constants.CLOUD_PROVIDERS.DROPBOX, function(ok_tok, token_or_err)
        if not ok_tok then
            if callback then callback(false, token_or_err) end
            return
        end

        local token = token_or_err
        local test_url = DROPBOX_API_BASE .. "/users/get_current_account"

        local r, code, headers, status, body = doDropboxRequest{
            url = test_url,
            method = "POST",
            headers = {
                ["Authorization"] = "Bearer " .. token,
            },
            body = "null",
        }

        local num_code = tonumber(code) or code
        if (num_code == 200 or num_code == 201) and body and body ~= "" then
            local data = nil
            if json and json.decode then pcall(function() data = json.decode(body) end) end
            local display_name = (data and data.name and data.name.display_name) or "Dropbox User"
            local email = (data and data.email) or ""
            local msg = (email ~= "" and display_name ~= "")
                and (string.format("%s: %s (%s)", _("Connection successful!"), display_name, email))
                or _("Connection successful!")
            if callback then callback(true, msg) end
            return
        elseif num_code == 401 and not opts.is_retry then
            OAuth.refreshToken(Constants.CLOUD_PROVIDERS.DROPBOX, nil, function(ok_ref, ref_res)
                if ok_ref then
                    local retry_opts = {}
                    for k, v in pairs(opts) do retry_opts[k] = v end
                    retry_opts.is_retry = true
                    Dropbox.testConnection(retry_opts, callback)
                else
                    if callback then callback(false, _("Connection failed")) end
                end
            end)
            return
        else
            if callback then callback(false, _("Connection failed")) end
        end
    end)
end

return Dropbox
