--[[--
backup_archiver.lua
Archival engine supporting .zip, .tar.gz, and .tar archives.
Uses KOReader's ffi/archiver (libarchive) with an embedded pure Lua TAR fallback.
--]]

local Constants = require("backup_constants")

local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
if not ok_lfs or not lfs then
    ok_lfs, lfs = pcall(require, "lfs")
end
if not ok_lfs or type(lfs) ~= "table" then
    lfs = nil
end

local ok_arch, Archiver = pcall(require, "ffi/archiver")
local ok_ds, DataStorage = pcall(require, "datastorage")
local ok_util, util = pcall(require, "util")

local cached_libarchive = nil

local ArchiverMgr = {}

-- --------------------------------------------------------------------------
-- Pure Lua TAR Writer (USTAR standard)
-- Zero-dependency fallback if libarchive writer bindings are not available
-- --------------------------------------------------------------------------
local TarWriter = {}

function TarWriter:new()
    local o = { handle = nil, filepath = nil }
    setmetatable(o, { __index = self })
    return o
end

local function octal(val, len)
    return string.format("%0" .. (len - 1) .. "o\0", val or 0)
end

function TarWriter:open(filepath)
    self.filepath = filepath
    local f, err = io.open(filepath, "wb")
    if not f then return false, err end
    self.handle = f
    return true
end

function TarWriter:addFileFromMemory(entry_path, content, mtime)
    if not self.handle then return false, "Archive not open" end
    content = content or ""
    mtime = mtime or os.time()
    local size = #content

    -- 512-byte POSIX ustar header
    local header = string.rep("\0", 512)
    local function put(offset, str)
        header = header:sub(1, offset - 1) .. str .. header:sub(offset + #str)
    end

    local path = entry_path:gsub("^/+", "")
    put(1, path:sub(1, 100))                         -- name (100)
    put(101, octal(420, 8))                          -- mode 0644 (8)
    put(109, octal(0, 8))                            -- uid (8)
    put(117, octal(0, 8))                            -- gid (8)
    put(125, octal(size, 12))                        -- size (12)
    put(137, octal(mtime, 12))                       -- mtime (12)
    put(157, "0")                                    -- typeflag: regular file (1)
    put(258, "ustar\0")                              -- magic (6)
    put(264, "00")                                   -- version (2)

    -- Calculate checksum (bytes 149-156 treated as spaces)
    put(149, "        ")
    local chksum = 0
    for i = 1, 512 do
        chksum = chksum + string.byte(header, i)
    end
    put(149, string.format("%06o\0 ", chksum))

    self.handle:write(header)
    if size > 0 then
        self.handle:write(content)
        local pad = (512 - (size % 512)) % 512
        if pad > 0 then
            self.handle:write(string.rep("\0", pad))
        end
    end
    return true
end

function TarWriter:addFileFromDisk(entry_path, disk_path, mtime, on_chunk, is_canceled)
    if is_canceled and is_canceled() then return false, "canceled" end
    if not self.handle then return false, "Archive not open" end
    local f = io.open(disk_path, "rb")
    if not f then return false, "Cannot open " .. tostring(disk_path) end

    local size = f:seek("end") or 0
    f:seek("set", 0)

    if not mtime and lfs and lfs.attributes then
        local attr = lfs.attributes(disk_path)
        mtime = attr and attr.modification
    end
    mtime = mtime or os.time()

    -- 512-byte POSIX ustar header
    local header = string.rep("\0", 512)
    local function put(offset, str)
        header = header:sub(1, offset - 1) .. str .. header:sub(offset + #str)
    end

    local path = entry_path:gsub("^/+", "")
    put(1, path:sub(1, 100))                         -- name (100)
    put(101, octal(420, 8))                          -- mode 0644 (8)
    put(109, octal(0, 8))                            -- uid (8)
    put(117, octal(0, 8))                            -- gid (8)
    put(125, octal(size, 12))                        -- size (12)
    put(137, octal(mtime, 12))                       -- mtime (12)
    put(157, "0")                                    -- typeflag: regular file (1)
    put(258, "ustar\0")                              -- magic (6)
    put(264, "00")                                   -- version (2)

    -- Calculate checksum (bytes 149-156 treated as spaces)
    put(149, "        ")
    local chksum = 0
    for i = 1, 512 do
        chksum = chksum + string.byte(header, i)
    end
    put(149, string.format("%06o\0 ", chksum))

    self.handle:write(header)
    if size > 0 then
        local CHUNK_SIZE = 65536
        local bytes_read = 0
        while bytes_read < size do
            if is_canceled and is_canceled() then
                f:close()
                return false, "canceled"
            end
            local chunk = f:read(CHUNK_SIZE)
            if not chunk or #chunk == 0 then break end
            self.handle:write(chunk)
            bytes_read = bytes_read + #chunk
            if on_chunk then on_chunk(#chunk) end
        end
        local pad = (512 - (size % 512)) % 512
        if pad > 0 then
            self.handle:write(string.rep("\0", pad))
        end
    end
    f:close()
    return true
end

function TarWriter:close()
    if self.handle then
        -- Two 512-byte blocks of zeros denote EOF
        self.handle:write(string.rep("\0", 1024))
        self.handle:close()
        self.handle = nil
    end
end

-- --------------------------------------------------------------------------
-- Archiver Manager Core API
-- --------------------------------------------------------------------------

--- Checks if a filename/directory should be excluded from backups.
function ArchiverMgr.shouldExclude(name, full_path)
    if not name or name == "" then return true end
    if name == "." or name == ".." then return true end
    if name == ".git" or name == ".github" or name == ".DS_Store" or name == "Thumbs.db" or name == "__MACOSX" then return true end
    if name:match("^%._") then return true end
    if name:match("%.tmp$") or name:match("%.bak$") or name == "crash.log" then return true end
    if name == "cache" or name == "backup_staging" then return true end
    if name:match("^bookinfo_cache%.sqlite3") then return true end
    if name:match("%.log%.old$") or name:match("%.log$") then return true end
    return false
end

--- Recursively scans a directory and collects file entries.
-- @param base_dir string: root on disk
-- @param entry_prefix string: prefix in archive
-- @param is_plugins_dir boolean: if true, skips core KOReader plugins
-- @param is_settings_dir boolean: if true, skips statistics and vocabulary databases
-- @param allowed_items table: optional set of top-level item names to include
-- @return table: array of { disk_path = "...", archive_path = "..." }
function ArchiverMgr.scanDirectory(base_dir, entry_prefix, is_plugins_dir, is_settings_dir, allowed_items)
    local files = {}
    if not lfs or not lfs.attributes then return files end
    if lfs.attributes(base_dir, "mode") ~= "directory" then return files end

    local function recurse(curr_dir, rel_path)
        for item in lfs.dir(curr_dir) do
            if not ArchiverMgr.shouldExclude(item, curr_dir .. "/" .. item) then
                local full = curr_dir .. "/" .. item
                local rel = (rel_path ~= "") and (rel_path .. "/" .. item) or item
                local mode = lfs.attributes(full, "mode")

                -- If allowed_items filter is provided, enforce it on top-level entries
                local item_allowed = true
                if rel_path == "" and allowed_items then
                    local matched = allowed_items[item]
                    if not matched then
                        local stem = item:gsub("%.ifo$", ""):gsub("%.idx$", ""):gsub("%.dict%.dz$", ""):gsub("%.dict$", ""):gsub("%.dz$", "")
                        if allowed_items[stem] or allowed_items[stem .. ".ifo"] then
                            matched = true
                        end
                    end
                    if not matched then
                        item_allowed = false
                    end
                end

                if item_allowed then
                    if mode == "directory" then
                        -- If scanning plugins directory, only include valid .koplugin directories, skip core KOReader plugins
                        local skip = false
                        if is_plugins_dir and rel_path == "" then
                            local clean_name = item:lower()
                            if Constants.CORE_KOREADER_PLUGINS[clean_name] or not item:match("%.koplugin$") then
                                skip = true
                            end
                        end
                        if not skip then
                            recurse(full, rel)
                        end
                    elseif mode == "file" then
                        local skip = false
                        if is_settings_dir and (item:match("%.sqlite3") or item:match("%.db") or item:match("%.sqlite")) then
                            skip = true
                        end
                        if not skip then
                            table.insert(files, {
                                disk_path = full,
                                archive_path = (entry_prefix ~= "") and (entry_prefix .. "/" .. rel) or rel,
                            })
                        end
                    end
                end
            end
        end
    end

    recurse(base_dir, "")
    return files
end

--- Scans and returns list of installed third-party user plugins.
-- @param data_dir string: KOReader data directory
-- @return table: sorted array of plugin directory names
function ArchiverMgr.getAvailablePlugins(data_dir)
    local list = {}
    local p_dir = (data_dir or ".") .. "/plugins"
    if not lfs or not lfs.attributes or lfs.attributes(p_dir, "mode") ~= "directory" then
        return list
    end
    for item in lfs.dir(p_dir) do
        if not ArchiverMgr.shouldExclude(item, p_dir .. "/" .. item) then
            local full = p_dir .. "/" .. item
            if lfs.attributes(full, "mode") == "directory" and item:match("%.koplugin$") then
                local clean_name = item:lower()
                if not Constants.CORE_KOREADER_PLUGINS[clean_name] then
                    table.insert(list, item)
                end
            end
        end
    end
    table.sort(list)
    return list
end

--- Scans and returns list of installed user patches.
-- @param data_dir string: KOReader data directory
-- @return table: sorted array of patch file names
function ArchiverMgr.getAvailablePatches(data_dir)
    local list = {}
    local pt_dir = (data_dir or ".") .. "/patches"
    if not lfs or not lfs.attributes or lfs.attributes(pt_dir, "mode") ~= "directory" then
        return list
    end
    for item in lfs.dir(pt_dir) do
        if not ArchiverMgr.shouldExclude(item, pt_dir .. "/" .. item) then
            table.insert(list, item)
        end
    end
    table.sort(list)
    return list
end

--- Scans and returns list of installed custom fonts.
-- @param data_dir string: KOReader data directory
-- @return table: sorted array of font file/folder names
function ArchiverMgr.getAvailableFonts(data_dir)
    local list = {}
    local f_dir = (data_dir or ".") .. "/fonts"
    if not lfs or not lfs.attributes or lfs.attributes(f_dir, "mode") ~= "directory" then
        return list
    end
    for item in lfs.dir(f_dir) do
        if not ArchiverMgr.shouldExclude(item, f_dir .. "/" .. item) then
            local full = f_dir .. "/" .. item
            local mode = lfs.attributes(full, "mode")
            local lower = item:lower()
            if mode == "directory" or lower:match("%.[ot]tf$") or lower:match("%.ttc$") or lower:match("%.woff2?$") then
                table.insert(list, item)
            end
        end
    end
    table.sort(list)
    return list
end

--- Scans and returns list of installed dictionaries and OCR datasets.
-- @param data_dir string: KOReader data directory
-- @return table: sorted array of dictionary/tessdata items
function ArchiverMgr.getAvailableDictionaries(data_dir)
    local list = {}
    local seen = {}
    local base = data_dir or "."

    local dict_dirs = {
        base .. "/data/dict",
        base .. "/dict",
        base .. "/data/dict_ext",
    }
    if _G.G_defaults and type(_G.G_defaults.readSetting) == "function" then
        local d = _G.G_defaults:readSetting("STARDICT_DATA_DIR")
        if d and d ~= "" then table.insert(dict_dirs, d) end
    end
    local env_dict = os.getenv("STARDICT_DATA_DIR")
    if env_dict and env_dict ~= "" then table.insert(dict_dirs, env_dict) end

    for _, dict_dir in ipairs(dict_dirs) do
        if lfs and lfs.attributes and lfs.attributes(dict_dir, "mode") == "directory" then
            for item in lfs.dir(dict_dir) do
                if not ArchiverMgr.shouldExclude(item, dict_dir .. "/" .. item) then
                    local full = dict_dir .. "/" .. item
                    local mode = lfs.attributes(full, "mode")
                    if mode == "directory" and not seen[item] then
                        seen[item] = true
                        table.insert(list, item)
                    elseif mode == "file" and item:match("%.ifo$") and not seen[item] then
                        seen[item] = true
                        table.insert(list, item)
                    end
                end
            end
        end
    end

    local tess_dirs = {
        base .. "/data/tessdata",
        base .. "/tessdata",
    }
    for _, tess_dir in ipairs(tess_dirs) do
        if lfs and lfs.attributes and lfs.attributes(tess_dir, "mode") == "directory" then
            for item in lfs.dir(tess_dir) do
                if not ArchiverMgr.shouldExclude(item, tess_dir .. "/" .. item) and not seen[item] then
                    seen[item] = true
                    table.insert(list, item)
                end
            end
        end
    end

    table.sort(list)
    return list
end

--- Resolves the effective books/library directory.
-- Priority: custom_dir -> custom_books_dir in settings -> home_dir in G_reader_settings -> Device.home_dir -> data_dir -> "."
function ArchiverMgr.getEffectiveBooksDir(custom_dir)
    if custom_dir and custom_dir ~= "" and lfs and lfs.attributes and lfs.attributes(custom_dir, "mode") == "directory" then
        return custom_dir
    end
    if _G.G_reader_settings and type(_G.G_reader_settings.readSetting) == "function" then
        local plugin_settings = _G.G_reader_settings:readSetting("backup_settings")
        if type(plugin_settings) == "table" and plugin_settings.custom_books_dir and plugin_settings.custom_books_dir ~= "" then
            if lfs and lfs.attributes and lfs.attributes(plugin_settings.custom_books_dir, "mode") == "directory" then
                return plugin_settings.custom_books_dir
            end
        end
        local home_dir = _G.G_reader_settings:readSetting("home_dir")
        if home_dir and home_dir ~= "" and lfs and lfs.attributes and lfs.attributes(home_dir, "mode") == "directory" then
            return home_dir
        end
    end
    local ok_dev, Device = pcall(require, "device")
    if ok_dev and Device and Device.home_dir and Device.home_dir ~= "" then
        if lfs and lfs.attributes and lfs.attributes(Device.home_dir, "mode") == "directory" then
            return Device.home_dir
        end
    end
    if ok_ds and DataStorage and type(DataStorage.getDataDir) == "function" then
        return DataStorage:getDataDir()
    end
    return "."
end

--- Recursively scans a books directory for *.sdr sidecar directories.
-- Skips system, hidden, cache, and OS media directories.
-- @param books_dir string: root library directory
-- @param seen_paths table: map of disk_path -> true for deduplication
-- @param exclude_dir string: optional directory to exclude (e.g. data_dir)
-- @return table: array of { disk_path = "...", archive_path = "..." }
function ArchiverMgr.scanSdrDirectories(books_dir, seen_paths, exclude_dir)
    local files = {}
    seen_paths = seen_paths or {}
    if not books_dir or books_dir == "" then return files end
    if not lfs or not lfs.attributes or lfs.attributes(books_dir, "mode") ~= "directory" then return files end

    local norm_books_dir = books_dir:gsub("[/\\]+$", "")
    local norm_exclude_dir = exclude_dir and exclude_dir:gsub("[/\\]+$", "")

    local function recurse(curr_dir, rel_path)
        if norm_exclude_dir and curr_dir == norm_exclude_dir then
            return
        end
        for item in lfs.dir(curr_dir) do
            if item ~= "." and item ~= ".." then
                local full = curr_dir .. "/" .. item
                local mode = lfs.attributes(full, "mode")
                if mode == "directory" then
                    if item:match("%.sdr$") then
                        -- Found a sidecar directory! Collect files inside it
                        local rel_sdr = (rel_path ~= "") and (rel_path .. "/" .. item) or item
                        for sdr_item in lfs.dir(full) do
                            if sdr_item ~= "." and sdr_item ~= ".." and not ArchiverMgr.shouldExclude(sdr_item, full .. "/" .. sdr_item) then
                                local sdr_file = full .. "/" .. sdr_item
                                if lfs.attributes(sdr_file, "mode") == "file" and not seen_paths[sdr_file] then
                                    seen_paths[sdr_file] = true
                                    table.insert(files, {
                                        disk_path = sdr_file,
                                        archive_path = Constants.ARCHIVE_SIDECARS_PREFIX .. "/" .. rel_sdr .. "/" .. sdr_item,
                                    })
                                end
                            end
                        end
                        -- Do NOT recurse deeper into .sdr directory
                    elseif not (Constants.EXCLUDED_SCAN_DIRS and Constants.EXCLUDED_SCAN_DIRS[item]) and not ArchiverMgr.shouldExclude(item, full) then
                        local next_rel = (rel_path ~= "") and (rel_path .. "/" .. item) or item
                        recurse(full, next_rel)
                    end
                end
            end
        end
    end

    recurse(norm_books_dir, "")
    return files
end

--- Collects .sdr sidecar folders referenced in history.lua or ReadHistory in memory.
-- Ensures that opened books located outside books_dir (e.g. secondary storage) are also captured.
-- @param data_dir string: KOReader data directory
-- @param books_dir string: primary books directory
-- @param seen_paths table: map of disk_path -> true for deduplication
-- @return table: array of { disk_path = "...", archive_path = "..." }
function ArchiverMgr.collectHistorySidecars(data_dir, books_dir, seen_paths)
    local files = {}
    seen_paths = seen_paths or {}
    local book_files = {}

    -- Check runtime ReadHistory if loaded
    if package.loaded["readhistory"] and type(package.loaded["readhistory"].hist) == "table" then
        for _, entry in ipairs(package.loaded["readhistory"].hist) do
            if entry and entry.file and entry.file ~= "" then
                table.insert(book_files, entry.file)
            end
        end
    end

    -- Also inspect data_dir .. "/history.lua" on disk
    if #book_files == 0 and data_dir then
        local hist_path = data_dir .. "/history.lua"
        if lfs and lfs.attributes and lfs.attributes(hist_path, "mode") == "file" then
            local ok, hist_data = pcall(dofile, hist_path)
            if ok and type(hist_data) == "table" then
                for _, entry in ipairs(hist_data) do
                    if entry and entry.file and entry.file ~= "" then
                        table.insert(book_files, entry.file)
                    end
                end
            end
        end
    end

    local norm_books_dir = books_dir and books_dir:gsub("[/\\]+$", "")

    for _, doc_path in ipairs(book_files) do
        local doc_base = doc_path:match("^(.*)%.[^./\\]+$") or doc_path
        local sdr_dir = doc_base .. ".sdr"
        if lfs and lfs.attributes and lfs.attributes(sdr_dir, "mode") == "directory" then
            for sdr_item in lfs.dir(sdr_dir) do
                if sdr_item ~= "." and sdr_item ~= ".." and not ArchiverMgr.shouldExclude(sdr_item, sdr_dir .. "/" .. sdr_item) then
                    local sdr_file = sdr_dir .. "/" .. sdr_item
                    if lfs.attributes(sdr_file, "mode") == "file" and not seen_paths[sdr_file] then
                        seen_paths[sdr_file] = true
                        local archive_path
                        if norm_books_dir and sdr_file:sub(1, #norm_books_dir) == norm_books_dir then
                            local rel = sdr_file:sub(#norm_books_dir + 1):gsub("^[/\\]+", "")
                            archive_path = Constants.ARCHIVE_SIDECARS_PREFIX .. "/" .. rel
                        else
                            local clean_abs = sdr_file:gsub("^[/\\]+", ""):gsub("^[A-Za-z]:[/\\]", "")
                            archive_path = Constants.ARCHIVE_SIDECARS_ABS_PREFIX .. "/" .. clean_abs
                        end
                        table.insert(files, {
                            disk_path = sdr_file,
                            archive_path = archive_path,
                        })
                    end
                end
            end
        end
    end

    return files
end

--- Creates an archive writer.
-- Prefers native libarchive Writer, falls back to TarWriter for .tar.
function ArchiverMgr.createWriter(filepath, format)
    format = format or filepath:match("[.](tar[.][^.]+)$") or filepath:match("[.]([^.]+)$") or "zip"
    if format == "tgz" then format = "tar.gz" end

    if not ok_arch or not Archiver then
        ok_arch, Archiver = pcall(require, "ffi/archiver")
    end

    -- Try native libarchive writer first
    if ok_arch and Archiver and Archiver.Writer then
        if not cached_libarchive then
            local candidate_fns = { Archiver.Writer.open, Archiver.Writer.addFileFromMemory, Archiver.Reader and Archiver.Reader.open }
            if debug and debug.getupvalue then
                for _, fn in ipairs(candidate_fns) do
                    if type(fn) == "function" then
                        local i = 1
                        while true do
                            local name, val = debug.getupvalue(fn, i)
                            if not name then break end
                            if name == "libarchive" and (type(val) == "userdata" or type(val) == "table") then
                                cached_libarchive = val
                                break
                            end
                            i = i + 1
                        end
                    end
                    if cached_libarchive then break end
                end
            end
            if not cached_libarchive and Archiver.libarchive then
                cached_libarchive = Archiver.libarchive
            end
            if not cached_libarchive then
                pcall(function()
                    local ffi = require("ffi")
                    cached_libarchive = ffi.loadlib("archive", "13")
                end)
            end
        end

        -- In libarchive, zip compression must be set before archive_write_open_filename
        if (format == "zip" or format:match("zip$") or filepath:match("%.zip$")) and not Archiver.Writer._zip_deflate_patched then
            Archiver.Writer._zip_deflate_patched = true
            local orig_open = Archiver.Writer.open
            local upvalues = {}
            if type(orig_open) == "function" and debug and debug.getupvalue then
                local i = 1
                while true do
                    local name, val = debug.getupvalue(orig_open, i)
                    if not name then break end
                    upvalues[name] = val
                    i = i + 1
                end
            end

            local libarchive = cached_libarchive or upvalues.libarchive
            if libarchive then
                cached_libarchive = libarchive
                Archiver.Writer.open = function(self, fp, fmt)
                    if not fmt then
                        fmt = fp:match("[.](tar[.][^.]+)$") or fp:match("[.]([^.]+)$")
                    end
                    local is_zip = (fmt == "zip" or (fmt and fmt:match("zip$")) or (fp and fp:match("%.zip$")))
                    if not is_zip then
                        return orig_open(self, fp, fmt)
                    end

                    local ok_ffi, ffi_mod = pcall(require, "ffi")
                    local ffi = upvalues.ffi or (ok_ffi and ffi_mod)
                    self.err = nil
                    if ffi and ffi.gc then
                        self.archive = ffi.gc(libarchive.archive_write_new(), libarchive.archive_free)
                    else
                        self.archive = libarchive.archive_write_new()
                    end
                    if libarchive.archive_write_set_format_by_name(self.archive, "zip") ~= libarchive.ARCHIVE_OK then
                        self.err = upvalues.archive_error_string and upvalues.archive_error_string(self.archive) or "failed to set zip format"
                        self.archive = nil
                        return
                    end
                    if libarchive.archive_write_zip_set_compression_deflate then
                        pcall(libarchive.archive_write_zip_set_compression_deflate, self.archive)
                    end
                    if libarchive.archive_write_open_filename(self.archive, fp) ~= libarchive.ARCHIVE_OK then
                        self.err = upvalues.archive_error_string and upvalues.archive_error_string(self.archive) or "failed to open archive file"
                        self.archive = nil
                        return
                    end
                    self.filepath = fp
                    return true
                end
            end
        end

        local writer = Archiver.Writer:new()
        local ok, err = writer:open(filepath, format)
        if ok then
            if (format == "zip" or format:match("%.zip$") or filepath:match("%.zip$")) and type(writer.setZipCompression) == "function" then
                pcall(writer.setZipCompression, writer, "deflate")
            end
            return {
                native = true,
                writer = writer,
                addMemory = function(self, entry_path, content, mtime)
                    return self.writer:addFileFromMemory(entry_path, content, mtime)
                end,
                addDisk = function(self, entry_path, disk_path, mtime, on_chunk, is_canceled)
                    if is_canceled and is_canceled() then return false, "canceled" end
                    local f = io.open(disk_path, "rb")
                    if not f then return false, "Cannot read file " .. tostring(disk_path) end
                    local size = f:seek("end") or 0
                    f:seek("set", 0)

                    if not mtime and lfs and lfs.attributes then
                        local attr = lfs.attributes(disk_path)
                        mtime = attr and attr.modification
                    end
                    mtime = mtime or os.time()

                    local libarchive = cached_libarchive or (self.writer and self.writer.libarchive)
                    if libarchive and self.writer and self.writer.archive then
                        local entry = libarchive.archive_entry_new()
                        libarchive.archive_entry_set_pathname(entry, entry_path)
                        libarchive.archive_entry_set_size(entry, size)
                        if libarchive.archive_entry_set_filetype then
                            pcall(libarchive.archive_entry_set_filetype, entry, libarchive.AE_IFREG or 32768)
                        end
                        libarchive.archive_entry_set_mtime(entry, mtime, 0)
                        libarchive.archive_entry_set_perm(entry, 420) -- 0644
                        libarchive.archive_write_header(self.writer.archive, entry)

                        local CHUNK_SIZE = 65536
                        local bytes_read = 0
                        local write_err = nil
                        while bytes_read < size do
                            if is_canceled and is_canceled() then
                                libarchive.archive_entry_free(entry)
                                f:close()
                                return false, "canceled"
                            end
                            local chunk = f:read(CHUNK_SIZE)
                            if not chunk or #chunk == 0 then break end
                            local written = libarchive.archive_write_data(self.writer.archive, chunk, #chunk)
                            if written ~= #chunk then
                                write_err = "failed writing chunk to archive"
                                break
                            end
                            bytes_read = bytes_read + #chunk
                            if on_chunk then on_chunk(#chunk) end
                        end
                        libarchive.archive_entry_free(entry)
                        f:close()
                        if write_err then return false, write_err end
                        return true
                    else
                        local content = f:read("*all")
                        f:close()
                        if is_canceled and is_canceled() then return false, "canceled" end
                        local ok_mem = self.writer:addFileFromMemory(entry_path, content, mtime)
                        if ok_mem and on_chunk then on_chunk(#content) end
                        return ok_mem
                    end
                end,
                close = function(self)
                    return self.writer:close()
                end,
            }
        end
    end

    -- Fallback to pure Lua TAR writer
    local tar_filepath = filepath
    if not filepath:match("%.tar$") then
        tar_filepath = filepath:gsub("%.[^.]+$", "") .. ".tar"
    end
    local fallback = TarWriter:new()
    local ok, err = fallback:open(tar_filepath)
    if not ok then return nil, err end

    return {
        native = false,
        fallback_tar_path = tar_filepath,
        writer = fallback,
        addMemory = function(self, entry_path, content, mtime)
            return self.writer:addFileFromMemory(entry_path, content, mtime)
        end,
        addDisk = function(self, entry_path, disk_path, mtime, on_chunk, is_canceled)
            return self.writer:addFileFromDisk(entry_path, disk_path, mtime, on_chunk, is_canceled)
        end,
        close = function(self)
            return self.writer:close()
        end,
    }
end

--- Creates a complete backup archive according to component selection.
-- @param options table:
--   - archive_path string (required)
--   - format string ("zip" or "tar.gz", optional)
--   - components table (map of component_name -> boolean)
--   - backup_name string
--   - data_dir string (optional)
--   - on_progress function(current, file_path) (optional)
-- @return boolean, table or string: (true, { archive_path = path, file_count = count, size = bytes }) or (false, error_msg)
function ArchiverMgr.createBackup(options)
    options = options or {}
    local archive_path = options.archive_path
    if not archive_path then return false, "No archive path specified" end

    local format = options.format
    local components = options.components or Constants.DEFAULT_COMPONENT_SELECTION
    local backup_name = options.backup_name or "backup"
    local data_dir = options.data_dir or (ok_ds and DataStorage and DataStorage.getDataDir and DataStorage:getDataDir()) or "."
    local books_dir = options.books_dir or ArchiverMgr.getEffectiveBooksDir()
    local on_progress = options.on_progress
    local is_canceled = options.is_canceled

    -- Ensure destination folder exists
    local parent_dir = archive_path:match("^(.*)[/\\][^/\\]+$")
    if parent_dir and ok_util and util and util.makePath then
        util.makePath(parent_dir)
    end

    -- Safely flush settings so disk is up to date
    if _G.G_reader_settings and type(_G.G_reader_settings.flush) == "function" then
        pcall(function() _G.G_reader_settings:flush() end)
    end

    local writer, err = ArchiverMgr.createWriter(archive_path, format)
    if not writer then
        return false, err or "Failed to initialize archive writer"
    end

    local ok_run, run_res = pcall(function()
        local plugin_descriptors = {}
        local patch_list = {}
        local total_files_added = 0

        local pending_entries = {}
        local total_bytes = 0

        local function collectDiskFile(entry_path, disk_path)
            local sz = 0
            if lfs and lfs.attributes then
                local attr = lfs.attributes(disk_path)
                if attr and attr.mode == "file" then
                    sz = attr.size or 0
                end
            end
            table.insert(pending_entries, { archive_path = entry_path, disk_path = disk_path, size = sz })
            total_bytes = total_bytes + sz
        end

        local function collectFiles(files)
            for _, f in ipairs(files) do
                collectDiskFile(f.archive_path, f.disk_path)
            end
        end

        -- 1. Settings (Configuration and UI Gestures, excluding large databases)
        if components[Constants.COMPONENTS.SETTINGS] then
            local s_file = data_dir .. "/settings.reader.lua"
            if lfs and lfs.attributes and lfs.attributes(s_file, "mode") == "file" then
                collectDiskFile("settings/settings.reader.lua", s_file)
            end
            local s_dir = data_dir .. "/settings"
            if lfs and lfs.attributes and lfs.attributes(s_dir, "mode") == "directory" then
                collectFiles(ArchiverMgr.scanDirectory(s_dir, "settings", false, true))
            end
        end

        -- 2. Plugins
        if components[Constants.COMPONENTS.PLUGINS] then
            local p_dir = data_dir .. "/plugins"
            if lfs and lfs.attributes and lfs.attributes(p_dir, "mode") == "directory" then
                collectFiles(ArchiverMgr.scanDirectory(p_dir, "plugins", true, false, options.selected_plugins))
            end
        end

        -- 3. Patches
        if components[Constants.COMPONENTS.PATCHES] then
            local pt_dir = data_dir .. "/patches"
            if lfs and lfs.attributes and lfs.attributes(pt_dir, "mode") == "directory" then
                collectFiles(ArchiverMgr.scanDirectory(pt_dir, "patches", false, false, options.selected_patches))
            end
        end

        -- 4. Fonts
        if components[Constants.COMPONENTS.FONTS] then
            local f_dir = data_dir .. "/fonts"
            if lfs and lfs.attributes and lfs.attributes(f_dir, "mode") == "directory" then
                collectFiles(ArchiverMgr.scanDirectory(f_dir, "fonts", false, false, options.selected_fonts))
            end
        end

        -- 5. Icons
        if components[Constants.COMPONENTS.ICONS] then
            local ic_dir = data_dir .. "/icons"
            if lfs and lfs.attributes and lfs.attributes(ic_dir, "mode") == "directory" then
                collectFiles(ArchiverMgr.scanDirectory(ic_dir, "icons", false))
            end
        end

        -- 6. Screensavers
        if components[Constants.COMPONENTS.SCREENSAVERS] then
            local sc_dir = data_dir .. "/screensavers"
            if lfs and lfs.attributes and lfs.attributes(sc_dir, "mode") == "directory" then
                collectFiles(ArchiverMgr.scanDirectory(sc_dir, "screensavers", false))
            end
        end

        -- 7. Style Tweaks
        if components[Constants.COMPONENTS.STYLETWEAKS] then
            local st_dir = data_dir .. "/styletweaks"
            if lfs and lfs.attributes and lfs.attributes(st_dir, "mode") == "directory" then
                collectFiles(ArchiverMgr.scanDirectory(st_dir, "styletweaks", false))
            end
        end

        -- 7. Docsettings (Reading Progress & Notes)
        if components[Constants.COMPONENTS.DOCSETTINGS] then
            local seen_sdr_paths = {}
            -- 7a. Scan books directory for *.sdr sidecars
            if books_dir and lfs and lfs.attributes and lfs.attributes(books_dir, "mode") == "directory" then
                collectFiles(ArchiverMgr.scanSdrDirectories(books_dir, seen_sdr_paths, data_dir))
            end
            -- 7b. Collect any .sdr sidecars referenced in reading history
            collectFiles(ArchiverMgr.collectHistorySidecars(data_dir, books_dir, seen_sdr_paths))
            -- 7c. Centralized and hash docsettings
            local ds_dir = data_dir .. "/docsettings"
            if lfs and lfs.attributes and lfs.attributes(ds_dir, "mode") == "directory" then
                collectFiles(ArchiverMgr.scanDirectory(ds_dir, "docsettings", false))
            end
            local hds_dir = data_dir .. "/hashdocsettings"
            if lfs and lfs.attributes and lfs.attributes(hds_dir, "mode") == "directory" then
                collectFiles(ArchiverMgr.scanDirectory(hds_dir, "hashdocsettings", false))
            end
        end

        -- 8. History (Reading History & Stats)
        if components[Constants.COMPONENTS.HISTORY] then
            local hist_file = data_dir .. "/history.lua"
            if lfs and lfs.attributes and lfs.attributes(hist_file, "mode") == "file" then
                collectDiskFile("history/history.lua", hist_file)
            end
            local h_dir = data_dir .. "/history"
            if lfs and lfs.attributes and lfs.attributes(h_dir, "mode") == "directory" then
                collectFiles(ArchiverMgr.scanDirectory(h_dir, "history", false))
            end
            local s_dir = data_dir .. "/settings"
            if lfs and lfs.attributes and lfs.attributes(s_dir, "mode") == "directory" then
                for item in lfs.dir(s_dir) do
                    if item:match("^statistics%.sqlite3") or item:match("^vocabulary_builder%.sqlite3") then
                        local full_path = s_dir .. "/" .. item
                        if lfs.attributes(full_path, "mode") == "file" then
                            collectDiskFile("settings/" .. item, full_path)
                        end
                    end
                end
            end
        end

        -- 9. Dictionaries & OCR
        if components[Constants.COMPONENTS.DICTIONARIES] then
            local dict_dir = data_dir .. "/data/dict"
            if lfs and lfs.attributes and lfs.attributes(dict_dir, "mode") == "directory" then
                collectFiles(ArchiverMgr.scanDirectory(dict_dir, "data/dict", false, false, options.selected_dictionaries))
            end
            local dict_alt = data_dir .. "/dict"
            if lfs and lfs.attributes and lfs.attributes(dict_alt, "mode") == "directory" then
                collectFiles(ArchiverMgr.scanDirectory(dict_alt, "dict", false, false, options.selected_dictionaries))
            end
            local tess_dir = data_dir .. "/data/tessdata"
            if lfs and lfs.attributes and lfs.attributes(tess_dir, "mode") == "directory" then
                collectFiles(ArchiverMgr.scanDirectory(tess_dir, "data/tessdata", false, false, options.selected_dictionaries))
            end
            local tess_alt = data_dir .. "/tessdata"
            if lfs and lfs.attributes and lfs.attributes(tess_alt, "mode") == "directory" then
                collectFiles(ArchiverMgr.scanDirectory(tess_alt, "tessdata", false, false, options.selected_dictionaries))
            end
        end

        local total_files = #pending_entries
        local current_files = 0
        local current_bytes = 0

        local font_descriptors = {}
        local dict_descriptors = {}

        for idx, item in ipairs(pending_entries) do
            if is_canceled and is_canceled() then
                error("canceled")
            end

            if on_progress then
                on_progress(current_files, total_files, current_bytes, total_bytes, item.archive_path)
            end

            local function on_chunk(chunk_size)
                current_bytes = current_bytes + chunk_size
                if on_progress then
                    on_progress(current_files, total_files, current_bytes, total_bytes, item.archive_path)
                end
            end

            local ok_add, add_err = writer:addDisk(item.archive_path, item.disk_path, nil, on_chunk, is_canceled)
            if not ok_add then
                if add_err == "canceled" or (is_canceled and is_canceled()) then
                    error("canceled")
                end
            else
                total_files_added = total_files_added + 1
                current_files = current_files + 1

                if item.archive_path:match("^plugins/") then
                    local p_name = item.archive_path:match("^plugins/([^/]+)")
                    if p_name and not plugin_descriptors[p_name] then
                        plugin_descriptors[p_name] = true
                    end
                elseif item.archive_path:match("^patches/") then
                    local patch_name = item.archive_path:gsub("^patches/", "")
                    table.insert(patch_list, patch_name)
                elseif item.archive_path:match("^fonts/") then
                    local f_name = item.archive_path:match("^fonts/([^/]+)")
                    if f_name and not font_descriptors[f_name] then
                        font_descriptors[f_name] = true
                    end
                elseif item.archive_path:match("^data/dict/") then
                    local d_name = item.archive_path:match("^data/dict/([^/]+)")
                    if d_name and not dict_descriptors[d_name] then
                        dict_descriptors[d_name] = true
                    end
                elseif item.archive_path:match("^data/tessdata/") then
                    local t_name = item.archive_path:match("^data/tessdata/([^/]+)")
                    if t_name and not dict_descriptors[t_name] then
                        dict_descriptors[t_name] = true
                    end
                end
            end
        end

        if is_canceled and is_canceled() then
            error("canceled")
        end

        if on_progress then
            on_progress(total_files, total_files, total_bytes, total_bytes, "manifest.json")
        end

        -- Build and serialize manifest
        local Manifest = require("backup_manifest")
        local p_list = {}
        for k, _ in pairs(plugin_descriptors) do table.insert(p_list, { dirname = k }) end
        table.sort(p_list, function(a, b) return a.dirname < b.dirname end)
        table.sort(patch_list)

        local f_list = {}
        for k, _ in pairs(font_descriptors) do table.insert(f_list, k) end
        table.sort(f_list)

        local d_list = {}
        for k, _ in pairs(dict_descriptors) do table.insert(d_list, k) end
        table.sort(d_list)

        local manifest = Manifest.create{
            backup_name = backup_name,
            backup_type = "modular",
            components = components,
            plugins = p_list,
            patches = patch_list,
            fonts = f_list,
            dictionaries = d_list,
            books_dir = books_dir,
        }
        writer:addMemory(Constants.MANIFEST_FILE_NAME, Manifest.serialize(manifest))
        writer:close()

        return total_files_added
    end)

    if not ok_run then
        pcall(function() writer:close() end)
        local actual_path = writer.fallback_tar_path or archive_path
        if tostring(run_res):find("canceled") then
            if lfs and lfs.attributes and lfs.attributes(actual_path) then
                os.remove(actual_path)
            end
            return false, "canceled"
        end
        return false, tostring(run_res)
    end

    local actual_path = writer.fallback_tar_path or archive_path
    local sz = 0
    if lfs and lfs.attributes then
        local attr = lfs.attributes(actual_path)
        if attr and attr.size then sz = attr.size end
    end

    return true, {
        archive_path = actual_path,
        file_count = run_res,
        size = sz,
    }
end

-- --------------------------------------------------------------------------
-- Pure Lua TAR Reader (USTAR standard)
-- Fallback reader for .tar archives if libarchive reader is not loaded
-- --------------------------------------------------------------------------
local TarReader = {}

function TarReader:new()
    local o = { filepath = nil, entries = {} }
    setmetatable(o, { __index = self })
    return o
end

function TarReader:open(filepath)
    self.filepath = filepath
    local f = io.open(filepath, "rb")
    if not f then return false, "Cannot open " .. tostring(filepath) end
    self.entries = {}
    while true do
        local header = f:read(512)
        if not header or #header < 512 then break end
        if header == string.rep("\0", 512) then break end
        local name = header:sub(1, 100):match("^([^%z]+)")
        local size_oct = header:sub(125, 136):match("(%d+)")
        local size = size_oct and tonumber(size_oct, 8) or 0
        local typeflag = header:sub(157, 157)
        local data_offset = f:seek()
        if name then
            table.insert(self.entries, {
                path = name:gsub("^%./", ""),
                size = size,
                typeflag = typeflag,
                offset = data_offset,
            })
        end
        local pad = (512 - (size % 512)) % 512
        f:seek("cur", size + pad)
    end
    f:close()
    return true
end

function TarReader:iterate()
    local idx = 0
    return function()
        idx = idx + 1
        return self.entries[idx]
    end
end

function TarReader:extractToMemory(path)
    for _, e in ipairs(self.entries) do
        if e.path == path or e.path == path:gsub("^%./", "") then
            local f = io.open(self.filepath, "rb")
            if not f then return nil end
            f:seek("set", e.offset)
            local data = f:read(e.size)
            f:close()
            return data
        end
    end
    return nil
end

function TarReader:extractToPath(path, dest_path)
    local data = self:extractToMemory(path)
    if not data then return false, "Entry not found: " .. tostring(path) end
    local f = io.open(dest_path, "wb")
    if not f then return false, "Cannot write to " .. tostring(dest_path) end
    f:write(data)
    f:close()
    return true
end

function TarReader:close()
    self.entries = {}
end

--- Opens an archive reader for extraction or inspection.
function ArchiverMgr.createReader(filepath)
    if ok_arch and Archiver and Archiver.Reader then
        local reader = Archiver.Reader:new()
        if reader:open(filepath) then
            return reader
        end
    end

    -- Try Pure Lua TarReader fallback if archive is a .tar or if native reader failed
    local tr = TarReader:new()
    if tr:open(filepath) then
        return tr
    end

    return nil, "Could not open archive with native reader or tar fallback"
end

--- Reads manifest.json directly from an archive without full extraction.
function ArchiverMgr.readManifest(filepath)
    local reader, err = ArchiverMgr.createReader(filepath)
    if not reader then return nil, err end

    local content = nil
    for entry in reader:iterate() do
        local path = entry.path or ""
        -- Match manifest.json or ./manifest.json
        if path == "manifest.json" or path:match("[/\\]manifest%.json$") then
            content = reader:extractToMemory(path)
            break
        end
    end
    reader:close()

    if not content then
        return nil, "manifest.json not found in archive"
    end

    local Manifest = require("backup_manifest")
    return Manifest.parse(content)
end

--- Extracts an entire archive to target destination path.
-- @param archive_path string
-- @param dest_dir string
-- @param on_progress function: optional callback(current, total, filename)
-- @return boolean, string: success, error_message
function ArchiverMgr.extractArchive(archive_path, dest_dir, on_progress)
    local reader, err = ArchiverMgr.createReader(archive_path)
    if not reader then return false, err end

    local util = require("util")
    util.makePath(dest_dir)

    -- First count entries for progress
    local entries = {}
    for entry in reader:iterate() do
        table.insert(entries, entry.path)
    end

    local total = #entries
    for idx, path in ipairs(entries) do
        if on_progress then
            on_progress(idx, total, path)
        end

        local target_file = dest_dir .. "/" .. path
        -- Ensure parent directories exist
        local parent = target_file:match("^(.*)[/\\][^/\\]+$")
        if parent then util.makePath(parent) end

        local ok, ext_err = reader:extractToPath(path, target_file)
        if not ok then
            -- If extractToPath fails, try extractToMemory as fallback
            local data = reader:extractToMemory(path)
            if data then
                local f = io.open(target_file, "wb")
                if f then
                    f:write(data)
                    f:close()
                    ok = true
                end
            end
        end
    end

    reader:close()
    return true
end

return ArchiverMgr
