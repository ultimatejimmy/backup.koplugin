-- spec_runner.lua
-- High-performance, zero-dependency unit test runner for KOReader plugins.
-- Uses KOReader's bundled LuaJIT binary (matching xray and storefront patterns).

local AppDir = os.getenv("KOREADER_APP_DIR")
if not AppDir or not io.open(AppDir .. "/luajit", "r") then
    local candidates = {
        "/usr/lib/koreader",
        "/home/jimmy/squashfs-root/usr/lib/koreader",
        "/home/" .. (os.getenv("USER") or "user") .. "/squashfs-root/usr/lib/koreader",
    }
    for _, dir in ipairs(candidates) do
        local f = io.open(dir .. "/luajit", "r")
        if f then
            f:close()
            AppDir = dir
            break
        end
    end
end
AppDir = AppDir or "/usr/lib/koreader"

-- Configure package.path
package.path = package.path .. ";" .. AppDir .. "/?.lua"
package.path = package.path .. ";" .. AppDir .. "/common/?.lua"
package.path = package.path .. ";" .. AppDir .. "/libs/?.lua"
package.path = package.path .. ";" .. AppDir .. "/frontend/?.lua"
package.path = package.path .. ";backup.koplugin/?.lua;backup.koplugin/backup.koplugin/?.lua;./backup.koplugin/?.lua;../backup.koplugin/?.lua;?.lua;tests/?.lua"

local ok_real_lfs, real_lfs = pcall(require, "lfs")
if ok_real_lfs and real_lfs then
    package.preload["libs/libkoreader-lfs"] = function() return real_lfs end
    package.loaded["libs/libkoreader-lfs"] = real_lfs
    package.loaded["lfs"] = real_lfs
end

local stats = { passed = 0, failed = 0, errors = {} }
local before_each_stack = {}
local after_each_stack = {}
local current_describe = {}

local function push_context()
    table.insert(before_each_stack, {})
    table.insert(after_each_stack, {})
end

local function pop_context()
    table.remove(before_each_stack)
    table.remove(after_each_stack)
end

_G.before_each = function(fn)
    local current = before_each_stack[#before_each_stack]
    if current then table.insert(current, fn) end
end

_G.after_each = function(fn)
    local current = after_each_stack[#after_each_stack]
    if current then table.insert(current, fn) end
end

_G.describe = function(name, fn)
    table.insert(current_describe, name)
    push_context()
    local ok, err = pcall(fn)
    if not ok then
        stats.failed = stats.failed + 1
        table.insert(stats.errors, { name = table.concat(current_describe, " -> "), err = err })
        print("[ERROR in describe] " .. table.concat(current_describe, " -> ") .. ": " .. tostring(err))
    end
    pop_context()
    table.remove(current_describe)
end

_G.it = function(name, fn)
    local full_name = table.concat(current_describe, " -> ") .. " -> " .. name

    for _, level in ipairs(before_each_stack) do
        for _, before_fn in ipairs(level) do
            local ok, err = pcall(before_fn)
            if not ok then
                print("[ERROR in before_each] " .. full_name .. ": " .. tostring(err))
            end
        end
    end

    local ok, err = pcall(fn)

    for _, level in ipairs(after_each_stack) do
        for _, after_fn in ipairs(level) do
            local ok_a, err_a = pcall(after_fn)
            if not ok_a then
                print("[ERROR in after_each] " .. full_name .. ": " .. tostring(err_a))
            end
        end
    end

    if ok then
        stats.passed = stats.passed + 1
    else
        stats.failed = stats.failed + 1
        table.insert(stats.errors, { name = full_name, err = err })
        print("[FAIL] " .. full_name)
        print("       " .. tostring(err))
    end
end

_G.setup = function(fn) pcall(fn) end
_G.teardown = function(fn) pcall(fn) end

local function deep_compare(t1, t2)
    if type(t1) ~= type(t2) then return false end
    if type(t1) ~= "table" then return t1 == t2 end
    for k, v in pairs(t1) do
        if not deep_compare(v, t2[k]) then return false end
    end
    for k, v in pairs(t2) do
        if not deep_compare(v, t1[k]) then return false end
    end
    return true
end

_G.assert = {
    is_true = function(val, msg)
        if not val then error(msg or ("Expected true, got " .. tostring(val)), 2) end
    end,
    is_false = function(val, msg)
        if val then error(msg or ("Expected false, got " .. tostring(val)), 2) end
    end,
    is_nil = function(val, msg)
        if val ~= nil then error(msg or ("Expected nil, got " .. tostring(val)), 2) end
    end,
    is_not_nil = function(val, msg)
        if val == nil then error(msg or "Expected not nil", 2) end
    end,
    is_table = function(val, msg)
        if type(val) ~= "table" then error(msg or ("Expected table, got " .. type(val)), 2) end
    end,
    is_string = function(val, msg)
        if type(val) ~= "string" then error(msg or ("Expected string, got " .. type(val)), 2) end
    end,
    is_number = function(val, msg)
        if type(val) ~= "number" then error(msg or ("Expected number, got " .. type(val)), 2) end
    end,
    is_boolean = function(val, msg)
        if type(val) ~= "boolean" then error(msg or ("Expected boolean, got " .. type(val)), 2) end
    end,
    is_function = function(val, msg)
        if type(val) ~= "function" then error(msg or ("Expected function, got " .. type(val)), 2) end
    end,
    truthy = function(val, msg)
        if not val then error(msg or ("Expected truthy, got " .. tostring(val)), 2) end
    end,
    falsy = function(val, msg)
        if val then error(msg or ("Expected falsy, got " .. tostring(val)), 2) end
    end,
    are = {
        equal = function(expected, actual, msg)
            if expected ~= actual then
                error(msg or ("Expected " .. tostring(expected) .. ", got " .. tostring(actual)), 3)
            end
        end,
        same = function(expected, actual, msg)
            if not deep_compare(expected, actual) then
                error(msg or "Expected identical values/tables", 3)
            end
        end,
    },
    are_not = {
        equal = function(expected, actual, msg)
            if expected == actual then
                error(msg or ("Expected not equal to " .. tostring(expected)), 3)
            end
        end,
        same = function(expected, actual)
            if deep_compare(expected, actual) then
                error("Expected non-identical values/tables", 3)
            end
        end,
    },
}
_G.assert.equals = _G.assert.are.equal
_G.assert.same = _G.assert.are.same
_G.assert.is_falsy = _G.assert.falsy
_G.assert.is_truthy = _G.assert.truthy
_G.assert.is_not_equal = _G.assert.are_not.equal
_G.assert.are_not.equals = _G.assert.are_not.equal
setmetatable(_G.assert, {
    __call = function(t, cond, msg)
        if not cond then
            error(msg or "assertion failed!", 2)
        end
        return cond
    end,
})

-- Load spec_helper baseline mocks
local ok_sh, err_sh = pcall(require, "tests/spec_helper")
if not ok_sh then
    ok_sh, err_sh = pcall(require, "spec_helper")
end

local base_loaded = {}
for k, v in pairs(package.loaded) do base_loaded[k] = v end

-- Default test suites
local test_files = {
    "backup_archiver_test.lua",
    "backup_beam_test.lua",
    "backup_folder_picker_test.lua",
    "backup_localization_test.lua",
    "backup_main_menu_test.lua",
    "backup_manifest_test.lua",
    "backup_restore_test.lua",
    "backup_retention_test.lua",
    "backup_sanitizer_test.lua",
    "backup_ui_focus_test.lua",
}

if arg and arg[1] then
    local target = arg[1]:match("([^/\\]+)$") or arg[1]
    test_files = { target }
end

-- Resolve test directory prefix
local function find_test_file(filename)
    local candidates = {
        filename,
        "tests/" .. filename,
        "backup.koplugin/tests/" .. filename,
        "../backup.koplugin/tests/" .. filename,
        "../tests/" .. filename,
    }
    for _, path in ipairs(candidates) do
        local f = io.open(path, "r")
        if f then
            f:close()
            return path
        end
    end
    return nil
end

print("=== Running KOReader Backup Unit Tests (LuaJIT) ===")
local t_start = os.clock()

for _, tf in ipairs(test_files) do
    local resolved = find_test_file(tf)
    if resolved then
        local t0 = os.clock()

        -- Snapshot settings
        local saved_settings = {}
        if _G.G_reader_settings and _G.G_reader_settings.data then
            for k, v in pairs(_G.G_reader_settings.data) do saved_settings[k] = v end
        end

        local fn, err = loadfile(resolved)
        if fn then
            fn()
            local dt = os.clock() - t0
            print(string.format("  PASS  %-35s (%.3fs)", tf, dt))
        else
            stats.failed = stats.failed + 1
            table.insert(stats.errors, { name = tf, err = err })
            print(string.format("  FAIL  %-35s: %s", tf, tostring(err)))
        end

        -- Restore environment isolation between test files
        for k in pairs(package.loaded) do
            if base_loaded[k] == nil then
                package.loaded[k] = nil
            else
                package.loaded[k] = base_loaded[k]
            end
        end
        if _G.G_reader_settings and _G.G_reader_settings.data then
            _G.G_reader_settings.data = {}
            for k, v in pairs(saved_settings) do _G.G_reader_settings.data[k] = v end
        end
    else
        print(string.format("  SKIP  %-35s (file not found)", tf))
    end
end

local total_time = os.clock() - t_start

print("\n=== Test Results ===")
print(string.format("Passed: %d", stats.passed))
print(string.format("Failed: %d", stats.failed))
print(string.format("Total execution time: %.3f seconds", total_time))

if stats.failed > 0 then
    print("\nFailures:")
    for _, item in ipairs(stats.errors) do
        print("  - " .. item.name .. "\n    " .. tostring(item.err))
    end
    os.exit(1)
else
    print("\nAll unit tests passed successfully!")
    os.exit(0)
end
