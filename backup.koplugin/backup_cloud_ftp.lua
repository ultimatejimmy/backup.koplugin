--[[--
backup_cloud_ftp.lua
Pure Lua FTP / FTPS client for KOReader Backup.
Uses standard FTP passive mode (PASV) and binary transfer (TYPE I).
Fully compatible with Kindle, Kobo, and Android network environments.
--]]

local ok_sock, socket = pcall(require, "socket")
local ok_su, socketutil = pcall(require, "socketutil")
local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
if not ok_lfs or not lfs then
    ok_lfs, lfs = pcall(require, "lfs")
end
local Localization = require("localization_backup")
local _ = Localization:getHelper()
local Constants = require("backup_constants")

local FTP = {}

local DEFAULT_PORT = 21

--- Reads a multi-line or single-line FTP reply from the control connection.
-- Returns code (number), full_text (string)
local function readReply(ctrl)
    local full_lines = {}
    local code = nil
    while true do
        local line, err = ctrl:receive("*l")
        if not line then
            return nil, err or "Connection closed by server"
        end
        table.insert(full_lines, line)
        -- Match standard FTP response: "123 text" (terminating) or "123-text" (continuation)
        local c, sep = line:match("^(%d%d%d)([ %-])")
        if c and not code then
            code = tonumber(c)
        end
        if c and sep == " " and tonumber(c) == code then
            break
        end
    end
    return code, table.concat(full_lines, "\n")
end

--- Sends an FTP command and reads the reply.
local function sendCmd(ctrl, cmd, arg)
    local line = arg and (cmd .. " " .. arg) or cmd
    local ok, err = ctrl:send(line .. "\r\n")
    if not ok then
        return nil, err or "Failed to send command"
    end
    return readReply(ctrl)
end

--- Opens and authenticates a control connection to the FTP server.
local function openSession(opts)
    if not ok_sock or not socket or not socket.tcp then
        return nil, "socket.tcp module not available"
    end

    local host = opts.host
    if not host or host == "" then
        return nil, _("FTP host is required.")
    end
    local port = tonumber(opts.port) or DEFAULT_PORT

    local ctrl = socket.tcp()
    if not ctrl then
        return nil, "Could not create TCP socket"
    end

    ctrl:settimeout(15)
    local ok_c, conn_err = ctrl:connect(host, port)
    if not ok_c then
        ctrl:close()
        return nil, string.format(_("Could not connect to %s:%d: %s"), host, port, tostring(conn_err))
    end

    -- Read initial 220 banner
    local code, reply = readReply(ctrl)
    if not code or code >= 400 then
        ctrl:close()
        return nil, string.format(_("Server greeting failed: %s"), tostring(reply))
    end

    -- Explicit FTPS (AUTH TLS) if requested
    if opts.use_ftps then
        local code_tls, reply_tls = sendCmd(ctrl, "AUTH", "TLS")
        if code_tls and (code_tls == 234 or code_tls == 334) then
            local ok_ssl, ssl = pcall(require, "ssl")
            if ok_ssl and ssl and ssl.wrap then
                local wrapped, wrap_err = ssl.wrap(ctrl, {
                    mode = "client",
                    protocol = "any",
                    verify = "none",
                })
                if wrapped then
                    local ok_hs, hs_err = wrapped:dohandshake()
                    if ok_hs then
                        ctrl = wrapped
                        -- Also protect data channel
                        sendCmd(ctrl, "PBSZ", "0")
                        sendCmd(ctrl, "PROT", "P")
                    end
                end
            end
        end
    end

    -- Authentication
    local user = (opts.username and opts.username ~= "") and opts.username or "anonymous"
    local pass = opts.password or "anonymous@koreader.org"

    local code_u, reply_u = sendCmd(ctrl, "USER", user)
    if code_u == 331 then
        -- Password required
        local code_p, reply_p = sendCmd(ctrl, "PASS", pass)
        if not code_p or code_p >= 400 then
            ctrl:close()
            return nil, string.format(_("FTP authentication failed: %s"), tostring(reply_p))
        end
    elseif not code_u or code_u >= 400 then
        ctrl:close()
        return nil, string.format(_("FTP user rejected: %s"), tostring(reply_u))
    end

    -- Set Binary transfer mode (TYPE I)
    sendCmd(ctrl, "TYPE", "I")

    return ctrl, nil
end

--- Closes an FTP control connection gracefully.
local function closeSession(ctrl)
    if ctrl then
        pcall(function()
            sendCmd(ctrl, "QUIT")
            ctrl:close()
        end)
    end
end

--- Enters passive mode and connects a data socket.
-- Returns data_socket, err
local function openDataChannel(ctrl)
    local code, reply = sendCmd(ctrl, "PASV")
    if not code or code >= 400 then
        -- Fallback to EPSV (Extended Passive Mode)
        code, reply = sendCmd(ctrl, "EPSV")
        if code and code == 229 then
            local port = reply:match("%(%|%|%|(%d+)%|%)")
            if port then
                local peer_ip = ctrl:getpeername()
                local data_sock = socket.tcp()
                data_sock:settimeout(20)
                local ok, err = data_sock:connect(peer_ip, tonumber(port))
                if ok then return data_sock end
            end
        end
        return nil, "PASV command failed: " .. tostring(reply)
    end

    -- Parse PASV reply: "227 Entering Passive Mode (h1,h2,h3,h4,p1,p2)"
    local h1, h2, h3, h4, p1, p2 = reply:match("%((%d+),(%d+),(%d+),(%d+),(%d+),(%d+)%)")
    if not h1 then
        return nil, "Invalid PASV reply: " .. tostring(reply)
    end

    local data_ip = string.format("%d.%d.%d.%d", h1, h2, h3, h4)
    local data_port = (tonumber(p1) * 256) + tonumber(p2)

    local data_sock = socket.tcp()
    if not data_sock then
        return nil, "Could not create data socket"
    end

    data_sock:settimeout(20)
    local ok_conn, conn_err = data_sock:connect(data_ip, data_port)
    if not ok_conn then
        -- Some servers return their internal NAT IP in PASV; fallback to control channel IP
        local ctrl_ip = ctrl:getpeername()
        if ctrl_ip and ctrl_ip ~= data_ip then
            ok_conn, conn_err = data_sock:connect(ctrl_ip, data_port)
        end
    end

    if not ok_conn then
        data_sock:close()
        return nil, "Could not connect to data port: " .. tostring(conn_err)
    end

    return data_sock, nil
end

--- Ensures the remote directory exists and navigates into it.
local function ensureAndCwdDir(ctrl, remote_dir)
    remote_dir = remote_dir or Constants.CLOUD_DEFAULT_REMOTE_DIR or "koreader_backups"
    remote_dir = remote_dir:gsub("^/+", ""):gsub("/+$", "")
    if remote_dir == "" then
        return true
    end

    -- Try navigating directly
    local code, reply = sendCmd(ctrl, "CWD", remote_dir)
    if code and code == 250 then
        return true
    end

    -- Directory may not exist; navigate or create segment by segment
    sendCmd(ctrl, "CWD", "/")
    for seg in remote_dir:gmatch("[^/]+") do
        local code_seg = sendCmd(ctrl, "CWD", seg)
        if not code_seg or code_seg ~= 250 then
            sendCmd(ctrl, "MKD", seg)
            local code_retry = sendCmd(ctrl, "CWD", seg)
            if not code_retry or code_retry ~= 250 then
                return false, "Could not enter directory: " .. seg
            end
        end
    end
    return true
end

--- Tests connectivity and credentials with the FTP server.
-- @param opts table: { host, port, username, password, remote_dir, use_ftps }
-- @param callback function(ok, err_or_msg)
function FTP.testConnection(opts, callback)
    local ctrl, err = openSession(opts)
    if not ctrl then
        if callback then callback(false, err) end
        return
    end

    local ok_dir, dir_err = ensureAndCwdDir(ctrl, opts.remote_dir)
    closeSession(ctrl)

    if ok_dir then
        if callback then callback(true, _("Connection successful!")) end
    else
        if callback then callback(false, dir_err) end
    end
end

--- Uploads a local file to the FTP server.
-- @param local_path string
-- @param opts table: { host, port, username, password, remote_dir, use_ftps, on_progress }
-- @param callback function(ok, result_or_err)
function FTP.upload(local_path, opts, callback)
    local ctrl, err = openSession(opts)
    if not ctrl then
        if callback then callback(false, err) end
        return
    end

    local ok_dir, dir_err = ensureAndCwdDir(ctrl, opts.remote_dir)
    if not ok_dir then
        closeSession(ctrl)
        if callback then callback(false, dir_err) end
        return
    end

    local filename = local_path:match("([^/\\]+)$") or "backup.zip"

    local f_in, f_err = io.open(local_path, "rb")
    if not f_in then
        closeSession(ctrl)
        if callback then callback(false, "Could not open local file: " .. tostring(f_err)) end
        return
    end

    local total_bytes = f_in:seek("end") or 0
    f_in:seek("set", 0)

    local data_sock, data_err = openDataChannel(ctrl)
    if not data_sock then
        f_in:close()
        closeSession(ctrl)
        if callback then callback(false, data_err) end
        return
    end

    local code_stor, reply_stor = sendCmd(ctrl, "STOR", filename)
    if not code_stor or (code_stor ~= 150 and code_stor ~= 125) then
        data_sock:close()
        f_in:close()
        closeSession(ctrl)
        if callback then callback(false, "STOR rejected: " .. tostring(reply_stor)) end
        return
    end

    -- Stream file chunks over data socket
    local chunk_size = 65536
    local sent_bytes = 0
    local write_failed = false

    while true do
        if opts.is_canceled and opts.is_canceled() then
            f_in:close()
            data_sock:close()
            closeSession(ctrl)
            if callback then callback(false, "canceled") end
            return
        end

        local chunk = f_in:read(chunk_size)
        if not chunk or #chunk == 0 then break end

        local ok_w, w_err = data_sock:send(chunk)
        if not ok_w then
            write_failed = true
            break
        end
        sent_bytes = sent_bytes + #chunk
        if opts.on_progress then
            opts.on_progress(math.min(sent_bytes, total_bytes), total_bytes, "uploading")
        end
        if opts.is_canceled and opts.is_canceled() then
            f_in:close()
            data_sock:close()
            closeSession(ctrl)
            if callback then callback(false, "canceled") end
            return
        end
    end
    f_in:close()
    data_sock:close()

    if write_failed then
        closeSession(ctrl)
        if callback then callback(false, _("Network transfer interrupted.")) end
        return
    end

    -- Read transfer completion (226)
    local code_comp, reply_comp = readReply(ctrl)
    closeSession(ctrl)

    if code_comp and (code_comp == 226 or code_comp == 250) then
        if callback then callback(true, filename) end
    else
        if callback then callback(false, "Upload did not complete cleanly: " .. tostring(reply_comp)) end
    end
end

--- Downloads a remote file from FTP to a local path.
-- @param remote_filename string
-- @param local_path string
-- @param opts table: { host, port, username, password, remote_dir, use_ftps, on_progress }
-- @param callback function(ok, local_path_or_err)
function FTP.download(remote_filename, local_path, opts, callback)
    local ctrl, err = openSession(opts)
    if not ctrl then
        if callback then callback(false, err) end
        return
    end

    local ok_dir, dir_err = ensureAndCwdDir(ctrl, opts.remote_dir)
    if not ok_dir then
        closeSession(ctrl)
        if callback then callback(false, dir_err) end
        return
    end

    -- Check file size via SIZE command
    local total_expected = 0
    local code_sz, reply_sz = sendCmd(ctrl, "SIZE", remote_filename)
    if code_sz == 213 then
        total_expected = tonumber(reply_sz:match("(%d+)$")) or 0
    end

    local data_sock, data_err = openDataChannel(ctrl)
    if not data_sock then
        closeSession(ctrl)
        if callback then callback(false, data_err) end
        return
    end

    local code_retr, reply_retr = sendCmd(ctrl, "RETR", remote_filename)
    if not code_retr or (code_retr ~= 150 and code_retr ~= 125) then
        data_sock:close()
        closeSession(ctrl)
        if callback then callback(false, "RETR rejected: " .. tostring(reply_retr)) end
        return
    end

    local f_out, out_err = io.open(local_path, "wb")
    if not f_out then
        data_sock:close()
        closeSession(ctrl)
        if callback then callback(false, "Could not open local file for writing: " .. tostring(out_err)) end
        return
    end

    local received_bytes = 0
    local read_failed = false

    while true do
        if opts.is_canceled and opts.is_canceled() then
            f_out:close()
            data_sock:close()
            closeSession(ctrl)
            pcall(os.remove, local_path)
            if callback then callback(false, "canceled") end
            return
        end

        local chunk, recv_err, partial = data_sock:receive(65536)
        local data = chunk or partial
        if data and #data > 0 then
            f_out:write(data)
            received_bytes = received_bytes + #data
            if opts.on_progress then
                opts.on_progress(received_bytes, total_expected, "downloading")
            end
            if opts.is_canceled and opts.is_canceled() then
                f_out:close()
                data_sock:close()
                closeSession(ctrl)
                pcall(os.remove, local_path)
                if callback then callback(false, "canceled") end
                return
            end
        end

        if recv_err == "closed" then
            break
        elseif recv_err then
            read_failed = true
            break
        end
    end
    f_out:close()
    data_sock:close()

    if read_failed then
        pcall(os.remove, local_path)
        closeSession(ctrl)
        if callback then callback(false, _("Download transfer interrupted.")) end
        return
    end

    local code_comp, reply_comp = readReply(ctrl)
    closeSession(ctrl)

    if code_comp and (code_comp == 226 or code_comp == 250) then
        if callback then callback(true, local_path) end
    else
        pcall(os.remove, local_path)
        if callback then callback(false, "Download did not complete cleanly: " .. tostring(reply_comp)) end
    end
end

--- Lists backup archives in the remote FTP directory.
-- @param opts table: { host, port, username, password, remote_dir, use_ftps }
-- @param callback function(ok, list_of_backups_or_err)
function FTP.list(opts, callback)
    local ctrl, err = openSession(opts)
    if not ctrl then
        if callback then callback(false, err) end
        return
    end

    local ok_dir, dir_err = ensureAndCwdDir(ctrl, opts.remote_dir)
    if not ok_dir then
        closeSession(ctrl)
        -- If remote dir doesn't exist yet, return empty list
        if callback then callback(true, {}) end
        return
    end

    local data_sock, data_err = openDataChannel(ctrl)
    if not data_sock then
        closeSession(ctrl)
        if callback then callback(false, data_err) end
        return
    end

    -- Send NLST to get filenames
    local code_nlst, reply_nlst = sendCmd(ctrl, "NLST")
    if not code_nlst or (code_nlst ~= 150 and code_nlst ~= 125) then
        data_sock:close()
        closeSession(ctrl)
        if callback then callback(false, "NLST rejected: " .. tostring(reply_nlst)) end
        return
    end

    local lines = {}
    while true do
        local line, l_err = data_sock:receive("*l")
        if line then
            line = line:gsub("\r", "")
            if line ~= "" then
                table.insert(lines, line)
            end
        else
            break
        end
    end
    data_sock:close()
    readReply(ctrl) -- read 226

    local files = {}
    for _, raw_name in ipairs(lines) do
        local fn = raw_name:match("([^/\\]+)$") or raw_name
        if fn:match("%.zip$") or fn:match("%.tar%.gz$") then
            -- Fetch file size via SIZE command
            local sz = 0
            local code_sz, reply_sz = sendCmd(ctrl, "SIZE", fn)
            if code_sz == 213 then
                sz = tonumber(reply_sz:match("(%d+)$")) or 0
            end

            table.insert(files, {
                filename = fn,
                size = sz,
                mtime_str = "",
            })
        end
    end

    closeSession(ctrl)

    -- Sort newest first
    table.sort(files, function(a, b)
        return (a.filename or "") > (b.filename or "")
    end)

    if callback then callback(true, files) end
end

--- Deletes a remote backup file on the FTP server.
-- @param remote_filename string
-- @param opts table: { host, port, username, password, remote_dir, use_ftps }
-- @param callback function(ok, err)
function FTP.delete(remote_filename, opts, callback)
    local ctrl, err = openSession(opts)
    if not ctrl then
        if callback then callback(false, err) end
        return
    end

    local ok_dir = ensureAndCwdDir(ctrl, opts.remote_dir)
    if not ok_dir then
        closeSession(ctrl)
        if callback then callback(true) end
        return
    end

    local code_del, reply_del = sendCmd(ctrl, "DELE", remote_filename)
    closeSession(ctrl)

    if code_del and (code_del == 250 or code_del == 450 or code_del == 550) then
        -- 250 success, 450/550 file not found / already gone
        if callback then callback(true) end
    else
        if callback then callback(false, "DELE failed: " .. tostring(reply_del)) end
    end
end

return FTP
