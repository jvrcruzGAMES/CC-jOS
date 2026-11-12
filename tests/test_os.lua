#!/usr/bin/env lua
-- ============================================================================
-- CC-jOS End-to-End Verification & Security Test Suite (tests/test_os.lua)
-- Simulates a CC:Tweaked Computer environment and tests:
--   1. GitHub Installer (installer.lua)
--   2. Full Verified Boot Chain: BIOS -> Bootloader -> Kernel -> Init.app ("Kernel's up")
--   3. BIOS Immutability Enforcement
--   4. Bootloader Signed Update Application & Tamper Rejection
--   5. Kernel Strict Code Signing (.app bundle verification & tamper rejection)
--   6. Kernel Strict Permission Enforcing (User App vs Sysmodule privilege separation)
-- ============================================================================

local Crypto = dofile("tools/crypto.lua")
local pubKey = dofile("keys/root_public.lua")
local privKey = dofile("keys/root_private.lua")

local function readHostFile(path)
    local f = assert(io.open(path, "rb"))
    local c = f:read("*a")
    f:close()
    return c
end

-- Create an in-memory CC:Tweaked Virtual Filesystem and Terminal
local function createMockComputer()
    local vfsFiles = {}
    local vfsDirs = { ["/"] = true }
    local consoleLines = {}
    local currentLine = ""

    local function norm(p)
        p = tostring(p or ""):gsub("\\", "/"):gsub("/+", "/")
        if p == "" or p:sub(1, 1) ~= "/" then p = "/" .. p end
        if #p > 1 and p:sub(-1) == "/" then p = p:sub(1, -2) end
        return p
    end

    local function ensureParentDirs(p)
        local parts = {}
        for part in p:gmatch("[^/]+") do parts[#parts + 1] = part end
        local cur = ""
        for i = 1, #parts - 1 do
            cur = cur .. "/" .. parts[i]
            vfsDirs[cur] = true
        end
    end

    local mockFS = {}
    function mockFS.combine(base, rel)
        local combined = tostring(base or "") .. "/" .. tostring(rel or "")
        return norm(combined):sub(2)
    end
    function mockFS.getDir(p)
        p = norm(p)
        local dir = p:match("^(.*)/[^/]+$")
        if not dir or dir == "" then return "" end
        return dir:sub(2)
    end
    function mockFS.exists(p)
        p = norm(p)
        return vfsFiles[p] ~= nil or vfsDirs[p] == true
    end
    function mockFS.isDir(p)
        p = norm(p)
        return vfsDirs[p] == true
    end
    function mockFS.isReadOnly(_)
        return false
    end
    function mockFS.makeDir(p)
        p = norm(p)
        ensureParentDirs(p .. "/placeholder")
        vfsDirs[p] = true
    end
    function mockFS.open(p, mode)
        p = norm(p)
        mode = mode or "r"
        if mode == "r" or mode == "rb" then
            if vfsFiles[p] == nil then return nil, "File not found: " .. p end
            local data = vfsFiles[p]
            return {
                readAll = function() return data end,
                close = function() end
            }
        elseif mode == "w" or mode == "wb" then
            ensureParentDirs(p)
            local buf = {}
            return {
                write = function(s) buf[#buf + 1] = tostring(s) end,
                close = function() vfsFiles[p] = table.concat(buf) end
            }
        end
        error("Unsupported mode: " .. tostring(mode))
    end
    function mockFS.delete(p)
        p = norm(p)
        vfsFiles[p] = nil
        vfsDirs[p] = nil
    end
    function mockFS.move(src, dst)
        src, dst = norm(src), norm(dst)
        ensureParentDirs(dst)
        vfsFiles[dst] = vfsFiles[src]
        vfsFiles[src] = nil
    end
    function mockFS.copy(src, dst)
        src, dst = norm(src), norm(dst)
        ensureParentDirs(dst)
        vfsFiles[dst] = vfsFiles[src]
    end
    function mockFS.list(p)
        p = norm(p)
        local prefix = (p == "/") and "/" or (p .. "/")
        local seen = {}
        local out = {}
        for k in pairs(vfsFiles) do
            if k:sub(1, #prefix) == prefix then
                local rest = k:sub(#prefix + 1)
                local first = rest:match("^([^/]+)")
                if first and not seen[first] then
                    seen[first] = true
                    out[#out + 1] = first
                end
            end
        end
        for k in pairs(vfsDirs) do
            if k ~= p and k:sub(1, #prefix) == prefix then
                local rest = k:sub(#prefix + 1)
                local first = rest:match("^([^/]+)")
                if first and not seen[first] then
                    seen[first] = true
                    out[#out + 1] = first
                end
            end
        end
        table.sort(out)
        return out
    end

    local mockTerm = {
        isColor = function() return true end,
        setTextColor = function() end,
        getTextColor = function() return 1 end,
        setBackgroundColor = function() end,
        clear = function() end,
        setCursorPos = function() end,
        write = function(s) currentLine = currentLine .. tostring(s) end
    }

    local mockHTTP = {
        get = function(url)
            local rel = url:match("^https://raw%.githubusercontent%.com/jvrcruzGAMES/CC%-jOS/main/(.+)$")
            if not rel then return nil, "404 Not Found: " .. tostring(url) end
            local content = readHostFile(rel)
            return {
                getResponseCode = function() return 200 end,
                readAll = function() return content end,
                close = function() end
            }
        end
    }

    local mockColors = {
        white = 1, red = 16384, yellow = 16, lime = 32, green = 8192, cyan = 512, lightBlue = 8
    }

    local mockOS = {
        pullEventRaw = function() return "timer" end,
        pullEvent = function() return "timer" end,
        reboot = function() end,
        sleep = function() end
    }

    local function customPrint(...)
        local parts = {}
        for i = 1, select("#", ...) do
            parts[#parts + 1] = tostring(select(i, ...))
        end
        local line = currentLine .. table.concat(parts, "\t")
        currentLine = ""
        consoleLines[#consoleLines + 1] = line
    end

    return {
        vfsFiles = vfsFiles,
        vfsDirs = vfsDirs,
        consoleLines = consoleLines,
        fs = mockFS,
        term = mockTerm,
        http = mockHTTP,
        colors = mockColors,
        os = mockOS,
        print = customPrint
    }
end

local function runInComputer(comp, vfsScriptPath, args, testHook)
    local code = assert(comp.vfsFiles[vfsScriptPath], "Script missing in VFS: " .. tostring(vfsScriptPath))
    local env = setmetatable({
        fs = comp.fs,
        term = comp.term,
        http = comp.http,
        colors = comp.colors,
        os = comp.os,
        print = comp.print
    }, { __index = _G })
    env._G = env

    local fn, err = loadstring(code, "@" .. vfsScriptPath)
    assert(fn, err)
    setfenv(fn, env)

    if testHook then
        -- Inject _testHook into rawHW via a wrapper around bios -> bootloader -> kernel
        comp.os._testHook = testHook
    end
    return fn(unpack(args or {}))
end

print("=== Running CC-jOS Automated Verification Suite ===")

-- ----------------------------------------------------------------------------
-- Test 1: Run GitHub Installer (installer.lua) in Mock CC:Tweaked Environment
-- ----------------------------------------------------------------------------
local comp = createMockComputer()
comp.vfsFiles["/installer.lua"] = readHostFile("installer.lua")
runInComputer(comp, "/installer.lua", { "--no-reboot" })

assert(comp.vfsFiles["/startup.lua"], "Installer must install /startup.lua")
assert(comp.vfsFiles["/boot/bootloader.lua"], "Installer must install /boot/bootloader.lua")
assert(comp.vfsFiles["/boot/bootloader.lua.sig"], "Installer must install /boot/bootloader.lua.sig")
assert(comp.vfsFiles["/System/Kernel/kernel.lua"], "Installer must install /System/Kernel/kernel.lua")
assert(comp.vfsFiles["/System/Kernel/kernel.lua.sig"], "Installer must install /System/Kernel/kernel.lua.sig")
assert(comp.vfsFiles["/System/Apps/Init.app/manifest.lua"], "Installer must install Init.app/manifest.lua")
assert(comp.vfsFiles["/System/Apps/Init.app/main.lua"], "Installer must install Init.app/main.lua")
assert(comp.vfsFiles["/System/Apps/Init.app/signature.sig"], "Installer must install Init.app/signature.sig")
print("[PASS] 1. GitHub Installer downloaded & installed all OS files into VFS")

-- ----------------------------------------------------------------------------
-- Test 2: Full Verified Boot Chain (BIOS -> Bootloader -> Kernel -> Init.app)
-- ----------------------------------------------------------------------------
for i = #comp.consoleLines, 1, -1 do comp.consoleLines[i] = nil end
runInComputer(comp, "/startup.lua")

local foundKernelsUp = false
for _, line in ipairs(comp.consoleLines) do
    if line == "Kernel's up" then
        foundKernelsUp = true
    end
end
assert(foundKernelsUp, "Expected Init.app to output 'Kernel's up' during boot!")
print("[PASS] 2. Full Boot Chain (BIOS -> Bootloader -> Kernel -> Init.app) printed: \"Kernel's up\"")

-- ----------------------------------------------------------------------------
-- Test 3: BIOS Immutability Enforcement
-- ----------------------------------------------------------------------------
-- Note: After Kernel boots, _G.fs is nil for userspace, and the wrapped FS
-- created by BIOS enforces immutability on /startup.lua. Let's test BIOS FS wrapper directly.
local compImmut = createMockComputer()
compImmut.vfsFiles["/installer.lua"] = readHostFile("installer.lua")
runInComputer(compImmut, "/installer.lua", { "--no-reboot" })
-- Replace bootloader temporarily with a signed diagnostic bootloader to inspect rawHW.fs
local diagBoot = [[
local BIOS, rawHW = ...
assert(rawHW.fs.isReadOnly("/startup.lua") == true, "/startup.lua must be read-only")
local okW = pcall(function() rawHW.fs.open("/startup.lua", "w") end)
assert(not okW, "Opening /startup.lua for write must fail")
local okD = pcall(function() rawHW.fs.delete("/startup.lua") end)
assert(not okD, "Deleting /startup.lua must fail")
local okM = pcall(function() rawHW.fs.move("/startup.lua", "/startup.bak") end)
assert(not okM, "Moving /startup.lua must fail")
local okMut = pcall(function() BIOS.version = "hacked" end)
assert(not okMut, "Mutating BIOS table must fail")
]]
local diagHash = Crypto.sha256(diagBoot)
local diagSig = Crypto.sign("CC-jOS-FILE-SIG-v1\n" .. diagHash, privKey)
compImmut.vfsFiles["/boot/bootloader.lua"] = diagBoot
compImmut.vfsFiles["/boot/bootloader.lua.sig"] = table.concat({
    'keyId = "' .. pubKey.keyId .. '"',
    'sha256 = "' .. diagHash .. '"',
    'signature = "' .. diagSig .. '"'
}, "\n")
runInComputer(compImmut, "/startup.lua")
print("[PASS] 3. BIOS (startup.lua) immutability strictly enforced against write/delete/move/mutation")

-- ----------------------------------------------------------------------------
-- Test 4: Bootloader Update Mechanism (Signed Update Applied, Unsigned Rejected)
-- ----------------------------------------------------------------------------
local compUpdate = createMockComputer()
compUpdate.vfsFiles["/installer.lua"] = readHostFile("installer.lua")
runInComputer(compUpdate, "/installer.lua", { "--no-reboot" })

-- Stage a corrupt/unsigned kernel update in /boot/update/kernel.lua
compUpdate.vfsFiles["/boot/update/kernel.lua"] = "-- tampered kernel"
compUpdate.vfsFiles["/boot/update/kernel.lua.sig"] = 'signature = "deadbeef"'
for i = #compUpdate.consoleLines, 1, -1 do compUpdate.consoleLines[i] = nil end
runInComputer(compUpdate, "/startup.lua")
-- Should have rejected the tampered update and still booted the valid kernel!
assert(compUpdate.vfsFiles["/boot/update/kernel.lua"] == nil, "Tampered staged update should be cleaned up")
local bootedAfterTamperUpdate = false
for _, line in ipairs(compUpdate.consoleLines) do
    if line == "Kernel's up" then bootedAfterTamperUpdate = true end
end
assert(bootedAfterTamperUpdate, "System should reject bad update and boot existing valid kernel")
print("[PASS] 4. Bootloader update verification & tamper rejection verified")

-- ----------------------------------------------------------------------------
-- Test 5 & 6: Kernel Code Signing & Strict Permission Enforcing
-- ----------------------------------------------------------------------------
local compSec = createMockComputer()
compSec.vfsFiles["/installer.lua"] = readHostFile("installer.lua")
runInComputer(compSec, "/installer.lua", { "--no-reboot" })

-- 5a: Tamper with Init.app/main.lua (1 byte change without re-signing) -> Kernel must PANIC
compSec.vfsFiles["/System/Apps/Init.app/main.lua"] = 'print("Hacked!")\n'
local bootTamperedOk, bootTamperedErr = pcall(function()
    runInComputer(compSec, "/startup.lua")
end)
assert(not bootTamperedOk and tostring(bootTamperedErr):find("ERR_CODESIGN_FILE_TAMPERED"),
    "Kernel must refuse to launch tampered .app bundle! Got: " .. tostring(bootTamperedErr))
print("[PASS] 5a. Kernel rejected tampered .app bundle (ERR_CODESIGN_FILE_TAMPERED)")

-- 5b: Drop an extra unsigned file into Init.app -> Kernel must PANIC
compSec.vfsFiles["/System/Apps/Init.app/main.lua"] = readHostFile("System/Apps/Init.app/main.lua")
compSec.vfsFiles["/System/Apps/Init.app/extra.lua"] = "-- unsigned payload"
local bootExtraOk, bootExtraErr = pcall(function()
    runInComputer(compSec, "/startup.lua")
end)
assert(not bootExtraOk and tostring(bootExtraErr):find("ERR_CODESIGN_UNSIGNED_FILE"),
    "Kernel must refuse bundle containing unsigned files! Got: " .. tostring(bootExtraErr))
compSec.vfsFiles["/System/Apps/Init.app/extra.lua"] = nil
print("[PASS] 5b. Kernel rejected .app bundle with extra unsigned file (ERR_CODESIGN_UNSIGNED_FILE)")

-- 6: Verify User App vs Sysmodule Permission Separation
-- Create a signed User App that tries to request sysmodule permission 'hw.fs.raw'
local badUserManifest = {
    id = "com.jos.baduser",
    name = "BadUser",
    version = "1.0.0",
    type = "user",
    entry = "main.lua",
    permissions = { "kernel.console", "hw.fs.raw" },
    files = {
        ["main.lua"] = Crypto.sha256('print("Should never run")')
    }
}
-- Even if signed with the root key, Kernel policy forbids type="user" from holding "hw.fs.raw"!
local function serializeCanonical(val)
    local t = type(val)
    if t == "string" then return string.format("%q", val)
    elseif t == "number" or t == "boolean" then return tostring(val)
    elseif t == "table" then
        local keys = {}
        for k in pairs(val) do keys[#keys + 1] = k end
        table.sort(keys, function(a, b)
            if type(a) == type(b) then return tostring(a) < tostring(b) end
            return type(a) < type(b)
        end)
        local parts = {}
        for i = 1, #keys do
            local k = keys[i]
            parts[#parts + 1] = "[" .. serializeCanonical(k) .. "]=" .. serializeCanonical(val[k])
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
end
local canonicalBad = serializeCanonical(badUserManifest)
local badSig = Crypto.sign("CC-jOS-APP-BUNDLE-v1\n" .. canonicalBad, privKey)

compSec.fs.makeDir("/System/Apps/BadUser.app")
compSec.vfsFiles["/System/Apps/BadUser.app/main.lua"] = 'print("Should never run")'
compSec.vfsFiles["/System/Apps/BadUser.app/manifest.lua"] = [[
return {
    id = "com.jos.baduser",
    name = "BadUser",
    version = "1.0.0",
    type = "user",
    entry = "main.lua",
    permissions = { "kernel.console", "hw.fs.raw" },
    files = { ["main.lua"] = "]] .. badUserManifest.files["main.lua"] .. [[" }
}
]]
compSec.vfsFiles["/System/Apps/BadUser.app/signature.sig"] = table.concat({
    'keyId = "' .. pubKey.keyId .. '"',
    'manifestSha256 = "' .. Crypto.sha256(canonicalBad) .. '"',
    'signature = "' .. badSig .. '"'
}, "\n")
compSec.vfsFiles["/boot/boot.cfg"] = 'initApp = "/System/Apps/BadUser.app"\n'

local badUserOk, badUserErr = pcall(function()
    runInComputer(compSec, "/startup.lua")
end)
assert(not badUserOk and tostring(badUserErr):find("ERR_PERMISSION_POLICY"),
    "Kernel must block user apps from requesting sysmodule permissions! Got: " .. tostring(badUserErr))
print("[PASS] 6. Kernel enforced permission policy (user apps blocked from sysmodule permissions like hw.fs.raw)")

print("=== ALL CC-jOS TESTS PASSED SUCCESSFULLY! ===")
