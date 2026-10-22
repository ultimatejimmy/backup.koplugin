require("tests/spec_helper")

local socket = require("socket")
local FTP = require("backup_cloud_ftp")

describe("backup_cloud_ftp unit tests", function()
    local orig_tcp = socket.tcp

    after_each(function()
        socket.tcp = orig_tcp
    end)

    local function createMockSocket(responses)
        local sent_cmds = {}
        local idx = 1
        return {
            sent = sent_cmds,
            settimeout = function(self, t) end,
            connect = function(self, host, port) return 1 end,
            send = function(self, data)
                table.insert(sent_cmds, data)
                return #data
            end,
            receive = function(self, pattern)
                local r = responses[idx]
                idx = idx + 1
                return r or "200 OK\r\n"
            end,
            close = function(self) return 1 end,
            getpeername = function(self) return "127.0.0.1", 21 end,
        }
    end

    describe("FTP.testConnection", function()
        it("returns success on valid greeting, authentication, and directory navigation", function()
            local mock_sock = createMockSocket({
                "220 FTP Server Ready\r\n", -- Greeting
                "331 User okay, password required\r\n", -- USER response
                "230 User logged in\r\n", -- PASS response
                "200 Type set to I\r\n", -- TYPE I response
                "250 Directory successfully changed\r\n", -- CWD response
                "221 Goodbye\r\n", -- QUIT response
            })

            socket.tcp = function() return mock_sock end

            local called = false
            local result_ok = false
            local result_msg = nil

            FTP.testConnection({
                host = "ftp.example.com",
                port = 21,
                username = "testuser",
                password = "testpass",
                remote_dir = "koreader_backups",
            }, function(ok, msg)
                called = true
                result_ok = ok
                result_msg = msg
            end)

            assert.is_true(called)
            assert.is_true(result_ok)
            assert.is_truthy(result_msg:find("Connection successful"))
        end)

        it("navigates and creates multi-level directory with backslashes and spaces segment-by-segment", function()
            local mock_sock = createMockSocket({
                "220 FTP Server Ready\r\n",
                "331 User okay, password required\r\n",
                "230 User logged in\r\n",
                "200 Type set to I\r\n",
                "550 Directory not found\r\n", -- CWD mine/koreader kindle/backup fails directly
                "250 CWD mine ok\r\n",        -- CWD mine succeeds
                "550 CWD koreader kindle not found\r\n",
                "257 MKD koreader kindle created\r\n",
                "250 CWD koreader kindle ok\r\n",
                "550 CWD backup not found\r\n",
                "257 MKD backup created\r\n",
                "250 CWD backup ok\r\n",
                "221 Goodbye\r\n",
            })

            socket.tcp = function() return mock_sock end

            local called = false
            local result_ok = false

            FTP.testConnection({
                host = "ftp.example.com",
                port = 21,
                username = "testuser",
                password = "testpass",
                remote_dir = [[\mine\koreader kindle\backup\]],
            }, function(ok, msg)
                called = true
                result_ok = ok
            end)

            assert.is_true(called)
            assert.is_true(result_ok)
            -- Verify sent commands include CWD/MKD for segments
            local all_sent = table.concat(mock_sock.sent, "")
            assert.is_truthy(all_sent:find("CWD mine"))
            assert.is_truthy(all_sent:find("MKD koreader kindle"))
            assert.is_truthy(all_sent:find("MKD backup"))
        end)

        it("fails gracefully if server connection is refused", function()
            socket.tcp = function()
                return {
                    settimeout = function() end,
                    connect = function() return nil, "connection refused" end,
                    close = function() end,
                }
            end

            local called = false
            local result_ok = true
            local result_msg = nil

            FTP.testConnection({
                host = "ftp.example.com",
                port = 21,
                username = "testuser",
                password = "testpass",
            }, function(ok, msg)
                called = true
                result_ok = ok
                result_msg = msg
            end)

            assert.is_true(called)
            assert.is_false(result_ok)
            assert.is_truthy(result_msg:find("Could not connect"))
        end)

        it("fails gracefully if server rejects credentials", function()
            local mock_sock = createMockSocket({
                "220 FTP Server Ready\r\n",
                "331 User okay, password required\r\n",
                "530 Not logged in, bad password\r\n", -- Bad pass
            })

            socket.tcp = function() return mock_sock end

            local called = false
            local result_ok = true
            local result_msg = nil

            FTP.testConnection({
                host = "ftp.example.com",
                port = 21,
                username = "wronguser",
                password = "wrongpass",
            }, function(ok, msg)
                called = true
                result_ok = ok
                result_msg = msg
            end)

            assert.is_true(called)
            assert.is_false(result_ok)
            assert.is_truthy(result_msg:find("authentication failed"))
        end)
    end)
end)
