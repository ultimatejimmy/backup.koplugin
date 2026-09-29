require("tests/spec_helper")
local RestoreEngine = require("backup_restore")
local ArchiverMgr = require("backup_archiver")
local Manifest = require("backup_manifest")
local Constants = require("backup_constants")
local Sanitizer = require("backup_sanitizer")

describe("backup_restore", function()
    local test_base = "/tmp/test_backup_restore_env"
    local data_dir = test_base .. "/data"
    local backup_dir = test_base .. "/data/backups"

    before_each(function()
        os.execute("mkdir -p \"" .. data_dir .. "/settings\"")
        os.execute("mkdir -p \"" .. data_dir .. "/plugins\"")
        os.execute("mkdir -p \"" .. data_dir .. "/patches\"")
        os.execute("mkdir -p \"" .. backup_dir .. "\"")

        -- Point datastorage mock to test data_dir
        package.loaded["datastorage"].getDataDir = function() return data_dir end

        -- Set initial G_reader_settings
        _G.G_reader_settings.data = {
            frontlight_intensity = 20,
            screen_dpi = 300,
            home_dir = "/mnt/onboard/original",
            font_size = 20,
        }

        -- Write initial settings.reader.lua
        local f = io.open(data_dir .. "/settings.reader.lua", "wb")
        f:write(Sanitizer.dumpSettings(_G.G_reader_settings.data))
        f:close()
    end)

    after_each(function()
        os.execute("rm -rf \"" .. test_base .. "\"")
    end)

    describe("copyDir and removeDir", function()
        it("copies directory contents recursively and removes them", function()
            local src = test_base .. "/src"
            local dst = test_base .. "/dst"
            os.execute("mkdir -p \"" .. src .. "/nested\"")
            local f = io.open(src .. "/nested/file.txt", "wb")
            f:write("hello world")
            f:close()

            local ok = RestoreEngine.copyDir(src, dst)
            assert.is_true(ok)

            local rf = io.open(dst .. "/nested/file.txt", "rb")
            assert.is_not_nil(rf)
            local content = rf:read("*all")
            rf:close()
            assert.are.equal("hello world", content)

            RestoreEngine.removeDir(dst)
            local check_f = io.open(dst .. "/nested/file.txt", "rb")
            assert.is_nil(check_f)
        end)
    end)

    describe("createRollbackSnapshot and hasRollbackSnapshot", function()
        it("creates a rollback snapshot containing current settings and patches", function()
            -- Add a test patch
            local pf = io.open(data_dir .. "/patches/test.lua", "wb")
            pf:write("print('test patch')")
            pf:close()

            local ok, path = RestoreEngine.createRollbackSnapshot()
            assert.is_true(ok)
            assert.is_true(RestoreEngine.hasRollbackSnapshot())
        end)
    end)

    describe("executeRestore with in-memory settings sync", function()
        it("restores archive, strips hardware keys in cross-device mode, and syncs G_reader_settings in memory", function()
            -- Create a test backup archive with simulated foreign device settings
            local archive_path = backup_dir .. "/foreign_backup.tar"
            local writer = ArchiverMgr.createWriter(archive_path, "tar")

            local foreign_settings = {
                frontlight_intensity = 88, -- Hardware key (should be stripped)
                dev_no_hw_dither = true,   -- Hardware key (should be stripped)
                home_dir = "/mnt/us/foreign", -- Device path (should be reset)
                font_size = 40,            -- Portable setting (should be restored!)
                line_spacing = 130,        -- Portable setting (should be restored!)
            }

            writer:addMemory("settings/settings.reader.lua", Sanitizer.dumpSettings(foreign_settings))

            -- Manifest indicating different origin device (Kindle)
            local manifest = Manifest.create{
                backup_name = "Foreign Kindle Backup",
                components = { [Constants.COMPONENTS.SETTINGS] = true },
            }
            manifest.device.model = "Kindle Oasis 3"
            manifest.device.platform = "kindle"
            writer:addMemory(Constants.MANIFEST_FILE_NAME, Manifest.serialize(manifest))
            writer:close()

            -- Execute restore in cross-device sanitized mode
            local ok, msg, details = RestoreEngine.executeRestore(archive_path, {
                mode = Sanitizer.MODE_SANITIZED,
            })
            assert.is_true(ok)
            assert.are.equal(Sanitizer.MODE_SANITIZED, details.mode)

            -- CRITICAL VERIFICATION:
            -- 1. Portable settings must be updated in G_reader_settings memory
            assert.are.equal(40, _G.G_reader_settings.data.font_size)
            assert.are.equal(130, _G.G_reader_settings.data.line_spacing)

            -- 2. Hardware keys and device paths must be sanitized:
            -- Target device's own hardware settings and books folder are preserved,
            -- while foreign hardware keys and paths are not imported.
            assert.are.equal(20, _G.G_reader_settings.data.frontlight_intensity)
            assert.is_nil(_G.G_reader_settings.data.dev_no_hw_dither)
            assert.are.equal("/mnt/onboard/original", _G.G_reader_settings.data.home_dir)

            -- 3. Staging folder must be cleaned up
            local staging = data_dir .. "/cache/" .. Constants.STAGING_DIR_NAME
            local sf = io.open(staging, "r")
            assert.is_nil(sf)
        end)

        it("restores statistics.sqlite3 only when history component is selected", function()
            local archive_path = backup_dir .. "/history_test_backup.tar"
            local writer = ArchiverMgr.createWriter(archive_path, "tar")

            writer:addMemory("settings/settings.reader.lua", "return { test = 123 }")
            writer:addMemory("settings/statistics.sqlite3", "restored_statistics_content")
            local manifest = Manifest.create{
                backup_name = "Stats Test Backup",
                components = {
                    [Constants.COMPONENTS.SETTINGS] = true,
                    [Constants.COMPONENTS.HISTORY] = true,
                },
            }
            writer:addMemory(Constants.MANIFEST_FILE_NAME, Manifest.serialize(manifest))
            writer:close()

            -- Write existing local statistics file
            local local_stat_file = data_dir .. "/settings/statistics.sqlite3"
            local f = io.open(local_stat_file, "wb")
            f:write("original_local_statistics")
            f:close()

            -- 1. Restore with SETTINGS=true, HISTORY=false: local stats MUST NOT be overwritten
            local ok1 = RestoreEngine.executeRestore(archive_path, {
                mode = Sanitizer.MODE_RAW,
                selected_components = {
                    [Constants.COMPONENTS.SETTINGS] = true,
                    [Constants.COMPONENTS.HISTORY] = false,
                },
            })
            assert.is_true(ok1)
            local rf1 = io.open(local_stat_file, "rb")
            local content1 = rf1:read("*all")
            rf1:close()
            assert.are.equal("original_local_statistics", content1)

            -- 2. Restore with HISTORY=true: local stats MUST be restored
            local ok2 = RestoreEngine.executeRestore(archive_path, {
                mode = Sanitizer.MODE_RAW,
                selected_components = {
                    [Constants.COMPONENTS.SETTINGS] = false,
                    [Constants.COMPONENTS.HISTORY] = true,
                },
            })
            assert.is_true(ok2)
            local rf2 = io.open(local_stat_file, "rb")
            local content2 = rf2:read("*all")
            rf2:close()
            assert.are.equal("restored_statistics_content", content2)
        end)

        it("never overwrites local bookinfo_cache.sqlite3 during restore", function()
            local archive_path = backup_dir .. "/cache_test_backup.tar"
            local writer = ArchiverMgr.createWriter(archive_path, "tar")

            writer:addMemory("settings/settings.reader.lua", "return { test = 123 }")
            writer:addMemory("settings/bookinfo_cache.sqlite3", "stale_archive_cache")
            local manifest = Manifest.create{
                backup_name = "Cache Test Backup",
                components = {
                    [Constants.COMPONENTS.SETTINGS] = true,
                },
            }
            writer:addMemory(Constants.MANIFEST_FILE_NAME, Manifest.serialize(manifest))
            writer:close()

            local local_cache_file = data_dir .. "/settings/bookinfo_cache.sqlite3"
            local f = io.open(local_cache_file, "wb")
            f:write("local_live_cache")
            f:close()

            local ok = RestoreEngine.executeRestore(archive_path, {
                mode = Sanitizer.MODE_RAW,
                selected_components = {
                    [Constants.COMPONENTS.SETTINGS] = true,
                },
            })
            assert.is_true(ok)
            local rf = io.open(local_cache_file, "rb")
            local content = rf:read("*all")
            rf:close()
            assert.are.equal("local_live_cache", content)
        end)

        it("restores docsettings/sidecars to target books_dir when DOCSETTINGS is selected", function()
            local archive_path = backup_dir .. "/docsettings_test_backup.tar"
            local writer = ArchiverMgr.createWriter(archive_path, "tar")

            local dune_meta = "return { percent_finished = 0.85, bookmark = 55 }"
            writer:addMemory("settings/settings.reader.lua", "return {}")
            writer:addMemory("docsettings/sidecars/Books/Fiction/Dune.sdr/metadata.epub.lua", dune_meta)
            writer:addMemory("history/history.lua", "return { { file = \"/mnt/onboard/Books/Fiction/Dune.epub\", time = 100 } }")

            local manifest = Manifest.create{
                backup_name = "Docsettings Test Backup",
                components = {
                    [Constants.COMPONENTS.DOCSETTINGS] = true,
                    [Constants.COMPONENTS.HISTORY] = true,
                },
                books_dir = "/mnt/onboard",
            }
            writer:addMemory(Constants.MANIFEST_FILE_NAME, Manifest.serialize(manifest))
            writer:close()

            local target_books_dir = test_base .. "/target_books"
            os.execute("mkdir -p \"" .. target_books_dir .. "\"")

            local ok, msg, details = RestoreEngine.executeRestore(archive_path, {
                mode = Sanitizer.MODE_RAW,
                books_dir = target_books_dir,
                selected_components = {
                    [Constants.COMPONENTS.DOCSETTINGS] = true,
                    [Constants.COMPONENTS.HISTORY] = true,
                },
            })
            assert.is_true(ok)

            -- Verify Dune sidecar is restored inside target_books_dir
            local restored_sdr = target_books_dir .. "/Books/Fiction/Dune.sdr/metadata.epub.lua"
            local rf = io.open(restored_sdr, "rb")
            assert.is_not_nil(rf)
            local content = rf:read("*all")
            rf:close()
            assert.are.equal(dune_meta, content)

            -- Verify history.lua is restored in data_dir
            local hf = io.open(data_dir .. "/history.lua", "rb")
            assert.is_not_nil(hf)
            local h_content = hf:read("*all")
            hf:close()
            assert.is_not_nil(h_content:find("Dune.epub"))

            os.execute("rm -rf \"" .. target_books_dir .. "\"")
        end)

        it("translates history.lua paths across devices during sanitized restore", function()
            local archive_path = backup_dir .. "/cross_device_history.tar"
            local writer = ArchiverMgr.createWriter(archive_path, "tar")

            local kobo_history = "return { { file = \"/mnt/onboard/Books/SciFi/Hyperion.epub\", time = 500 } }"
            writer:addMemory("settings/settings.reader.lua", "return {}")
            writer:addMemory("docsettings/sidecars/Books/SciFi/Hyperion.sdr/metadata.epub.lua", "return { percent_finished = 0.5 }")
            writer:addMemory("history/history.lua", kobo_history)

            local manifest = Manifest.create{
                backup_name = "Kobo to Kindle Migration",
                components = {
                    [Constants.COMPONENTS.DOCSETTINGS] = true,
                    [Constants.COMPONENTS.HISTORY] = true,
                },
                books_dir = "/mnt/onboard",
            }
            manifest.device.model = "Kobo Libra 2"
            manifest.device.platform = "kobo"
            manifest.device.books_dir = "/mnt/onboard"
            writer:addMemory(Constants.MANIFEST_FILE_NAME, Manifest.serialize(manifest))
            writer:close()

            local kindle_books_dir = test_base .. "/kindle_books"
            os.execute("mkdir -p \"" .. kindle_books_dir .. "\"")

            local ok, msg, details = RestoreEngine.executeRestore(archive_path, {
                mode = Sanitizer.MODE_SANITIZED,
                books_dir = kindle_books_dir,
                selected_components = {
                    [Constants.COMPONENTS.DOCSETTINGS] = true,
                    [Constants.COMPONENTS.HISTORY] = true,
                },
            })
            assert.is_true(ok)

            -- Verify sidecar unpacked under kindle_books_dir
            local restored_sdr = kindle_books_dir .. "/Books/SciFi/Hyperion.sdr/metadata.epub.lua"
            local rf = io.open(restored_sdr, "rb")
            assert.is_not_nil(rf)
            rf:close()

            -- Verify history.lua had its /mnt/onboard path translated to kindle_books_dir
            local hf = io.open(data_dir .. "/history.lua", "rb")
            assert.is_not_nil(hf)
            local h_content = hf:read("*all")
            hf:close()
            assert.is_not_nil(h_content:find(kindle_books_dir .. "/Books/SciFi/Hyperion.epub", 1, true))
            assert.is_nil(h_content:find("/mnt/onboard/Books"))

            os.execute("rm -rf \"" .. kindle_books_dir .. "\"")
        end)

        it("treats archives without manifest.json as unknown cross-device archives", function()
            local archive_path = backup_dir .. "/no_manifest_backup.tar"
            local writer = ArchiverMgr.createWriter(archive_path, "tar")
            writer:addMemory("settings/settings.reader.lua", "return { font_size = 24 }")
            writer:close()

            local inspect, err = RestoreEngine.inspectArchive(archive_path)
            assert.is_not_nil(inspect)
            assert.is_false(inspect.is_same_device)
            assert.are.equal("Unknown", inspect.backup_model)
        end)

        it("undoLastRestore reverts to rollback snapshot without overwriting it", function()
            local ok_roll, roll_path = RestoreEngine.createRollbackSnapshot()
            assert.is_true(ok_roll)
            assert.is_true(RestoreEngine.hasRollbackSnapshot())

            -- Simulate a bad restore that mutated settings
            _G.G_reader_settings.data.home_dir = "/mnt/us/bad_path"
            _G.G_reader_settings.data.font_size = 99
            local sf = io.open(data_dir .. "/settings.reader.lua", "wb")
            sf:write(Sanitizer.dumpSettings(_G.G_reader_settings.data))
            sf:close()

            -- Perform undo
            local ok_undo, err_undo = RestoreEngine.undoLastRestore()
            assert.is_true(ok_undo)

            -- Verified restored to original snapshot
            assert.are.equal("/mnt/onboard/original", _G.G_reader_settings.data.home_dir)
            assert.are.equal(20, _G.G_reader_settings.data.font_size)
        end)

        it("restores custom icons to data_dir/icons when ICONS is selected", function()
            local archive_path = backup_dir .. "/icons_test_backup.tar"
            local writer = ArchiverMgr.createWriter(archive_path, "tar")

            local icon_data = "<svg viewBox='0 0 24 24'><circle cx='12' cy='12' r='10'/></svg>"
            writer:addMemory("settings/settings.reader.lua", "return {}")
            writer:addMemory("icons/custom_star.svg", icon_data)

            local manifest = Manifest.create{
                backup_name = "Icons Test Backup",
                components = {
                    [Constants.COMPONENTS.ICONS] = true,
                },
            }
            writer:addMemory(Constants.MANIFEST_FILE_NAME, Manifest.serialize(manifest))
            writer:close()

            local ok, msg = RestoreEngine.executeRestore(archive_path, {
                mode = Sanitizer.MODE_RAW,
                selected_components = {
                    [Constants.COMPONENTS.ICONS] = true,
                },
            })
            assert.is_true(ok)

            local restored_icon = data_dir .. "/icons/custom_star.svg"
            local rf = io.open(restored_icon, "rb")
            assert.is_not_nil(rf)
            local content = rf:read("*all")
            rf:close()
            assert.are.equal(icon_data, content)
        end)

        it("restores profiles.lua and gestures.lua to data_dir/settings and preserves profiles_autoexec during cross-device restore", function()
            local archive_path = backup_dir .. "/profiles_test_backup.tar"
            local writer = ArchiverMgr.createWriter(archive_path, "tar")

            local profiles_content = "return { DayReading = { settings = { name = 'DayReading', qm_show = true } } }"
            local gestures_content = "return { double_tap = { action = 'profile_exec_DayReading' } }"
            local foreign_settings = {
                frontlight_intensity = 95, -- Hardware key to be stripped
                screen_dpi = 212,          -- Hardware key to be stripped
                profiles_autoexec = {
                    onDocumentOpen = { "DayReading" }
                },
                line_spacing = 110,
            }

            writer:addMemory("settings/settings.reader.lua", Sanitizer.dumpSettings(foreign_settings))
            writer:addMemory("settings/profiles.lua", profiles_content)
            writer:addMemory("settings/gestures.lua", gestures_content)

            local manifest = Manifest.create{
                backup_name = "Profiles Test Backup",
                components = {
                    [Constants.COMPONENTS.SETTINGS] = true,
                },
            }
            manifest.device.model = "Kobo Clara 2E"
            manifest.device.platform = "kobo"
            writer:addMemory(Constants.MANIFEST_FILE_NAME, Manifest.serialize(manifest))
            writer:close()

            local ok, msg = RestoreEngine.executeRestore(archive_path, {
                mode = Sanitizer.MODE_SANITIZED,
                selected_components = {
                    [Constants.COMPONENTS.SETTINGS] = true,
                },
            })
            assert.is_true(ok)

            -- Verify profiles.lua was deployed to settings
            local pf = io.open(data_dir .. "/settings/profiles.lua", "rb")
            assert.is_not_nil(pf)
            local p_data = pf:read("*all")
            pf:close()
            assert.are.equal(profiles_content, p_data)

            -- Verify gestures.lua was deployed to settings
            local gf = io.open(data_dir .. "/settings/gestures.lua", "rb")
            assert.is_not_nil(gf)
            local g_data = gf:read("*all")
            gf:close()
            assert.are.equal(gestures_content, g_data)

            -- Verify profiles_autoexec was preserved while hardware keys preserved current device values
            assert.is_not_nil(_G.G_reader_settings.data.profiles_autoexec)
            assert.are.same({ "DayReading" }, _G.G_reader_settings.data.profiles_autoexec.onDocumentOpen)
            assert.are.equal(110, _G.G_reader_settings.data.line_spacing)
            -- Foreign hardware values (95 and 212) were stripped, preserving target device hardware defaults (20 and 300)
            assert.are.equal(20, _G.G_reader_settings.data.frontlight_intensity)
            assert.are.equal(300, _G.G_reader_settings.data.screen_dpi)
        end)
    end)
end)
