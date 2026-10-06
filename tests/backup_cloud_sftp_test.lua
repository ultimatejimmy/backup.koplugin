require("tests/spec_helper")

local SFTP = require("backup_cloud_sftp")

describe("backup_cloud_sftp unit tests", function()
    describe("SFTP availability and testConnection", function()
        it("returns error message when sftp binary is unavailable", function()
            local orig_is_avail = SFTP.isAvailable
            SFTP.isAvailable = function() return false end

            local called = false
            local result_ok = true
            local result_msg = nil

            SFTP.testConnection({
                host = "sftp.example.com",
                port = 22,
            }, function(ok, msg)
                called = true
                result_ok = ok
                result_msg = msg
            end)

            assert.is_true(called)
            assert.is_false(result_ok)
            assert.is_truthy(result_msg:find("SFTP is not available"))

            SFTP.isAvailable = orig_is_avail
        end)

        it("validates that host is required when sftp is available", function()
            local orig_is_avail = SFTP.isAvailable
            SFTP.isAvailable = function() return true end

            local called = false
            local result_ok = true
            local result_msg = nil

            SFTP.testConnection({
                host = "",
                port = 22,
            }, function(ok, msg)
                called = true
                result_ok = ok
                result_msg = msg
            end)

            assert.is_true(called)
            assert.is_false(result_ok)
            assert.is_truthy(result_msg:find("required"))

            SFTP.isAvailable = orig_is_avail
        end)

        it("fails gracefully without crashing when target host is unreachable", function()
            -- Test real sftp command execution against an unreachable port (only if sftp binary exists)
            if SFTP.isAvailable() then
                local called = false
                local result_ok = true
                local result_msg = nil

                SFTP.testConnection({
                    host = "127.0.0.1",
                    port = 59999, -- unused high port
                    username = "testuser",
                }, function(ok, msg)
                    called = true
                    result_ok = ok
                    result_msg = msg
                end)

                assert.is_true(called)
                assert.is_false(result_ok)
                assert.is_not_nil(result_msg)
            end
        end)
    end)

    describe("SFTP operations when binary is missing", function()
        local orig_is_avail

        before_each(function()
            orig_is_avail = SFTP.isAvailable
            SFTP.isAvailable = function() return false end
        end)

        after_each(function()
            SFTP.isAvailable = orig_is_avail
        end)

        it("fails upload cleanly", function()
            local called = false
            SFTP.upload("/tmp/fake.zip", { host = "example.com" }, function(ok, err)
                called = true
                assert.is_false(ok)
                assert.is_truthy(err:find("not installed"))
            end)
            assert.is_true(called)
        end)

        it("fails download cleanly", function()
            local called = false
            SFTP.download("fake.zip", "/tmp/dest.zip", { host = "example.com" }, function(ok, err)
                called = true
                assert.is_false(ok)
                assert.is_truthy(err:find("not installed"))
            end)
            assert.is_true(called)
        end)

        it("fails list cleanly", function()
            local called = false
            SFTP.list({ host = "example.com" }, function(ok, err)
                called = true
                assert.is_false(ok)
                assert.is_truthy(err:find("not installed"))
            end)
            assert.is_true(called)
        end)

        it("fails delete cleanly", function()
            local called = false
            SFTP.delete("fake.zip", { host = "example.com" }, function(ok, err)
                called = true
                assert.is_false(ok)
            end)
            assert.is_true(called)
        end)
    end)
end)
