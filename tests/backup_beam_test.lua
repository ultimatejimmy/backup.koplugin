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
    end)
end)
