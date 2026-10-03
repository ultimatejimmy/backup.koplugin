require("tests/spec_helper")

local Dropbox = require("backup_cloud_dropbox")
local OAuth = require("backup_cloud_oauth")
local Constants = require("backup_constants")

describe("backup_cloud_dropbox", function()
    describe("isConfigured", function()
        before_each(function()
            OAuth.clearTokens(Constants.CLOUD_PROVIDERS.DROPBOX)
        end)

        after_each(function()
            OAuth.clearTokens(Constants.CLOUD_PROVIDERS.DROPBOX)
        end)

        it("returns false when no tokens are stored", function()
            assert.is_false(Dropbox.isConfigured())
        end)

        it("returns true when an access token is stored", function()
            OAuth.saveTokens(Constants.CLOUD_PROVIDERS.DROPBOX, {
                access_token = "sl.fake_dropbox_access_token_12345",
                refresh_token = "fake_refresh_token_67890",
                expires_in = 14400,
            })
            assert.is_true(Dropbox.isConfigured())
        end)
    end)

    describe("Driver registration and methods", function()
        it("provides all required driver interfaces", function()
            assert.is_function(Dropbox.isConfigured)
            assert.is_function(Dropbox.upload)
            assert.is_function(Dropbox.download)
            assert.is_function(Dropbox.list)
            assert.is_function(Dropbox.delete)
            assert.is_function(Dropbox.testConnection)
        end)
    end)
end)
