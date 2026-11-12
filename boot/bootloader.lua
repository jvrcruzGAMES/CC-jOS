-- ============================================================================
-- CC-jOS Bootloader (/boot/bootloader.lua)
-- Updateable Stage-2 Loader: Applies Verified Updates & Immediately Loads Kernel
-- ============================================================================

local BIOS, rawHW = ...
if not BIOS or not rawHW then
    error("BOOTLOADER_ERROR: Bootloader must be invoked by CC-jOS BIOS", 0)
end

local BOOTLOADER_VERSION = "1.0.0"
local fs = rawHW.fs

-- Parse simple key=value boot configuration file
local function loadBootConfig(cfgPath)
    local cfg = {
        version = BOOTLOADER_VERSION,
        kernel = "/System/Kernel/kernel.lua",
        kernelSig = "/System/Kernel/kernel.lua.sig",
        initApp = "/System/Apps/Init.app",
        updateDir = "/boot/update",
        repoBaseUrl = "https://raw.githubusercontent.com/jvrcruzGAMES/CC-jOS/main"
    }
    local text = BIOS.readFileRaw(cfgPath)
    if text then
        for line in text:gmatch("[^\r\n]+") do
            local trimmed = line:match("^%s*(.-)%s*$")
            if trimmed ~= "" and trimmed:sub(1, 1) ~= "#" and trimmed:sub(1, 2) ~= "--" then
                local k, v = trimmed:match("^([%w_%-]+)%s*=%s*(.+)$")
                if k and v then
                    v = v:match('^"(.*)"$') or v:match("^'(.*)'$") or v
                    cfg[k] = v
                end
            end
        end
    end
    return cfg
end

local function writeFileAtomic(path, content)
    local dir = fs.getDir and fs.getDir(path) or path:match("^(.*)/[^/]+$")
    if dir and dir ~= "" and fs.makeDir and not fs.exists(dir) then
        fs.makeDir(dir)
    end
    local h, err = fs.open(path, "w")
    if not h then
        return false, err or ("Cannot open " .. tostring(path) .. " for writing")
    end
    h.write(content)
    h.close()
    return true
end

-- Check for and apply cryptographically signed updates in /boot/update
local function applyStagedUpdates(cfg)
    local updateDir = cfg.updateDir or "/boot/update"
    if not fs or not fs.exists or not fs.exists(updateDir) then
        return false
    end

    -- 1. Staged Bootloader Self-Update
    local stagedBoot = updateDir .. "/bootloader.lua"
    local stagedBootSig = updateDir .. "/bootloader.lua.sig"
    if fs.exists(stagedBoot) and fs.exists(stagedBootSig) then
        BIOS.log("INFO", "Bootloader", "Found staged bootloader update. Verifying signature...")
        local ok, newBootCode = BIOS.verifySignedFile(stagedBoot, stagedBootSig)
        local newSigText = BIOS.readFileRaw(stagedBootSig)
        if ok and newBootCode and newSigText then
            writeFileAtomic("/boot/bootloader.lua", newBootCode)
            writeFileAtomic("/boot/bootloader.lua.sig", newSigText)
            fs.delete(stagedBoot)
            fs.delete(stagedBootSig)
            BIOS.log("OK", "Bootloader", "Bootloader updated successfully. Reloading updated bootloader...")
            local bootEnv = setmetatable({}, { __index = _G })
            local fn, err = BIOS.loadProtectedChunk(newBootCode, "@bootloader.lua", bootEnv)
            if not fn then
                BIOS.panic("Bootloader", "Updated bootloader failed to compile: " .. tostring(err))
            end
            fn(BIOS, rawHW)
            return true
        else
            BIOS.log("WARN", "Bootloader", "Rejected invalid bootloader update: " .. tostring(newBootCode))
            fs.delete(stagedBoot)
            fs.delete(stagedBootSig)
        end
    end

    -- 2. Staged Kernel Update
    local stagedKernel = updateDir .. "/kernel.lua"
    local stagedKernelSig = updateDir .. "/kernel.lua.sig"
    if fs.exists(stagedKernel) and fs.exists(stagedKernelSig) then
        BIOS.log("INFO", "Bootloader", "Found staged kernel update. Verifying signature...")
        local ok, newKernelCode = BIOS.verifySignedFile(stagedKernel, stagedKernelSig)
        local newSigText = BIOS.readFileRaw(stagedKernelSig)
        if ok and newKernelCode and newSigText then
            writeFileAtomic(cfg.kernel, newKernelCode)
            writeFileAtomic(cfg.kernelSig, newSigText)
            fs.delete(stagedKernel)
            fs.delete(stagedKernelSig)
            BIOS.log("OK", "Bootloader", "Kernel updated successfully.")
        else
            BIOS.log("WARN", "Bootloader", "Rejected invalid kernel update: " .. tostring(newKernelCode))
            fs.delete(stagedKernel)
            fs.delete(stagedKernelSig)
        end
    end

    return false
end

-- ============================================================================
-- Bootloader Execution Flow
-- ============================================================================
BIOS.log("INFO", "Bootloader", "CC-jOS Bootloader v" .. BOOTLOADER_VERSION .. " starting...")

local bootConfig = loadBootConfig("/boot/boot.cfg")
local reloaded = applyStagedUpdates(bootConfig)
if reloaded then
    return
end

BIOS.log("INFO", "Bootloader", "Verifying kernel image: " .. tostring(bootConfig.kernel))
local ok, kernelSourceOrErr = BIOS.verifySignedFile(bootConfig.kernel, bootConfig.kernelSig)
if not ok then
    BIOS.panic("Bootloader", "Kernel verification failed: " .. tostring(kernelSourceOrErr))
end

BIOS.log("OK", "Bootloader", "Kernel signature verified. Jumping to kernel...")

local kernelEnv = setmetatable({}, { __index = _G })
local kernelFn, loadErr = BIOS.loadProtectedChunk(kernelSourceOrErr, "@kernel.lua", kernelEnv)
if not kernelFn then
    BIOS.panic("Bootloader", "Failed to compile kernel: " .. tostring(loadErr))
end

kernelFn(BIOS, rawHW, bootConfig)
