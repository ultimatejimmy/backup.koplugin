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

        it("creates backup with custom icons when icons component is enabled", function()
            local lfs = require("libs/libkoreader-lfs")
            local data_dir = "/tmp/test_icons_backup_data"
            os.execute("mkdir -p " .. data_dir .. "/icons")
            local ic_f = io.open(data_dir .. "/icons/bookmark.svg", "w")
            if ic_f then
                ic_f:write("<svg>custom-icon</svg>")
                ic_f:close()
            end

            local ok, res = ArchiverMgr.createBackup{
                archive_path = test_out,
                format = "tar",
                backup_name = "test_icons_backup",
                data_dir = data_dir,
                components = {
                    icons = true,
                },
            }
            assert.is_true(ok)
            assert.is_table(res)

            local f = io.open(test_out, "rb")
            assert.is_not_nil(f)
            local content = f:read("*all")
            f:close()

            assert.is_not_nil(content:find("icons/bookmark%.svg"))

            os.execute("rm -rf " .. data_dir)
        end)

        it("excludes bookinfo_cache.sqlite3 and statistics.sqlite3 from settings", function()
            local lfs = require("libs/libkoreader-lfs")
            local data_dir = "/tmp/test_stats_backup_data"
            os.execute("mkdir -p " .. data_dir .. "/settings")
            local sf = io.open(data_dir .. "/settings/settings.reader.lua", "w")
            if sf then sf:write("return {}"); sf:close() end
            local stat_f = io.open(data_dir .. "/settings/statistics.sqlite3", "w")
            if stat_f then stat_f:write("fake_statistics_db"); stat_f:close() end
            local vocab_f = io.open(data_dir .. "/settings/vocabulary_builder.sqlite3", "w")
            if vocab_f then vocab_f:write("fake_vocab_db"); vocab_f:close() end
            local bookinfo_f = io.open(data_dir .. "/settings/bookinfo_cache.sqlite3", "w")
            if bookinfo_f then bookinfo_f:write("fake_coverbrowser_cache"); bookinfo_f:close() end
            local bookinfo_wal = io.open(data_dir .. "/settings/bookinfo_cache.sqlite3-wal", "w")
            if bookinfo_wal then bookinfo_wal:write("fake_wal"); bookinfo_wal:close() end

            -- 1. Backup with only SETTINGS: should NOT include any sqlite3 files
            local settings_only_out = "/tmp/test_settings_only.tar"
            local ok1, res1 = ArchiverMgr.createBackup{
                archive_path = settings_only_out,
                format = "tar",
                backup_name = "test_settings_only",
                data_dir = data_dir,
                components = { settings = true, history = false },
            }
            assert.is_true(ok1)
            local f1 = io.open(settings_only_out, "rb")
            local c1 = f1:read("*all")
            f1:close()
            os.remove(settings_only_out)

            assert.is_not_nil(c1:find("settings/settings.reader.lua"))
            assert.is_nil(c1:find("statistics.sqlite3"))
            assert.is_nil(c1:find("vocabulary_builder.sqlite3"))
            assert.is_nil(c1:find("bookinfo_cache.sqlite3"))

            -- 2. Backup with HISTORY: should include statistics.sqlite3 and vocabulary_builder.sqlite3, but NOT bookinfo_cache
            local history_out = "/tmp/test_history.tar"
            local ok2, res2 = ArchiverMgr.createBackup{
                archive_path = history_out,
                format = "tar",
                backup_name = "test_history",
                data_dir = data_dir,
                components = { settings = false, history = true },
            }
            assert.is_true(ok2)
            local f2 = io.open(history_out, "rb")
            local c2 = f2:read("*all")
            f2:close()
            os.remove(history_out)

            assert.is_not_nil(c2:find("settings/statistics.sqlite3"))
            assert.is_not_nil(c2:find("settings/vocabulary_builder.sqlite3"))
            assert.is_nil(c2:find("bookinfo_cache.sqlite3"))

            os.execute("rm -rf " .. data_dir)
        end)

        it("gracefully fails when given invalid archive path", function()
            local ok, err = ArchiverMgr.createBackup{
                archive_path = nil,
            }
            assert.is_false(ok)
            assert.is_not_nil(err)
        end)

        it("streams dictionary files in chunks and reports progress", function()
            local data_dir = "/tmp/test_dict_chunk_data"
            os.execute("mkdir -p " .. data_dir .. "/data/dict")
            local dummy_dict_file = data_dir .. "/data/dict/large_stardict.dict.dz"
            local df = io.open(dummy_dict_file, "wb")
            if df then
                -- Write 200KB of dummy dictionary data (> 2 chunks of 64KB)
                local chunk_data = string.rep("D", 65536)
                df:write(chunk_data)
                df:write(chunk_data)
                df:write(chunk_data)
                df:close()
            end

            local dict_out = "/tmp/test_dict_backup.tar"
            local progress_calls = 0
            local last_bytes = 0

            local ok, res = ArchiverMgr.createBackup{
                archive_path = dict_out,
                format = "tar",
                backup_name = "test_dict_backup",
                data_dir = data_dir,
                components = { dictionaries = true },
                on_progress = function(curr_files, total_files, curr_bytes, total_bytes, path)
                    progress_calls = progress_calls + 1
                    last_bytes = curr_bytes
                end,
            }

            assert.is_true(ok)
            assert.is_true(progress_calls >= 3)
            assert.is_true(last_bytes >= 196608)

            os.remove(dict_out)
            os.execute("rm -rf " .. data_dir)
        end)

        it("aborts backup creation immediately when is_canceled returns true", function()
            local data_dir = "/tmp/test_cancel_data"
            os.execute("mkdir -p " .. data_dir .. "/data/dict")
            local dummy_dict_file = data_dir .. "/data/dict/large_stardict.dict.dz"
            local df = io.open(dummy_dict_file, "wb")
            if df then
                local chunk_data = string.rep("X", 65536)
                for i = 1, 5 do df:write(chunk_data) end
                df:close()
            end

            local cancel_out = "/tmp/test_cancel_backup.tar"
            local chunks_seen = 0

            local ok, res = ArchiverMgr.createBackup{
                archive_path = cancel_out,
                format = "tar",
                backup_name = "test_cancel_backup",
                data_dir = data_dir,
                components = { dictionaries = true },
                is_canceled = function()
                    return chunks_seen >= 2
                end,
                on_progress = function(curr_files, total_files, curr_bytes, total_bytes, path)
                    chunks_seen = chunks_seen + 1
                end,
            }

            assert.is_false(ok)
            assert.are.equal("canceled", res)

            -- Verify partial archive file is cleaned up from disk
            local f = io.open(cancel_out, "rb")
            assert.is_nil(f)

            os.execute("rm -rf " .. data_dir)
        end)
    end)

    describe("Native libarchive streaming writer", function()
        local orig_archiver = package.loaded["ffi/archiver"]
        local orig_ffi = package.loaded["ffi"]
        local test_file = "/tmp/test_native_stream.txt"
        local test_archive = "/tmp/test_native_archive.zip"

        after_each(function()
            package.loaded["ffi/archiver"] = orig_archiver
            package.loaded["ffi"] = orig_ffi
            package.loaded["backup_archiver"] = nil
            os.remove(test_file)
            os.remove(test_archive)
        end)

        it("calls archive_entry_set_mtime with exact C signature (3 arguments) and streams chunks", function()
            package.loaded["ffi"] = {
                gc = function(obj, finalizer) return obj end,
                string = tostring,
            }

            local f = io.open(test_file, "wb")
            local test_content = string.rep("0123456789abcdef", 5000) -- ~80KB (> 64KB chunk)
            f:write(test_content)
            f:close()

            local mtime_args_received = nil
            local data_chunks_received = {}
            local mock_libarchive = {
                AE_IFREG = 32768,
                ARCHIVE_OK = 0,
                archive_write_new = function() return { handle = 1 } end,
                archive_write_set_format_by_name = function(...) return 0 end,
                archive_write_open_filename = function(...) return 0 end,
                archive_free = function(...) end,
                archive_entry_new = function() return { id = "entry1" } end,
                archive_entry_set_pathname = function(entry, path) end,
                archive_entry_set_size = function(entry, sz) end,
                archive_entry_set_filetype = function(entry, ft) end,
                archive_entry_set_perm = function(entry, p) end,
                archive_entry_set_mtime = function(...)
                    local num_args = select("#", ...)
                    if num_args ~= 3 then
                        error("wrong number of arguments for function call")
                    end
                    local entry, mtime, ns = ...
                    mtime_args_received = { entry = entry, mtime = mtime, ns = ns }
                end,
                archive_write_header = function(arc, entry) return 0 end,
                archive_write_data = function(arc, chunk, len)
                    table.insert(data_chunks_received, chunk)
                    return len
                end,
                archive_entry_free = function(entry) end,
            }

            local mock_archiver = {
                Writer = {
                    new = function(self)
                        local o = { archive = { handle = 1 }, libarchive = mock_libarchive }
                        setmetatable(o, { __index = self })
                        return o
                    end,
                    open = function(self, fp, fmt)
                        -- Keep mock_libarchive in an upvalue so debug.getupvalue finds it
                        local _ = mock_libarchive
                        self.filepath = fp
                        return true
                    end,
                    close = function(self) return true end,
                    addFileFromMemory = function(self, p, c, m) return true end,
                },
                libarchive = mock_libarchive,
            }

            package.loaded["ffi/archiver"] = mock_archiver
            package.loaded["backup_archiver"] = nil
            local FreshArchiverMgr = require("backup_archiver")

            local writer = FreshArchiverMgr.createWriter(test_archive, "zip")
            assert.is_table(writer)
            assert.is_true(writer.native)

            local chunk_bytes = 0
            local ok, err = writer:addDisk("streamed.txt", test_file, 1700000000, function(sz)
                chunk_bytes = chunk_bytes + sz
            end)

            assert.is_true(ok)
            assert.is_nil(err)
            assert.is_not_nil(mtime_args_received)
            assert.are.equal(1700000000, mtime_args_received.mtime)
            assert.are.equal(0, mtime_args_received.ns)
            assert.is_true(#data_chunks_received >= 2)
            assert.are.equal(#test_content, chunk_bytes)

            writer:close()

            -- Verify subsequent call to createWriter reuses cached_libarchive without issue
            local writer2 = FreshArchiverMgr.createWriter(test_archive, "zip")
            assert.is_table(writer2)
            assert.is_true(writer2.native)
            local ok2 = writer2:addDisk("streamed2.txt", test_file)
            assert.is_true(ok2)
            writer2:close()
        end)
    end)

    describe("Reading progress and sidecars (.sdr) archiving", function()
        local test_out = "/tmp/test_reading_progress_backup.tar"
        local books_dir = "/tmp/test_books_env"
        local data_dir = "/tmp/test_data_env"

        before_each(function()
            os.execute("mkdir -p \"" .. books_dir .. "/Fiction/Dune.sdr\"")
            os.execute("mkdir -p \"" .. books_dir .. "/SciFi/Hyperion.sdr\"")
            os.execute("mkdir -p \"" .. books_dir .. "/.koreader\"")
            os.execute("mkdir -p \"" .. books_dir .. "/Android\"")
            os.execute("mkdir -p \"" .. data_dir .. "\"")

            local f1 = io.open(books_dir .. "/Fiction/Dune.sdr/metadata.epub.lua", "w")
            if f1 then f1:write("return { percent_finished = 0.75, bookmark = 42 }"); f1:close() end

            local f2 = io.open(books_dir .. "/SciFi/Hyperion.sdr/metadata.epub.lua", "w")
            if f2 then f2:write("return { percent_finished = 0.30 }"); f2:close() end

            -- File inside excluded folder (should NOT be collected)
            local f_ex = io.open(books_dir .. "/Android/fake.sdr_file", "w")
            if f_ex then f_ex:write("exclude me"); f_ex:close() end

            -- Create history.lua with a book outside books_dir
            local ext_sdr = "/tmp/test_ext_storage/Foundation.sdr"
            os.execute("mkdir -p \"" .. ext_sdr .. "\"")
            local f_ext = io.open(ext_sdr .. "/metadata.epub.lua", "w")
            if f_ext then f_ext:write("return { percent_finished = 0.99 }"); f_ext:close() end

            local hf = io.open(data_dir .. "/history.lua", "w")
            if hf then
                hf:write("return { { file = \"/tmp/test_ext_storage/Foundation.epub\", time = 1234567 } }")
                hf:close()
            end
        end)

        after_each(function()
            os.remove(test_out)
            os.execute("rm -rf \"" .. books_dir .. "\"")
            os.execute("rm -rf \"" .. data_dir .. "\"")
            os.execute("rm -rf /tmp/test_ext_storage")
        end)

        it("archives sidecars from books_dir and history.lua when DOCSETTINGS is selected", function()
            local ok, res = ArchiverMgr.createBackup{
                archive_path = test_out,
                format = "tar",
                backup_name = "test_docsettings_backup",
                data_dir = data_dir,
                books_dir = books_dir,
                components = {
                    docsettings = true,
                    history = true,
                },
            }
            assert.is_true(ok)
            assert.is_table(res)

            local f = io.open(test_out, "rb")
            assert.is_not_nil(f)
            local content = f:read("*all")
            f:close()

            -- Relative sidecars under books_dir
            assert.is_not_nil(content:find("docsettings/sidecars/Fiction/Dune.sdr/metadata.epub.lua"))
            assert.is_not_nil(content:find("docsettings/sidecars/SciFi/Hyperion.sdr/metadata.epub.lua"))

            -- External sidecar from history.lua
            assert.is_not_nil(content:find("docsettings/sidecars_abs/tmp/test_ext_storage/Foundation.sdr/metadata.epub.lua"))

            -- Modern history.lua under history/
            assert.is_not_nil(content:find("history/history.lua"))

            -- Excluded folders must not be present
            assert.is_nil(content:find("Android"))
        end)

        it("omits sidecars when DOCSETTINGS is false", function()
            local ok, res = ArchiverMgr.createBackup{
                archive_path = test_out,
                format = "tar",
                backup_name = "test_no_docsettings",
                data_dir = data_dir,
                books_dir = books_dir,
                components = {
                    docsettings = false,
                    history = false,
                },
            }
            assert.is_true(ok)

            local f = io.open(test_out, "rb")
            local content = f:read("*all")
            f:close()

            assert.is_nil(content:find("docsettings/sidecars"))
            assert.is_nil(content:find("history/history.lua"))
        end)

        it("includes profiles.lua and gestures.lua when SETTINGS is true", function()
            local lfs = require("libs/libkoreader-lfs")
            local custom_data_dir = "/tmp/test_profiles_backup_data"
            os.execute("mkdir -p " .. custom_data_dir .. "/settings")

            local pf = io.open(custom_data_dir .. "/settings/profiles.lua", "w")
            if pf then
                pf:write("return { NightMode = { settings = { name = 'NightMode', qm_show = true } } }")
                pf:close()
            end

            local gf = io.open(custom_data_dir .. "/settings/gestures.lua", "w")
            if gf then
                gf:write("return { swipe_up = { action = 'profile_exec_NightMode' } }")
                gf:close()
            end

            local sf = io.open(custom_data_dir .. "/settings.reader.lua", "w")
            if sf then
                sf:write("return { profiles_autoexec = { onWake = { 'NightMode' } } }")
                sf:close()
            end

            local ok, res = ArchiverMgr.createBackup{
                archive_path = test_out,
                format = "tar",
                backup_name = "test_profiles_backup",
                data_dir = custom_data_dir,
                components = {
                    settings = true,
                },
            }
            assert.is_true(ok)
            assert.is_table(res)

            local f = io.open(test_out, "rb")
            assert.is_not_nil(f)
            local content = f:read("*all")
            f:close()

            assert.is_not_nil(content:find("settings/profiles.lua"))
            assert.is_not_nil(content:find("settings/gestures.lua"))
            assert.is_not_nil(content:find("settings/settings.reader.lua"))

            os.execute("rm -rf " .. custom_data_dir)
        end)

        it("includes user quickmenu.koplugin under plugins component", function()
            local lfs = require("libs/libkoreader-lfs")
            local custom_data_dir = "/tmp/test_qm_plugin_backup_data"
            os.execute("mkdir -p " .. custom_data_dir .. "/plugins/quickmenu.koplugin")

            local mf = io.open(custom_data_dir .. "/plugins/quickmenu.koplugin/main.lua", "w")
            if mf then
                mf:write("-- mock quickmenu plugin")
                mf:close()
            end

            local ok, res = ArchiverMgr.createBackup{
                archive_path = test_out,
                format = "tar",
                backup_name = "test_qm_plugin_backup",
                data_dir = custom_data_dir,
                components = {
                    plugins = true,
                },
            }
            assert.is_true(ok)
            assert.is_table(res)

            local f = io.open(test_out, "rb")
            assert.is_not_nil(f)
            local content = f:read("*all")
            f:close()

            assert.is_not_nil(content:find("plugins/quickmenu.koplugin/main.lua"))

            os.execute("rm -rf " .. custom_data_dir)
        end)

        it("discovers available plugins, patches, fonts, and dictionaries", function()
            local test_dir = "/tmp/test_discovery_backup_data"
            os.execute("mkdir -p " .. test_dir .. "/plugins/myplugin.koplugin")
            os.execute("mkdir -p " .. test_dir .. "/plugins/statistics.koplugin") -- core plugin, should be skipped
            os.execute("mkdir -p " .. test_dir .. "/plugins/__MACOSX") -- mac junk, should be skipped
            os.execute("mkdir -p " .. test_dir .. "/plugins/Floating-Dictionary.koplugin-main") -- not a .koplugin, should be skipped
            os.execute("mkdir -p " .. test_dir .. "/patches")
            os.execute("mkdir -p " .. test_dir .. "/fonts")
            os.execute("mkdir -p " .. test_dir .. "/data/dict")
            os.execute("mkdir -p " .. test_dir .. "/dict/subfolder-dict")

            local pf = io.open(test_dir .. "/patches/1-mypatch.lua", "w")
            if pf then pf:write("patch") pf:close() end

            local ff = io.open(test_dir .. "/fonts/MyFont.ttf", "w")
            if ff then ff:write("font") ff:close() end

            local df = io.open(test_dir .. "/data/dict/stardict-test.ifo", "w")
            if df then df:write("dict") df:close() end

            local plugins = ArchiverMgr.getAvailablePlugins(test_dir)
            assert.are.equal(1, #plugins)
            assert.are.equal("myplugin.koplugin", plugins[1])

            local patches = ArchiverMgr.getAvailablePatches(test_dir)
            assert.are.equal(1, #patches)
            assert.are.equal("1-mypatch.lua", patches[1])

            local fonts = ArchiverMgr.getAvailableFonts(test_dir)
            assert.are.equal(1, #fonts)
            assert.are.equal("MyFont.ttf", fonts[1])

            local dicts = ArchiverMgr.getAvailableDictionaries(test_dir)
            assert.are.equal(2, #dicts)
            assert.are.equal("stardict-test.ifo", dicts[1])
            assert.are.equal("subfolder-dict", dicts[2])

            os.execute("rm -rf " .. test_dir)
        end)

        it("filters items selectively using selected_plugins, selected_patches, selected_fonts", function()
            local test_dir = "/tmp/test_selective_backup_data"
            os.execute("mkdir -p " .. test_dir .. "/plugins/pluginA.koplugin")
            os.execute("mkdir -p " .. test_dir .. "/plugins/pluginB.koplugin")
            os.execute("mkdir -p " .. test_dir .. "/patches")

            local p1 = io.open(test_dir .. "/plugins/pluginA.koplugin/main.lua", "w")
            if p1 then p1:write("pA") p1:close() end

            local p2 = io.open(test_dir .. "/plugins/pluginB.koplugin/main.lua", "w")
            if p2 then p2:write("pB") p2:close() end

            local pt1 = io.open(test_dir .. "/patches/1-patchA.lua", "w")
            if pt1 then pt1:write("ptA") pt1:close() end

            local pt2 = io.open(test_dir .. "/patches/2-patchB.lua", "w")
            if pt2 then pt2:write("ptB") pt2:close() end

            local ok, res = ArchiverMgr.createBackup{
                archive_path = test_out,
                format = "tar",
                backup_name = "test_selective_backup",
                data_dir = test_dir,
                components = {
                    plugins = true,
                    patches = true,
                },
                selected_plugins = {
                    ["pluginA.koplugin"] = true,
                    ["pluginB.koplugin"] = false,
                },
                selected_patches = {
                    ["1-patchA.lua"] = false,
                    ["2-patchB.lua"] = true,
                },
            }
            assert.is_true(ok)

            local f = io.open(test_out, "rb")
            assert.is_not_nil(f)
            local content = f:read("*all")
            f:close()

            -- pluginA should be included, pluginB excluded
            assert.is_not_nil(content:find("plugins/pluginA.koplugin/main.lua", 1, true))
            assert.is_nil(content:find("plugins/pluginB.koplugin/main.lua", 1, true))

            -- patchB should be included, patchA excluded
            assert.is_not_nil(content:find("patches/2-patchB.lua", 1, true))
            assert.is_nil(content:find("patches/1-patchA.lua", 1, true))

            os.execute("rm -rf " .. test_dir)
        end)

        it("filters out non-font files like README.md in getAvailableFonts", function()
            local test_dir = "/tmp/test_font_scan_dir"
            os.execute("mkdir -p " .. test_dir .. "/fonts/fontFamilyDir")
            local f1 = io.open(test_dir .. "/fonts/Custom-Font.ttf", "w")
            if f1 then f1:write("ttf"); f1:close() end
            local f2 = io.open(test_dir .. "/fonts/Other-Font.otf", "w")
            if f2 then f2:write("otf"); f2:close() end
            local f3 = io.open(test_dir .. "/fonts/README.md", "w")
            if f3 then f3:write("readme"); f3:close() end
            local f4 = io.open(test_dir .. "/fonts/notes.txt", "w")
            if f4 then f4:write("notes"); f4:close() end

            local fonts = ArchiverMgr.getAvailableFonts(test_dir)
            assert.is_table(fonts)
            assert.are.equal(3, #fonts)
            assert.are.equal("Custom-Font.ttf", fonts[1])
            assert.are.equal("Other-Font.otf", fonts[2])
            assert.are.equal("fontFamilyDir", fonts[3])

            os.execute("rm -rf " .. test_dir)
        end)
    end)
end)
