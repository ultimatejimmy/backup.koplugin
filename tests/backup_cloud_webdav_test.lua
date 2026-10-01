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
