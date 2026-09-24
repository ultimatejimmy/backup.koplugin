require("tests/spec_helper")
local Manifest = require("backup_manifest")

describe("backup_manifest", function()
    describe("create", function()
        it("populates device, platform, version, and timestamps", function()
            local m = Manifest.create{
                backup_name = "Test Setup",
                plugins = { { dirname = "storefront.koplugin" } },
                patches = { "1-custom.lua" },
            }

            assert.are.equal("Test Setup", m.backup_name)
            assert.are.equal(1, m.manifest_version)
            assert.is_number(m.created_at)
            assert.is_string(m.created_at_str)
            assert.are.equal("Kobo Clara 2E", m.device.model)
            assert.are.equal("kobo", m.device.platform)
            assert.are.equal("v2026.07", m.device.koreader_version)
            assert.are.equal(1, #m.installed_plugins)
            assert.are.equal("storefront.koplugin", m.installed_plugins[1].dirname)
            assert.are.equal(1, #m.installed_patches)
        end)
    end)

    describe("serialize and parse", function()
        it("correctly encodes and decodes manifest JSON", function()
            local original = Manifest.create{
                backup_name = "JSON Roundtrip",
                description = "Testing serialization",
            }
            local json_str = Manifest.serialize(original)
            assert.is_string(json_str)

            local parsed, err = Manifest.parse(json_str)
            assert.is_nil(err)
            assert.are.equal(original.backup_name, parsed.backup_name)
            assert.are.equal(original.device.model, parsed.device.model)
        end)
    end)

    describe("isSameDevice", function()
        it("returns true when model and platform match current device", function()
            local m = {
                device = {
                    model = "Kobo Clara 2E",
                    platform = "kobo",
                }
            }
            assert.is_true(Manifest.isSameDevice(m))
        end)

        it("returns false when device model differs", function()
            local m = {
                device = {
                    model = "Kindle Paperwhite 4",
                    platform = "kindle",
                }
            }
            assert.is_false(Manifest.isSameDevice(m))
        end)

        it("handles case-insensitive model comparisons", function()
            local m = {
                device = {
                    model = "kobo clara 2e",
                    platform = "KOBO",
                }
            }
            assert.is_true(Manifest.isSameDevice(m))
        end)
    end)
end)
