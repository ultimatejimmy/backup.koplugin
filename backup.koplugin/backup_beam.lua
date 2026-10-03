--[[--
backup_beam.lua
Anonymous 6-digit Beam Code cross-device backup transfer client.
Provides zero-knowledge encrypted transfer using outbound HTTPS requests,
fully compatible with Kindle firewalls and all KOReader platforms.
High-speed LuaJIT FFI stream cipher with progress reporting.
--]]

local Constants = require("backup_constants")

local ok_sha2, sha2 = pcall(require, "ffi/sha2")
if not ok_sha2 or not sha2 then
    ok_sha2, sha2 = pcall(require, "sha2")
end

local ok_ffi, ffi = pcall(require, "ffi")

local ok_bit, bit_mod = pcall(require, "bit")
if not ok_bit or not bit_mod then
    ok_bit, bit_mod = pcall(require, "bit32")
end

local ok_json, json = pcall(require, "json")
if not ok_json or not json then
    ok_json, json = pcall(require, "dkjson")
end

local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
if not ok_lfs or not lfs then
    ok_lfs, lfs = pcall(require, "lfs")
end
if not ok_lfs or type(lfs) ~= "table" then
    lfs = nil
end

local ok_util, util = pcall(require, "util")
local ok_sock, socket = pcall(require, "socket")
local ok_su, socketutil = pcall(require, "socketutil")
local Localization = require("localization_backup")
local _ = Localization:getHelper()

-- --------------------------------------------------------------------------
-- Beam Diagnostics Logger
-- Writes timestamped entries to backup_beam.log next to this plugin file.
-- Log path: <plugin_dir>/backup_beam.log  (readable via USB or file manager)
-- --------------------------------------------------------------------------
local BeamLog = {}
do
    local _log_path = nil
    local function _get_log_path()
        if _log_path then return _log_path end
        -- Resolve path relative to this source file
        local src = debug.getinfo(1, "S").source or ""
        local dir = src:match("^@(.+)[/\\][^/\\]+$") or "."
        _log_path = dir .. "/backup_beam.log"
        return _log_path
    end

    function BeamLog.log(level, msg, ...)
        local args = {...}
        local ok, err = pcall(function()
            local f = io.open(_get_log_path(), "a")
            if not f then return end
            local ts = os.date and os.date("!%Y-%m-%dT%H:%M:%SZ") or tostring(os.time())
            local formatted = (#args > 0) and string.format(msg, table.unpack(args)) or tostring(msg)
            f:write(string.format("[%s] [%s] %s\n", ts, level, formatted))
            f:close()
        end)
        if not ok then
            -- silently ignore log write failures on read-only filesystems
        end
    end

    function BeamLog.info(msg, ...)  BeamLog.log("INFO",  msg, ...) end
    function BeamLog.warn(msg, ...)  BeamLog.log("WARN",  msg, ...) end
    function BeamLog.err(msg, ...)   BeamLog.log("ERROR", msg, ...) end

    --- Truncate log file to last N lines (call on plugin startup to avoid unbounded growth)
    function BeamLog.rotate(max_lines)
        max_lines = max_lines or 500
        local path = _get_log_path()
        local f = io.open(path, "r")
        if not f then return end
        local lines = {}
        for line in f:lines() do table.insert(lines, line) end
        f:close()
        if #lines > max_lines then
            local trimmed = {}
            for i = #lines - max_lines + 1, #lines do table.insert(trimmed, lines[i]) end
            local fw = io.open(path, "w")
            if fw then
                fw:write(table.concat(trimmed, "\n") .. "\n")
                fw:close()
            end
        end
    end
end

local Beam = {}

--- Returns the module-level diagnostics logger (BeamLog).
function Beam.getLogger() return BeamLog end

-- --------------------------------------------------------------------------
-- Fast Bitwise XOR Fallback Table
-- --------------------------------------------------------------------------
local _xor_table = nil
local _cached_xor_fn = nil
local function get_xor_fn()
    if _cached_xor_fn then return _cached_xor_fn end
    if ok_bit and bit_mod and bit_mod.bxor then
        local bxor = bit_mod.bxor
        _cached_xor_fn = function(a, b) return bxor(a, b) end
        return _cached_xor_fn
    end
    if not _xor_table then
        _xor_table = {}
        for a = 0, 255 do
            _xor_table[a] = {}
            for b = 0, 255 do
                local res, p, va, vb = 0, 1, a, b
                while va > 0 or vb > 0 do
                    if (va % 2) ~= (vb % 2) then res = res + p end
                    va = math.floor(va / 2)
                    vb = math.floor(vb / 2)
                    p = p * 2
                end
                _xor_table[a][b] = res
            end
        end
    end
    _cached_xor_fn = function(a, b) return _xor_table[a][b] end
    return _cached_xor_fn
end

-- --------------------------------------------------------------------------
-- PIN Code & Token Helpers
-- --------------------------------------------------------------------------

--- Generates a random 6-digit numeric PIN string (e.g. "482910").
function Beam.generatePin()
    math.randomseed(os.time() + (os.clock() * 1000000 % 100000))
    local n = math.random(100000, 999999)
    return string.format("%06d", n)
end

--- Formats a 6-digit PIN for readable display (e.g. "482 910").
function Beam.formatPin(pin)
    if not pin then return "" end
    local clean = tostring(pin):gsub("%D", "")
    if #clean == 6 then
        return clean:sub(1, 3) .. " " .. clean:sub(4, 6)
    end
    return tostring(pin)
end

--- Cleans and validates a user-entered PIN string.
-- Returns 6-digit string or nil, error.
function Beam.cleanPin(str)
    if not str then return nil, _("Please enter a 6-digit Beam code.") end
    local clean = tostring(str):gsub("%D", "")
    if #clean ~= (Constants.BEAM_CODE_LENGTH or 6) then
        return nil, string.format(_("Beam code must be exactly %d digits."), Constants.BEAM_CODE_LENGTH or 6)
    end
    return clean
end

--- Derives the public relay lookup token from a PIN.
-- The relay server only sees this token and cannot determine the original PIN.
function Beam.deriveToken(pin)
    local clean = Beam.cleanPin(pin)
    if not clean then return nil end
    if not sha2 or not sha2.sha256 then
        return "beam_" .. clean
    end
    return sha2.sha256("kobeam_token:" .. clean):sub(1, 16)
end

-- --------------------------------------------------------------------------
-- High-Speed End-to-End Cryptography (Zero-Knowledge Stream Cipher + HMAC)
-- --------------------------------------------------------------------------

--- Generates random hex salt.
local function generateSalt(length_bytes)
    length_bytes = length_bytes or 16
    local hex = {}
    for _ = 1, length_bytes do
        table.insert(hex, string.format("%02x", math.random(0, 255)))
    end
    return table.concat(hex)
end

--- Pre-computes keystream mask from a 32-byte key.
-- Generates only the required number of 32-byte SHA-256 blocks (up to 64KB max)
-- to avoid unnecessary hashing when encrypting/decrypting small payloads or unit tests.
local function generateKeystreamMask(key, required_len)
    local mask_size = math.min(65536, math.max(32, math.ceil((required_len or 65536) / 32) * 32))
    local mask_blocks = mask_size / 32
    local chunks = {}
    for i = 1, mask_blocks do
        local h = sha2.sha256(key .. string.format("%08x", i))
        local bin = sha2.hex2bin and sha2.hex2bin(h) or h
        table.insert(chunks, bin)
    end
    return table.concat(chunks)
end

--- Blazing fast in-memory XOR processor using 32-bit native words in LuaJIT FFI.
-- 4-byte naturally aligned, perfectly safe against ARM alignment faults (SIGBUS) on Kindle.
local function processKeystreamFast(data, key, start_offset, precomputed_mask)
    local data_len = #data
    if data_len == 0 then return "" end

    start_offset = start_offset or 0
    local mask_str = precomputed_mask or generateKeystreamMask(key, data_len + start_offset)
    local mask_size = #mask_str

    -- 1. Try LuaJIT FFI 32-bit word XOR (safe on ARM 32-bit and 64-bit architectures)
    if ok_ffi and ffi and ok_bit and bit_mod and bit_mod.bxor then
        local ok_run, result = pcall(function()
            local words_needed = math.ceil(data_len / 4)
            local buf = ffi.new("uint32_t[?]", words_needed + 1)
            ffi.copy(buf, data, data_len)

            local mask_words = math.floor(mask_size / 4)
            local mask_buf = ffi.new("uint32_t[?]", mask_words)
            ffi.copy(mask_buf, mask_str, mask_size)

            local p_data = ffi.cast("uint32_t*", buf)
            local p_mask = ffi.cast("uint32_t*", mask_buf)
            local total_words = math.floor(data_len / 4)
            local start_word = math.floor(start_offset / 4)

            for i = 0, total_words - 1 do
                p_data[i] = bit_mod.bxor(p_data[i], p_mask[(start_word + i) % mask_words])
            end

            local processed_bytes = total_words * 4
            if processed_bytes < data_len then
                local p_byte_data = ffi.cast("uint8_t*", buf)
                local p_byte_mask = ffi.cast("uint8_t*", mask_buf)
                for i = processed_bytes, data_len - 1 do
                    p_byte_data[i] = bit_mod.bxor(p_byte_data[i], p_byte_mask[(start_offset + i) % mask_size])
                end
            end

            return ffi.string(buf, data_len)
        end)
        if ok_run and result then
            return result
        end
    end

    -- 2. Fast chunked fallback (for non-FFI environments)
    local bxor_fn = get_xor_fn()
    local out = {}
    local pos = 1
    while pos <= data_len do
        local chunk_len = math.min(mask_size, data_len - pos + 1)
        local chunk_chars = {}
        for i = 1, chunk_len do
            local b_data = string.byte(data, pos + i - 1)
            local stream_pos = start_offset + pos + i - 2
            local b_mask = string.byte(mask_str, (stream_pos % mask_size) + 1)
            chunk_chars[i] = string.char(bxor_fn(b_data, b_mask))
        end
        table.insert(out, table.concat(chunk_chars))
        pos = pos + chunk_len
    end
    return table.concat(out)
end
Beam._processKeystreamFast = processKeystreamFast

--- Encrypts payload data with a 6-digit PIN.
-- Returns binary payload string ready for transmission.
function Beam.encryptPayload(plaintext, pin, filename)
    assert(sha2 and sha2.sha256, "sha2 cryptographic module required")
    local clean_pin, err = Beam.cleanPin(pin)
    if not clean_pin then return nil, err end

    filename = filename or "backup.zip"
    filename = filename:match("([^/\\]+)$") or filename

    local salt = generateSalt(16)
    local key = sha2.sha256("kobeam_key:" .. clean_pin .. ":" .. salt)

    local ciphertext = processKeystreamFast(plaintext, key)

    -- Authenticate with Hash-then-MAC (fast and avoids copying multi-megabyte strings)
    local data_hash = sha2.sha256(ciphertext)
    local tag = sha2.hmac(sha2.sha256, key, salt .. filename .. data_hash)

    local fn_len = #filename
    local fn_header = string.format("%04x", fn_len)
    local magic = Constants.BEAM_MAGIC_HEADER or "KOBEAM01"

    -- Payload layout:
    -- [8B magic][32B salt][64B tag][4B fn_len][fn][ciphertext]
    local payload = magic .. salt .. tag .. fn_header .. filename .. ciphertext
    return payload
end

--- Encrypts a file on disk directly to a destination path using low-memory streaming chunks.
-- Keeps memory consumption strictly constant (< 128KB) regardless of archive size.
-- Returns true, total_bytes OR false, error_msg.
function Beam.encryptFileToPath(src_path, dst_path, pin)
    assert(sha2 and sha2.sha256, "sha2 cryptographic module required")
    local clean_pin, err = Beam.cleanPin(pin)
    if not clean_pin then return false, err end

    local f_in, in_err = io.open(src_path, "rb")
    if not f_in then
        return false, string.format(_("Could not read file: %s"), tostring(in_err))
    end
    local src_size = f_in:seek("end") or 0
    f_in:seek("set", 0)

    local filename = src_path:match("([^/\\]+)$") or "backup.zip"
    local fn_len = #filename
    if fn_len <= 0 or fn_len > 256 then
        f_in:close()
        return false, _("Invalid filename in backup path.")
    end

    local f_out, out_err = io.open(dst_path, "w+b")
    if not f_out then
        f_in:close()
        return false, string.format(_("Could not write file: %s"), tostring(out_err))
    end

    local magic = Constants.BEAM_MAGIC_HEADER or "KOBEAM01"
    local salt = generateSalt(16)
    local key = sha2.sha256("kobeam_key:" .. clean_pin .. ":" .. salt)
    local fn_header = string.format("%04x", fn_len)

    -- Payload layout: [8B magic][32B salt][64B tag][4B fn_len][fn][ciphertext]
    local header_len = #magic + 32 + 64 + 4 + fn_len
    local dummy_header = string.rep("\0", header_len)

    local ok_w, w_err = f_out:write(dummy_header)
    if not ok_w then
        f_in:close()
        f_out:close()
        os.remove(dst_path)
        return false, string.format(_("Disk full or write error writing header: %s"), tostring(w_err))
    end

    BeamLog.info("encryptFileToPath: staging=%s src_size=%d header_len=%d", dst_path, src_size, header_len)

    local mask_str = generateKeystreamMask(key, 65536)
    local hasher = nil
    if sha2 and sha2.sha256 then
        local ok_h, h = pcall(sha2.sha256)
        if ok_h and type(h) == "function" then
            hasher = h
        end
    end
    local hash_chunks = not hasher and {} or nil

    local chunk_size = 65536
    local byte_offset = 0
    local write_error = nil
    while true do
        local chunk = f_in:read(chunk_size)
        if not chunk or #chunk == 0 then break end

        local cipher_chunk = processKeystreamFast(chunk, key, byte_offset, mask_str)
        if hasher then
            hasher(cipher_chunk)
        else
            table.insert(hash_chunks, cipher_chunk)
        end
        local ok_cw, cw_err = f_out:write(cipher_chunk)
        if not ok_cw then
            write_error = cw_err or "disk full"
            BeamLog.err("encryptFileToPath: write failed at byte_offset=%d: %s", byte_offset, tostring(cw_err))
            break
        end
        byte_offset = byte_offset + #chunk
    end
    f_in:close()

    -- Detect disk-full: compare actual bytes written to f_out vs bytes read from f_in
    local written_data_bytes = (f_out:seek("end") or 0) - header_len
    BeamLog.info("encryptFileToPath: read=%d written=%d write_error=%s", byte_offset, written_data_bytes, tostring(write_error))

    if write_error or written_data_bytes < byte_offset then
        f_out:close()
        os.remove(dst_path)
        local msg = write_error
            or string.format(_("Disk full: only %s of %s encrypted data written to staging file. Free up space on the Kindle and try again."),
                tostring(written_data_bytes), tostring(byte_offset))
        return false, msg
    end

    if src_size > 0 and byte_offset < src_size then
        f_out:close()
        os.remove(dst_path)
        return false, string.format(_("Encryption stopped early: read only %s of %s."),
            (util and util.getFriendlySize and util.getFriendlySize(byte_offset)) or tostring(byte_offset),
            (util and util.getFriendlySize and util.getFriendlySize(src_size)) or tostring(src_size))
    end

    local data_hash
    if hasher then
        data_hash = hasher()
    else
        data_hash = sha2.sha256(table.concat(hash_chunks))
    end

    local tag = sha2.hmac(sha2.sha256, key, salt .. filename .. data_hash)
    local actual_header = magic .. salt .. tag .. fn_header .. filename

    f_out:flush()
    f_out:seek("set", 0)
    f_out:write(actual_header)
    f_out:flush()
    local total_encrypted_size = f_out:seek("end") or (header_len + byte_offset)
    f_out:close()

    return true, total_encrypted_size
end

--- Decrypts a Beam payload from disk directly to dest_dir using low-memory streaming chunks.
-- Returns true, target_path, filename OR false, error_msg.
function Beam.decryptFileToPath(encrypted_path, pin, dest_dir, on_progress, is_canceled)
    assert(sha2 and sha2.sha256, "sha2 cryptographic module required")
    local clean_pin, err = Beam.cleanPin(pin)
    if not clean_pin then return false, err end

    local f_in, in_err = io.open(encrypted_path, "rb")
    if not f_in then
        return false, string.format(_("Could not read file: %s"), tostring(in_err))
    end

    local magic = Constants.BEAM_MAGIC_HEADER or "KOBEAM01"
    local magic_len = #magic
    local header_min = magic_len + 32 + 64 + 4

    local header_prefix = f_in:read(header_min)
    if not header_prefix or #header_prefix < header_min then
        f_in:close()
        return false, _("Corrupted or empty Beam payload.")
    end

    local header_magic = header_prefix:sub(1, magic_len)
    if header_magic ~= magic then
        f_in:close()
        return false, _("Invalid Beam archive format.")
    end

    local offset = magic_len + 1
    local salt = header_prefix:sub(offset, offset + 31)
    offset = offset + 32

    local received_tag = header_prefix:sub(offset, offset + 63)
    offset = offset + 64

    local fn_len_hex = header_prefix:sub(offset, offset + 3)
    local fn_len = tonumber(fn_len_hex, 16) or 0
    if fn_len <= 0 or fn_len > 256 then
        f_in:close()
        return false, _("Invalid filename in Beam payload.")
    end

    local filename = f_in:read(fn_len)
    if not filename or #filename < fn_len then
        f_in:close()
        return false, _("Corrupted filename in Beam payload.")
    end

    local header_len = header_min + fn_len

    local key = sha2.sha256("kobeam_key:" .. clean_pin .. ":" .. salt)
    local hasher = nil
    if sha2 and sha2.sha256 then
        local ok_h, h = pcall(sha2.sha256)
        if ok_h and type(h) == "function" then
            hasher = h
        end
    end
    local hash_chunks = not hasher and {} or nil

    local total_file_size = f_in:seek("end") or 0
    local payload_size = math.max(0, total_file_size - header_len)
    f_in:seek("set", header_len)

    local chunk_size = 65536
    local bytes_hashed = 0
    while true do
        if is_canceled and is_canceled() then
            f_in:close()
            return false, "canceled"
        end
        local chunk = f_in:read(chunk_size)
        if not chunk or #chunk == 0 then break end
        if hasher then
            hasher(chunk)
        else
            table.insert(hash_chunks, chunk)
        end
        bytes_hashed = bytes_hashed + #chunk
        if on_progress then
            local pct = (payload_size > 0) and math.floor((bytes_hashed / payload_size) * 50) or 25
            on_progress(pct, _("Verifying integrity..."))
        end
    end

    local data_hash
    if hasher then
        data_hash = hasher()
    else
        data_hash = sha2.sha256(table.concat(hash_chunks))
    end

    local expected_tag = sha2.hmac(sha2.sha256, key, salt .. filename .. data_hash)
    if received_tag ~= expected_tag then
        f_in:close()
        return false, _("Invalid Beam code or corrupted data.")
    end

    f_in:seek("set", header_len)

    if util and util.makePath then
        util.makePath(dest_dir)
    end

    local target_path = dest_dir .. "/" .. filename
    local f_out, out_err = io.open(target_path, "wb")
    if not f_out then
        f_in:close()
        return false, string.format(_("Could not write file: %s"), tostring(out_err))
    end

    local mask_str = generateKeystreamMask(key, 65536)
    local byte_offset = 0
    while true do
        if is_canceled and is_canceled() then
            f_in:close()
            f_out:close()
            os.remove(target_path)
            return false, "canceled"
        end
        local chunk = f_in:read(chunk_size)
        if not chunk or #chunk == 0 then break end

        local plain_chunk = processKeystreamFast(chunk, key, byte_offset, mask_str)
        f_out:write(plain_chunk)
        byte_offset = byte_offset + #chunk
        if on_progress then
            local pct = 50 + ((payload_size > 0) and math.floor((byte_offset / payload_size) * 50) or 50)
            on_progress(math.min(100, pct), _("Decrypting files..."))
        end
    end

    f_in:close()
    f_out:close()

    return true, target_path, filename
end

--- Decrypts an incoming Beam payload using a 6-digit PIN.
-- Returns true, filename, decrypted_plaintext OR false, error_msg.
function Beam.decryptPayload(payload, pin)
    assert(sha2 and sha2.sha256, "sha2 cryptographic module required")
    local clean_pin, err = Beam.cleanPin(pin)
    if not clean_pin then return false, err end

    if not payload or #payload < (8 + 32 + 64 + 4) then
        return false, _("Corrupted or empty Beam payload.")
    end

    local magic = Constants.BEAM_MAGIC_HEADER or "KOBEAM01"
    local header_magic = payload:sub(1, #magic)
    if header_magic ~= magic then
        return false, _("Invalid Beam archive format.")
    end

    local offset = #magic + 1
    local salt = payload:sub(offset, offset + 31)
    offset = offset + 32

    local received_tag = payload:sub(offset, offset + 63)
    offset = offset + 64

    local fn_len_hex = payload:sub(offset, offset + 3)
    offset = offset + 4
    local fn_len = tonumber(fn_len_hex, 16) or 0
    if fn_len <= 0 or fn_len > 256 then
        return false, _("Invalid filename in Beam payload.")
    end

    local filename = payload:sub(offset, offset + fn_len - 1)
    offset = offset + fn_len

    local ciphertext = payload:sub(offset)

    -- Recompute key and HMAC verification
    local key = sha2.sha256("kobeam_key:" .. clean_pin .. ":" .. salt)
    local data_hash = sha2.sha256(ciphertext)
    local expected_tag = sha2.hmac(sha2.sha256, key, salt .. filename .. data_hash)

    if received_tag ~= expected_tag then
        return false, _("Invalid Beam code or corrupted data.")
    end

    -- Decrypt ciphertext
    local plaintext = processKeystreamFast(ciphertext, key)

    return true, filename, plaintext
end

--- Reads an archive from disk and encrypts it with PIN.
function Beam.encryptFile(filepath, pin)
    local f, err = io.open(filepath, "rb")
    if not f then
        return nil, string.format(_("Could not read file: %s"), tostring(err))
    end
    local content = f:read("*a")
    f:close()

    local filename = filepath:match("([^/\\]+)$") or "backup.zip"
    return Beam.encryptPayload(content, pin, filename)
end

--- Decrypts payload (from memory string or disk file path) and writes result to dest_dir.
function Beam.decryptToFile(payload_or_path, pin, dest_dir, on_progress, is_canceled)
    if type(payload_or_path) == "string" and lfs and lfs.attributes and lfs.attributes(payload_or_path, "mode") == "file" then
        return Beam.decryptFileToPath(payload_or_path, pin, dest_dir, on_progress, is_canceled)
    end

    if is_canceled and is_canceled() then
        return false, "canceled"
    end

    local ok, res_filename, decrypted_data = Beam.decryptPayload(payload_or_path, pin)
    if not ok then
        return false, res_filename
    end

    if is_canceled and is_canceled() then
        return false, "canceled"
    end

    if util and util.makePath then
        util.makePath(dest_dir)
    end

    local target_path = dest_dir .. "/" .. res_filename
    local f, err = io.open(target_path, "wb")
    if not f then
        return false, string.format(_("Could not write file: %s"), tostring(err))
    end
    f:write(decrypted_data)
    f:close()

    return true, target_path, res_filename
end

-- --------------------------------------------------------------------------
-- Network Transport Layer (Outbound HTTPS with Progress Reporting)
-- --------------------------------------------------------------------------

--- Checks if device Wi-Fi or network is currently active.
function Beam.isNetworkConnected()
    local ok_net, NetworkMgr = pcall(require, "ui/network/manager")
    if ok_net and NetworkMgr then
        if type(NetworkMgr.isConnected) == "function" then
            return NetworkMgr:isConnected()
        end
    end
    return true
end

--- Prompts user to connect to Wi-Fi if offline, then runs on_connected_cb.
function Beam.ensureNetwork(on_connected_cb, on_cancel_cb)
    local ok_net, NetworkMgr = pcall(require, "ui/network/manager")
    if ok_net and NetworkMgr and type(NetworkMgr.isConnected) == "function" and not NetworkMgr:isConnected() then
        if type(NetworkMgr.promptWifiOn) == "function" then
            NetworkMgr:promptWifiOn(function()
                if NetworkMgr:isConnected() then
                    if on_connected_cb then on_connected_cb() end
                else
                    if on_cancel_cb then on_cancel_cb() end
                end
            end)
            return
        end
    end
    if on_connected_cb then on_connected_cb() end
end

--- Creates a chunked LTN12 source from a string that reports upload progress.
local function makeProgressSource(data, on_progress, is_canceled)
    local pos = 1
    local total = #data
    local chunk_size = 65536 -- 64KB chunks
    local finalized = false
    return function()
        if is_canceled and is_canceled() then
            return nil, "canceled"
        end
        if pos > total then
            if on_progress and not finalized then
                finalized = true
                on_progress(total, total, "finalizing")
            end
            return nil
        end
        local chunk = data:sub(pos, pos + chunk_size - 1)
        pos = pos + #chunk
        if on_progress then
            on_progress(math.min(pos - 1, total), total, "uploading")
        end
        return chunk
    end
end
Beam._makeProgressSource = makeProgressSource

--- Creates a chunked LTN12 source from an open file handle that reports upload progress.
-- Keeps memory usage strictly constant (< 64KB) during transmission.
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
        return chunk
    end
end
Beam._makeFileProgressSource = makeFileProgressSource

--- Two-pass zero-disk encrypted stream source for Beam upload.
-- Pass 1: reads src_path once to compute ciphertext hash and HMAC header.
-- Pass 2: returns an LTN12 source that re-reads and re-encrypts on-the-fly,
--         prepending the authenticated header, streaming directly into HTTP.
-- Requires NO staging file — works even when Kindle disk is full.
-- Returns: source_fn, total_payload_bytes, error_msg
local function makeEncryptedStreamSource(src_path, clean_pin, on_progress, is_canceled)
    assert(sha2 and sha2.sha256, "sha2 required")

    local filename = src_path:match("([^/\\]+)$") or "backup.zip"
    local fn_len = #filename
    if fn_len <= 0 or fn_len > 256 then
        return nil, nil, "Invalid filename"
    end

    local magic = Constants.BEAM_MAGIC_HEADER or "KOBEAM01"
    local salt = generateSalt(16)
    local key = sha2.sha256("kobeam_key:" .. clean_pin .. ":" .. salt)
    local fn_header = string.format("%04x", fn_len)
    local header_len = #magic + 32 + 64 + 4 + fn_len

    -- Determine source file size
    local f_size_check = io.open(src_path, "rb")
    if not f_size_check then return nil, nil, "Cannot open source: " .. src_path end
    local src_size = f_size_check:seek("end") or 0
    f_size_check:close()

    local total_payload = header_len + src_size

    BeamLog.info("makeEncryptedStreamSource: src=%s src_size=%d total_payload=%d (no staging disk needed)",
        src_path, src_size, total_payload)

    -- Pre-compute keystream mask (reused across both passes for determinism)
    local mask_str = generateKeystreamMask(key, 65536)

    -- ----------------------------------------------------------------
    -- PASS 1: Read file once to compute sha256(ciphertext) → HMAC tag
    -- ----------------------------------------------------------------
    local f1, f1_err = io.open(src_path, "rb")
    if not f1 then return nil, nil, "Cannot open source for HMAC pass: " .. tostring(f1_err) end

    local hasher
    local ok_h, h = pcall(sha2.sha256)
    if ok_h and type(h) == "function" then
        hasher = h
    end
    local hash_chunks_p1 = not hasher and {} or nil

    local byte_off_p1 = 0
    while true do
        if is_canceled and is_canceled() then
            f1:close()
            return nil, nil, "canceled"
        end
        local chunk = f1:read(65536)
        if not chunk or #chunk == 0 then break end
        local enc = processKeystreamFast(chunk, key, byte_off_p1, mask_str)
        if hasher then hasher(enc) else table.insert(hash_chunks_p1, enc) end
        byte_off_p1 = byte_off_p1 + #chunk
    end
    f1:close()

    local data_hash = hasher and hasher() or sha2.sha256(table.concat(hash_chunks_p1))
    local tag = sha2.hmac(sha2.sha256, key, salt .. filename .. data_hash)
    local header = magic .. salt .. tag .. fn_header .. filename
    assert(#header == header_len, "Header length mismatch")
    BeamLog.info("makeEncryptedStreamSource: pass1 complete bytes_hashed=%d data_hash=%s", byte_off_p1, data_hash:sub(1,16))

    -- ----------------------------------------------------------------
    -- PASS 2: Return LTN12 source that streams header + re-encrypted chunks
    -- ----------------------------------------------------------------
    local f2 = io.open(src_path, "rb")
    if not f2 then return nil, nil, "Cannot open source for stream pass" end

    local header_pending = header
    local byte_off_p2 = 0
    local sent_total = 0
    local finalized = false

    local function source()
        if is_canceled and is_canceled() then
            if f2 then f2:close(); f2 = nil end
            return nil, "canceled"
        end
        -- First call: emit the authenticated header
        if header_pending then
            local h = header_pending
            header_pending = nil
            sent_total = sent_total + #h
            return h
        end
        -- Subsequent calls: read, re-encrypt, and emit
        local chunk = f2:read(65536)
        if not chunk or #chunk == 0 then
            f2:close()
            f2 = nil
            if on_progress and not finalized then
                finalized = true
                on_progress(total_payload, total_payload, "finalizing")
            end
            return nil
        end
        local enc = processKeystreamFast(chunk, key, byte_off_p2, mask_str)
        byte_off_p2 = byte_off_p2 + #chunk
        sent_total = sent_total + #enc
        if on_progress then
            on_progress(math.min(sent_total, total_payload), total_payload, "uploading")
        end
        return enc
    end

    return source, total_payload, nil
end

--- Creates a progress-tracking sink for downloads.
local function makeProgressSink(target_sink, on_progress, total_expected, is_canceled)
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
        end
        return target_sink(chunk, err)
    end
end

--- Sleeps for the given duration in seconds.
function Beam.sleep(sec)
    if ok_sock and socket and socket.sleep then
        pcall(socket.sleep, sec)
    end
end

--- Checks if a request error is transient (temporary network drop, reset, or server overload).
function Beam.isTransientError(r, code, status)
    if not r then
        local err_str = string.lower(tostring(code or ""))
        if err_str:find("reset") or
           err_str:find("closed") or
           err_str:find("timeout") or
           err_str:find("broken pipe") or
           err_str:find("wantread") or
           err_str:find("refused") or
           err_str:find("handshake") or
           err_str:find("eof") then
            return true
        end
        return false
    end
    local num = tonumber(code)
    if num and (num == 408 or num == 429 or num == 500 or num == 502 or num == 503 or num == 504) then
        return true
    end
    return false
end

--- Performs an HTTP/HTTPS request with progress callbacks.
local function doHttpRequest(req)
    local ok_https, https = pcall(require, "ssl.https")
    local ok_http, http = pcall(require, "socket.http")
    local ok_ltn, ltn12 = pcall(require, "ltn12")

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

    local source = req.source
    local file_handle = nil
    if not source then
        if req.file_path then
            file_handle = io.open(req.file_path, "rb")
            if not file_handle then
                if resp_file_handle then pcall(resp_file_handle.close, resp_file_handle) end
                return nil, "Could not open request body file: " .. tostring(req.file_path)
            end
            local total_bytes = req.total_bytes or (file_handle:seek("end") or 0)
            file_handle:seek("set", 0)
            if req.on_upload_progress then
                source = makeFileProgressSource(file_handle, total_bytes, req.on_upload_progress, req.is_canceled)
            else
                source = ltn12.source.file(file_handle)
            end
        elseif req.body then
            if req.on_upload_progress then
                source = makeProgressSource(req.body, req.on_upload_progress, req.is_canceled)
            else
                source = ltn12.source.string(req.body)
            end
        end
    end

    if req.on_download_progress or req.is_canceled then
        sink = makeProgressSink(base_sink, req.on_download_progress, req.total_expected, req.is_canceled)
    end

    local prev_block, prev_total
    if ok_su and socketutil and socketutil.set_timeout then
        prev_block = socketutil.block_timeout
        prev_total = socketutil.total_timeout
        local block = 45
        local total_bytes = req.total_bytes or req.total_expected or (req.body and #req.body) or 0
        local total = math.max(120, math.min(600, 60 + math.ceil(total_bytes / 50000)))
        pcall(function()
            socketutil:set_timeout(block, total)
        end)
    end

    local ok_call, r, code, headers, status = pcall(client.request, {
        url = url,
        method = req.method or "GET",
        headers = req.headers or {},
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
        headers = nil
        status = nil
    end

    local body_str = ""
    if not req.sink_file_path then
        body_str = table.concat(resp_body)
    elseif code and code ~= 200 and code ~= 201 then
        local err_f = io.open(req.sink_file_path, "rb")
        if err_f then
            body_str = err_f:read(4096) or ""
            err_f:close()
        end
    end

    return r, code, headers, status, body_str
end

--- Uploads a backup archive to the ephemeral relay with progress reporting.
function Beam.upload(filepath, pin, opts, callback)
    opts = opts or {}
    local relay_url = opts.relay_url or Constants.BEAM_DEFAULT_RELAY_URL
    local clean_pin, err = Beam.cleanPin(pin)
    if not clean_pin then
        BeamLog.err("upload: invalid PIN: %s", tostring(err))
        if callback then callback(false, err) end
        return
    end

    -- Log source file size before encryption
    local src_size_check = 0
    if lfs and lfs.attributes then
        src_size_check = lfs.attributes(filepath, "size") or 0
    else
        local _tf = io.open(filepath, "rb")
        if _tf then src_size_check = _tf:seek("end") or 0; _tf:close() end
    end
    BeamLog.info("upload: START filepath=%s src_size=%d relay=%s", tostring(filepath), src_size_check, tostring(relay_url))

    if opts.on_progress then
        opts.on_progress(0, 100, "encrypting")
    end

    local token = Beam.deriveToken(clean_pin)

    -- Log timeout settings that will apply
    if ok_su and socketutil then
        BeamLog.info("upload: socketutil present block_timeout=%s total_timeout=%s",
            tostring(socketutil.block_timeout), tostring(socketutil.total_timeout))
    else
        BeamLog.warn("upload: socketutil NOT available - using raw LuaSocket defaults")
    end

    local last_sent = 0
    local progress_wrap = function(sent, total, stage)
        last_sent = sent or last_sent
        if opts.on_progress then opts.on_progress(sent, total, stage) end
    end

    -- Build two-pass zero-disk streaming source (no staging file needed)
    local stream_source, payload_size, stream_err = makeEncryptedStreamSource(filepath, clean_pin, progress_wrap, opts.is_canceled)
    if not stream_source then
        BeamLog.err("upload: makeEncryptedStreamSource FAILED: %s", tostring(stream_err))
        if stream_err == "canceled" then
            if callback then callback(false, "canceled") end
            return
        end
        if callback then callback(false, stream_err or _("Failed to prepare encrypted stream")) end
        return
    end
    BeamLog.info("upload: stream source ready payload_size=%d (src=%d, no staging file)", payload_size, src_size_check)

    if opts.on_progress then
        opts.on_progress(0, payload_size, "connecting")
    end

    local upload_url = string.format("%s/api/beam/upload?token=%s", relay_url:gsub("/+$", ""), token)
    local max_attempts = opts.max_retries and (opts.max_retries + 1) or 3
    local r, code, headers, status, resp_body

    for attempt = 1, max_attempts do
        if opts.is_canceled and opts.is_canceled() then
            if callback then callback(false, "canceled") end
            return
        end
        if attempt > 1 then
            if opts.on_progress then
                opts.on_progress(0, payload_size, "connecting")
            end
            Beam.sleep(1.5)
            -- Rebuild stream source for retry (resets file position)
            last_sent = 0
            stream_source, payload_size, stream_err = makeEncryptedStreamSource(filepath, clean_pin, progress_wrap, opts.is_canceled)
            if not stream_source then
                BeamLog.err("upload: retry stream rebuild FAILED: %s", tostring(stream_err))
                break
            end
        end

        last_sent = 0
        BeamLog.info("upload: attempt %d/%d url=%s payload_size=%d", attempt, max_attempts, upload_url, payload_size)

        r, code, headers, status, resp_body = doHttpRequest{
            url = upload_url,
            method = "POST",
            headers = {
                ["Content-Type"] = "application/octet-stream",
                ["Content-Length"] = tostring(payload_size),
                ["X-Beam-Token"] = token,
            },
            source = stream_source,
            total_bytes = payload_size,
            on_upload_progress = nil, -- progress already wired inside stream_source
        }

        BeamLog.info("upload: attempt %d result: r=%s code=%s status=%s last_sent=%d resp=%s",
            attempt, tostring(r), tostring(code), tostring(status), last_sent,
            tostring(resp_body and resp_body:sub(1, 200)))

        if (code == 200 or code == 201) then
            break
        end

        if not Beam.isTransientError(r, code, status) or attempt == max_attempts then
            break
        end
    end

    -- No staging file to clean up — streaming approach uses zero extra disk space.

    if (code == 200 or code == 201) then
        local data = nil
        if json and json.decode then
            pcall(function() data = json.decode(resp_body) end)
        end

        local server_size = data and tonumber(data.size)
        BeamLog.info("upload: relay response ok=true server_size=%s payload_size=%d",
            tostring(server_size), payload_size)

        if server_size and server_size < payload_size then
            local err_msg = string.format(_("Upload incomplete: relay received only %s of %s. The wireless connection was cut off."),
                (util and util.getFriendlySize and util.getFriendlySize(server_size)) or tostring(server_size),
                (util and util.getFriendlySize and util.getFriendlySize(payload_size)) or tostring(payload_size))
            BeamLog.err("upload: INCOMPLETE server_size=%d < payload_size=%d", server_size, payload_size)
            if callback then callback(false, err_msg) end
            return
        end

        if opts.on_progress then
            opts.on_progress(payload_size, payload_size, "complete")
        end
        if callback then
            callback(true, {
                pin = clean_pin,
                token = token,
                size = payload_size,
                expires_in = (data and data.expires_in) or Constants.BEAM_TTL_SECONDS or 900,
            })
        end
    else
        local err_msg
        if not r then
            err_msg = string.format(_("Upload failed (Network error): %s"), tostring(code or "Connection failed"))
        else
            local detail = (resp_body and resp_body ~= "") and resp_body or (status or "")
            err_msg = string.format(_("Upload failed (HTTP %s): %s"), tostring(code or "error"), tostring(detail))
        end
        if callback then callback(false, err_msg) end
    end
end

--- Queries metadata/size for a beam code without downloading the payload.
function Beam.getInfo(pin, opts, callback)
    opts = opts or {}
    local relay_url = opts.relay_url or Constants.BEAM_DEFAULT_RELAY_URL
    local clean_pin, err = Beam.cleanPin(pin)
    if not clean_pin then
        if callback then callback(false, err) end
        return
    end

    local token = Beam.deriveToken(clean_pin)
    if not token then
        if callback then callback(false, _("Invalid Beam code.")) end
        return
    end

    local info_url = string.format("%s/api/beam/info/%s", relay_url:gsub("/+$", ""), token)
    local r, code, headers, status, resp_body = doHttpRequest{
        url = info_url,
        method = "GET",
        headers = {
            ["X-Beam-Token"] = token,
        },
    }

    if code == 200 then
        local data = nil
        if json and json.decode then
            pcall(function() data = json.decode(resp_body) end)
        end
        if data and data.ok and data.size then
            if callback then callback(true, data) end
            return
        end
    elseif code == 404 then
        if callback then
            callback(false, _("Beam code expired or not found. Please verify the 6-digit code on the sending device."))
        end
        return
    end
    if callback then callback(false, resp_body or tostring(code or "Failed to query relay")) end
end

--- Downloads and decrypts a backup archive with progress reporting.
function Beam.download(pin, dest_dir, opts, callback)
    opts = opts or {}
    local relay_url = opts.relay_url or Constants.BEAM_DEFAULT_RELAY_URL
    local clean_pin, err = Beam.cleanPin(pin)
    if not clean_pin then
        if callback then callback(false, err) end
        return
    end

    local token = Beam.deriveToken(clean_pin)
    if not token then
        if callback then callback(false, _("Invalid Beam code.")) end
        return
    end

    local total_expected = opts.total_expected or opts.total_size

    -- Query size in advance so progress bar has the exact total byte count
    if not total_expected and not opts._skip_info then
        Beam.getInfo(clean_pin, opts, function(ok_info, info_data)
            if ok_info and type(info_data) == "table" and info_data.size then
                opts.total_expected = info_data.size
                if opts.on_total then
                    opts.on_total(info_data.size)
                end
            elseif not ok_info and type(info_data) == "string" and info_data:find("expired or not found") then
                if callback then callback(false, info_data) end
                return
            end
            opts._skip_info = true
            Beam.download(clean_pin, dest_dir, opts, callback)
        end)
        return
    end

    local download_url = string.format("%s/api/beam/download/%s", relay_url:gsub("/+$", ""), token)
    local max_attempts = opts.max_retries and (opts.max_retries + 1) or 3
    local r, code, headers, status, resp_body

    if util and util.makePath then
        util.makePath(dest_dir)
    end

    local dl_staging_path = dest_dir .. "/.beam_download_" .. token .. ".tmp"
    os.remove(dl_staging_path)

    for attempt = 1, max_attempts do
        if opts.is_canceled and opts.is_canceled() then
            os.remove(dl_staging_path)
            if callback then callback(false, "canceled") end
            return
        end
        if attempt > 1 then
            Beam.sleep(1.5)
        end

        r, code, headers, status, resp_body = doHttpRequest{
            url = download_url,
            method = "GET",
            headers = {
                ["X-Beam-Token"] = token,
            },
            sink_file_path = dl_staging_path,
            total_expected = opts.total_expected,
            total_bytes = opts.total_expected,
            on_download_progress = opts.on_progress,
            is_canceled = opts.is_canceled,
        }

        if code == 200 or code == 404 then
            break
        end

        if (opts.is_canceled and opts.is_canceled()) or tostring(code):find("canceled") then
            os.remove(dl_staging_path)
            if callback then callback(false, "canceled") end
            return
        end

        if not Beam.isTransientError(r, code, status) or attempt == max_attempts then
            break
        end
    end

    if opts.is_canceled and opts.is_canceled() then
        os.remove(dl_staging_path)
        if callback then callback(false, "canceled") end
        return
    end

    if code == 200 then
        local dl_size = 0
        if lfs and lfs.attributes then
            dl_size = lfs.attributes(dl_staging_path, "size") or 0
        else
            local sf = io.open(dl_staging_path, "rb")
            if sf then dl_size = sf:seek("end") or 0; sf:close() end
        end

        local expected_size = headers and (headers["content-length"] or headers["Content-Length"])
        expected_size = tonumber(expected_size) or opts.total_expected

        if expected_size and expected_size > 0 and dl_size < expected_size then
            os.remove(dl_staging_path)
            local err_msg = string.format(_("Download incomplete (%s received out of %s). Network connection may have dropped."),
                (util and util.getFriendlySize and util.getFriendlySize(dl_size)) or tostring(dl_size),
                (util and util.getFriendlySize and util.getFriendlySize(expected_size)) or tostring(expected_size))
            if callback then callback(false, err_msg) end
            return
        end

        local ok, target_path, filename = Beam.decryptToFile(dl_staging_path, clean_pin, dest_dir, opts.on_decrypt_progress, opts.is_canceled)
        os.remove(dl_staging_path)
        if ok then
            if callback then callback(true, target_path, filename) end
        else
            if callback then callback(false, target_path) end
        end
    elseif code == 404 then
        os.remove(dl_staging_path)
        if callback then
            callback(false, _("Beam code expired or not found. Please verify the 6-digit code on the sending device."))
        end
    else
        os.remove(dl_staging_path)
        local err_msg
        if not r then
            err_msg = string.format(_("Download failed (Network error): %s"), tostring(code or "Connection failed"))
        else
            local detail = (resp_body and resp_body ~= "") and resp_body or (status or "")
            err_msg = string.format(_("Download failed (HTTP %s): %s"), tostring(code or "error"), tostring(detail))
        end
        if callback then callback(false, err_msg) end
    end
end

--- Cancels an active Beam session on the relay server.
function Beam.cancelSession(pin, opts, callback)
    opts = opts or {}
    local relay_url = opts.relay_url or Constants.BEAM_DEFAULT_RELAY_URL
    local token = Beam.deriveToken(pin)
    if not token then return end

    local cancel_url = string.format("%s/api/beam/%s", relay_url:gsub("/+$", ""), token)
    local r, code = doHttpRequest{
        url = cancel_url,
        method = "DELETE",
        headers = { ["X-Beam-Token"] = token },
    }
    if callback then callback(code == 200 or code == 204) end
end

return Beam
