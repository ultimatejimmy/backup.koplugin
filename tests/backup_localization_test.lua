require("tests/spec_helper")
local Localization = require("localization_backup")

describe("localization_backup", function()
    local plugin_dir = "./"
    local f = io.open("languages/en.po", "r")
    if not f then
        f = io.open("backup.koplugin/languages/en.po", "r")
        if f then
            plugin_dir = "backup.koplugin"
            f:close()
        end
    else
        f:close()
    end

    before_each(function()
        Localization:init(plugin_dir)
    end)

    describe("discovery and parsing", function()
        it("discovers all 19 supported language catalogs", function()
            assert.is_true(#Localization.available_languages >= 19)
            assert.is_true(Localization:languageExists("en"))
            assert.is_true(Localization:languageExists("es"))
            assert.is_true(Localization:languageExists("de"))
            assert.is_true(Localization:languageExists("fr"))
            assert.is_true(Localization:languageExists("zh_CN"))
            assert.is_true(Localization:languageExists("pt_br"))
            assert.is_true(Localization:languageExists("ru"))
            assert.is_true(Localization:languageExists("ja"))
            assert.is_true(Localization:languageExists("ko"))
            assert.is_true(Localization:languageExists("ar"))
        end)

        it("parses PO msgid and msgstr correctly", function()
            local en_po = plugin_dir .. "/languages/en.po"
            local parsed = Localization:parsePO(en_po)
            assert.is_table(parsed)
            assert.is_string(parsed["Device Backup & Restore"] or parsed["btn_close"] or parsed["Close"])
        end)
    end)

    describe("system language auto-detection", function()
        it("detects and normalizes Spanish 'es_ES'", function()
            _G.G_reader_settings.data["language"] = "es_ES"
            local detected = Localization:detectSystemLanguage()
            assert.are.equal("es", detected)
        end)

        it("detects German 'de'", function()
            _G.G_reader_settings.data["language"] = "de"
            local detected = Localization:detectSystemLanguage()
            assert.are.equal("de", detected)
        end)

        it("detects and preserves Simplified Chinese 'zh_CN'", function()
            _G.G_reader_settings.data["language"] = "zh_CN"
            local detected = Localization:detectSystemLanguage()
            assert.are.equal("zh_CN", detected)
        end)

        it("normalizes Brazilian Portuguese 'pt_BR' to 'pt_br'", function()
            _G.G_reader_settings.data["language"] = "pt_BR"
            local detected = Localization:detectSystemLanguage()
            assert.are.equal("pt_br", detected)
        end)

        it("normalizes Slovak 'sk_SK' to 'sk'", function()
            _G.G_reader_settings.data["language"] = "sk_SK"
            local detected = Localization:detectSystemLanguage()
            assert.are.equal("sk", detected)
        end)

        it("falls back to English 'en' for unknown locale", function()
            _G.G_reader_settings.data["language"] = "xx_YY"
            local detected = Localization:detectSystemLanguage()
            assert.are.equal("en", detected)
        end)
    end)

    describe("string lookup and formatting", function()
        it("formats strings with single %s specifier", function()
            Localization.current_language = "en"
            Localization:loadTranslations()
            local res = Localization:t("Create subfolder in '%s':", "/sdcard/backups")
            assert.are.equal("Create subfolder in '/sdcard/backups':", res)
        end)

        it("formats strings with numeric %d specifiers", function()
            Localization.current_language = "en"
            Localization:loadTranslations()
            local res = Localization:t("Beam code must be exactly %d digits.", 6)
            assert.are.equal("Beam code must be exactly 6 digits.", res)
        end)

        it("supports positional format specifiers like %1$s", function()
            Localization.translations["test_positional"] = "File %2$s has size %1$d bytes"
            local res = Localization:t("test_positional", 1024, "backup.zip")
            assert.are.equal("File backup.zip has size 1024 bytes", res)
        end)

        it("falls back to raw key if translation does not exist", function()
            local untranslated = "A completely unique unmapped test key"
            local res = Localization:t(untranslated)
            assert.are.equal(untranslated, res)
        end)

        it("provides a working helper alias _()", function()
            local _ = Localization:getHelper()
            assert.is_function(_)
            assert.is_string(_("Device Backup & Restore"))
        end)
    end)
end)
