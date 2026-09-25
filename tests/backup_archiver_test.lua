require("tests/spec_helper")
local ArchiverMgr = require("backup_archiver")
local Constants = require("backup_constants")

describe("backup_archiver", function()
    describe("shouldExclude", function()
        it("excludes git repositories and system junk", function()
            assert.is_true(ArchiverMgr.shouldExclude(".git"))
            assert.is_true(ArchiverMgr.shouldExclude(".github"))
            assert.is_true(ArchiverMgr.shouldExclude(".DS_Store"))
            assert.is_true(ArchiverMgr.shouldExclude("Thumbs.db"))
            assert.is_true(ArchiverMgr.shouldExclude("crash.log"))
            assert.is_true(ArchiverMgr.shouldExclude("cache"))
            assert.is_true(ArchiverMgr.shouldExclude("backup_staging"))
            assert.is_true(ArchiverMgr.shouldExclude("temp.tmp"))
        end)

        it("allows valid plugin and patch files", function()
            assert.is_false(ArchiverMgr.shouldExclude("storefront.koplugin"))
            assert.is_false(ArchiverMgr.shouldExclude("1-custom-tweak.lua"))
            assert.is_false(ArchiverMgr.shouldExclude("settings.reader.lua"))
            assert.is_false(ArchiverMgr.shouldExclude("NotoSans-Regular.ttf"))
        end)
    end)

    describe("Pure Lua TarWriter fallback", function()
        local test_tar = "/tmp/test_backup_archive.tar"

        after_each(function()
            os.remove(test_tar)
        end)

        it("creates a standard POSIX ustar tar archive in 512-byte blocks", function()
            local writer = ArchiverMgr.createWriter(test_tar, "tar")
            assert.is_table(writer)

            local ok1 = writer:addMemory("manifest.json", "{\"test\":true}")
            assert.is_true(ok1)

            local ok2 = writer:addMemory("settings/test.lua", "return { a = 123 }")
            assert.is_true(ok2)

            writer:close()

            local f = io.open(test_tar, "rb")
            assert.is_not_nil(f)
            local content = f:read("*all")
            f:close()

            -- Tar archives must be an exact multiple of 512 bytes
            assert.are.equal(0, #content % 512)

            -- Header contains ustar magic at offset 258
            local magic = content:sub(258, 263)
            assert.are.equal("ustar\0", magic)

            -- Filename appears at beginning of header
            assert.is_not_nil(content:find("manifest.json"))
            assert.is_not_nil(content:find("settings/test.lua"))
        end)
    end)

    describe("Core KOReader plugin filtering", function()
        it("identifies core KOReader plugins that should not be duplicated", function()
            assert.is_true(Constants.CORE_KOREADER_PLUGINS["statistics.koplugin"])
            assert.is_true(Constants.CORE_KOREADER_PLUGINS["calibre.koplugin"])
            assert.is_true(Constants.CORE_KOREADER_PLUGINS["wallabag.koplugin"])
            assert.is_true(Constants.CORE_KOREADER_PLUGINS["coverimage.koplugin"])

            -- User plugins must not be identified as core
            assert.is_nil(Constants.CORE_KOREADER_PLUGINS["storefront.koplugin"])
            assert.is_nil(Constants.CORE_KOREADER_PLUGINS["backup.koplugin"])
            assert.is_nil(Constants.CORE_KOREADER_PLUGINS["xray.koplugin"])
        end)
    end)

    describe("createBackup", function()
        local test_out = "/tmp/test_create_backup.tar"

        after_each(function()
            os.remove(test_out)
        end)

        it("creates a valid backup archive with manifest", function()
            local ok, res = ArchiverMgr.createBackup{
                archive_path = test_out,
                format = "tar",
                backup_name = "test_unit_backup",
                components = {
                    settings = true,
                },
            }
            assert.is_true(ok)
            assert.is_table(res)
            assert.is_not_nil(res.archive_path)

            local f = io.open(test_out, "rb")
            assert.is_not_nil(f)
            local content = f:read("*all")
            f:close()
            assert.is_not_nil(content:find("manifest.json"))
        end)

        it("creates backup with patches and tracks patch_list", function()
            local lfs = require("libs/libkoreader-lfs")
            local data_dir = "/tmp/test_patch_backup_data"
            os.execute("mkdir -p " .. data_dir .. "/patches")
            local pf = io.open(data_dir .. "/patches/2-test-patch.lua", "w")
            if pf then
                pf:write("-- test patch")
                pf:close()
            end

            local ok, res = ArchiverMgr.createBackup{
                archive_path = test_out,
                format = "tar",
                backup_name = "test_patch_backup",
                data_dir = data_dir,
                components = {
                    patches = true,
                },
            }
            assert.is_true(ok)
            assert.is_table(res)

            os.execute("rm -rf " .. data_dir)
        end)

        it("excludes bookinfo_cache.sqlite3 and statistics.sqlite3 from settings", function()
            local lfs = require("libs/libkoreader-lfs")
            local data_dir = "/tmp/test_stats_backup_data"
            os.execute("mkdir -p " .. data_dir .. "/settings")
            local sf = io.open(data_dir .. "/settings/settings.reader.lua", "w")
            if sf then sf:write("return {}"); sf:close() end
            local stat_f = io.open(data_dir .. "/settings/statistics.sqlite3", "w")
            if stat_f then stat_f:write("fake_statistics_db"); stat_f:close() end
            local vocab_f = io.open(data_dir .. "/settings/vocabulary_builder.sqlite3", "w")
            if vocab_f then vocab_f:write("fake_vocab_db"); vocab_f:close() end
            local bookinfo_f = io.open(data_dir .. "/settings/bookinfo_cache.sqlite3", "w")
            if bookinfo_f then bookinfo_f:write("fake_coverbrowser_cache"); bookinfo_f:close() end
            local bookinfo_wal = io.open(data_dir .. "/settings/bookinfo_cache.sqlite3-wal", "w")
            if bookinfo_wal then bookinfo_wal:write("fake_wal"); bookinfo_wal:close() end

            -- 1. Backup with only SETTINGS: should NOT include any sqlite3 files
            local settings_only_out = "/tmp/test_settings_only.tar"
            local ok1, res1 = ArchiverMgr.createBackup{
                archive_path = settings_only_out,
                format = "tar",
                backup_name = "test_settings_only",
                data_dir = data_dir,
                components = { settings = true, history = false },
            }
            assert.is_true(ok1)
            local f1 = io.open(settings_only_out, "rb")
            local c1 = f1:read("*all")
            f1:close()
            os.remove(settings_only_out)

            assert.is_not_nil(c1:find("settings/settings.reader.lua"))
            assert.is_nil(c1:find("statistics.sqlite3"))
            assert.is_nil(c1:find("vocabulary_builder.sqlite3"))
            assert.is_nil(c1:find("bookinfo_cache.sqlite3"))

            -- 2. Backup with HISTORY: should include statistics.sqlite3 and vocabulary_builder.sqlite3, but NOT bookinfo_cache
            local history_out = "/tmp/test_history.tar"
            local ok2, res2 = ArchiverMgr.createBackup{
                archive_path = history_out,
                format = "tar",
                backup_name = "test_history",
                data_dir = data_dir,
                components = { settings = false, history = true },
            }
            assert.is_true(ok2)
            local f2 = io.open(history_out, "rb")
            local c2 = f2:read("*all")
            f2:close()
            os.remove(history_out)

            assert.is_not_nil(c2:find("settings/statistics.sqlite3"))
            assert.is_not_nil(c2:find("settings/vocabulary_builder.sqlite3"))
            assert.is_nil(c2:find("bookinfo_cache.sqlite3"))

            os.execute("rm -rf " .. data_dir)
        end)

        it("gracefully fails when given invalid archive path", function()
            local ok, err = ArchiverMgr.createBackup{
                archive_path = nil,
            }
            assert.is_false(ok)
            assert.is_not_nil(err)
        end)
    end)
end)
