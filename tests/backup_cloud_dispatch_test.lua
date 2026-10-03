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
end)
