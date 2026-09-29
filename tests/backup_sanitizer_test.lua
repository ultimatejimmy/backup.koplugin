require("tests/spec_helper")
local Sanitizer = require("backup_sanitizer")

describe("backup_sanitizer", function()
    local sample_settings

    before_each(function()
        sample_settings = {
            -- Hardware / Driver
            dev_no_hw_dither = true,
            frontlight_intensity = 42,
            frontlight_warmth = 18,
            screen_dpi = 300,
            color_rendering = false,
            closed_rotation_mode = 0,
            android_screen_timeout = 60,

            -- Device storage paths
            home_dir = "/mnt/onboard/books",
            lastdir = "/mnt/onboard/books/fiction",
            lastfile = "/mnt/onboard/books/fiction/test.epub",

            -- Portable settings
            font_size = 32,
            line_spacing = 110,
            margin_left = 15,
            status_bar = { progress = true, battery = true, clock = true },
            custom_gestures = { swipe_left = "next_page", swipe_right = "prev_page" },
            storefront_settings = { show_updates_badge = true },
        }
    end)

    describe("isHardwareKey", function()
        it("identifies known hardware keys", function()
            assert.is_true(Sanitizer.isHardwareKey("dev_no_hw_dither"))
            assert.is_true(Sanitizer.isHardwareKey("frontlight_intensity"))
            assert.is_true(Sanitizer.isHardwareKey("screen_dpi"))
            assert.is_true(Sanitizer.isHardwareKey("android_screen_timeout"))
        end)

        it("identifies dynamic prefix hardware keys", function()
            assert.is_true(Sanitizer.isHardwareKey("dev_custom_flag"))
            assert.is_true(Sanitizer.isHardwareKey("hw_rotation"))
            assert.is_true(Sanitizer.isHardwareKey("mxcfb_bypass_wait_for"))
        end)

        it("returns false for portable reader preferences", function()
            assert.is_false(Sanitizer.isHardwareKey("font_size"))
            assert.is_false(Sanitizer.isHardwareKey("margin_left"))
            assert.is_false(Sanitizer.isHardwareKey("status_bar"))
            assert.is_false(Sanitizer.isHardwareKey("custom_gestures"))
        end)
    end)

    describe("isDevicePathKey", function()
        it("identifies device storage path keys", function()
            assert.is_true(Sanitizer.isDevicePathKey("home_dir"))
            assert.is_true(Sanitizer.isDevicePathKey("lastdir"))
            assert.is_true(Sanitizer.isDevicePathKey("lastfile"))
            assert.is_true(Sanitizer.isDevicePathKey("download_dir"))
        end)

        it("returns false for non-path keys", function()
            assert.is_false(Sanitizer.isDevicePathKey("font_size"))
            assert.is_false(Sanitizer.isDevicePathKey("frontlight_intensity"))
        end)
    end)

    describe("MODE_RAW (Disaster Recovery)", function()
        it("leaves all hardware settings and paths untouched", function()
            local sanitized, stripped, reset = Sanitizer.sanitize(sample_settings, Sanitizer.MODE_RAW)
            assert.are.same(sample_settings, sanitized)
            assert.are.equal(0, #stripped)
            assert.are.equal(0, #reset)
        end)
    end)

    describe("MODE_SANITIZED (Cross-Device Normalization)", function()
        it("strips hardware keys and resets storage paths", function()
            local sanitized, stripped, reset = Sanitizer.sanitize(sample_settings, Sanitizer.MODE_SANITIZED)

            -- Hardware keys must be removed
            assert.is_nil(sanitized.dev_no_hw_dither)
            assert.is_nil(sanitized.frontlight_intensity)
            assert.is_nil(sanitized.frontlight_warmth)
            assert.is_nil(sanitized.screen_dpi)
            assert.is_nil(sanitized.closed_rotation_mode)
            assert.is_nil(sanitized.android_screen_timeout)

            -- Storage paths must be removed so KOReader re-derives them
            assert.is_nil(sanitized.home_dir)
            assert.is_nil(sanitized.lastdir)
            assert.is_nil(sanitized.lastfile)

            -- Portable preferences must be preserved
            assert.are.equal(32, sanitized.font_size)
            assert.are.equal(110, sanitized.line_spacing)
            assert.are.equal(15, sanitized.margin_left)
            assert.is_true(sanitized.status_bar.progress)
            assert.are.equal("next_page", sanitized.custom_gestures.swipe_left)
            assert.is_true(sanitized.storefront_settings.show_updates_badge)

            assert.is_true(#stripped >= 7)
            assert.is_true(#reset >= 3)
        end)
    end)

    describe("MODE_MERGE (Overlay onto Target Device)", function()
        it("preserves target device hardware and paths while applying backup portable preferences", function()
            local current_target_settings = {
                dev_no_hw_dither = false,
                frontlight_intensity = 10,
                screen_dpi = 212,
                home_dir = "/storage/emulated/0/Books",
                font_size = 18, -- Will be overwritten by backup's 32
            }

            local merged, stripped, reset = Sanitizer.sanitize(sample_settings, Sanitizer.MODE_MERGE, current_target_settings)

            -- Current device's hardware & paths must remain intact
            assert.is_false(merged.dev_no_hw_dither)
            assert.are.equal(10, merged.frontlight_intensity)
            assert.are.equal(212, merged.screen_dpi)
            assert.are.equal("/storage/emulated/0/Books", merged.home_dir)

            -- Portable settings from backup should be applied
            assert.are.equal(32, merged.font_size)
            assert.are.equal(110, merged.line_spacing)
            assert.are.equal("next_page", merged.custom_gestures.swipe_left)
        end)
    end)

    describe("Cross-Device Hardware and Path Normalization", function()
        it("adapts color_rendering based on target device screen capability", function()
            local Device = require("device")
            local orig_hasColor = Device.hasColorScreen

            -- 1. Target is a color screen (e.g. desktop/Android)
            Device.hasColorScreen = function() return true end
            local sanitized_color = Sanitizer.sanitize(sample_settings, Sanitizer.MODE_SANITIZED, {})
            assert.is_true(sanitized_color.color_rendering)

            -- 2. Target is a grayscale screen (e.g. Kobo / Kindle)
            Device.hasColorScreen = function() return false end
            local foreign_color_settings = { color_rendering = true, font_size = 28 }
            local sanitized_gray = Sanitizer.sanitize(foreign_color_settings, Sanitizer.MODE_SANITIZED, {})
            assert.is_false(sanitized_gray.color_rendering)

            -- 3. Target device already has an explicit preference
            local current_pref = { color_rendering = false }
            local sanitized_pref = Sanitizer.sanitize(foreign_color_settings, Sanitizer.MODE_SANITIZED, current_pref)
            assert.is_false(sanitized_pref.color_rendering)

            Device.hasColorScreen = orig_hasColor
        end)

        it("preserves target home_dir and updates folder_shortcuts", function()
            local current_target = {
                home_dir = "/mnt/c/Users/jpautz/Documents/ebooks",
                folder_shortcuts = {
                    ["/mnt/c/Users/jpautz/Documents/ebooks"] = {
                        providers = { home_dir = true },
                        time = 1700000000,
                    },
                },
            }

            local foreign_kindle = {
                home_dir = "/mnt/us/Books",
                inbox_dir = "/mnt/us/documents/Books",
                FilebrowserPlus_dataPath = "/mnt/us",
                folder_shortcuts = {
                    ["/mnt/us/Books"] = {
                        providers = { home_dir = true },
                        time = 1600000000,
                    },
                },
                font_size = 36,
            }

            local sanitized = Sanitizer.sanitize(foreign_kindle, Sanitizer.MODE_SANITIZED, current_target)

            -- Must preserve target device's books folder
            assert.are.equal("/mnt/c/Users/jpautz/Documents/ebooks", sanitized.home_dir)
            -- Foreign inbox_dir and plugin data path must be stripped
            assert.is_nil(sanitized.inbox_dir)
            assert.is_nil(sanitized.FilebrowserPlus_dataPath)
            -- Folder shortcuts must contain target home_dir and NOT contain Kindle /mnt/us
            assert.is_nil(sanitized.folder_shortcuts["/mnt/us/Books"])
            assert.is_not_nil(sanitized.folder_shortcuts["/mnt/c/Users/jpautz/Documents/ebooks"])
            assert.is_true(sanitized.folder_shortcuts["/mnt/c/Users/jpautz/Documents/ebooks"].providers.home_dir)
            -- Portable preferences must still be imported
            assert.are.equal(36, sanitized.font_size)
        end)
    end)

    describe("dumpSettings", function()
        it("serializes to valid executable Lua code", function()
            local code = Sanitizer.dumpSettings({ a = 1, b = "hello", c = { true, false } })
            assert.is_string(code)
            local fn, err = loadstring(code)
            assert.is_nil(err)
            assert.is_function(fn)
            local res = fn()
            assert.are.equal(1, res.a)
            assert.are.equal("hello", res.b)
            assert.is_true(res.c[1])
        end)
    end)
end)
