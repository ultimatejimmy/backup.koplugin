require("tests/spec_helper")

local Beam = require("backup_beam")
local Constants = require("backup_constants")

describe("backup_beam", function()
    local test_dir = "/tmp/koreader_beam_test"
    before_each(function()
        os.execute("mkdir -p " .. test_dir .. " 2>/dev/null")
    end)
    after_each(function()
        os.execute("rm -rf " .. test_dir .. " 2>/dev/null")
    end)

    describe("PIN generation and formatting", function()
        it("generates a 6-digit numeric PIN", function()
            local pin = Beam.generatePin()
            assert.is_string(pin)
            assert.equals(6, #pin)
            assert.is_truthy(pin:match("^%d%d%d%d%d%d$"))
        end)

        it("formats 6-digit PIN with a dash for display", function()
            assert.equals("482-910", Beam.formatPin("482910"))
            assert.equals("123-456", Beam.formatPin("123-456"))
        end)

        it("cleans and validates user input PIN strings", function()
            local clean, err = Beam.cleanPin("482-910")
            assert.equals("482910", clean)
            assert.is_nil(err)

            local clean_spaced = Beam.cleanPin("  739 281  ")
            assert.equals("739281", clean_spaced)

            local invalid_short, err_short = Beam.cleanPin("12345")
            assert.is_nil(invalid_short)
            assert.is_string(err_short)

            local invalid_chars, err_chars = Beam.cleanPin("abcdef")
            assert.is_nil(invalid_chars)
        end)

        it("derives deterministic lookup token from PIN", function()
            local token1 = Beam.deriveToken("482910")
            local token2 = Beam.deriveToken("482-910")
            assert.is_string(token1)
            assert.equals(16, #token1)
            assert.equals(token1, token2)

            -- Different PIN produces different token
            local token3 = Beam.deriveToken("482911")
            assert.are_not.equals(token1, token3)
        end)
    end)

    describe("End-to-End Encryption and Decryption (Zero-Knowledge)", function()
        it("encrypts and decrypts payload data accurately", function()
            local original_data = "PK\003\004... simulated zip binary content with settings and history ..."
            local pin = "739281"
            local filename = "backup_test_2026.zip"

            local encrypted_payload = Beam.encryptPayload(original_data, pin, filename)
            assert.is_string(encrypted_payload)
            assert.is_truthy(#encrypted_payload > #original_data)
            -- Starts with magic header
            assert.is_truthy(encrypted_payload:find("^" .. Constants.BEAM_MAGIC_HEADER))

            -- Decrypt with correct PIN
            local ok, dec_filename, decrypted_data = Beam.decryptPayload(encrypted_payload, pin)
            assert.is_true(ok)
            assert.equals(filename, dec_filename)
            assert.equals(original_data, decrypted_data)
        end)

        it("fails decryption when wrong PIN is provided", function()
            local original_data = "sensitive user settings and reading progress"
            local pin = "112233"
            local wrong_pin = "998877"

            local encrypted = Beam.encryptPayload(original_data, pin, "test.zip")
            local ok, err = Beam.decryptPayload(encrypted, wrong_pin)
            assert.is_false(ok)
            assert.is_string(err)
            assert.is_truthy(err:find("Invalid Beam code") or err:find("corrupted"))
        end)

        it("fails decryption when payload is corrupted or tampered with", function()
            local original_data = "unaltered backup archive bytes"
            local pin = "554433"
            local encrypted = Beam.encryptPayload(original_data, pin, "test.zip")

            -- Tamper with ciphertext at end
            local corrupted = encrypted:sub(1, #encrypted - 5) .. "XXXXX"
            local ok, err = Beam.decryptPayload(corrupted, pin)
            assert.is_false(ok)
            assert.is_string(err)
        end)

        it("handles file encryption and decryption to disk", function()
            local src_file = test_dir .. "/sample_backup.zip"
            local content = "BINARY_MOCK_BACKUP_CONTENT_FOR_DISK_TEST"
            local f = io.open(src_file, "wb")
            f:write(content)
            f:close()

            local pin = "654321"
            local payload, enc_err = Beam.encryptFile(src_file, pin)
            assert.is_string(payload)
            assert.is_nil(enc_err)

            local dest_dir = test_dir .. "/restored_backups"
            local ok, target_path, filename = Beam.decryptToFile(payload, pin, dest_dir)
            assert.is_true(ok)
            assert.equals("sample_backup.zip", filename)
            assert.equals(dest_dir .. "/sample_backup.zip", target_path)

            local rf = io.open(target_path, "rb")
            local read_content = rf:read("*a")
            rf:close()
            assert.equals(content, read_content)
        end)

        it("streams multi-chunk file encryption directly to disk without memory buffering", function()
            local src_file = test_dir .. "/large_test.zip"
            local enc_file = test_dir .. "/large_test.enc"
            local dest_dir = test_dir .. "/stream_restored"
            -- Create a 200KB file spanning multiple 64KB chunks
            local chunk_sample = "CHUNK_DATA_FOR_STREAMING_ENCRYPTION_AND_DECRYPTION_TEST_1234567890\n"
            local total_chunks = math.ceil(200000 / #chunk_sample)
            local large_content = string.rep(chunk_sample, total_chunks)

            local f = io.open(src_file, "wb")
            f:write(large_content)
            f:close()

            local pin = "819273"
            local ok_enc, total_enc_bytes = Beam.encryptFileToPath(src_file, enc_file, pin)
            assert.is_true(ok_enc)
            assert.is_truthy(total_enc_bytes > #large_content)

            -- Stream-decrypt directly from disk to destination folder
            local ok_dec, target_path, filename = Beam.decryptToFile(enc_file, pin, dest_dir)
            assert.is_true(ok_dec)
            assert.equals("large_test.zip", filename)

            local rf = io.open(target_path, "rb")
            local read_content = rf:read("*a")
            rf:close()
            assert.equals(#large_content, #read_content)
            assert.equals(large_content, read_content)

            -- Verify wrong pin fails cleanly in streaming mode
            local ok_bad, err_bad = Beam.decryptToFile(enc_file, "000000", dest_dir)
            assert.is_false(ok_bad)
            assert.is_string(err_bad)
            assert.is_truthy(err_bad:find("Invalid Beam code") or err_bad:find("corrupted"))
        end)
    end)

    describe("Progress and transport stages", function()
        it("reports uploading chunks and finalizing stage on completion", function()
            local dummy_data = string.rep("A", 150000) -- ~150KB (3 chunks of 64KB)
            local reports = {}
            local on_progress = function(sent, total, stage)
                table.insert(reports, { sent = sent, total = total, stage = stage })
            end

            local source = Beam._makeProgressSource(dummy_data, on_progress)
            assert.is_function(source)

            local chunk1 = source()
            assert.equals(65536, #chunk1)
            assert.equals("uploading", reports[#reports].stage)

            local chunk2 = source()
            assert.equals(65536, #chunk2)
            assert.equals("uploading", reports[#reports].stage)

            local chunk3 = source()
            assert.equals(150000 - 65536 * 2, #chunk3)
            assert.equals("uploading", reports[#reports].stage)

            -- Next call hits EOF and must report "finalizing" before returning nil
            local chunk4 = source()
            assert.is_nil(chunk4)
            assert.equals("finalizing", reports[#reports].stage)
            assert.equals(150000, reports[#reports].sent)
            assert.equals(150000, reports[#reports].total)

            -- Subsequent call should remain nil without duplicate finalizing event
            local prev_count = #reports
            local chunk5 = source()
            assert.is_nil(chunk5)
            assert.equals(prev_count, #reports)
        end)

        it("reports uploading chunks and finalizing stage using streaming file source", function()
            local test_file = test_dir .. "/source_file.bin"
            local dummy_data = string.rep("B", 140000) -- ~140KB (2 full 64KB chunks + remainder)
            local f = io.open(test_file, "wb")
            f:write(dummy_data)
            f:close()

            local fh = io.open(test_file, "rb")
            local reports = {}
            local on_progress = function(sent, total, stage)
                table.insert(reports, { sent = sent, total = total, stage = stage })
            end

            local source = Beam._makeFileProgressSource(fh, #dummy_data, on_progress)
            assert.is_function(source)

            local c1 = source()
            assert.equals(65536, #c1)
            assert.equals("uploading", reports[#reports].stage)

            local c2 = source()
            assert.equals(65536, #c2)
            assert.equals("uploading", reports[#reports].stage)

            local c3 = source()
            assert.equals(140000 - 65536 * 2, #c3)
            assert.equals("uploading", reports[#reports].stage)

            local c4 = source()
            assert.is_nil(c4)
            assert.equals("finalizing", reports[#reports].stage)
            assert.equals(140000, reports[#reports].sent)
            fh:close()
        end)
    end)

    describe("Unaligned byte boundaries and 32-bit word stream cipher safety", function()
        it("accurately encrypts and decrypts odd and unaligned lengths", function()
            local test_lengths = { 1, 2, 3, 4, 7, 8, 15, 16, 31, 33, 127, 255, 1027, 65535, 65537 }
            local pin = "842915"

            for _, len in ipairs(test_lengths) do
                local raw = string.rep("x", len)
                local enc, err = Beam.encryptPayload(raw, pin, "test_" .. len .. ".zip")
                assert.is_string(enc, "Failed for length: " .. len)
                assert.is_nil(err)

                local ok, dec_fn, dec_data = Beam.decryptPayload(enc, pin)
                assert.is_true(ok, "Decryption failed for length: " .. len)
                assert.equals(raw, dec_data)
                assert.equals("test_" .. len .. ".zip", dec_fn)
            end
        end)

        it("handles empty payload data without error", function()
            local pin = "123456"
            local enc = Beam.encryptPayload("", pin, "empty.zip")
            assert.is_string(enc)

            local ok, _, dec = Beam.decryptPayload(enc, pin)
            assert.is_true(ok)
            assert.equals("", dec)
        end)
    end)

    describe("Transient error detection and network retry handling", function()
        it("identifies transient socket and HTTP errors correctly", function()
            -- Transport / socket errors (r == nil)
            assert.is_true(Beam.isTransientError(nil, "Connection reset by peer"))
            assert.is_true(Beam.isTransientError(nil, "connection closed"))
            assert.is_true(Beam.isTransientError(nil, "timeout"))
            assert.is_true(Beam.isTransientError(nil, "broken pipe"))
            assert.is_true(Beam.isTransientError(nil, "wantread"))
            assert.is_true(Beam.isTransientError(nil, "connection refused"))
            assert.is_true(Beam.isTransientError(nil, "SSL handshake failed"))
            assert.is_true(Beam.isTransientError(nil, "unexpected eof"))

            -- Transient server/gateway HTTP status codes
            assert.is_true(Beam.isTransientError(1, 500))
            assert.is_true(Beam.isTransientError(1, 502))
            assert.is_true(Beam.isTransientError(1, 503))
            assert.is_true(Beam.isTransientError(1, 504))
            assert.is_true(Beam.isTransientError(1, 408))
            assert.is_true(Beam.isTransientError(1, 429))

            -- Permanent or client errors
            assert.is_false(Beam.isTransientError(1, 200))
            assert.is_false(Beam.isTransientError(1, 201))
            assert.is_false(Beam.isTransientError(1, 400))
            assert.is_false(Beam.isTransientError(1, 404))
            assert.is_false(Beam.isTransientError(1, 403))
            assert.is_false(Beam.isTransientError(nil, "invalid parameter"))
        end)

        describe("Upload retry and error formatting", function()
            local orig_https = package.loaded["ssl.https"]
            local orig_http = package.loaded["socket.http"]

            after_each(function()
                package.loaded["ssl.https"] = orig_https
                package.loaded["socket.http"] = orig_http
            end)

            it("retries on transient socket reset and succeeds on subsequent attempt", function()
                local test_file = test_dir .. "/retry_test.zip"
                local f = io.open(test_file, "wb")
                f:write("RETRY_CONTENT")
                f:close()

                local attempts = 0
                package.loaded["ssl.https"] = {
                    request = function(req)
                        attempts = attempts + 1
                        if attempts == 1 then
                            return nil, "Connection reset by peer"
                        else
                            if req.sink then
                                req.sink('{"ok":true,"expires_in":900}')
                            end
                            return 1, 200, {}, "HTTP/1.1 200 OK"
                        end
                    end,
                }

                local pin = "123456"
                local success = false
                local res_data = nil
                Beam.upload(test_file, pin, { relay_url = "https://mock.relay" }, function(ok, data)
                    success = ok
                    res_data = data
                end)

                assert.is_true(success)
                assert.equals(2, attempts)
                assert.is_table(res_data)
                assert.equals(pin, res_data.pin)
                -- Staging file must be cleaned up
                local check_staging = io.open(test_file .. ".beam_staging", "rb")
                assert.is_nil(check_staging)
            end)

            it("formats network transport errors cleanly without HTTP prefix", function()
                local test_file = test_dir .. "/fail_test.zip"
                local f = io.open(test_file, "wb")
                f:write("FAIL_CONTENT")
                f:close()

                package.loaded["ssl.https"] = {
                    request = function(req)
                        return nil, "Connection reset by peer"
                    end,
                }

                local pin = "123456"
                local success = true
                local err_msg = nil
                Beam.upload(test_file, pin, { relay_url = "https://mock.relay", max_retries = 0 }, function(ok, err)
                    success = ok
                    err_msg = err
                end)

                assert.is_false(success)
                assert.is_truthy(err_msg:find("Upload failed %(Network error%): Connection reset by peer"))
                assert.is_falsy(err_msg:find("HTTP Connection reset by peer"))
                -- Staging file must be cleaned up even on failure
                local check_staging = io.open(test_file .. ".beam_staging", "rb")
                assert.is_nil(check_staging)
            end)

            it("formats download transport errors cleanly without HTTP prefix", function()
                package.loaded["ssl.https"] = {
                    request = function(req)
                        return nil, "Connection reset by peer"
                    end,
                }

                local pin = "123456"
                local success = true
                local err_msg = nil
                Beam.download(pin, test_dir, { relay_url = "https://mock.relay", _skip_info = true, max_retries = 0 }, function(ok, err)
                    success = ok
                    err_msg = err
                end)

                assert.is_false(success)
                assert.is_truthy(err_msg:find("Download failed %(Network error%): Connection reset by peer"))
                assert.is_falsy(err_msg:find("HTTP Connection reset by peer"))
            end)
        end)
    end)
end)

