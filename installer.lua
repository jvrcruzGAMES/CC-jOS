-- ============================================================================
-- CC-jOS GitHub Network Installer (installer.lua)
-- Run in CC:Tweaked via:
--   wget run https://raw.githubusercontent.com/jvrcruzGAMES/CC-jOS/main/installer.lua
-- ============================================================================

local args = { ... }
local REPO_BASE = "https://raw.githubusercontent.com/jvrcruzGAMES/CC-jOS/main"

local MANIFEST_FILES = {
    { remote = "boot/boot.cfg",                        target = "/boot/boot.cfg" },
    { remote = "boot/bootloader.lua",                  target = "/boot/bootloader.lua" },
    { remote = "boot/bootloader.lua.sig",              target = "/boot/bootloader.lua.sig" },
    { remote = "System/Kernel/kernel.lua",             target = "/System/Kernel/kernel.lua" },
    { remote = "System/Kernel/kernel.lua.sig",         target = "/System/Kernel/kernel.lua.sig" },
    { remote = "System/Apps/Init.app/manifest.lua",    target = "/System/Apps/Init.app/manifest.lua" },
    { remote = "System/Apps/Init.app/main.lua",        target = "/System/Apps/Init.app/main.lua" },
    { remote = "System/Apps/Init.app/signature.sig",   target = "/System/Apps/Init.app/signature.sig" },
    -- Install BIOS (startup.lua) last as the immutable root of trust
    { remote = "startup.lua",                          target = "/startup.lua" }
}

local function setColor(col)
    if term and term.isColor and term.isColor() and colors then
        term.setTextColor(col)
    end
end

local function info(msg)
    setColor(colors and colors.cyan or 1)
    if term and term.write then term.write("[INSTALL] ") else io.write("[INSTALL] ") end
    setColor(colors and colors.white or 1)
    print(msg)
end

local function ok(msg)
    setColor(colors and colors.lime or 1)
    if term and term.write then term.write("[  OK   ] ") else io.write("[  OK   ] ") end
    setColor(colors and colors.white or 1)
    print(msg)
end

local function fail(msg)
    setColor(colors and colors.red or 1)
    print("[ ERROR ] " .. tostring(msg))
    setColor(colors and colors.white or 1)
    error(msg, 0)
end

if not http then
    fail("CC-jOS Installer requires the ComputerCraft HTTP API to be enabled in config.")
end

if term and term.clear then
    term.clear()
    term.setCursorPos(1, 1)
end

print("==========================================")
print("         CC-jOS GitHub Installer          ")
print("  https://github.com/jvrcruzGAMES/CC-jOS  ")
print("==========================================")

local function fetchRemote(url)
    local response, err = http.get(url)
    if not response then
        return nil, err or ("HTTP GET failed for " .. url)
    end
    local status = response.getResponseCode and response.getResponseCode() or 200
    if status ~= 200 then
        response.close()
        return nil, "HTTP " .. tostring(status) .. " for " .. url
    end
    local body = response.readAll()
    response.close()
    if not body or #body == 0 then
        return nil, "Empty response body for " .. url
    end
    return body
end

local function ensureDirForFile(filePath)
    local dir = fs.getDir and fs.getDir(filePath) or filePath:match("^(.*)/[^/]+$")
    if dir and dir ~= "" and not fs.exists(dir) then
        fs.makeDir(dir)
    end
end

-- Create staging/update directory for future bootloader updates
if not fs.exists("/boot/update") then
    fs.makeDir("/boot/update")
end

-- First download all files into memory so a partial network failure never leaves a half-installed system
local downloaded = {}
for i = 1, #MANIFEST_FILES do
    local item = MANIFEST_FILES[i]
    local url = REPO_BASE .. "/" .. item.remote
    info(string.format("Downloading (%d/%d): %s", i, #MANIFEST_FILES, item.remote))
    local content, err = fetchRemote(url)
    if not content then
        fail("Failed to download " .. item.remote .. ": " .. tostring(err))
    end
    downloaded[i] = content
end

-- Write all verified payloads to disk
for i = 1, #MANIFEST_FILES do
    local item = MANIFEST_FILES[i]
    ensureDirForFile(item.target)
    local handle, err = fs.open(item.target, "w")
    if not handle then
        fail("Cannot write to " .. item.target .. ": " .. tostring(err))
    end
    handle.write(downloaded[i])
    handle.close()
    ok("Installed " .. item.target .. " (" .. tostring(#downloaded[i]) .. " bytes)")
end

print("------------------------------------------")
ok("CC-jOS installation complete!")

local noReboot = false
for i = 1, #args do
    if args[i] == "--no-reboot" then
        noReboot = true
    end
end

if not noReboot and os and os.reboot then
    info("Rebooting into CC-jOS...")
    if os.sleep then os.sleep(1) end
    os.reboot()
end
