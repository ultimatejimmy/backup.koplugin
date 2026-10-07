require("tests/spec_helper")

local WebDAV = require("backup_cloud_webdav")

describe("backup_cloud_webdav", function()
    describe("Base64 encoding", function()
        it("encodes standard credentials accurately", function()
            local b64 = WebDAV._toBase64("user:password")
            assert.equals("dXNlcjpwYXNzd29yZA==", b64)

            local b64_empty = WebDAV._toBase64("")
            assert.equals("", b64_empty)

            local b64_short = WebDAV._toBase64("a")
            assert.equals("YQ==", b64_short)

            local b64_two = WebDAV._toBase64("ab")
            assert.equals("YWI=", b64_two)
        end)
    end)

    describe("URL normalization and preservation", function()
        it("preserves trailing slashes when provided by the user", function()
            local url = WebDAV._normalizeUrl("http://192.168.1.50/webdav/")
            assert.equals("http://192.168.1.50/webdav/", url)

            local https_url = WebDAV._normalizeUrl("https://cloud.example.com/remote.php/dav/files/user/")
            assert.equals("https://cloud.example.com/remote.php/dav/files/user/", https_url)
        end)

        it("preserves URLs without trailing slashes", function()
            local url = WebDAV._normalizeUrl("http://192.168.1.50/webdav")
            assert.equals("http://192.168.1.50/webdav", url)
        end)

        it("collapses multiple consecutive trailing slashes down to a single slash", function()
            local url = WebDAV._normalizeUrl("http://192.168.1.50/webdav///")
            assert.equals("http://192.168.1.50/webdav/", url)
        end)

        it("defaults protocol to https when omitted", function()
            local url = WebDAV._normalizeUrl("192.168.1.50/webdav/")
            assert.equals("https://192.168.1.50/webdav/", url)
        end)

        it("trims surrounding whitespace", function()
            local url = WebDAV._normalizeUrl("   http://192.168.1.50/webdav/   ")
            assert.equals("http://192.168.1.50/webdav/", url)
        end)

        it("handles empty and nil URLs gracefully", function()
            assert.equals("", WebDAV._normalizeUrl(""))
            assert.equals("", WebDAV._normalizeUrl(nil))
        end)
    end)

    describe("Remote folder URL construction", function()
        it("joins base URL and remote directory without producing double slashes", function()
            local folder_url = WebDAV._getRemoteFolderUrl({
                url = "http://192.168.1.50/webdav/",
                remote_dir = "koreader_backups",
            })
            assert.equals("http://192.168.1.50/webdav/koreader_backups", folder_url)
        end)

        it("handles remote directory with leading and trailing slashes", function()
            local folder_url = WebDAV._getRemoteFolderUrl({
                url = "http://192.168.1.50/webdav/",
                remote_dir = "/backups/koreader/",
            })
            assert.equals("http://192.168.1.50/webdav/backups/koreader", folder_url)
        end)

        it("returns base URL preserving trailing slash when remote directory is empty", function()
            local folder_url = WebDAV._getRemoteFolderUrl({
                url = "http://192.168.1.50/webdav/",
                remote_dir = "",
            })
            assert.equals("http://192.168.1.50/webdav/", folder_url)
        end)

        it("returns base URL without trailing slash when remote directory is empty and base had none", function()
            local folder_url = WebDAV._getRemoteFolderUrl({
                url = "http://192.168.1.50/webdav",
                remote_dir = "",
            })
            assert.equals("http://192.168.1.50/webdav", folder_url)
        end)
    end)

    describe("Redirect Location resolution (RFC 3986)", function()
        it("resolves absolute URLs directly", function()
            local res = WebDAV._resolveRedirectUrl("http://192.168.1.50/webdav", "http://192.168.1.50/webdav/")
            assert.equals("http://192.168.1.50/webdav/", res)

            local https_res = WebDAV._resolveRedirectUrl("http://192.168.1.50/webdav", "https://192.168.1.50/webdav/")
            assert.equals("https://192.168.1.50/webdav/", https_res)
        end)

        it("resolves path-absolute redirects starting with a slash", function()
            local res = WebDAV._resolveRedirectUrl("http://192.168.1.50/webdav", "/webdav/")
            assert.equals("http://192.168.1.50/webdav/", res)

            local res_sub = WebDAV._resolveRedirectUrl("http://192.168.1.50:8080/files/backup", "/files/backup/")
            assert.equals("http://192.168.1.50:8080/files/backup/", res_sub)
        end)

        it("resolves relative path redirects", function()
            local res = WebDAV._resolveRedirectUrl("http://192.168.1.50/webdav", "webdav/")
            assert.equals("http://192.168.1.50/webdav/", res)

            local res_child = WebDAV._resolveRedirectUrl("http://192.168.1.50/dav/files/", "backup/")
            assert.equals("http://192.168.1.50/dav/files/backup/", res_child)
        end)

        it("resolves protocol-relative redirects", function()
            local res = WebDAV._resolveRedirectUrl("http://example.com/dav", "//example.com/dav/")
            assert.equals("http://example.com/dav/", res)
        end)

        it("returns nil for invalid or empty Location headers", function()
            assert.is_nil(WebDAV._resolveRedirectUrl("http://example.com/dav", ""))
            assert.is_nil(WebDAV._resolveRedirectUrl("http://example.com/dav", nil))
            assert.is_nil(WebDAV._resolveRedirectUrl("not_a_url", "/dav/"))
        end)
    end)

    describe("HTTP redirect handling in doRequest", function()
        local orig_http
        local orig_webdav_mod

        before_each(function()
            orig_http = package.loaded["socket.http"]
            orig_webdav_mod = package.loaded["backup_cloud_webdav"]
        end)

        after_each(function()
            package.loaded["socket.http"] = orig_http
            package.loaded["backup_cloud_webdav"] = orig_webdav_mod
        end)

        it("follows 301 Moved Permanently to new destination URL", function()
            local calls = {}
            package.loaded["socket.http"] = {
                request = function(req)
                    table.insert(calls, req.url)
                    if #calls == 1 then
                        return 1, 301, { location = "/webdav/" }, "HTTP/1.1 301 Moved Permanently"
                    else
                        return 1, 207, {}, "HTTP/1.1 207 Multi-Status"
                    end
                end
            }
            package.loaded["backup_cloud_webdav"] = nil
            local fresh_WebDAV = require("backup_cloud_webdav")

            local r, code, resp_headers, status, body, final_url = fresh_WebDAV._doRequest({
                url = "http://192.168.1.50/webdav",
                method = "PROPFIND",
            })

            assert.equals(2, #calls)
            assert.equals("http://192.168.1.50/webdav", calls[1])
            assert.equals("http://192.168.1.50/webdav/", calls[2])
            assert.equals(207, code)
            assert.equals("http://192.168.1.50/webdav/", final_url)
        end)

        it("follows 302, 307, and 308 redirects", function()
            for _, status_code in ipairs({ 302, 307, 308 }) do
                local calls = {}
                package.loaded["socket.http"] = {
                    request = function(req)
                        table.insert(calls, req.url)
                        if #calls == 1 then
                            return 1, status_code, { location = "http://192.168.1.50/target/" }, "Redirect"
                        else
                            return 1, 200, {}, "OK"
                        end
                    end,
                }
                package.loaded["backup_cloud_webdav"] = nil
                local fresh_WebDAV = require("backup_cloud_webdav")

                local r, code, resp_headers, status, body, final_url = fresh_WebDAV._doRequest({
                    url = "http://192.168.1.50/start",
                    method = "GET",
                })

                assert.equals(2, #calls)
                assert.equals("http://192.168.1.50/target/", calls[2])
                assert.equals(200, code)
            end
        end)

        it("changes method to GET on 303 See Other", function()
            local calls = {}
            package.loaded["socket.http"] = {
                request = function(req)
                    table.insert(calls, { url = req.url, method = req.method })
                    if #calls == 1 then
                        return 1, 303, { location = "/other" }, "See Other"
                    else
                        return 1, 200, {}, "OK"
                    end
                end
            }
            package.loaded["backup_cloud_webdav"] = nil
            local fresh_WebDAV = require("backup_cloud_webdav")

            local r, code = fresh_WebDAV._doRequest({
                url = "http://192.168.1.50/action",
                method = "PROPFIND",
            })

            assert.equals(2, #calls)
            assert.equals("PROPFIND", calls[1].method)
            assert.equals("GET", calls[2].method)
            assert.equals(200, code)
        end)

        it("halts after max 5 redirects to prevent infinite loops", function()
            local call_count = 0
            package.loaded["socket.http"] = {
                request = function(req)
                    call_count = call_count + 1
                    return 1, 301, { location = "http://192.168.1.50/loop" }, "Moved"
                end
            }
            package.loaded["backup_cloud_webdav"] = nil
            local fresh_WebDAV = require("backup_cloud_webdav")

            local r, code = fresh_WebDAV._doRequest({
                url = "http://192.168.1.50/loop",
                method = "GET",
            })

            -- Initial request + 5 redirects = 6 calls total
            assert.equals(6, call_count)
            assert.equals(301, code)
        end)

        it("strips Authorization header when redirected cross-host", function()
            local calls = {}
            package.loaded["socket.http"] = {
                request = function(req)
                    table.insert(calls, {
                        url = req.url,
                        auth = req.headers and (req.headers["Authorization"] or req.headers["authorization"]),
                    })
                    if #calls == 1 then
                        return 1, 301, { location = "http://different-host.com/webdav/" }, "Moved"
                    else
                        return 1, 200, {}, "OK"
                    end
                end,
            }
            package.loaded["backup_cloud_webdav"] = nil
            local fresh_WebDAV = require("backup_cloud_webdav")

            local r, code = fresh_WebDAV._doRequest({
                url = "http://source-host.com/webdav",
                method = "PROPFIND",
                headers = {
                    ["Authorization"] = "Basic dXNlcjpwYXNz",
                },
            })

            assert.equals(2, #calls)
            assert.equals("http://source-host.com/webdav", calls[1].url)
            assert.equals("Basic dXNlcjpwYXNz", calls[1].auth)
            assert.equals("http://different-host.com/webdav/", calls[2].url)
            assert.is_nil(calls[2].auth)
            assert.equals(200, code)
        end)

        it("preserves Authorization header when redirected to same host", function()
            local calls = {}
            package.loaded["socket.http"] = {
                request = function(req)
                    table.insert(calls, {
                        url = req.url,
                        auth = req.headers and (req.headers["Authorization"] or req.headers["authorization"]),
                    })
                    if #calls == 1 then
                        return 1, 301, { location = "http://source-host.com/webdav/" }, "Moved"
                    else
                        return 1, 200, {}, "OK"
                    end
                end,
            }
            package.loaded["backup_cloud_webdav"] = nil
            local fresh_WebDAV = require("backup_cloud_webdav")

            local r, code = fresh_WebDAV._doRequest({
                url = "http://source-host.com/webdav",
                method = "PROPFIND",
                headers = {
                    ["Authorization"] = "Basic dXNlcjpwYXNz",
                },
            })

            assert.equals(2, #calls)
            assert.equals("http://source-host.com/webdav", calls[1].url)
            assert.equals("Basic dXNlcjpwYXNz", calls[1].auth)
            assert.equals("http://source-host.com/webdav/", calls[2].url)
            assert.equals("Basic dXNlcjpwYXNz", calls[2].auth)
            assert.equals(200, code)
        end)
    end)

    describe("PROPFIND XML parsing", function()
        it("parses WebDAV multi-status XML responses into backup file entries", function()
            local sample_xml = [[<?xml version="1.0" encoding="utf-8"?>
<D:multistatus xmlns:D="DAV:">
    <D:response>
        <D:href>/remote.php/dav/files/user/koreader_backups/</D:href>
        <D:propstat>
            <D:prop>
                <D:resourcetype><D:collection/></D:resourcetype>
            </D:prop>
            <D:status>HTTP/1.1 200 OK</D:status>
        </D:propstat>
    </D:response>
    <D:response>
        <D:href>/remote.php/dav/files/user/koreader_backups/backup_2026-09-30_120000.zip</D:href>
        <D:propstat>
            <D:prop>
                <D:getcontentlength>15420391</D:getcontentlength>
                <D:getlastmodified>Wed, 30 Sep 2026 12:00:00 GMT</D:getlastmodified>
                <D:resourcetype/>
            </D:prop>
            <D:status>HTTP/1.1 200 OK</D:status>
        </D:propstat>
    </D:response>
    <D:response>
        <D:href>/remote.php/dav/files/user/koreader_backups/backup_2026-09-29_100000.tar.gz</D:href>
        <D:propstat>
            <D:prop>
                <D:getcontentlength>8392100</D:getcontentlength>
                <D:getlastmodified>Tue, 29 Sep 2026 10:00:00 GMT</D:getlastmodified>
                <D:resourcetype/>
            </D:prop>
            <D:status>HTTP/1.1 200 OK</D:status>
        </D:propstat>
    </D:response>
    <D:response>
        <D:href>/remote.php/dav/files/user/koreader_backups/notes.txt</D:href>
        <D:propstat>
            <D:prop>
                <D:getcontentlength>120</D:getcontentlength>
                <D:resourcetype/>
            </D:prop>
            <D:status>HTTP/1.1 200 OK</D:status>
        </D:propstat>
    </D:response>
</D:multistatus>]]

            local files = WebDAV._parsePropfindXml(sample_xml)
            assert.equals(2, #files)

            -- Sorted newest first
            assert.equals("backup_2026-09-30_120000.zip", files[1].filename)
            assert.equals(15420391, files[1].size)
            assert.equals("Wed, 30 Sep 2026 12:00:00 GMT", files[1].mtime_str)

            assert.equals("backup_2026-09-29_100000.tar.gz", files[2].filename)
            assert.equals(8392100, files[2].size)
        end)

        it("handles empty or invalid XML gracefully", function()
            local empty = WebDAV._parsePropfindXml("")
            assert.equals(0, #empty)

            local nil_xml = WebDAV._parsePropfindXml(nil)
            assert.equals(0, #nil_xml)
        end)
    end)
end)
