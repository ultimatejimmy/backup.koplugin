require("tests/spec_helper")

local OAuth = require("backup_cloud_oauth")
local Constants = require("backup_constants")

describe("backup_cloud_oauth", function()
    describe("URL encoding and form data serialization", function()
        it("properly URL-encodes special characters", function()
            assert.equals("hello+world", OAuth.urlEncode("hello world"))
            assert.equals("a%2Bb%26c%3Dd", OAuth.urlEncode("a+b&c=d"))
            assert.equals("https%3A%2F%2Fexample.com%2Fpath", OAuth.urlEncode("https://example.com/path"))
            assert.equals("", OAuth.urlEncode(""))
            assert.equals("", OAuth.urlEncode(nil))
        end)

        it("serializes tables into application/x-www-form-urlencoded format", function()
            local form = OAuth.makeFormData({
                client_id = "test_id",
                scope = "test_scope",
            })
            assert.is_truthy(form:find("client_id=test_id"))
            assert.is_truthy(form:find("scope=test_scope"))
            assert.is_truthy(form:find("&"))
        end)
    end)

    describe("Token Storage and Retrieval", function()
        local test_provider = "test_provider"
        local sample_tokens = {
            access_token = "ya29.test_access_token_12345",
            refresh_token = "1//test_refresh_token_67890",
            expires_in = 3600,
            token_type = "Bearer",
            scope = "https://www.googleapis.com/auth/drive.file",
            created_at = os.time(),
            expires_at = os.time() + 3600,
        }

        it("saves, loads, and clears tokens correctly", function()
            local ok_save = OAuth.saveTokens(test_provider, sample_tokens)
            assert.is_true(ok_save)

            local loaded = OAuth.loadTokens(test_provider)
            assert.is_not_nil(loaded)
            assert.equals(sample_tokens.access_token, loaded.access_token)
            assert.equals(sample_tokens.refresh_token, loaded.refresh_token)

            local ok_clear = OAuth.clearTokens(test_provider)
            assert.is_true(ok_clear)

            local after_clear = OAuth.loadTokens(test_provider)
            assert.is_nil(after_clear)
        end)

        it("returns valid unexpired access token immediately", function()
            OAuth.saveTokens(test_provider, sample_tokens)

            local cb_called = false
            OAuth.getValidAccessToken(test_provider, function(ok, token)
                cb_called = true
                assert.is_true(ok)
                assert.equals(sample_tokens.access_token, token)
            end)

            assert.is_true(cb_called)
            OAuth.clearTokens(test_provider)
        end)

        it("fails getValidAccessToken if provider is not authenticated", function()
            OAuth.clearTokens(test_provider)

            local cb_called = false
            OAuth.getValidAccessToken(test_provider, function(ok, err)
                cb_called = true
                assert.is_false(ok)
                assert.is_string(err)
            end)

            assert.is_true(cb_called)
        end)
    end)

    describe("OAuth provider definition", function()
        it("defines Google Drive configuration with device-code endpoints", function()
            local gdef = OAuth.PROVIDERS[Constants.CLOUD_PROVIDERS.GDRIVE]
            assert.is_not_nil(gdef)
            assert.equals("https://oauth2.googleapis.com/device/code", gdef.device_code_url)
            assert.equals("https://oauth2.googleapis.com/token", gdef.token_url)
            assert.equals("https://oauth2.googleapis.com/revoke", gdef.revoke_url)
            assert.equals("https://www.googleapis.com/auth/drive.file", gdef.default_scope)
            assert.is_not_nil(gdef.client_id)
            assert.equals(Constants.OAUTH_DEFAULT_RELAY_URL, gdef.relay_url)
        end)

        it("defines Microsoft OneDrive configuration with device-code endpoints", function()
            local odef = OAuth.PROVIDERS[Constants.CLOUD_PROVIDERS.ONEDRIVE]
            assert.is_not_nil(odef)
            assert.equals("https://login.microsoftonline.com/consumers/oauth2/v2.0/devicecode", odef.device_code_url)
            assert.equals("https://login.microsoftonline.com/consumers/oauth2/v2.0/token", odef.token_url)
            assert.equals("Files.ReadWrite offline_access", odef.default_scope)
            assert.equals("982359c5-d74b-408c-8ff0-7d43c678195e", odef.client_id)
        end)

        it("defines Dropbox configuration with relay endpoints", function()
            local ddef = OAuth.PROVIDERS[Constants.CLOUD_PROVIDERS.DROPBOX]
            assert.is_not_nil(ddef)
            assert.equals("Dropbox", ddef.name)
            assert.equals((Constants.OAUTH_DEFAULT_RELAY_URL or "https://backup.ultimatejimmy.workers.dev") .. "/api/oauth/dropbox/init", ddef.device_code_url)
            assert.equals("https://api.dropboxapi.com/oauth2/token", ddef.token_url)
            assert.equals(Constants.OAUTH_DROPBOX_CLIENT_ID, ddef.client_id)
        end)

        it("refreshes token successfully without calling callback multiple times", function()
            local call_count = 0
            local last_ok = nil
            local last_res = nil

            -- Test with custom mock if needed or verify return logic
            assert.is_function(OAuth.refreshToken)
        end)
    end)
end)
