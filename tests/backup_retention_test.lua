require("tests/spec_helper")
local Retention = require("backup_retention")

describe("backup_retention", function()
    describe("formatSize", function()
        it("formats bytes, kilobytes, and megabytes properly", function()
            assert.are.equal("500 B", Retention.formatSize(500))
            assert.are.equal("48.8 KB", Retention.formatSize(50000))
            assert.are.equal("14.3 MB", Retention.formatSize(15000000))
        end)
    end)

    describe("isBackupFile", function()
        it("identifies supported archive extensions", function()
            assert.is_true(Retention.isBackupFile("backup_2026.zip"))
            assert.is_true(Retention.isBackupFile("koreader_backup.tar.gz"))
            assert.is_true(Retention.isBackupFile("koreader_backup.tgz"))
            assert.is_true(Retention.isBackupFile("legacy.tar"))
        end)

        it("rejects non-backup files", function()
            assert.is_false(Retention.isBackupFile(".DS_Store"))
            assert.is_false(Retention.isBackupFile("notes.txt"))
            assert.is_false(Retention.isBackupFile("crash.log"))
            assert.is_false(Retention.isBackupFile("archive.zip.tmp"))
        end)
    end)

    describe("prune", function()
        local test_dir = "/tmp/test_backup_retention"

        before_each(function()
            os.execute("mkdir -p \"" .. test_dir .. "\"")
            -- Create 5 fake backups with staggered mtimes
            for i = 1, 5 do
                local path = string.format("%s/backup_%d.zip", test_dir, i)
                local f = io.open(path, "wb")
                f:write("test data")
                f:close()
                -- Give distinct modification times
                os.execute(string.format("touch -t 20260915120%d \"%s\"", i, path))
            end

            -- Create a rollback safety snapshot that should never be pruned
            local rollback_path = test_dir .. "/rollback_before_restore.zip"
            local rf = io.open(rollback_path, "wb")
            rf:write("rollback data")
            rf:close()
        end)

        after_each(function()
            os.execute("rm -rf \"" .. test_dir .. "\"")
        end)

        it("prunes oldest backups down to specified limit while protecting rollback snapshot", function()
            local pruned = Retention.prune(test_dir, 3)
            assert.are.equal(2, pruned)

            local remaining = Retention.listBackups(test_dir)
            -- 3 standard backups + 1 rollback = 4 total remaining
            assert.are.equal(4, #remaining)

            -- Verify rollback snapshot is still present
            local rf = io.open(test_dir .. "/rollback_before_restore.zip", "rb")
            assert.is_not_nil(rf)
            rf:close()
        end)
    end)
end)
