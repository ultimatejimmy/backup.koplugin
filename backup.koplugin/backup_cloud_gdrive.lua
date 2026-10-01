--[[--
backup_cloud_gdrive.lua
Google Drive v3 REST API driver for KOReader Backup.
Uses OAuth2 Bearer tokens with Drive resumable upload for low memory consumption.
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

local GDrive = {}

local DRIVE_API_BASE = "https://www.googleapis.com/drive/v3"
local DRIVE_UPLOAD_BASE = "https://www.googleapis.com/upload/drive/v3"

--- Creates a chunked LTN12 source from an open file handle that reports progress.
local function makeFileProgressSource(file_handle, total_expected, on_progress)
    local sent = 0
    local finalized = false
    local chunk_size = 65536
    return function()
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
        return chunk
    end
end

--- Creates a progress-tracking sink for file downloads.
local function makeFileProgressSink(target_sink, on_progress, total_expected)
    local received = 0
    return function(chunk, err)
        if chunk then
            received = received + #chunk
            if on_progress then
                on_progress(received, total_expected)
            end
        end
        return target_sink(chunk, err)
    end
end

--- Executes an HTTPS request to Google Drive API.
local function doDriveRequest(req)
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
    if req.on_download_progress then
        sink = makeFileProgressSink(base_sink, req.on_download_progress, req.total_expected)
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
            if req.on_upload_progress then
                source = makeFileProgressSource(file_handle, total_bytes, req.on_upload_progress)
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

    local ok_call, r, code, resp_headers, status = pcall(https.request, {
        url = req.url,
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

local _folder_id_cache = nil

--- Resolves or creates the remote folder in Google Drive.
-- @param token string: OAuth2 access token
-- @param folder_name string: e.g. "koreader_backups"
-- @param callback function(ok, folder_id_or_err)
local function ensureFolder(token, folder_name, callback)
    if _folder_id_cache then
        if callback then callback(true, _folder_id_cache) end
        return
    end

    folder_name = folder_name or Constants.CLOUD_DEFAULT_REMOTE_DIR or "koreader_backups"
    folder_name = folder_name:gsub("^/+", ""):gsub("/+$", "")

    -- Search for existing folder
    local query = string.format("name='%s' and mimeType='application/vnd.google-apps.folder' and trashed=false", folder_name)
    local search_url = DRIVE_API_BASE .. "/files?q=" .. OAuth.urlEncode(query) .. "&fields=" .. OAuth.urlEncode("files(id,name)")

    local r, code, headers, status, body = doDriveRequest{
        url = search_url,
        method = "GET",
        headers = {
            ["Authorization"] = "Bearer " .. token,
        },
    }

    if (code == 200 or code == 201) and body and body ~= "" then
        local data = nil
        if json and json.decode then pcall(function() data = json.decode(body) end) end
        if data and data.files and #data.files > 0 then
            _folder_id_cache = data.files[1].id
            if callback then callback(true, _folder_id_cache) end
            return
        end
    end

    -- Folder not found; create it
    local create_url = DRIVE_API_BASE .. "/files"
    local meta = {
        name = folder_name,
        mimeType = "application/vnd.google-apps.folder",
    }
    local meta_json = json and json.encode and json.encode(meta) or string.format('{"name":%q,"mimeType":"application/vnd.google-apps.folder"}', folder_name)

    local r_c, code_c, h_c, s_c, body_c = doDriveRequest{
        url = create_url,
        method = "POST",
        headers = {
            ["Authorization"] = "Bearer " .. token,
            ["Content-Type"] = "application/json; charset=UTF-8",
        },
        body = meta_json,
    }

    if (code_c == 200 or code_c == 201) and body_c and body_c ~= "" then
        local data_c = nil
        if json and json.decode then pcall(function() data_c = json.decode(body_c) end) end
        if data_c and data_c.id then
            _folder_id_cache = data_c.id
            if callback then callback(true, _folder_id_cache) end
            return
        end
    end

    local err_msg = string.format(_("Could not create Google Drive folder '%s' (HTTP %s): %s"), folder_name, tostring(code_c), tostring(body_c))
    if callback then callback(false, err_msg) end
end
GDrive.ensureFolder = ensureFolder

--- Tests connectivity and access token validity.
-- @param opts table: optional overrides
-- @param callback function(ok, msg_or_err)
function GDrive.testConnection(opts, callback)
    OAuth.getValidAccessToken(Constants.CLOUD_PROVIDERS.GDRIVE, function(ok_tok, token_or_err)
        if not ok_tok then
            if callback then callback(false, token_or_err) end
            return
        end

        ensureFolder(token_or_err, opts.remote_dir, function(ok_f, f_or_err)
            if ok_f then
                if callback then callback(true, _("Connected to Google Drive successfully!")) end
            else
                if callback then callback(false, f_or_err) end
            end
        end)
    end)
end

--- Uploads a local file to Google Drive using the Resumable Upload protocol.
-- @param local_path string
-- @param opts table: { remote_dir, on_progress }
-- @param callback function(ok, file_id_or_err)
function GDrive.upload(local_path, opts, callback)
    opts = opts or {}
    OAuth.getValidAccessToken(Constants.CLOUD_PROVIDERS.GDRIVE, function(ok_tok, token_or_err)
        if not ok_tok then
            if callback then callback(false, token_or_err) end
            return
        end

        local token = token_or_err
        ensureFolder(token, opts.remote_dir, function(ok_f, folder_id_or_err)
            if not ok_f then
                if callback then callback(false, folder_id_or_err) end
                return
            end

            local folder_id = folder_id_or_err
            local filename = local_path:match("([^/\\]+)$") or "backup.zip"

            local file_size = 0
            if lfs and lfs.attributes then
                file_size = lfs.attributes(local_path, "size") or 0
            else
                local f = io.open(local_path, "rb")
                if f then file_size = f:seek("end") or 0; f:close() end
            end

            -- Step 1: Initiate Resumable Upload session
            local init_url = DRIVE_UPLOAD_BASE .. "/files?uploadType=resumable"
            local meta = {
                name = filename,
                parents = { folder_id },
            }
            local meta_json = (json and json.encode and json.encode(meta))
                or string.format('{"name":%q,"parents":[%q]}', filename, folder_id)

            if opts.on_progress then
                opts.on_progress(0, file_size, "connecting")
            end

            local r_i, code_i, h_i, s_i, body_i = doDriveRequest{
                url = init_url,
                method = "POST",
                headers = {
                    ["Authorization"] = "Bearer " .. token,
                    ["Content-Type"] = "application/json; charset=UTF-8",
                    ["X-Upload-Content-Type"] = "application/zip",
                    ["X-Upload-Content-Length"] = tostring(file_size),
                },
                body = meta_json,
            }

            local upload_session_url = h_i and (h_i["location"] or h_i["Location"])
            if not upload_session_url or upload_session_url == "" then
                local err_msg = string.format(_("Google Drive upload initiation failed (HTTP %s): %s"), tostring(code_i), tostring(body_i))
                if callback then callback(false, err_msg) end
                return
            end

            -- Step 2: Upload file stream to session URL
            local r_u, code_u, h_u, s_u, body_u = doDriveRequest{
                url = upload_session_url,
                method = "PUT",
                headers = {
                    ["Content-Type"] = "application/zip",
                },
                file_path = local_path,
                total_bytes = file_size,
                on_upload_progress = opts.on_progress,
            }

            if code_u == 200 or code_u == 201 then
                local data = nil
                if json and json.decode and body_u and body_u ~= "" then
                    pcall(function() data = json.decode(body_u) end)
                end
                local file_id = data and data.id or filename
                if callback then callback(true, file_id) end
            else
                local err_msg = string.format(_("Google Drive upload failed (HTTP %s): %s"), tostring(code_u), tostring(body_u))
                if callback then callback(false, err_msg) end
            end
        end)
    end)
end

--- Downloads a remote file from Google Drive by file ID.
-- @param file_id string: Google Drive file ID
-- @param local_path string: local destination file path
-- @param opts table: { on_progress }
-- @param callback function(ok, local_path_or_err)
function GDrive.download(file_id, local_path, opts, callback)
    opts = opts or {}
    OAuth.getValidAccessToken(Constants.CLOUD_PROVIDERS.GDRIVE, function(ok_tok, token_or_err)
        if not ok_tok then
            if callback then callback(false, token_or_err) end
            return
        end

        local token = token_or_err
        -- Fetch file metadata first to know total size
        local meta_url = DRIVE_API_BASE .. "/files/" .. file_id .. "?fields=size,name"
        local r_m, code_m, h_m, s_m, body_m = doDriveRequest{
            url = meta_url,
            method = "GET",
            headers = { ["Authorization"] = "Bearer " .. token },
        }

        local total_size = 0
        if (code_m == 200 or code_m == 201) and body_m then
            local data_m = nil
            if json and json.decode then pcall(function() data_m = json.decode(body_m) end) end
            if data_m and data_m.size then total_size = tonumber(data_m.size) or 0 end
        end

        -- Download binary content
        local dl_url = DRIVE_API_BASE .. "/files/" .. file_id .. "?alt=media"
        local r_d, code_d = doDriveRequest{
            url = dl_url,
            method = "GET",
            headers = { ["Authorization"] = "Bearer " .. token },
            sink_file_path = local_path,
            total_expected = total_size,
            on_download_progress = opts.on_progress,
        }

        if code_d == 200 then
            if callback then callback(true, local_path) end
        else
            pcall(os.remove, local_path)
            local err_msg = string.format(_("Google Drive download failed (HTTP %s)"), tostring(code_d))
            if callback then callback(false, err_msg) end
        end
    end)
end

--- Lists backup files stored in the Google Drive backup folder.
-- @param opts table: { remote_dir }
-- @param callback function(ok, list_of_backups_or_err)
function GDrive.list(opts, callback)
    opts = opts or {}
    OAuth.getValidAccessToken(Constants.CLOUD_PROVIDERS.GDRIVE, function(ok_tok, token_or_err)
        if not ok_tok then
            if callback then callback(false, token_or_err) end
            return
        end

        local token = token_or_err
        ensureFolder(token, opts.remote_dir, function(ok_f, folder_id_or_err)
            if not ok_f then
                if callback then callback(false, folder_id_or_err) end
                return
            end

            local folder_id = folder_id_or_err
            local query = string.format("'%s' in parents and trashed=false", folder_id)
            local list_url = DRIVE_API_BASE .. "/files?q=" .. OAuth.urlEncode(query)
                .. "&fields=" .. OAuth.urlEncode("files(id,name,size,modifiedTime)")
                .. "&orderBy=" .. OAuth.urlEncode("modifiedTime desc")

            local r, code, headers, status, body = doDriveRequest{
                url = list_url,
                method = "GET",
                headers = { ["Authorization"] = "Bearer " .. token },
            }

            if (code == 200 or code == 201) and body and body ~= "" then
                local data = nil
                if json and json.decode then pcall(function() data = json.decode(body) end) end
                local files = {}
                for _, item in ipairs(data and data.files or {}) do
                    local fn = item.name or ""
                    if fn:match("%.zip$") or fn:match("%.tar%.gz$") then
                        table.insert(files, {
                            filename = fn,
                            file_id = item.id,
                            size = tonumber(item.size) or 0,
                            mtime_str = item.modifiedTime or "",
                        })
                    end
                end
                if callback then callback(true, files) end
            else
                local err_msg = string.format(_("Google Drive listing failed (HTTP %s)"), tostring(code))
                if callback then callback(false, err_msg) end
            end
        end)
    end)
end

--- Deletes a remote backup file in Google Drive.
-- @param file_id_or_name string
-- @param opts table
-- @param callback function(ok, err)
function GDrive.delete(file_id_or_name, opts, callback)
    OAuth.getValidAccessToken(Constants.CLOUD_PROVIDERS.GDRIVE, function(ok_tok, token_or_err)
        if not ok_tok then
            if callback then callback(false, token_or_err) end
            return
        end

        local token = token_or_err
        local file_id = file_id_or_name

        -- If a filename was passed instead of file_id, find its ID first
        local function executeDelete(id_to_del)
            local del_url = DRIVE_API_BASE .. "/files/" .. id_to_del
            local r, code = doDriveRequest{
                url = del_url,
                method = "DELETE",
                headers = { ["Authorization"] = "Bearer " .. token },
            }

            if code == 200 or code == 204 or code == 404 then
                if callback then callback(true) end
            else
                if callback then callback(false, "Google Drive delete failed (HTTP " .. tostring(code) .. ")") end
            end
        end

        if file_id:match("%.zip$") or file_id:match("%.tar%.gz$") then
            -- Search by name
            GDrive.list(opts, function(ok_l, list)
                if ok_l and list then
                    for _, item in ipairs(list) do
                        if item.filename == file_id then
                            executeDelete(item.file_id)
                            return
                        end
                    end
                end
                -- If not found, nothing to delete
                if callback then callback(true) end
            end)
        else
            executeDelete(file_id)
        end
    end)
end

return GDrive
