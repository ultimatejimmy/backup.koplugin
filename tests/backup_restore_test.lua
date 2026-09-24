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
        f:write("return " .. Sanitizer.dumpSettings(_G.G_reader_settings.data))
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

            -- 2. Hardware keys and device paths must be stripped
            assert.is_nil(_G.G_reader_settings.data.frontlight_intensity)
            assert.is_nil(_G.G_reader_settings.data.dev_no_hw_dither)
            assert.is_nil(_G.G_reader_settings.data.home_dir)

            -- 3. Staging folder must be cleaned up
            local staging = data_dir .. "/cache/" .. Constants.STAGING_DIR_NAME
            local sf = io.open(staging, "r")
            assert.is_nil(sf)
        end)
    end)
end)
