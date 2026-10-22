require("tests/spec_helper")

local OneDrive = require("backup_cloud_onedrive")
local Constants = require("backup_constants")

describe("backup_cloud_onedrive unit tests", function()
    before_each(function()
        OneDrive.clearFolderCache()
    end)

    after_each(function()
        OneDrive.clearFolderCache()
    end)

    describe("path normalization and graph encoding", function()
        it("normalizes and splits paths", function()
            local p, segs = OneDrive._normalizeAndSplitPath([[\mine\koreader kindle\backup\]])
            assert.equals("mine/koreader kindle/backup", p)
            assert.equals(3, #segs)
            assert.equals("mine", segs[1])
            assert.equals("koreader kindle", segs[2])
            assert.equals("backup", segs[3])
        end)

        it("encodes multi-level Graph URI paths preserving slashes and encoding spaces as %20", function()
            local encoded = OneDrive._encodeGraphPath([[\mine\koreader kindle\backup\]])
            assert.equals("mine/koreader%20kindle/backup", encoded)
        end)
    end)

    describe("ensureFolder resolution and creation", function()
        local orig_https
        before_each(function()
            orig_https = package.loaded["ssl.https"]
        end)

        after_each(function()
            package.loaded["ssl.https"] = orig_https
        end)

        it("resolves multi-level folder on fast-path when it exists", function()
            local request_log = {}
            package.loaded["ssl.https"] = {
                request = function(req)
                    table.insert(request_log, req)
                    if req.url:find("root:/mine/koreader%%20kindle/backup$") then
                        local body = '{"id":"onedrive_leaf_id","name":"backup"}'
                        if req.sink then req.sink(body) end
                        return 1, 200, {}, "OK"
                    end
                    return 1, 404, {}, "Not Found"
                end
            }

            local called = false
            local result_id = nil
            OneDrive.ensureFolder("fake_token", "/mine/koreader kindle/backup/", function(ok, id)
                called = true
                result_id = id
            end)

            assert.is_true(called)
            assert.equals("onedrive_leaf_id", result_id)
            assert.equals(1, #request_log)
        end)

        it("creates missing folder segments when full path is not found", function()
            local request_log = {}
            package.loaded["ssl.https"] = {
                request = function(req)
                    table.insert(request_log, req)
                    if req.method == "GET" then
                        -- Pretend fast path and segments don't exist
                        return 1, 404, {}, "Not Found"
                    elseif req.method == "POST" then
                        local req_body = req.source and req.source() or ""
                        local cid = "created_id"
                        if req_body:find('"name":"mine"') then
                            cid = "id_od_mine"
                        elseif req_body:find('"name":"koreader kindle"') then
                            cid = "id_od_kk"
                        elseif req_body:find('"name":"backup"') then
                            cid = "id_od_backup"
                        end
                        local resp = string.format('{"id":%q,"name":"folder"}', cid)
                        if req.sink then req.sink(resp) end
                        return 1, 201, {}, "Created"
                    end
                    return 1, 400, {}, "Bad Request"
                end
            }

            local called = false
            local result_id = nil
            OneDrive.ensureFolder("fake_token", [[\mine\koreader kindle\backup\]], function(ok, id)
                called = true
                result_id = id
            end)

            assert.is_true(called)
            assert.equals("id_od_backup", result_id)
            -- 1 fast-path GET + 3 segment GETs + 3 POST creations = 7 requests
            assert.equals(7, #request_log)
        end)

        it("invalidates cache on path change", function()
            local call_count = 0
            package.loaded["ssl.https"] = {
                request = function(req)
                    call_count = call_count + 1
                    local body = string.format('{"id":"od_%d","name":"folder"}', call_count)
                    if req.sink then req.sink(body) end
                    return 1, 200, {}, "OK"
                end
            }

            local id1, id2
            OneDrive.ensureFolder("fake_token", "folder_a", function(ok, id) id1 = id end)
            assert.equals("od_1", id1)
            assert.equals(1, call_count)

            OneDrive.ensureFolder("fake_token", "folder_a", function(ok, id) id1 = id end)
            assert.equals("od_1", id1)
            assert.equals(1, call_count)

            OneDrive.ensureFolder("fake_token", "folder_b", function(ok, id) id2 = id end)
            assert.equals("od_2", id2)
            assert.equals(2, call_count)
        end)
    end)
end)
