--[[--
backup_cloud_onedrive.lua
Microsoft OneDrive (Microsoft Graph API v1.0) driver for KOReader Backup.
Uses OAuth2 Bearer tokens with chunked upload sessions for low memory consumption.
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
local ok_ui, UIManager = pcall(require, "ui/uimanager")

local OneDrive = {}

local GRAPH_API_BASE = "https://graph.microsoft.com/v1.0"
local UPLOAD_CHUNK_SIZE = 10 * 327680 -- 3,276,800 bytes (must be a multiple of 320 KiB for Graph API)

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

--- Executes an HTTP/HTTPS request to Microsoft Graph or Azure Blob download URL.
-- Supports file sink and follows HTTP 301/302 redirects (required for Graph item downloads).
local function doOneDriveRequest(req)
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
        method = req.method or "GET",
        headers = headers,
        source = source,
        sink = sink,
        redirect = false,
    })

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

    local num_code = tonumber(code) or code

    -- Follow 301/302/303/307 redirects for downloads (e.g. Graph /content -> Azure Blob SAS URL)
    local max_hops = req.max_redirect_hops or 5
    local current_hop = req.current_hop or 0
    if (num_code == 301 or num_code == 302 or num_code == 303 or num_code == 307) and resp_headers and (current_hop < max_hops) and req.allow_redirect ~= false then
        local redirect_url = resp_headers["location"] or resp_headers["Location"]
        if redirect_url and redirect_url ~= "" then
            -- Note: Pre-signed download URLs reject the Bearer Authorization header
            local redirect_headers = {}
            for k, v in pairs(headers) do
                if k:lower() ~= "authorization" then
                    redirect_headers[k] = v
                end
            end
            return doOneDriveRequest{
                url = redirect_url,
                method = "GET",
                headers = redirect_headers,
                sink_file_path = req.sink_file_path,
                total_expected = req.total_expected,
                on_download_progress = req.on_download_progress,
                current_hop = current_hop + 1,
                max_redirect_hops = max_hops,
                allow_redirect = true,
            }
        end
    end

    local body_str = ""
    if not req.sink_file_path then
        body_str = table.concat(resp_body)
    end

    return r, num_code, resp_headers, status, body_str
end

local _folder_id_cache = nil
local _folder_name_cache = nil

--- Resolves or creates the remote folder in OneDrive.
-- @param token string: OAuth2 access token
-- @param folder_name string: e.g. "koreader_backups"
-- @param callback function(ok, folder_id_or_err)
local function ensureFolder(token, folder_name, callback)
    folder_name = folder_name or Constants.CLOUD_DEFAULT_REMOTE_DIR or "koreader_backups"
    folder_name = folder_name:gsub("^/+", ""):gsub("/+$", "")

    if _folder_id_cache and _folder_name_cache == folder_name then
        if callback then callback(true, _folder_id_cache) end
        return
    end

    local check_url = GRAPH_API_BASE .. "/me/drive/root:/" .. OAuth.urlEncode(folder_name)
    local r, code, headers, status, body = doOneDriveRequest{
        url = check_url,
        method = "GET",
        headers = {
            ["Authorization"] = "Bearer " .. token,
            ["Accept"] = "application/json",
        },
    }

    if (code == 200 or code == 201) and body and body ~= "" then
        local data = nil
        if json and json.decode then pcall(function() data = json.decode(body) end) end
        if data and data.id then
            _folder_id_cache = data.id
            _folder_name_cache = folder_name
            if callback then callback(true, _folder_id_cache) end
            return
        end
    end

    -- Folder not found; create it under root
    local create_url = GRAPH_API_BASE .. "/me/drive/root/children"
    local meta = {
        name = folder_name,
        folder = {},
        ["@microsoft.graph.conflictBehavior"] = "fail",
    }
    local meta_json = (json and json.encode and json.encode(meta))
        or string.format('{"name":%q,"folder":{},"@microsoft.graph.conflictBehavior":"fail"}', folder_name)

    local r_c, code_c, h_c, s_c, body_c = doOneDriveRequest{
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
            _folder_name_cache = folder_name
            if callback then callback(true, _folder_id_cache) end
            return
        end
    end

    local err_msg = string.format(_("Could not create OneDrive folder '%s' (HTTP %s): %s"), folder_name, tostring(code_c), tostring(body_c))
    if callback then callback(false, err_msg) end
end
OneDrive.ensureFolder = ensureFolder

--- Tests connectivity and access token validity.
-- @param opts table: optional overrides
-- @param callback function(ok, msg_or_err)
function OneDrive.testConnection(opts, callback)
    opts = opts or {}
    OAuth.getValidAccessToken(Constants.CLOUD_PROVIDERS.ONEDRIVE, function(ok_tok, token_or_err)
        if not ok_tok then
            if callback then callback(false, token_or_err) end
            return
        end

        ensureFolder(token_or_err, opts.remote_dir, function(ok_f, f_or_err)
            if ok_f then
                if callback then callback(true, _("Connected to Microsoft OneDrive successfully!")) end
            else
                if callback then callback(false, f_or_err) end
            end
        end)
    end)
end

--- Uploads a local file to Microsoft OneDrive using a chunked Resumable Upload Session.
-- Uploading in chunks (multiples of 320 KiB) keeps RAM usage minimal on e-ink devices.
-- @param local_path string
-- @param opts table: { remote_dir, on_progress }
-- @param callback function(ok, file_id_or_err)
function OneDrive.upload(local_path, opts, callback)
    opts = opts or {}
    OAuth.getValidAccessToken(Constants.CLOUD_PROVIDERS.ONEDRIVE, function(ok_tok, token_or_err)
        if not ok_tok then
            if callback then callback(false, token_or_err) end
            return
        end

        local token = token_or_err
        local folder_name = opts.remote_dir or Constants.CLOUD_DEFAULT_REMOTE_DIR or "koreader_backups"
        folder_name = folder_name:gsub("^/+", ""):gsub("/+$", "")

        ensureFolder(token, folder_name, function(ok_f, folder_id_or_err)
            if not ok_f then
                if callback then callback(false, folder_id_or_err) end
                return
            end

            local filename = local_path:match("([^/\\]+)$") or "backup.zip"

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

            -- Step 1: Create Resumable Upload Session
            local session_url = GRAPH_API_BASE .. "/me/drive/items/" .. folder_id_or_err .. ":/" .. OAuth.urlEncode(filename) .. ":/createUploadSession"
            local meta = {
                item = {
                    ["@microsoft.graph.conflictBehavior"] = "replace",
                },
            }
            local meta_json = (json and json.encode and json.encode(meta))
                or '{"item":{"@microsoft.graph.conflictBehavior":"replace"}}'

            local r_s, code_s, h_s, s_s, body_s = doOneDriveRequest{
                url = session_url,
                method = "POST",
                headers = {
                    ["Authorization"] = "Bearer " .. token,
                    ["Content-Type"] = "application/json; charset=UTF-8",
                },
                body = meta_json,
            }

            local session_data = nil
            if json and json.decode and body_s and body_s ~= "" then
                pcall(function() session_data = json.decode(body_s) end)
            end

            local upload_url = session_data and session_data.uploadUrl
            if not upload_url or upload_url == "" then
                local err_msg = string.format(_("OneDrive upload session creation failed (HTTP %s): %s"), tostring(code_s), tostring(body_s))
                if callback then callback(false, err_msg) end
                return
            end

            -- Step 2: Upload in sequential 3.2MB chunks (must be multiple of 320 KiB)
            local file_handle = io.open(local_path, "rb")
            if not file_handle then
                if callback then callback(false, "Could not open local file for reading: " .. tostring(local_path)) end
                return
            end

            local offset = 0
            local function uploadNextChunk()
                if opts.is_canceled and opts.is_canceled() then
                    pcall(file_handle.close, file_handle)
                    if callback then callback(false, "canceled") end
                    return
                end

                if offset >= file_size then
                    pcall(file_handle.close, file_handle)
                    if callback then callback(true, filename) end
                    return
                end

                local chunk_len = math.min(UPLOAD_CHUNK_SIZE, file_size - offset)
                file_handle:seek("set", offset)
                local chunk_data = file_handle:read(chunk_len)
                if not chunk_data or #chunk_data == 0 then
                    pcall(file_handle.close, file_handle)
                    if callback then callback(false, "Unexpected end of file while reading chunk at offset " .. tostring(offset)) end
                    return
                end

                local range_end = offset + #chunk_data - 1
                local range_header = string.format("bytes %d-%d/%d", offset, range_end, file_size)

                local r_c, code_c, h_c, s_c, body_c = doOneDriveRequest{
                    url = upload_url,
                    method = "PUT",
                    headers = {
                        ["Content-Length"] = tostring(#chunk_data),
                        ["Content-Range"] = range_header,
                        ["Content-Type"] = "application/zip",
                    },
                    body = chunk_data,
                    total_bytes = #chunk_data,
                }

                -- Intermediate chunks return 202 Accepted; final chunk returns 200 or 201 Created
                if code_c == 200 or code_c == 201 or code_c == 202 then
                    offset = offset + #chunk_data
                    if opts.on_progress then
                        opts.on_progress(math.min(offset, file_size), file_size, "uploading")
                    end

                    if code_c == 200 or code_c == 201 or offset >= file_size then
                        -- Final chunk succeeded
                        pcall(file_handle.close, file_handle)
                        local data_res = nil
                        if json and json.decode and body_c and body_c ~= "" then
                            pcall(function() data_res = json.decode(body_c) end)
                        end
                        local file_id = data_res and data_res.id or filename
                        if callback then callback(true, file_id) end
                        return
                    else
                        -- Continue with next chunk (yield to event loop so progress bar renders smoothly)
                        if ok_ui and UIManager and UIManager.nextTick then
                            UIManager:nextTick(uploadNextChunk)
                        else
                            uploadNextChunk()
                        end
                    end
                else
                    pcall(file_handle.close, file_handle)
                    local err_msg = string.format(_("OneDrive chunk upload failed at %d-%d (HTTP %s): %s"), offset, range_end, tostring(code_c), tostring(body_c))
                    if callback then callback(false, err_msg) end
                end
            end

            uploadNextChunk()
        end)
    end)
end

--- Downloads a remote backup file from Microsoft OneDrive by file ID.
-- @param file_id string: OneDrive item ID
-- @param local_path string: local destination file path
-- @param opts table: { on_progress }
-- @param callback function(ok, local_path_or_err)
function OneDrive.download(file_id, local_path, opts, callback)
    opts = opts or {}
    OAuth.getValidAccessToken(Constants.CLOUD_PROVIDERS.ONEDRIVE, function(ok_tok, token_or_err)
        if not ok_tok then
            if callback then callback(false, token_or_err) end
            return
        end

        local token = token_or_err

        -- Step 1: Fetch file metadata first to know total size for progress reporting
        local meta_url = GRAPH_API_BASE .. "/me/drive/items/" .. file_id .. "?$select=size,name"
        local r_m, code_m, h_m, s_m, body_m = doOneDriveRequest{
            url = meta_url,
            method = "GET",
            headers = {
                ["Authorization"] = "Bearer " .. token,
                ["Accept"] = "application/json",
            },
        }

        local total_size = 0
        if (code_m == 200 or code_m == 201) and body_m then
            local data_m = nil
            if json and json.decode then pcall(function() data_m = json.decode(body_m) end) end
            if data_m and data_m.size then total_size = tonumber(data_m.size) or 0 end
        end

        -- Step 2: Download binary content (handles 302 redirect to Azure Blob storage)
        local dl_url = GRAPH_API_BASE .. "/me/drive/items/" .. file_id .. "/content"
        local r_d, code_d = doOneDriveRequest{
            url = dl_url,
            method = "GET",
            headers = {
                ["Authorization"] = "Bearer " .. token,
            },
            sink_file_path = local_path,
            total_expected = total_size,
            on_download_progress = opts.on_progress,
            is_canceled = opts.is_canceled,
            allow_redirect = true,
        }

        if (opts.is_canceled and opts.is_canceled()) or tostring(code_d):find("canceled") then
            pcall(os.remove, local_path)
            if callback then callback(false, "canceled") end
            return
        end

        local num_code_d = tonumber(code_d) or code_d
        if num_code_d == 200 then
            if callback then callback(true, local_path) end
        else
            pcall(os.remove, local_path)
            local err_msg = string.format(_("OneDrive download failed (HTTP %s)"), tostring(code_d))
            if callback then callback(false, err_msg) end
        end
    end)
end

--- Lists backup archives stored in the OneDrive backup folder.
-- @param opts table: { remote_dir }
-- @param callback function(ok, list_of_backups_or_err)
function OneDrive.list(opts, callback)
    opts = opts or {}
    OAuth.getValidAccessToken(Constants.CLOUD_PROVIDERS.ONEDRIVE, function(ok_tok, token_or_err)
        if not ok_tok then
            if callback then callback(false, token_or_err) end
            return
        end

        local token = token_or_err
        local folder_name = opts.remote_dir or Constants.CLOUD_DEFAULT_REMOTE_DIR or "koreader_backups"
        folder_name = folder_name:gsub("^/+", ""):gsub("/+$", "")

        local list_url = GRAPH_API_BASE .. "/me/drive/root:/" .. OAuth.urlEncode(folder_name)
            .. ":/children?$select=id,name,size,lastModifiedDateTime&$top=100"

        local r, code, headers, status, body = doOneDriveRequest{
            url = list_url,
            method = "GET",
            headers = {
                ["Authorization"] = "Bearer " .. token,
                ["Accept"] = "application/json",
            },
        }

        if code == 404 then
            -- Folder does not exist yet; return empty list
            if callback then callback(true, {}) end
            return
        end

        if (code == 200 or code == 201) and body and body ~= "" then
            local data = nil
            if json and json.decode then pcall(function() data = json.decode(body) end) end
            local files = {}
            for _, item in ipairs(data and data.value or {}) do
                local fn = item.name or ""
                if fn:match("%.zip$") or fn:match("%.tar%.gz$") then
                    table.insert(files, {
                        filename = fn,
                        file_id = item.id,
                        size = tonumber(item.size) or 0,
                        mtime_str = item.lastModifiedDateTime or "",
                    })
                end
            end
            -- Sort newest to oldest
            table.sort(files, function(a, b)
                return (a.mtime_str or "") > (b.mtime_str or "")
            end)
            if callback then callback(true, files) end
        else
            local err_msg = string.format(_("OneDrive listing failed (HTTP %s)"), tostring(code))
            if callback then callback(false, err_msg) end
        end
    end)
end

--- Deletes a remote backup file in Microsoft OneDrive.
-- @param file_id_or_name string
-- @param opts table
-- @param callback function(ok, err)
function OneDrive.delete(file_id_or_name, opts, callback)
    opts = opts or {}
    OAuth.getValidAccessToken(Constants.CLOUD_PROVIDERS.ONEDRIVE, function(ok_tok, token_or_err)
        if not ok_tok then
            if callback then callback(false, token_or_err) end
            return
        end

        local token = token_or_err
        local file_id = file_id_or_name

        local function executeDelete(id_to_del)
            local del_url = GRAPH_API_BASE .. "/me/drive/items/" .. id_to_del
            local r, code = doOneDriveRequest{
                url = del_url,
                method = "DELETE",
                headers = { ["Authorization"] = "Bearer " .. token },
            }

            if code == 200 or code == 204 or code == 404 then
                if callback then callback(true) end
            else
                if callback then callback(false, "OneDrive delete failed (HTTP " .. tostring(code) .. ")") end
            end
        end

        if file_id:match("%.zip$") or file_id:match("%.tar%.gz$") then
            -- Find file ID by name first
            OneDrive.list(opts, function(ok_l, list)
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

return OneDrive
