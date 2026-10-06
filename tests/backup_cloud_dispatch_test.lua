require("tests/spec_helper")

local Cloud = require("backup_cloud")
local Constants = require("backup_constants")
local Retention = require("backup_retention")

describe("backup_cloud_dispatch", function()
    describe("Provider Drivers and Labels", function()
        it("resolves driver modules for all providers", function()
            assert.is_not_nil(Cloud.getDriver(Constants.CLOUD_PROVIDERS.GDRIVE))
            assert.is_not_nil(Cloud.getDriver(Constants.CLOUD_PROVIDERS.ONEDRIVE))
            assert.is_not_nil(Cloud.getDriver(Constants.CLOUD_PROVIDERS.DROPBOX))
            assert.is_not_nil(Cloud.getDriver(Constants.CLOUD_PROVIDERS.WEBDAV))
            assert.is_not_nil(Cloud.getDriver(Constants.CLOUD_PROVIDERS.FTP))
            assert.is_not_nil(Cloud.getDriver(Constants.CLOUD_PROVIDERS.SFTP))
            assert.is_nil(Cloud.getDriver(Constants.CLOUD_PROVIDERS.NONE))
        end)

        it("returns friendly human-readable provider labels", function()
            assert.equals("Google Drive", Cloud.getProviderLabel(Constants.CLOUD_PROVIDERS.GDRIVE))
            assert.is_truthy(Cloud.getProviderLabel(Constants.CLOUD_PROVIDERS.ONEDRIVE):find("OneDrive"))
            assert.equals("Dropbox", Cloud.getProviderLabel(Constants.CLOUD_PROVIDERS.DROPBOX))
            assert.is_truthy(Cloud.getProviderLabel(Constants.CLOUD_PROVIDERS.WEBDAV):find("WebDAV"))
            assert.is_truthy(Cloud.getProviderLabel(Constants.CLOUD_PROVIDERS.FTP):find("FTP"))
            assert.is_truthy(Cloud.getProviderLabel(Constants.CLOUD_PROVIDERS.SFTP):find("SFTP"))
            assert.equals("None", Cloud.getProviderLabel(Constants.CLOUD_PROVIDERS.NONE))
        end)
    end)

    describe("Credential Storage and isConfigured", function()
        before_each(function()
            Cloud.clearCredentials(Constants.CLOUD_PROVIDERS.WEBDAV)
            Cloud.clearCredentials(Constants.CLOUD_PROVIDERS.FTP)
        end)

        after_each(function()
            Cloud.clearCredentials(Constants.CLOUD_PROVIDERS.WEBDAV)
            Cloud.clearCredentials(Constants.CLOUD_PROVIDERS.FTP)
        end)

        it("correctly identifies unconfigured providers", function()
            assert.is_false(Cloud.isConfigured(Constants.CLOUD_PROVIDERS.NONE))
            assert.is_false(Cloud.isConfigured(Constants.CLOUD_PROVIDERS.WEBDAV))
            assert.is_false(Cloud.isConfigured(Constants.CLOUD_PROVIDERS.FTP))
            assert.is_false(Cloud.isConfigured(Constants.CLOUD_PROVIDERS.DROPBOX))
        end)

        it("saves and loads provider credentials accurately", function()
            local webdav_creds = {
                url = "https://cloud.example.com/dav",
                username = "myuser",
                password = "mypassword",
            }
            local ok_save = Cloud.saveCredentials(Constants.CLOUD_PROVIDERS.WEBDAV, webdav_creds)
            assert.is_true(ok_save)

            assert.is_true(Cloud.isConfigured(Constants.CLOUD_PROVIDERS.WEBDAV))

            local loaded = Cloud.loadCredentials(Constants.CLOUD_PROVIDERS.WEBDAV)
            assert.equals(webdav_creds.url, loaded.url)
            assert.equals(webdav_creds.username, loaded.username)
            assert.equals(webdav_creds.password, loaded.password)

            Cloud.clearCredentials(Constants.CLOUD_PROVIDERS.WEBDAV)
            assert.is_false(Cloud.isConfigured(Constants.CLOUD_PROVIDERS.WEBDAV))
        end)
    end)

    describe("Retention.pruneRemote", function()
        it("prunes remote backups exceeding the limit via delete callback", function()
            local fake_remote_backups = {
                { filename = "backup_2026-09-30.zip" },
                { filename = "backup_2026-09-29.zip" },
                { filename = "backup_2026-09-28.zip" },
                { filename = "backup_2026-09-27.zip" },
                { filename = "backup_2026-09-26.zip" },
            }

            local deleted = {}
            local mock_delete_fn = function(item, cb)
                table.insert(deleted, item.filename)
                cb(true)
            end

            -- Keep only 3 backups -> oldest 2 should be deleted
            local pruned_count = 0
            Retention.pruneRemote(fake_remote_backups, 3, mock_delete_fn, function(count)
                pruned_count = count
            end)

            assert.equals(2, pruned_count)
            assert.equals(2, #deleted)
            assert.equals("backup_2026-09-27.zip", deleted[1])
            assert.equals("backup_2026-09-26.zip", deleted[2])
        end)

        it("does nothing when backup count is within limit", function()
            local fake_remote_backups = {
                { filename = "backup_2026-09-30.zip" },
                { filename = "backup_2026-09-29.zip" },
            }

            local delete_called = false
            Retention.pruneRemote(fake_remote_backups, 5, function(item, cb)
                delete_called = true
                cb(true)
            end, function(count)
                assert.equals(0, count)
            end)

            assert.is_false(delete_called)
        end)
    end)

    describe("Cloud.testConnection dispatch and transient credentials", function()
        it("returns an error if provider is 'none' or unselected", function()
            local called = false
            Cloud.testConnection(Constants.CLOUD_PROVIDERS.NONE, function(ok, err)
                called = true
                assert.is_false(ok)
                assert.is_not_nil(err)
            end)
            assert.is_true(called)
        end)

        it("dispatches WebDAV testConnection with transient credentials", function()
            local webdav_driver = Cloud.getDriver(Constants.CLOUD_PROVIDERS.WEBDAV)
            local orig_test = webdav_driver.testConnection
            local received_creds = nil

            webdav_driver.testConnection = function(creds, cb)
                received_creds = creds
                cb(true, "WebDAV OK")
            end

            local test_creds = {
                url = "https://nextcloud.example.com/dav",
                username = "alice",
                password = "secretpassword",
            }

            local test_cb_called = false
            Cloud.testConnection(Constants.CLOUD_PROVIDERS.WEBDAV, test_creds, function(ok, msg)
                test_cb_called = true
                assert.is_true(ok)
                assert.equals("WebDAV OK", msg)
            end)

            assert.is_true(test_cb_called)
            assert.is_not_nil(received_creds)
            assert.equals("https://nextcloud.example.com/dav", received_creds.url)
            assert.equals("alice", received_creds.username)
            assert.equals("secretpassword", received_creds.password)
            assert.is_not_nil(received_creds.remote_dir)

            webdav_driver.testConnection = orig_test
        end)

        it("dispatches FTP testConnection with transient credentials", function()
            local ftp_driver = Cloud.getDriver(Constants.CLOUD_PROVIDERS.FTP)
            local orig_test = ftp_driver.testConnection
            local received_creds = nil

            ftp_driver.testConnection = function(creds, cb)
                received_creds = creds
                cb(true, "FTP OK")
            end

            local test_creds = {
                host = "ftp.example.com",
                port = 21,
                username = "bob",
                password = "ftppassword",
            }

            local test_cb_called = false
            Cloud.testConnection(Constants.CLOUD_PROVIDERS.FTP, test_creds, function(ok, msg)
                test_cb_called = true
                assert.is_true(ok)
                assert.equals("FTP OK", msg)
            end)

            assert.is_true(test_cb_called)
            assert.is_not_nil(received_creds)
            assert.equals("ftp.example.com", received_creds.host)
            assert.equals(21, received_creds.port)
            assert.equals("bob", received_creds.username)

            ftp_driver.testConnection = orig_test
        end)

        it("dispatches SFTP testConnection with transient credentials", function()
            local sftp_driver = Cloud.getDriver(Constants.CLOUD_PROVIDERS.SFTP)
            local orig_test = sftp_driver.testConnection
            local received_creds = nil

            sftp_driver.testConnection = function(creds, cb)
                received_creds = creds
                cb(true, "SFTP OK")
            end

            local test_creds = {
                host = "sftp.example.com",
                port = 22,
                username = "charlie",
                password = "sftppassword",
            }

            local test_cb_called = false
            Cloud.testConnection(Constants.CLOUD_PROVIDERS.SFTP, test_creds, function(ok, msg)
                test_cb_called = true
                assert.is_true(ok)
                assert.equals("SFTP OK", msg)
            end)

            assert.is_true(test_cb_called)
            assert.is_not_nil(received_creds)
            assert.equals("sftp.example.com", received_creds.host)
            assert.equals(22, received_creds.port)

            sftp_driver.testConnection = orig_test
        end)

        it("supports overloaded signature without credentials (provider, callback)", function()
            local webdav_driver = Cloud.getDriver(Constants.CLOUD_PROVIDERS.WEBDAV)
            local orig_test = webdav_driver.testConnection
            local received_creds = nil

            webdav_driver.testConnection = function(creds, cb)
                received_creds = creds
                cb(true, "Stored WebDAV OK")
            end

            Cloud.saveCredentials(Constants.CLOUD_PROVIDERS.WEBDAV, {
                url = "https://saved.example.com/dav",
                username = "saveduser",
            })

            local test_cb_called = false
            Cloud.testConnection(Constants.CLOUD_PROVIDERS.WEBDAV, function(ok, msg)
                test_cb_called = true
                assert.is_true(ok)
                assert.equals("Stored WebDAV OK", msg)
            end)

            assert.is_true(test_cb_called)
            assert.is_not_nil(received_creds)
            assert.equals("https://saved.example.com/dav", received_creds.url)

            Cloud.clearCredentials(Constants.CLOUD_PROVIDERS.WEBDAV)
            webdav_driver.testConnection = orig_test
        end)
    end)
end)
