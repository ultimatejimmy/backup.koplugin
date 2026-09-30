--[[--
backup_restore.lua
Restore engine with safety rollback snapshot, staged extraction,
in-memory settings synchronization, and crash-safe deployment.
--]]

local Constants = require("backup_constants")
local Sanitizer = require("backup_sanitizer")
local ArchiverMgr = require("backup_archiver")
local Manifest = require("backup_manifest")
local Retention = require("backup_retention")

local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
if not ok_lfs or not lfs then
    ok_lfs, lfs = pcall(require, "lfs")
end

local ok_ds, DataStorage = pcall(require, "datastorage")
local ok_util, util = pcall(require, "util")
local Localization = require("localization_backup")
local _ = Localization:getHelper()

local RestoreEngine = {}

local function getDataDir()
    return (ok_ds and DataStorage and DataStorage.getDataDir and DataStorage:getDataDir()) or "."
end

local function getStagingDir()
    return getDataDir() .. "/cache/" .. Constants.STAGING_DIR_NAME
end

local function getRollbackPath()
    local backup_dir = Retention.getDefaultBackupDir()
    return backup_dir .. "/" .. Constants.ROLLBACK_FILE_NAME .. ".zip"
end

--- Recursively deletes a directory and all its contents.
function RestoreEngine.removeDir(dir_path)
    if not lfs or not lfs.attributes or lfs.attributes(dir_path, "mode") ~= "directory" then
        return
    end
    for item in lfs.dir(dir_path) do
        if item ~= "." and item ~= ".." then
            local full = dir_path .. "/" .. item
            if lfs.attributes(full, "mode") == "directory" then
                RestoreEngine.removeDir(full)
            else
                os.remove(full)
            end
        end
    end
    if lfs.rmdir then
        lfs.rmdir(dir_path)
    else
        os.remove(dir_path)
    end
end

--- Recursively copies all files from src_dir to dest_dir.
-- @param src_dir string
-- @param dest_dir string
-- @param exclude_filter function(filename, is_root)|string: optional filter function or lua pattern to skip matching filenames
-- @param is_root boolean: optional flag indicating if current scan is top-level
function RestoreEngine.copyDir(src_dir, dest_dir, exclude_filter, is_root)
    if is_root == nil then is_root = true end
    if not lfs or not lfs.attributes or lfs.attributes(src_dir, "mode") ~= "directory" then
        return false, string.format(_("Source directory does not exist: %s"), tostring(src_dir))
    end
    if util and util.makePath then
        util.makePath(dest_dir)
    end

    for item in lfs.dir(src_dir) do
        if item ~= "." and item ~= ".." then
            local skip = false
            if type(exclude_filter) == "function" then
                skip = exclude_filter(item, is_root)
            elseif type(exclude_filter) == "string" then
                skip = item:match(exclude_filter)
            end

            if not skip then
                local src_item = src_dir .. "/" .. item
                local dest_item = dest_dir .. "/" .. item
                local mode = lfs.attributes(src_item, "mode")

                if mode == "directory" then
                    RestoreEngine.copyDir(src_item, dest_item, exclude_filter, false)
                elseif mode == "file" then
                    local sf = io.open(src_item, "rb")
                    if sf then
                        local content = sf:read("*all")
                        sf:close()
                        local df = io.open(dest_item, "wb")
                        if df then
                            df:write(content)
                            df:close()
                        end
                    end
                end
            end
        end
    end
    return true
end

--- Creates an automated safety rollback snapshot of current settings and patches
-- before any restore operation is executed.
function RestoreEngine.createRollbackSnapshot()
    local data_dir = getDataDir()
    local backup_dir = Retention.getDefaultBackupDir()
    if util and util.makePath then
        util.makePath(backup_dir)
    end

    local rollback_zip = getRollbackPath()
    -- If an existing rollback exists, remove it
    os.remove(rollback_zip)
    local rollback_tar = rollback_zip:gsub("%.zip$", ".tar")
    os.remove(rollback_tar)

    local writer, err = ArchiverMgr.createWriter(rollback_zip, "zip")
    if not writer then
        -- Try tar fallback
        writer, err = ArchiverMgr.createWriter(rollback_tar, "tar")
        if not writer then
            return false, "Failed to create rollback writer: " .. tostring(err)
        end
    end

    -- Flush current in-memory settings to disk first
    if _G.G_reader_settings and type(_G.G_reader_settings.flush) == "function" then
        _G.G_reader_settings:flush()
    end

    -- 1. Add current settings.reader.lua
    local settings_file = data_dir .. "/settings.reader.lua"
    if lfs.attributes(settings_file, "mode") == "file" then
        writer:addDisk("settings/settings.reader.lua", settings_file)
    end

    -- 2. Add current user patches
    local patches_dir = data_dir .. "/patches"
    if lfs.attributes(patches_dir, "mode") == "directory" then
        local patch_files = ArchiverMgr.scanDirectory(patches_dir, "patches", false)
        for _, p in ipairs(patch_files) do
            writer:addDisk(p.archive_path, p.disk_path)
        end
    end

    -- 3. Add rollback manifest
    local manifest = Manifest.create{
        backup_name = "Pre-Restore Rollback Snapshot",
        backup_type = "rollback",
        description = "Automatic safety rollback captured prior to applying backup",
        components = {
            [Constants.COMPONENTS.SETTINGS] = true,
            [Constants.COMPONENTS.PATCHES] = true,
        },
    }
    writer:addMemory(Constants.MANIFEST_FILE_NAME, Manifest.serialize(manifest))
    writer:close()

    return true, rollback_zip
end

--- Inspects an archive and returns its manifest and pre-flight validation status.
function RestoreEngine.inspectArchive(archive_path)
    if not lfs or not lfs.attributes or lfs.attributes(archive_path, "mode") ~= "file" then
        return nil, "Archive file does not exist"
    end

    local manifest, err = ArchiverMgr.readManifest(archive_path)
    if not manifest then
        -- Generate fallback manifest for legacy or external archives lacking manifest.json
        local archive_name = archive_path:match("([^/\\]+)%.[^.]+$") or "Backup Archive"
        manifest = Manifest.create{
            backup_name = archive_name,
            backup_type = "legacy",
            description = "Legacy or external backup archive (no manifest.json)",
            components = {
                [Constants.COMPONENTS.SETTINGS] = true,
                [Constants.COMPONENTS.PLUGINS] = true,
                [Constants.COMPONENTS.PATCHES] = true,
                [Constants.COMPONENTS.FONTS] = true,
                [Constants.COMPONENTS.ICONS] = true,
                [Constants.COMPONENTS.SCREENSAVERS] = true,
                [Constants.COMPONENTS.STYLETWEAKS] = true,
                [Constants.COMPONENTS.DOCSETTINGS] = true,
                [Constants.COMPONENTS.HISTORY] = true,
                [Constants.COMPONENTS.DICTIONARIES] = true,
            },
        }
        manifest.device = {
            model = "Unknown",
            platform = "unknown",
            is_fallback = true,
        }
    end

    local is_same = Manifest.isSameDevice(manifest)
    local cur_model = Manifest.getDeviceModel()
    local backup_model = (manifest.device and manifest.device.model) or "Unknown"

    -- Extract plugin list
    local plugins_list = {}
    if manifest.installed_plugins and #manifest.installed_plugins > 0 then
        for _, p in ipairs(manifest.installed_plugins) do
            local name = type(p) == "table" and p.dirname or tostring(p)
            table.insert(plugins_list, name)
        end
    end

    local patches_list = manifest.installed_patches or {}
    local fonts_list = manifest.installed_fonts or {}
    local dicts_list = manifest.installed_dictionaries or {}

    return {
        manifest = manifest,
        is_same_device = is_same,
        current_model = cur_model,
        backup_model = backup_model,
        components = manifest.components or {},
        available_plugins = plugins_list,
        available_patches = patches_list,
        available_fonts = fonts_list,
        available_dictionaries = dicts_list,
    }
end

--- Executes the restore sequence.
-- @param archive_path string
-- @param options table: {
--     mode = "sanitized"|"raw"|"merge",
--     clean_slate = boolean,
--     selected_components = table (optional override of which components to restore),
--     on_progress = function(current, total, filename),
-- }
-- @return boolean, string, table: success, message, details
function RestoreEngine.executeRestore(archive_path, options)
    options = options or {}
    local data_dir = getDataDir()
    local staging_dir = getStagingDir()

    -- 1. Pre-flight check
    local inspect, err = RestoreEngine.inspectArchive(archive_path)
    if not inspect then
        return false, string.format(_("Pre-flight check failed: %s"), tostring(err))
    end

    local manifest = inspect.manifest
    local mode = options.mode
    if not mode then
        -- Auto-detect: if different device model, default to sanitized
        mode = inspect.is_same_device and Sanitizer.MODE_RAW or Sanitizer.MODE_SANITIZED
    end

    local selected_components = options.selected_components or manifest.components or Constants.DEFAULT_COMPONENT_SELECTION

    -- 2. Create safety rollback snapshot (skip during undo to avoid overwriting rollback with current state)
    if not options.is_undo then
        local ok_roll, roll_err = RestoreEngine.createRollbackSnapshot()
        if not ok_roll then
            -- Non-fatal warning, but log it
            print("Warning: Failed to create pre-restore rollback snapshot:", roll_err)
        end
    end

    -- 3. Extract archive to staging directory
    RestoreEngine.removeDir(staging_dir)
    local ok_ext, ext_err = ArchiverMgr.extractArchive(archive_path, staging_dir, options.on_progress)
    if not ok_ext then
        RestoreEngine.removeDir(staging_dir)
        return false, string.format(_("Extraction failed: %s"), tostring(ext_err))
    end

    local stripped_keys = {}
    local reset_paths = {}

    -- 4. Process settings (settings.reader.lua) if selected
    if selected_components[Constants.COMPONENTS.SETTINGS] then
        local staged_settings = staging_dir .. "/settings/settings.reader.lua"
        if not (lfs.attributes(staged_settings, "mode") == "file") then
            -- Check alternate root layout
            staged_settings = staging_dir .. "/settings.reader.lua"
        end

        if lfs.attributes(staged_settings, "mode") == "file" then
            local cur_settings_tbl = (_G.G_reader_settings and _G.G_reader_settings.data)
            if not cur_settings_tbl or not next(cur_settings_tbl) then
                local current_file = data_dir .. "/settings.reader.lua"
                local ok_cur, cur_data = pcall(dofile, current_file)
                if ok_cur and type(cur_data) == "table" then
                    cur_settings_tbl = cur_data
                else
                    cur_settings_tbl = {}
                end
            end
            local target_options = {
                books_dir = options.books_dir or ArchiverMgr.getEffectiveBooksDir(),
            }
            local sanitized_data, stripped, reset = Sanitizer.sanitizeFile(staged_settings, mode, cur_settings_tbl, target_options)

            if sanitized_data then
                stripped_keys = stripped
                reset_paths = reset

                -- Write sanitized settings back to file
                local dumped = Sanitizer.dumpSettings(sanitized_data)
                local f = io.open(data_dir .. "/settings.reader.lua", "wb")
                if f then
                    f:write(dumped)
                    f:close()
                end

                -- CRITICAL: Update G_reader_settings in-memory so Device:exit() on restart doesn't overwrite!
                if _G.G_reader_settings then
                    _G.G_reader_settings.data = sanitized_data
                    if type(_G.G_reader_settings.flush) == "function" then
                        _G.G_reader_settings:flush()
                    end
                end
            end
        end

        -- Process plugin-specific settings directory (excluding stats databases if HISTORY not selected)
        local staged_settings_dir = staging_dir .. "/settings"
        if lfs.attributes(staged_settings_dir, "mode") == "directory" then
            local exclude_fn = function(name)
                if not selected_components[Constants.COMPONENTS.HISTORY] then
                    if name:match("^statistics%.sqlite3") or name:match("^vocabulary_builder%.sqlite3") then
                        return true
                    end
                end
                if name:match("^bookinfo_cache%.sqlite3") then
                    return true
                end
                return false
            end
            RestoreEngine.copyDir(staged_settings_dir, data_dir .. "/settings", exclude_fn)
        end
    end

    -- 5. Process user plugins
    if selected_components[Constants.COMPONENTS.PLUGINS] then
        local staged_plugins = staging_dir .. "/plugins"
        if lfs.attributes(staged_plugins, "mode") == "directory" then
            local target_plugins = data_dir .. "/plugins"

            -- If clean-slate mode: remove user plugins currently installed that are not in backup
            if options.clean_slate and lfs.attributes(target_plugins, "mode") == "directory" then
                for item in lfs.dir(target_plugins) do
                    if item ~= "." and item ~= ".." and not Constants.CORE_KOREADER_PLUGINS[item:lower()] then
                        -- Check if present in staged plugins
                        if lfs.attributes(staged_plugins .. "/" .. item, "mode") ~= "directory" then
                            RestoreEngine.removeDir(target_plugins .. "/" .. item)
                        end
                    end
                end
            end

            -- Copy staged plugins
            local plugin_filter = nil
            if options.selected_plugins then
                plugin_filter = function(item, is_root)
                    if not is_root then return false end
                    return options.selected_plugins[item] ~= true
                end
            end
            RestoreEngine.copyDir(staged_plugins, target_plugins, plugin_filter)
        end
    end

    -- 6. Process patches
    if selected_components[Constants.COMPONENTS.PATCHES] then
        local staged_patches = staging_dir .. "/patches"
        if lfs.attributes(staged_patches, "mode") == "directory" then
            local patch_filter = nil
            if options.selected_patches then
                patch_filter = function(item, is_root)
                    if not is_root then return false end
                    return options.selected_patches[item] ~= true
                end
            end
            RestoreEngine.copyDir(staged_patches, data_dir .. "/patches", patch_filter)
        end
    end

    -- 7. Process fonts
    if selected_components[Constants.COMPONENTS.FONTS] then
        local staged_fonts = staging_dir .. "/fonts"
        if lfs.attributes(staged_fonts, "mode") == "directory" then
            local font_filter = nil
            if options.selected_fonts then
                font_filter = function(item, is_root)
                    if not is_root then return false end
                    return options.selected_fonts[item] ~= true
                end
            end
            RestoreEngine.copyDir(staged_fonts, data_dir .. "/fonts", font_filter)
        end
    end

    -- 8. Process icons
    if selected_components[Constants.COMPONENTS.ICONS] then
        local staged_icons = staging_dir .. "/icons"
        if lfs.attributes(staged_icons, "mode") == "directory" then
            RestoreEngine.copyDir(staged_icons, data_dir .. "/icons")
        end
    end

    -- 9. Process screensavers
    if selected_components[Constants.COMPONENTS.SCREENSAVERS] then
        local staged_screensavers = staging_dir .. "/screensavers"
        if lfs.attributes(staged_screensavers, "mode") == "directory" then
            RestoreEngine.copyDir(staged_screensavers, data_dir .. "/screensavers")
        end
    end

    -- 10. Process style tweaks
    if selected_components[Constants.COMPONENTS.STYLETWEAKS] then
        local staged_tweaks = staging_dir .. "/styletweaks"
        if lfs.attributes(staged_tweaks, "mode") == "directory" then
            RestoreEngine.copyDir(staged_tweaks, data_dir .. "/styletweaks")
        end
    end

    -- 10. Process reading progress & annotations (docsettings)
    if selected_components[Constants.COMPONENTS.DOCSETTINGS] then
        local target_books_dir = options.books_dir or ArchiverMgr.getEffectiveBooksDir()

        -- 10a. Restore sidecars relative to books_dir
        local staged_sidecars = staging_dir .. "/" .. Constants.ARCHIVE_SIDECARS_PREFIX
        if lfs.attributes(staged_sidecars, "mode") == "directory" then
            RestoreEngine.copyDir(staged_sidecars, target_books_dir)
        end

        -- 10b. Restore sidecars with absolute paths
        local staged_abs = staging_dir .. "/" .. Constants.ARCHIVE_SIDECARS_ABS_PREFIX
        if lfs.attributes(staged_abs, "mode") == "directory" then
            if mode == Sanitizer.MODE_RAW then
                RestoreEngine.copyDir(staged_abs, "/")
            else
                RestoreEngine.copyDir(staged_abs, target_books_dir)
            end
        end

        -- 10c. Restore centralized docsettings (skipping sidecars/sidecars_abs)
        local staged_docsettings = staging_dir .. "/docsettings"
        if lfs.attributes(staged_docsettings, "mode") == "directory" then
            local exclude_sidecars = function(name)
                return name == "sidecars" or name == "sidecars_abs"
            end
            RestoreEngine.copyDir(staged_docsettings, data_dir .. "/docsettings", exclude_sidecars)
        end

        -- 10d. Restore hashdocsettings
        local staged_hashdoc = staging_dir .. "/hashdocsettings"
        if lfs.attributes(staged_hashdoc, "mode") == "directory" then
            RestoreEngine.copyDir(staged_hashdoc, data_dir .. "/hashdocsettings")
        end
    end

    -- 11. Process reading history & stats
    if selected_components[Constants.COMPONENTS.HISTORY] then
        local target_books_dir = options.books_dir or ArchiverMgr.getEffectiveBooksDir()

        -- 11a. Restore modern history.lua
        local staged_hist_path = nil
        if lfs.attributes(staging_dir .. "/history/history.lua", "mode") == "file" then
            staged_hist_path = staging_dir .. "/history/history.lua"
        elseif lfs.attributes(staging_dir .. "/history.lua", "mode") == "file" then
            staged_hist_path = staging_dir .. "/history.lua"
        end

        if staged_hist_path then
            local origin_books = (manifest and manifest.device and manifest.device.books_dir) and manifest.device.books_dir:gsub("[/\\]+$", "")
            local new_books = target_books_dir:gsub("[/\\]+$", "")
            local path_translated = false

            if mode ~= Sanitizer.MODE_RAW and origin_books and new_books and origin_books ~= "" and new_books ~= "" and origin_books ~= new_books then
                local ok_load, hist_tbl = pcall(dofile, staged_hist_path)
                if ok_load and type(hist_tbl) == "table" then
                    for _, item in ipairs(hist_tbl) do
                        if item.file and item.file:sub(1, #origin_books) == origin_books then
                            item.file = new_books .. item.file:sub(#origin_books + 1)
                        end
                    end
                    local ok_dump, dump = pcall(require, "dump")
                    local serialized
                    if ok_dump and dump then
                        serialized = "return " .. dump(hist_tbl)
                    else
                        serialized = "return " .. Sanitizer.dumpSettings(hist_tbl)
                    end
                    local hf = io.open(data_dir .. "/history.lua", "wb")
                    if hf then
                        hf:write(serialized)
                        hf:close()
                        path_translated = true
                    end
                end
            end

            if not path_translated then
                local sf = io.open(staged_hist_path, "rb")
                if sf then
                    local content = sf:read("*all")
                    sf:close()
                    local df = io.open(data_dir .. "/history.lua", "wb")
                    if df then
                        df:write(content)
                        df:close()
                    end
                end
            end

            if package.loaded["readhistory"] and type(package.loaded["readhistory"]._read) == "function" then
                pcall(package.loaded["readhistory"]._read, package.loaded["readhistory"], true)
            end
        end

        -- 11b. Legacy history folder (skipping history.lua if inside history/)
        local staged_history = staging_dir .. "/history"
        if lfs.attributes(staged_history, "mode") == "directory" then
            local exclude_hist_lua = function(name)
                return name == "history.lua"
            end
            RestoreEngine.copyDir(staged_history, data_dir .. "/history", exclude_hist_lua)
        end

        -- Restore modern KOReader statistics and vocabulary databases to settings/
        local staged_settings_dir = staging_dir .. "/settings"
        if lfs.attributes(staged_settings_dir, "mode") == "directory" then
            local target_settings_dir = data_dir .. "/settings"
            if util and util.makePath then util.makePath(target_settings_dir) end
            for item in lfs.dir(staged_settings_dir) do
                if item:match("^statistics%.sqlite3") or item:match("^vocabulary_builder%.sqlite3") then
                    local sf = io.open(staged_settings_dir .. "/" .. item, "rb")
                    if sf then
                        local content = sf:read("*all")
                        sf:close()
                        local df = io.open(target_settings_dir .. "/" .. item, "wb")
                        if df then
                            df:write(content)
                            df:close()
                        end
                    end
                end
            end
        end
    end

    -- 12. Process dictionaries & OCR data
    if selected_components[Constants.COMPONENTS.DICTIONARIES] then
        local dict_filter = nil
        if options.selected_dictionaries then
            dict_filter = function(item, is_root)
                if not is_root then return false end
                return options.selected_dictionaries[item] ~= true
            end
        end
        local staged_dict = staging_dir .. "/data/dict"
        if lfs.attributes(staged_dict, "mode") == "directory" then
            RestoreEngine.copyDir(staged_dict, data_dir .. "/data/dict", dict_filter)
        end
        local staged_tess = staging_dir .. "/data/tessdata"
        if lfs.attributes(staged_tess, "mode") == "directory" then
            RestoreEngine.copyDir(staged_tess, data_dir .. "/data/tessdata", dict_filter)
        end
    end

    -- 13. Clean up staging area
    RestoreEngine.removeDir(staging_dir)

    return true, "Restore completed successfully", {
        mode = mode,
        stripped_keys = stripped_keys,
        reset_paths = reset_paths,
    }
end

--- Undoes the last restore by restoring the pre-restore rollback snapshot.
function RestoreEngine.undoLastRestore()
    local rollback_zip = getRollbackPath()
    local rollback_tar = rollback_zip:gsub("%.zip$", ".tar")

    local target_path = nil
    if lfs.attributes(rollback_zip, "mode") == "file" then
        target_path = rollback_zip
    elseif lfs.attributes(rollback_tar, "mode") == "file" then
        target_path = rollback_tar
    end

    if not target_path then
        return false, _("No rollback snapshot available to undo.")
    end

    -- Restore rollback in RAW mode (exact same device)
    return RestoreEngine.executeRestore(target_path, {
        mode = Sanitizer.MODE_RAW,
        clean_slate = false,
        is_undo = true,
    })
end

--- Checks if a rollback snapshot is currently available.
function RestoreEngine.hasRollbackSnapshot()
    local rollback_zip = getRollbackPath()
    local rollback_tar = rollback_zip:gsub("%.zip$", ".tar")
    if lfs and lfs.attributes then
        if lfs.attributes(rollback_zip, "mode") == "file" then return true end
        if lfs.attributes(rollback_tar, "mode") == "file" then return true end
    end
    return false
end

return RestoreEngine
