--[[--
backup_cloud_oauth.lua
OAuth2 Device Authorization Grant (RFC 8628) handler for KOReader Backup.
Enables e-ink devices to authenticate with cloud services without an embedded browser.
--]]

local ok_https, https = pcall(require, "ssl.https")
local ok_http, http = pcall(require, "socket.http")
local ok_ltn, ltn12 = pcall(require, "ltn12")
local ok_json, json = pcall(require, "json")
if not ok_json or not json then
    ok_json, json = pcall(require, "dkjson")
end
local ok_ds, DataStorage = pcall(require, "datastorage")
local ok_su, socketutil = pcall(require, "socketutil")
local ok_util, util = pcall(require, "util")
local Localization = require("localization_backup")
local _ = Localization:getHelper()
local Constants = require("backup_constants")
local Sanitizer = require("backup_sanitizer")

local OAuth = {}

local function getDataDir()
    return (ok_ds and DataStorage and DataStorage.getDataDir and DataStorage:getDataDir()) or "."
end

--- URL-encode a string.
function OAuth.urlEncode(str)
    if not str then return "" end
    str = tostring(str)
    str = str:gsub("\n", "\r\n")
    str = str:gsub("([^%w %-%_%.%~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
    str = str:gsub(" ", "+")
    return str
end

--- Formats a table of key-values as application/x-www-form-urlencoded string.
function OAuth.makeFormData(tbl)
    local parts = {}
    for k, v in pairs(tbl or {}) do
        if v ~= nil then
            table.insert(parts, OAuth.urlEncode(k) .. "=" .. OAuth.urlEncode(v))
        end
    end
    return table.concat(parts, "&")
end

--- Internal HTTP/HTTPS request runner with timeouts and error handling.
local function doHttpRequest(req)
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

    local resp_body = {}
    local sink = ltn12.sink.table(resp_body)
    local source = nil
    local headers = req.headers or {}

    if not headers["User-Agent"] then
        headers["User-Agent"] = "KOReader-Backup/1.0"
    end

    if req.body then
        source = ltn12.source.string(req.body)
        if not headers["Content-Length"] then
            headers["Content-Length"] = tostring(#req.body)
        end
    end

    local prev_block, prev_total
    if ok_su and socketutil and socketutil.set_timeout then
        prev_block = socketutil.block_timeout
        prev_total = socketutil.total_timeout
        pcall(function()
            socketutil:set_timeout(15, 30)
        end)
    end

    local ok_call, r, code, resp_headers, status = pcall(client.request, {
        url = url,
        method = req.method or "GET",
        headers = headers,
        source = source,
        sink = sink,
    })

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

    local body_str = table.concat(resp_body)
    return r, code, resp_headers, status, body_str
end

--- Provider configuration definitions.
OAuth.PROVIDERS = {
    [Constants.CLOUD_PROVIDERS.GDRIVE] = {
        name = "Google Drive",
        device_code_url = "https://oauth2.googleapis.com/device/code",
        token_url = "https://oauth2.googleapis.com/token",
        revoke_url = "https://oauth2.googleapis.com/revoke",
        default_scope = "https://www.googleapis.com/auth/drive.file",
        client_id = Constants.OAUTH_GDRIVE_CLIENT_ID,
        client_secret = Constants.OAUTH_GDRIVE_CLIENT_SECRET,
        relay_url = Constants.OAUTH_DEFAULT_RELAY_URL,
    },
    [Constants.CLOUD_PROVIDERS.ONEDRIVE] = {
        name = "Microsoft OneDrive",
        device_code_url = "https://login.microsoftonline.com/consumers/oauth2/v2.0/devicecode",
        token_url = "https://login.microsoftonline.com/consumers/oauth2/v2.0/token",
        default_scope = "Files.ReadWrite offline_access",
        client_id = Constants.OAUTH_ONEDRIVE_CLIENT_ID,
    },
    [Constants.CLOUD_PROVIDERS.DROPBOX] = {
        name = "Dropbox",
        device_code_url = (Constants.OAUTH_DEFAULT_RELAY_URL or "https://backup.ultimatejimmy.workers.dev") .. "/api/oauth/dropbox/init",
        token_url = "https://api.dropboxapi.com/oauth2/token",
        client_id = Constants.OAUTH_DROPBOX_CLIENT_ID or "khboin1ohr74q7y",
        relay_url = Constants.OAUTH_DEFAULT_RELAY_URL,
    },
}

--- Requests a device code and verification URL from the OAuth2 provider.
-- @param provider string (e.g. "gdrive")
-- @param opts table optional overrides { client_id, scope }
-- @param callback function(ok, result_or_err)
function OAuth.requestDeviceCode(provider, opts, callback)
    opts = opts or {}
    local pdef = OAuth.PROVIDERS[provider]
    if not pdef or not pdef.device_code_url then
        if callback then callback(false, "Unsupported OAuth provider: " .. tostring(provider)) end
        return
    end

    local client_id = opts.client_id or pdef.client_id
    if not client_id or client_id == "" then
        if callback then callback(false, _("OAuth Client ID is not configured for this provider.")) end
        return
    end

    local scope = opts.scope or pdef.default_scope
    local body = OAuth.makeFormData({
        client_id = client_id,
        scope = scope,
    })

    local r, code, headers, status, resp_body = doHttpRequest{
        url = pdef.device_code_url,
        method = "POST",
        headers = {
            ["Content-Type"] = "application/x-www-form-urlencoded",
        },
        body = body,
    }

    if (code == 200 or code == 201) and resp_body and resp_body ~= "" then
        local data = nil
        if json and json.decode then
            pcall(function() data = json.decode(resp_body) end)
        end
        if data and data.device_code and data.user_code then
            local info = {
                device_code = data.device_code,
                user_code = data.user_code,
                verification_url = data.verification_url or data.verification_uri or "https://www.google.com/device",
                verification_uri_complete = data.verification_uri_complete or data.verification_url_complete,
                expires_in = tonumber(data.expires_in) or 1800,
                interval = tonumber(data.interval) or 5,
            }
            if callback then callback(true, info) end
            return
        end
    end

    local err_msg = "Device code request failed (HTTP " .. tostring(code) .. "): " .. tostring(resp_body)
    if callback then callback(false, err_msg) end
end

--- Polls the token endpoint once for authorization status.
-- @param provider string
-- @param device_code string
-- @param opts table optional overrides { client_id, relay_url, direct_google, client_secret }
-- @param callback function(ok, data_or_status, raw_resp)
-- Returns ok=true with token data when granted, or ok=false with status string:
-- "authorization_pending", "slow_down", "expired_token", "access_denied", or error message.
function OAuth.pollToken(provider, device_code, opts, callback)
    opts = opts or {}
    local pdef = OAuth.PROVIDERS[provider]
    if not pdef or not pdef.token_url then
        if callback then callback(false, "Unsupported OAuth provider: " .. tostring(provider)) end
        return
    end

    local relay_url = opts.relay_url or pdef.relay_url
    local client_secret = opts.client_secret or pdef.client_secret

    -- If a relay worker URL is configured and we don't have a direct client_secret, proxy through the worker
    if relay_url and relay_url ~= "" and not client_secret and not opts.direct_google then
        local poll_url = relay_url:gsub("/+$", "") .. "/api/oauth/" .. provider .. "/poll"
        local req_payload = (json and json.encode and json.encode({ device_code = device_code }))
            or string.format('{"device_code":%q}', device_code)

        local r, code, headers, status, resp_body = doHttpRequest{
            url = poll_url,
            method = "POST",
            headers = {
                ["Content-Type"] = "application/json",
            },
            body = req_payload,
        }

        local data = nil
        if json and json.decode and resp_body and resp_body ~= "" then
            pcall(function() data = json.decode(resp_body) end)
        end

        if (code == 200 or code == 201) and data and data.access_token then
            local token_info = {
                access_token = data.access_token,
                refresh_token = data.refresh_token,
                expires_in = tonumber(data.expires_in) or 3600,
                token_type = data.token_type or "Bearer",
                scope = data.scope,
                created_at = os.time(),
                expires_at = os.time() + (tonumber(data.expires_in) or 3600),
            }
            if callback then callback(true, token_info) end
            return
        end

        if data and data.error then
            local err_name = tostring(data.error)
            if callback then callback(false, err_name, data) end
            return
        end

        local err_msg = "Token polling relay failed (HTTP " .. tostring(code) .. "): " .. tostring(resp_body)
        if callback then callback(false, err_msg) end
        return
    end

    -- Direct Google polling (passes client_secret if configured)
    local client_id = opts.client_id or pdef.client_id
    local form_fields = {
        client_id = client_id,
        device_code = device_code,
        grant_type = "urn:ietf:params:oauth:grant-type:device_code",
    }
    if client_secret and client_secret ~= "" then
        form_fields.client_secret = client_secret
    end
    local body = OAuth.makeFormData(form_fields)

    local r, code, headers, status, resp_body = doHttpRequest{
        url = pdef.token_url,
        method = "POST",
        headers = {
            ["Content-Type"] = "application/x-www-form-urlencoded",
        },
        body = body,
    }

    local data = nil
    if json and json.decode and resp_body and resp_body ~= "" then
        pcall(function() data = json.decode(resp_body) end)
    end

    if (code == 200 or code == 201) and data and data.access_token then
        local token_info = {
            access_token = data.access_token,
            refresh_token = data.refresh_token,
            expires_in = tonumber(data.expires_in) or 3600,
            token_type = data.token_type or "Bearer",
            scope = data.scope,
            created_at = os.time(),
            expires_at = os.time() + (tonumber(data.expires_in) or 3600),
        }
        if callback then callback(true, token_info) end
        return
    end

    if data and data.error then
        local err_name = tostring(data.error)
        -- Standard RFC 8628 error codes: authorization_pending, slow_down, access_denied, expired_token
        if callback then callback(false, err_name, data) end
        return
    end

    local err_msg = "Token polling failed (HTTP " .. tostring(code) .. "): " .. tostring(resp_body)
    if callback then callback(false, err_msg) end
end

--- Refreshes an expired access token using the stored refresh_token.
-- @param provider string
-- @param refresh_token string
-- @param opts table optional overrides { client_id, relay_url, direct_google, client_secret }
-- @param callback function(ok, token_info_or_err)
function OAuth.refreshToken(provider, refresh_token, opts, callback)
    opts = opts or {}
    local pdef = OAuth.PROVIDERS[provider]
    if not pdef or not pdef.token_url then
        if callback then callback(false, "Unsupported OAuth provider: " .. tostring(provider)) end
        return
    end

    local relay_url = opts.relay_url or pdef.relay_url
    local client_secret = opts.client_secret or pdef.client_secret

    -- If a relay worker URL is configured and we don't have a direct client_secret, proxy through the worker
    if relay_url and relay_url ~= "" and not client_secret and not opts.direct_google then
        local refresh_url = relay_url:gsub("/+$", "") .. "/api/oauth/" .. provider .. "/refresh"
        local req_payload = (json and json.encode and json.encode({ refresh_token = refresh_token }))
            or string.format('{"refresh_token":%q}', refresh_token)

        local r, code, headers, status, resp_body = doHttpRequest{
            url = refresh_url,
            method = "POST",
            headers = {
                ["Content-Type"] = "application/json",
            },
            body = req_payload,
        }

        local data = nil
        if json and json.decode and resp_body and resp_body ~= "" then
            pcall(function() data = json.decode(resp_body) end)
        end

        if (code == 200 or code == 201) and data and data.access_token then
            local token_info = {
                access_token = data.access_token,
                refresh_token = data.refresh_token or refresh_token,
                expires_in = tonumber(data.expires_in) or 3600,
                token_type = data.token_type or "Bearer",
                scope = data.scope,
                created_at = os.time(),
                expires_at = os.time() + (tonumber(data.expires_in) or 3600),
            }
            if callback then callback(true, token_info) end
            return
        end

        local err_msg = "Token refresh relay failed (HTTP " .. tostring(code) .. "): " .. tostring(resp_body)
        if callback then callback(false, err_msg) end
        return
    end

    -- Direct Google refresh
    local client_id = opts.client_id or pdef.client_id
    local form_fields = {
        client_id = client_id,
        refresh_token = refresh_token,
        grant_type = "refresh_token",
    }
    if client_secret and client_secret ~= "" then
        form_fields.client_secret = client_secret
    end
    local body = OAuth.makeFormData(form_fields)

    local r, code, headers, status, resp_body = doHttpRequest{
        url = pdef.token_url,
        method = "POST",
        headers = {
            ["Content-Type"] = "application/x-www-form-urlencoded",
        },
        body = body,
    }

    local data = nil
    if json and json.decode and resp_body and resp_body ~= "" then
        pcall(function() data = json.decode(resp_body) end)
    end

    local num_code = tonumber(code) or code
    if (num_code == 200 or num_code == 201) and data and data.access_token then
        local token_info = {
            access_token = data.access_token,
            refresh_token = data.refresh_token or refresh_token, -- keep old refresh token if new one not sent
            expires_in = tonumber(data.expires_in) or 3600,
            token_type = data.token_type or "Bearer",
            scope = data.scope,
            created_at = os.time(),
            expires_at = os.time() + (tonumber(data.expires_in) or 3600),
        }
        if callback then callback(true, token_info) end
        return
    end

    local err_msg = "Token refresh failed (HTTP " .. tostring(code) .. "): " .. tostring(resp_body)
    if callback then callback(false, err_msg) end
end

--- Revokes an access or refresh token (logs out).
-- @param provider string
-- @param token string
-- @param callback function(ok, err)
function OAuth.revokeToken(provider, token, callback)
    local pdef = OAuth.PROVIDERS[provider]
    if not pdef or not pdef.revoke_url or not token then
        if callback then callback(true) end
        return
    end

    local body = OAuth.makeFormData({ token = token })
    local r, code, headers, status, resp_body = doHttpRequest{
        url = pdef.revoke_url,
        method = "POST",
        headers = {
            ["Content-Type"] = "application/x-www-form-urlencoded",
        },
        body = body,
    }

    if code == 200 or code == 204 then
        if callback then callback(true) end
    else
        if callback then callback(false, "Revoke failed (HTTP " .. tostring(code) .. ")") end
    end
end

-- --------------------------------------------------------------------------
-- Token Persistence (Stored securely in settings/backup_cloud_tokens.lua)
-- --------------------------------------------------------------------------

local function getTokensFilePath()
    return getDataDir() .. "/settings/backup_cloud_tokens.lua"
end

local _tokens_cache = nil

local function loadAllTokens()
    if _tokens_cache then return _tokens_cache end
    local path = getTokensFilePath()
    local ok, data = pcall(dofile, path)
    if ok and type(data) == "table" then
        _tokens_cache = data
    else
        _tokens_cache = {}
    end
    return _tokens_cache
end

local function saveAllTokens(all_tokens)
    _tokens_cache = all_tokens
    local path = getTokensFilePath()
    local settings_dir = getDataDir() .. "/settings"
    if util and util.makePath then util.makePath(settings_dir) end
    local dumped = Sanitizer.dumpSettings(all_tokens)
    local f = io.open(path, "wb")
    if f then
        f:write(dumped)
        f:close()
        return true
    end
    return false
end

--- Saves OAuth tokens for a specific provider.
function OAuth.saveTokens(provider, tokens)
    if not provider then return false end
    local all = loadAllTokens()
    all[provider] = tokens
    return saveAllTokens(all)
end

--- Loads OAuth tokens for a specific provider.
function OAuth.loadTokens(provider)
    if not provider then return nil end
    local all = loadAllTokens()
    return all[provider]
end

--- Clears stored OAuth tokens for a specific provider.
function OAuth.clearTokens(provider)
    if not provider then return false end
    local all = loadAllTokens()
    all[provider] = nil
    return saveAllTokens(all)
end

--- Retrieves a fresh, valid access token for the given provider.
-- Automatically refreshes the access token if within 60 seconds of expiry.
-- @param provider string
-- @param callback function(ok, access_token_or_err)
function OAuth.getValidAccessToken(provider, callback)
    local tokens = OAuth.loadTokens(provider)
    if not tokens or not tokens.access_token then
        if callback then callback(false, _("Not authenticated. Please connect your account in Settings.")) end
        return
    end

    local now = os.time()
    local expires_at = tonumber(tokens.expires_at) or 0
    -- Buffer of 60 seconds before expiration
    if expires_at > (now + 60) then
        if callback then callback(true, tokens.access_token) end
        return
    end

    -- Token has expired or is expiring soon; attempt refresh if refresh_token available
    if not tokens.refresh_token then
        if callback then callback(false, _("Session expired. Please reconnect your account in Settings.")) end
        return
    end

    OAuth.refreshToken(provider, tokens.refresh_token, {}, function(ok, new_tokens)
        if ok and new_tokens and new_tokens.access_token then
            -- Merge with existing tokens to preserve any fields not returned
            for k, v in pairs(new_tokens) do
                tokens[k] = v
            end
            OAuth.saveTokens(provider, tokens)
            if callback then callback(true, tokens.access_token) end
        else
            -- Refresh failed; clear expired token and report error
            OAuth.clearTokens(provider)
            local err_msg = string.format(_("Failed to refresh authorization: %s. Please reconnect in Settings."), tostring(new_tokens))
            if callback then callback(false, err_msg) end
        end
    end)
end

return OAuth
