require("tests/spec_helper")

local GDrive = require("backup_cloud_gdrive")
local Constants = require("backup_constants")

describe("backup_cloud_gdrive unit tests", function()
    before_each(function()
        GDrive.clearFolderCache()
    end)

    after_each(function()
        GDrive.clearFolderCache()
    end)

    describe("normalizeAndSplitPath", function()
        it("normalizes default and empty paths", function()
            local path, segs = GDrive._normalizeAndSplitPath(nil)
            assert.equals("koreader_backups", path)
            assert.equals(1, #segs)
            assert.equals("koreader_backups", segs[1])

            local path_empty, segs_empty = GDrive._normalizeAndSplitPath("")
            assert.equals("koreader_backups", path_empty)
            assert.equals(1, #segs_empty)
            assert.equals("koreader_backups", segs_empty[1])

            local path_slash, segs_slash = GDrive._normalizeAndSplitPath("///")
            assert.equals("koreader_backups", path_slash)
            assert.equals(1, #segs_slash)
            assert.equals("koreader_backups", segs_slash[1])
        end)

        it("normalizes multi-level forward slash paths with spaces", function()
            local path, segs = GDrive._normalizeAndSplitPath("/mine/koreader kindle/backup/")
            assert.equals("mine/koreader kindle/backup", path)
            assert.equals(3, #segs)
            assert.equals("mine", segs[1])
            assert.equals("koreader kindle", segs[2])
            assert.equals("backup", segs[3])
        end)

        it("normalizes Windows backslash paths", function()
            local path, segs = GDrive._normalizeAndSplitPath([[\mine\koreader kindle\backup\]])
            assert.equals("mine/koreader kindle/backup", path)
            assert.equals(3, #segs)
            assert.equals("mine", segs[1])
            assert.equals("koreader kindle", segs[2])
            assert.equals("backup", segs[3])
        end)

        it("collapses multiple consecutive slashes", function()
            local path, segs = GDrive._normalizeAndSplitPath("///mine//subfolder///backups///")
            assert.equals("mine/subfolder/backups", path)
            assert.equals(3, #segs)
            assert.equals("mine", segs[1])
            assert.equals("subfolder", segs[2])
            assert.equals("backups", segs[3])
        end)
    end)

    describe("ensureFolder hierarchical resolution and creation", function()
        local orig_https
        before_each(function()
            orig_https = package.loaded["ssl.https"]
        end)

        after_each(function()
            package.loaded["ssl.https"] = orig_https
        end)

        it("resolves multi-level folder hierarchy when folders already exist", function()
            local request_log = {}
            package.loaded["ssl.https"] = {
                request = function(req)
                    table.insert(request_log, req)
                    local url = req.url
                    if url:find("files%?q=") then
                        if url:find("mine", 1, true) and url:find("root", 1, true) then
                            local body = '{"files":[{"id":"id_mine","name":"mine"}]}'
                            if req.sink then req.sink(body) end
                            return 1, 200, {}, "OK"
                        elseif url:find("koreader", 1, true) and url:find("id_mine", 1, true) then
                            local body = '{"files":[{"id":"id_kk","name":"koreader kindle"}]}'
                            if req.sink then req.sink(body) end
                            return 1, 200, {}, "OK"
                        elseif url:find("backup", 1, true) and url:find("id_kk", 1, true) then
                            local body = '{"files":[{"id":"id_backup_leaf","name":"backup"}]}'
                            if req.sink then req.sink(body) end
                            return 1, 200, {}, "OK"
                        end
                    end
                    local body = '{"files":[]}'
                    if req.sink then req.sink(body) end
                    return 1, 200, {}, "OK"
                end
            }

            local called = false
            local result_ok = false
            local result_id = nil

            GDrive.ensureFolder("fake_token", [[\mine\koreader kindle\backup\]], function(ok, folder_id)
                called = true
                result_ok = ok
                result_id = folder_id
            end)

            assert.is_true(called)
            assert.is_true(result_ok)
            assert.equals("id_backup_leaf", result_id)
            assert.equals(3, #request_log)
        end)

        it("creates missing nested folders sequentially linking parents", function()
            local request_log = {}
            package.loaded["ssl.https"] = {
                request = function(req)
                    table.insert(request_log, req)
                    if req.method == "GET" then
                        -- Pretend none exist
                        local body = '{"files":[]}'
                        if req.sink then req.sink(body) end
                        return 1, 200, {}, "OK"
                    elseif req.method == "POST" then
                        -- Creation
                        local req_body = req.source and req.source() or ""
                        local created_id = "new_id_unknown"
                        if req_body:find('"name":"mine"') and req_body:find('"parents":%["root"%]') then
                            created_id = "new_id_mine"
                        elseif req_body:find('"name":"koreader kindle"') and req_body:find('"parents":%["new_id_mine"%]') then
                            created_id = "new_id_kk"
                        elseif req_body:find('"name":"backup"') and req_body:find('"parents":%["new_id_kk"%]') then
                            created_id = "new_id_backup"
                        end
                        local resp = string.format('{"id":%q,"name":"folder"}', created_id)
                        if req.sink then req.sink(resp) end
                        return 1, 200, {}, "OK"
                    end
                    return 1, 400, {}, "Bad Request"
                end
            }

            local called = false
            local result_ok = false
            local result_id = nil

            GDrive.ensureFolder("fake_token", "/mine/koreader kindle/backup/", function(ok, folder_id)
                called = true
                result_ok = ok
                result_id = folder_id
            end)

            assert.is_true(called)
            assert.is_true(result_ok)
            assert.equals("new_id_backup", result_id)
            -- 3 GET searches + 3 POST creations = 6 requests
            assert.equals(6, #request_log)
        end)

        it("escapes single quotes in segment names for the query", function()
            local queries = {}
            package.loaded["ssl.https"] = {
                request = function(req)
                    if req.method == "GET" then
                        table.insert(queries, req.url)
                        local body = '{"files":[{"id":"id_jimmy_folder","name":"Jimmy\'s Backups"}]}'
                        if req.sink then req.sink(body) end
                        return 1, 200, {}, "OK"
                    end
                    return 1, 200, {}, "OK"
                end
            }

            local called = false
            local result_id = nil
            GDrive.ensureFolder("fake_token", "Jimmy's Backups", function(ok, id)
                called = true
                result_id = id
            end)

            assert.is_true(called)
            assert.equals("id_jimmy_folder", result_id)
            assert.equals(1, #queries)
            assert.is_truthy(queries[1]:find("Jimmy", 1, true))
            assert.is_truthy(queries[1]:find("%27s", 1, true))
        end)

        it("invalidates cache when remote_dir path changes", function()
            local call_count = 0
            package.loaded["ssl.https"] = {
                request = function(req)
                    call_count = call_count + 1
                    local body = string.format('{"files":[{"id":"id_%d","name":"folder"}]}', call_count)
                    if req.sink then req.sink(body) end
                    return 1, 200, {}, "OK"
                end
            }

            local id1, id2
            GDrive.ensureFolder("fake_token", "folder_a", function(ok, id) id1 = id end)
            assert.equals("id_1", id1)
            assert.equals(1, call_count)

            -- Same path should use cache (no new network request)
            GDrive.ensureFolder("fake_token", "folder_a", function(ok, id) id1 = id end)
            assert.equals("id_1", id1)
            assert.equals(1, call_count)

            -- Different path should bust cache and query
            GDrive.ensureFolder("fake_token", "folder_b", function(ok, id) id2 = id end)
            assert.equals("id_2", id2)
            assert.equals(2, call_count)
        end)
    end)
end)
