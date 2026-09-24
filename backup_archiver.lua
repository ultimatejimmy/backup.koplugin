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

local ok_arch, Archiver = pcall(require, "ffi/archiver")
local ok_ds, DataStorage = pcall(require, "datastorage")
local ok_util, util = pcall(require, "util")

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

function TarWriter:addFileFromDisk(entry_path, disk_path, mtime)
    local f = io.open(disk_path, "rb")
    if not f then return false, "Cannot open " .. disk_path end
    local content = f:read("*all")
    f:close()
    return self:addFileFromMemory(entry_path, content, mtime)
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
    if name == ".git" or name == ".github" or name == ".DS_Store" or name == "Thumbs.db" then return true end
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
-- @return table: array of { disk_path = "...", archive_path = "..." }
function ArchiverMgr.scanDirectory(base_dir, entry_prefix, is_plugins_dir)
    local files = {}
    if not lfs or not lfs.attributes then return files end
    if lfs.attributes(base_dir, "mode") ~= "directory" then return files end

    local function recurse(curr_dir, rel_path)
        for item in lfs.dir(curr_dir) do
            if not ArchiverMgr.shouldExclude(item, curr_dir .. "/" .. item) then
                local full = curr_dir .. "/" .. item
                local rel = (rel_path ~= "") and (rel_path .. "/" .. item) or item
                local mode = lfs.attributes(full, "mode")

                if mode == "directory" then
                    -- If scanning plugins directory, skip core KOReader plugins
                    local skip = false
                    if is_plugins_dir and rel_path == "" then
                        local clean_name = item:lower()
                        if Constants.CORE_KOREADER_PLUGINS[clean_name] then
                            skip = true
                        end
                    end
                    if not skip then
                        recurse(full, rel)
                    end
                elseif mode == "file" then
                    table.insert(files, {
                        disk_path = full,
                        archive_path = (entry_prefix ~= "") and (entry_prefix .. "/" .. rel) or rel,
                    })
                end
            end
        end
    end

    recurse(base_dir, "")
    return files
end

--- Creates an archive writer.
-- Prefers native libarchive Writer, falls back to TarWriter for .tar.
function ArchiverMgr.createWriter(filepath, format)
    format = format or filepath:match("[.](tar[.][^.]+)$") or filepath:match("[.]([^.]+)$") or "zip"
    if format == "tgz" then format = "tar.gz" end

    -- Try native libarchive writer first
    if ok_arch and Archiver and Archiver.Writer then
        local writer = Archiver.Writer:new()
        local ok, err = writer:open(filepath, format)
        if ok then
            return {
                native = true,
                writer = writer,
                addMemory = function(self, entry_path, content, mtime)
                    return self.writer:addFileFromMemory(entry_path, content, mtime)
                end,
                addDisk = function(self, entry_path, disk_path, mtime)
                    local f = io.open(disk_path, "rb")
                    if not f then return false, "Cannot read file" end
                    local c = f:read("*all")
                    f:close()
                    return self.writer:addFileFromMemory(entry_path, c, mtime)
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
        addDisk = function(self, entry_path, disk_path, mtime)
            return self.writer:addFileFromDisk(entry_path, disk_path, mtime)
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
    local on_progress = options.on_progress

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

        local function addFileList(files)
            for _, f in ipairs(files) do
                if writer:addDisk(f.archive_path, f.disk_path) then
                    total_files_added = total_files_added + 1
                    if on_progress then
                        on_progress(total_files_added, f.archive_path)
                    end
                end
            end
        end

        -- 1. Settings
        if components[Constants.COMPONENTS.SETTINGS] then
            local s_file = data_dir .. "/settings.reader.lua"
            if lfs and lfs.attributes and lfs.attributes(s_file, "mode") == "file" then
                if writer:addDisk("settings/settings.reader.lua", s_file) then
                    total_files_added = total_files_added + 1
                end
            end
            local s_dir = data_dir .. "/settings"
            if lfs and lfs.attributes and lfs.attributes(s_dir, "mode") == "directory" then
                addFileList(ArchiverMgr.scanDirectory(s_dir, "settings", false))
            end
        end

        -- 2. Plugins
        if components[Constants.COMPONENTS.PLUGINS] then
            local p_dir = data_dir .. "/plugins"
            if lfs and lfs.attributes and lfs.attributes(p_dir, "mode") == "directory" then
                local files = ArchiverMgr.scanDirectory(p_dir, "plugins", true)
                for _, f in ipairs(files) do
                    if writer:addDisk(f.archive_path, f.disk_path) then
                        total_files_added = total_files_added + 1
                        local p_name = f.archive_path:match("^plugins/([^/]+)")
                        if p_name and not plugin_descriptors[p_name] then
                            plugin_descriptors[p_name] = true
                        end
                        if on_progress then
                            on_progress(total_files_added, f.archive_path)
                        end
                    end
                end
            end
        end

        -- 3. Patches
        if components[Constants.COMPONENTS.PATCHES] then
            local pt_dir = data_dir .. "/patches"
            if lfs and lfs.attributes and lfs.attributes(pt_dir, "mode") == "directory" then
                local files = ArchiverMgr.scanDirectory(pt_dir, "patches", false)
                for _, f in ipairs(files) do
                    if writer:addDisk(f.archive_path, f.disk_path) then
                        total_files_added = total_files_added + 1
                        local patch_name = f.archive_path:gsub("^patches/", "")
                        table.insert(patch_list, patch_name)
                        if on_progress then
                            on_progress(total_files_added, f.archive_path)
                        end
                    end
                end
            end
        end

        -- 4. Fonts
        if components[Constants.COMPONENTS.FONTS] then
            local f_dir = data_dir .. "/fonts"
            if lfs and lfs.attributes and lfs.attributes(f_dir, "mode") == "directory" then
                addFileList(ArchiverMgr.scanDirectory(f_dir, "fonts", false))
            end
        end

        -- 5. Screensavers
        if components[Constants.COMPONENTS.SCREENSAVERS] then
            local sc_dir = data_dir .. "/screensavers"
            if lfs and lfs.attributes and lfs.attributes(sc_dir, "mode") == "directory" then
                addFileList(ArchiverMgr.scanDirectory(sc_dir, "screensavers", false))
            end
        end

        -- 6. Style Tweaks
        if components[Constants.COMPONENTS.STYLETWEAKS] then
            local st_dir = data_dir .. "/styletweaks"
            if lfs and lfs.attributes and lfs.attributes(st_dir, "mode") == "directory" then
                addFileList(ArchiverMgr.scanDirectory(st_dir, "styletweaks", false))
            end
        end

        -- 7. Docsettings
        if components[Constants.COMPONENTS.DOCSETTINGS] then
            local ds_dir = data_dir .. "/docsettings"
            if lfs and lfs.attributes and lfs.attributes(ds_dir, "mode") == "directory" then
                addFileList(ArchiverMgr.scanDirectory(ds_dir, "docsettings", false))
            end
            local hds_dir = data_dir .. "/hashdocsettings"
            if lfs and lfs.attributes and lfs.attributes(hds_dir, "mode") == "directory" then
                addFileList(ArchiverMgr.scanDirectory(hds_dir, "hashdocsettings", false))
            end
        end

        -- 8. History
        if components[Constants.COMPONENTS.HISTORY] then
            local h_dir = data_dir .. "/history"
            if lfs and lfs.attributes and lfs.attributes(h_dir, "mode") == "directory" then
                addFileList(ArchiverMgr.scanDirectory(h_dir, "history", false))
            end
        end

        -- 9. Dictionaries & OCR
        if components[Constants.COMPONENTS.DICTIONARIES] then
            local dict_dir = data_dir .. "/data/dict"
            if lfs and lfs.attributes and lfs.attributes(dict_dir, "mode") == "directory" then
                addFileList(ArchiverMgr.scanDirectory(dict_dir, "data/dict", false))
            end
            local tess_dir = data_dir .. "/data/tessdata"
            if lfs and lfs.attributes and lfs.attributes(tess_dir, "mode") == "directory" then
                addFileList(ArchiverMgr.scanDirectory(tess_dir, "data/tessdata", false))
            end
        end

        -- Build and serialize manifest
        local Manifest = require("backup_manifest")
        local p_list = {}
        for k, _ in pairs(plugin_descriptors) do table.insert(p_list, { dirname = k }) end
        table.sort(p_list, function(a, b) return a.dirname < b.dirname end)
        table.sort(patch_list)

        local manifest = Manifest.create{
            backup_name = backup_name,
            backup_type = "modular",
            components = components,
            plugins = p_list,
            patches = patch_list,
        }
        writer:addMemory(Constants.MANIFEST_FILE_NAME, Manifest.serialize(manifest))
        writer:close()

        return total_files_added
    end)

    if not ok_run then
        pcall(function() writer:close() end)
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
