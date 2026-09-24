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

        it("gracefully fails when given invalid archive path", function()
            local ok, err = ArchiverMgr.createBackup{
                archive_path = nil,
            }
            assert.is_false(ok)
            assert.is_not_nil(err)
        end)
    end)
end)
