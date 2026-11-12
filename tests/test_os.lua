#!/usr/bin/env lua
-- ============================================================================
-- CC-jOS End-to-End Verification & Security Test Suite (tests/test_os.lua)
-- Simulates a CC:Tweaked Computer environment and tests:
--   1. GitHub Installer (installer.lua) including /System/Libraries/jvk.lua
--   2. BIOS Framebuffer & Centered White "J" Boot Screen (retained until start app)
--   3. Start App (Init.app) taking over rendering via libjvk (2D UI + 3D Cube + "Kernel's up")
--   4. BIOS Immutability Enforcement
--   5. Bootloader Signed Update Application & Tamper Rejection
--   6. Kernel Strict Code Signing (.app bundle & signed library tamper rejection)
--   7. Kernel Strict Permission Enforcing (User App vs Sysmodule privilege separation)
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

-- Create an in-memory CC:Tweaked Virtual Filesystem and Framebuffer-capable Terminal
local function createMockComputer()
    local vfsFiles = {}
    local vfsDirs = { ["/"] = true }
    local consoleLines = {}
    local currentLine = ""

    local termW, termH = 51, 19
    local curX, curY = 1, 1
    local screenText = {}
    local screenFg = {}
    local screenBg = {}
    local frameHistory = {} -- snapshots captured whenever row termH is blitted

    for y = 1, termH do
        screenText[y] = string.rep(" ", termW)
        screenFg[y] = string.rep("0", termW)
        screenBg[y] = string.rep("f", termW)
    end

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
        getSize = function() return termW, termH end,
        isColor = function() return true end,
        setTextColor = function() end,
        getTextColor = function() return 1 end,
        setBackgroundColor = function() end,
        setCursorBlink = function() end,
        clear = function() end,
        setCursorPos = function(x, y)
            curX = math.floor(tonumber(x) or 1)
            curY = math.floor(tonumber(y) or 1)
        end,
        write = function(s)
            currentLine = currentLine .. tostring(s)
        end,
        blit = function(textRow, fgRow, bgRow)
            if curY >= 1 and curY <= termH then
                screenText[curY] = tostring(textRow)
                screenFg[curY] = tostring(fgRow)
                screenBg[curY] = tostring(bgRow)
                if curY == termH then
                    local tSnap, fSnap, bSnap = {}, {}, {}
                    for y = 1, termH do
                        tSnap[y] = screenText[y]
                        fSnap[y] = screenFg[y]
                        bSnap[y] = screenBg[y]
                    end
                    frameHistory[#frameHistory + 1] = {
                        text = tSnap,
                        fg = fSnap,
                        bg = bSnap
                    }
                end
            end
        end
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
        screenText = screenText,
        screenFg = screenFg,
        screenBg = screenBg,
        frameHistory = frameHistory,
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
        comp.os._testHook = testHook
    end
    return fn(unpack(args or {}))
end

local function screenContainsText(frame, needle)
    for y = 1, #frame.text do
        if frame.text[y]:find(needle, 1, true) then
            return true
        end
    end
    return false
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
assert(comp.vfsFiles["/System/Libraries/jvk.lua"], "Installer must install /System/Libraries/jvk.lua")
assert(comp.vfsFiles["/System/Libraries/jvk.lua.sig"], "Installer must install /System/Libraries/jvk.lua.sig")
assert(comp.vfsFiles["/System/Apps/Init.app/manifest.lua"], "Installer must install Init.app/manifest.lua")
assert(comp.vfsFiles["/System/Apps/Init.app/main.lua"], "Installer must install Init.app/main.lua")
assert(comp.vfsFiles["/System/Apps/Init.app/signature.sig"], "Installer must install Init.app/signature.sig")
print("[PASS] 1. GitHub Installer downloaded & installed all OS files (including libjvk) into VFS")

-- ----------------------------------------------------------------------------
-- Test 2: Boot Screen ("J" centered) & Start App Taking Over via libjvk
-- ----------------------------------------------------------------------------
for i = #comp.frameHistory, 1, -1 do comp.frameHistory[i] = nil end
runInComputer(comp, "/startup.lua")

assert(#comp.frameHistory >= 2, "Expected boot splash frame(s) followed by Init.app libjvk frame")

-- Verify the early boot frames (BIOS & Bootloader) are strictly a centered white "J" on black
local bootFrame = comp.frameHistory[1]
local centerX = math.floor((51 + 1) / 2) -- 26
local centerY = math.floor((19 + 1) / 2) -- 10
assert(bootFrame.text[centerY]:sub(centerX, centerX) == "J", "Boot screen must have 'J' centered at (26, 10)")
assert(bootFrame.fg[centerY]:sub(centerX, centerX) == "0", "Boot screen 'J' must be white ('0')")
assert(bootFrame.bg[centerY]:sub(centerX, centerX) == "f", "Boot screen background must be black ('f')")

-- Verify every other cell on the boot splash frame is blank space
for y = 1, 19 do
    for x = 1, 51 do
        local ch = bootFrame.text[y]:sub(x, x)
        if x == centerX and y == centerY then
            assert(ch == "J", "Center cell must be 'J'")
        else
            assert(ch == " ", "Boot screen cell (" .. x .. "," .. y .. ") must be blank space, got: " .. ch)
        end
    end
end
print("[PASS] 2a. BIOS & Bootloader rendered hardcoded centered white 'J' directly via BIOS.fb")

-- Verify final frame after Init.app took over the rendering stack via libjvk
local appFrame = comp.frameHistory[#comp.frameHistory]
assert(screenContainsText(appFrame, "Kernel's up"), "Expected Init.app to render \"Kernel's up\" via libjvk")
assert(screenContainsText(appFrame, "CC-jOS Userspace [libjvk]"), "Expected Init.app 2D UI Window title")
assert(screenContainsText(appFrame, "3D Cube"), "Expected Init.app 3D Viewport title")
print("[PASS] 2b. Init.app took over rendering stack via libjvk (2D UI + 3D Cube + \"Kernel's up\")")

-- ----------------------------------------------------------------------------
-- Test 3: BIOS Immutability Enforcement
-- ----------------------------------------------------------------------------
local compImmut = createMockComputer()
compImmut.vfsFiles["/installer.lua"] = readHostFile("installer.lua")
runInComputer(compImmut, "/installer.lua", { "--no-reboot" })
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

compUpdate.vfsFiles["/boot/update/kernel.lua"] = "-- tampered kernel"
compUpdate.vfsFiles["/boot/update/kernel.lua.sig"] = 'signature = "deadbeef"'
for i = #compUpdate.frameHistory, 1, -1 do compUpdate.frameHistory[i] = nil end
runInComputer(compUpdate, "/startup.lua")
assert(compUpdate.vfsFiles["/boot/update/kernel.lua"] == nil, "Tampered staged update should be cleaned up")
local finalUpdateFrame = compUpdate.frameHistory[#compUpdate.frameHistory]
assert(finalUpdateFrame and screenContainsText(finalUpdateFrame, "Kernel's up"),
    "System should reject bad update and boot existing valid kernel")
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
