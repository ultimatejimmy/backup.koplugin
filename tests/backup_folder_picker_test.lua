require("tests/spec_helper")

local BackupFolderPicker = require("backup_folder_picker")

describe("backup_folder_picker", function()
    describe("getParentPath", function()
        it("returns nil for root, nil, or empty paths", function()
            assert.is_nil(BackupFolderPicker.getParentPath(nil))
            assert.is_nil(BackupFolderPicker.getParentPath(""))
            assert.is_nil(BackupFolderPicker.getParentPath("/"))
            assert.is_nil(BackupFolderPicker.getParentPath("   "))
        end)

        it("correctly finds parent directory for nested unix paths", function()
            assert.are.same("/home/jpautz/.config", BackupFolderPicker.getParentPath("/home/jpautz/.config/koreader"))
            assert.are.same("/home/jpautz/.config", BackupFolderPicker.getParentPath("/home/jpautz/.config/koreader/"))
            assert.are.same("/home/jpautz", BackupFolderPicker.getParentPath("/home/jpautz/.config"))
            assert.are.same("/home", BackupFolderPicker.getParentPath("/home/jpautz"))
            assert.are.same("/", BackupFolderPicker.getParentPath("/home"))
        end)

        it("handles windows-style drive roots gracefully", function()
            assert.are.same("C:/Users", BackupFolderPicker.getParentPath("C:/Users/backups"))
            assert.are.same("C:", BackupFolderPicker.getParentPath("C:/Users"))
            assert.is_nil(BackupFolderPicker.getParentPath("C:"))
        end)
    end)

    describe("scanDirectory", function()
        it("returns subdirectories and counts backup archives", function()
            local mock_files = {
                ["/test/backups"] = { "daily", "weekly", "backup_2026.zip", "full_backup.tar.gz", "notes.txt" },
            }

            local mock_dirs = {
                ["/test/backups"] = true,
                ["/test/backups/daily"] = true,
                ["/test/backups/weekly"] = true,
            }

            local lfs = {
                dir = function(path)
                    local files = mock_files[path] or {}
                    local i = 0
                    return function()
                        i = i + 1
                        return files[i]
                    end
                end,
                attributes = function(path, mode)
                    if mock_dirs[path] then
                        return { mode = "directory", modification = 1700000000 }
                    else
                        return { mode = "file", size = 2048, modification = 1700000000 }
                    end
                end,
            }
            package.loaded["libs/libkoreader-lfs"] = lfs

            local subdirs, backup_count = BackupFolderPicker.scanDirectory("/test/backups")
            assert.are.same(2, backup_count) -- backup_2026.zip and full_backup.tar.gz
            assert.are.same(2, #subdirs)
            assert.are.same("daily", subdirs[1].name)
            assert.are.same("weekly", subdirs[2].name)
        end)
    end)

    describe("formatTwoLinesMax and truncateToWidth", function()
        local Font = require("ui/font")
        local face = Font:getFace("cfont", 14)

        it("returns empty string on nil or empty input", function()
            assert.are.same("", BackupFolderPicker.formatTwoLinesMax(nil, 200, face, true))
            assert.are.same("", BackupFolderPicker.formatTwoLinesMax("", 200, face, true))
        end)

        it("handles short names without wrapping", function()
            local text = "backups"
            local res = BackupFolderPicker.formatTwoLinesMax(text, 500, face, true)
            assert.are.same("backups", res)
            assert.is_nil(res:find("\n"))
        end)

        it("wraps and truncates super long folder names properly", function()
            local long_name = "koreader backup storage folder for multiple devices testing long name"
            local TextWidget = require("ui/widget/textwidget")
            local orig_new = TextWidget.new
            TextWidget.new = function(a, b)
                local args = b or a or {}
                local txt = args.text or ""
                return {
                    getSize = function()
                        return { w = #txt * 8, h = 16 }
                    end
                }
            end

            local formatted = BackupFolderPicker.formatTwoLinesMax(long_name, 200, face, true)
            assert.is_string(formatted)
            assert.truthy(formatted:find("\n"))

            local single_token = "VeryLongSingleFolderNameWithoutAnySpacesInItAtAllForTestingPurposes"
            local formatted_single = BackupFolderPicker.formatTwoLinesMax(single_token, 100, face, true)
            assert.is_string(formatted_single)
            assert.truthy(formatted_single:find("\n"))
            assert.truthy(formatted_single:find("%.%.%."))

            TextWidget.new = orig_new
        end)
    end)

    describe("show", function()
        it("instantiates Storefront-style UI and verifies no covers_fullscreen overlap bug", function()
            local UIManager = require("ui/uimanager")
            local shown_widget = nil
            local orig_show = UIManager.show
            UIManager.show = function(self, widget)
                shown_widget = widget
            end

            local mock_files = {
                ["/test/storage"] = {
                    "monthly_backups",
                    "nightly_backups",
                    "backup.zip"
                },
            }

            local mock_dirs = {
                ["/test/storage"] = true,
                ["/test/storage/monthly_backups"] = true,
                ["/test/storage/nightly_backups"] = true,
            }

            local lfs = {
                dir = function(path)
                    local files = mock_files[path] or {}
                    local i = 0
                    return function()
                        i = i + 1
                        return files[i]
                    end
                end,
                attributes = function(path, mode)
                    if mock_dirs[path] then
                        return { mode = "directory", modification = 1700000000 }
                    else
                        return { mode = "file", size = 1024, modification = 1700000000 }
                    end
                end,
            }
            package.loaded["libs/libkoreader-lfs"] = lfs

            local logger = require("logger")
            local last_err = nil
            local orig_err = logger.err
            logger.err = function(msg)
                last_err = msg
            end

            local confirmed_path = nil
            BackupFolderPicker.show{
                title = "Select Backup Folder",
                initial_path = "/test/storage",
                on_confirm = function(path)
                    confirmed_path = path
                end,
            }

            logger.err = orig_err
            if last_err then
                error(last_err)
            end
            assert.is_not_nil(shown_widget)
            -- Crucial: covers_fullscreen must NOT be true to prevent dialog overlapping bug
            assert.is_falsy(shown_widget.covers_fullscreen)

            UIManager.show = orig_show
        end)
    end)
end)
