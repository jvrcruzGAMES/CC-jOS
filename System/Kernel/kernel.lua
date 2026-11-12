-- ============================================================================
-- CC-jOS Barebones Microkernel (/System/Kernel/kernel.lua)
-- Enforces Code Signing, .app Bundle Integrity, Process Isolation & Permissions
-- ============================================================================

local BIOS, rawHW, bootConfig = ...
if not BIOS or not rawHW then
    error("KERNEL_PANIC: Kernel must be booted by CC-jOS Bootloader", 0)
end

local KERNEL_VERSION = "1.1.0-micro"
local fs = rawHW.fs
local term = rawHW.term
local fb = rawHW.fb or BIOS.fb
local rawOS = rawHW.os

-- ============================================================================
-- 1. Lock Down Global Environment (_G)
-- ============================================================================
-- Strip privileged ComputerCraft APIs from _G so everything above the kernel
-- is strictly isolated in userspace and must go through permission-checked syscalls.
local PRIVILEGED_GLOBALS = {
    "fs", "io", "http", "loadfile", "dofile",
    "shell", "multishell", "package", "peripheral", "redstone"
}
for i = 1, #PRIVILEGED_GLOBALS do
    rawset(_G, PRIVILEGED_GLOBALS[i], nil)
end

-- ============================================================================
-- 2. Kernel State: Process Table, IPC Bus & Security Audit Log
-- ============================================================================
local nextPid = 1
local processes = {}       -- pid -> PCB
local ipcServices = {}     -- serviceName -> pid
local securityAuditLog = {}

local function recordAudit(pid, bundleId, action, allowed, detail)
    securityAuditLog[#securityAuditLog + 1] = {
        seq = #securityAuditLog + 1,
        pid = pid,
        bundleId = bundleId,
        action = action,
        allowed = allowed,
        detail = detail
    }
end

-- Permissions reserved strictly for signed sysmodules (e.g. FS.app, Net.app).
-- Standard user apps (type == "user") are forbidden from holding these permissions.
local SYSMODULE_ONLY_PERMISSIONS = {
    ["hw.fs.raw"] = true,
    ["hw.http.raw"] = true,
    ["hw.term.raw"] = true,
    ["ipc.register"] = true,
    ["kernel.audit"] = true
}

-- Map of syscalls to their required permission capability
local SYSCALL_PERMISSIONS = {
    ["console.write"]  = "kernel.console",
    ["console.print"]  = "kernel.console",
    ["fb.info"]        = "graphics.framebuffer",
    ["fb.clear"]       = "graphics.framebuffer",
    ["fb.setCell"]     = "graphics.framebuffer",
    ["fb.getCell"]     = "graphics.framebuffer",
    ["fb.writeText"]   = "graphics.framebuffer",
    ["fb.fillRect"]    = "graphics.framebuffer",
    ["fb.blitRow"]     = "graphics.framebuffer",
    ["fb.submitBatch"] = "graphics.framebuffer",
    ["fb.present"]     = "graphics.framebuffer",
    ["fb.snapshot"]    = "graphics.framebuffer",
    ["process.self"]   = "process.info",
    ["process.list"]   = "process.list",
    ["process.spawn"]  = "process.spawn",
    ["process.kill"]   = "process.kill",
    ["ipc.register"]   = "ipc.register",
    ["ipc.send"]       = "ipc.send",
    ["ipc.recv"]       = "ipc.recv",
    ["hw.fs"]          = "hw.fs.raw",
    ["hw.term"]        = "hw.term.raw",
    ["kernel.audit"]   = "kernel.audit"
}

-- ============================================================================
-- 3. .app Bundle Loader & Strict Code Signing Verification
-- ============================================================================
-- Recursively list all relative file paths inside a bundle directory
local function listBundleFilesRecursive(rootDir, relPrefix, out)
    out = out or {}
    relPrefix = relPrefix or ""
    if not fs.list then return out end
    local entries = fs.list(rootDir)
    table.sort(entries)
    for i = 1, #entries do
        local name = entries[i]
        local fullPath = rootDir .. "/" .. name
        local relPath = (relPrefix == "") and name or (relPrefix .. "/" .. name)
        if fs.isDir(fullPath) then
            listBundleFilesRecursive(fullPath, relPath, out)
        else
            out[#out + 1] = relPath
        end
    end
    return out
end

local function parseManifestSafely(manifestSource, bundlePath)
    local emptyEnv = {}
    local fn, err = BIOS.loadProtectedChunk(manifestSource, "@" .. bundlePath .. "/manifest.lua", emptyEnv)
    if not fn then
        return nil, "ERR_MANIFEST_SYNTAX: " .. tostring(err)
    end
    local ok, manifest = pcall(fn)
    if not ok or type(manifest) ~= "table" then
        return nil, "ERR_MANIFEST_INVALID: Manifest must return a table"
    end
    if type(manifest.id) ~= "string" or manifest.id == "" then
        return nil, "ERR_MANIFEST_SCHEMA: Missing string 'id'"
    end
    if type(manifest.name) ~= "string" or manifest.name == "" then
        return nil, "ERR_MANIFEST_SCHEMA: Missing string 'name'"
    end
    if type(manifest.version) ~= "string" or manifest.version == "" then
        return nil, "ERR_MANIFEST_SCHEMA: Missing string 'version'"
    end
    if manifest.type ~= "user" and manifest.type ~= "sysmodule" then
        return nil, "ERR_MANIFEST_SCHEMA: 'type' must be 'user' or 'sysmodule'"
    end
    if type(manifest.entry) ~= "string" or manifest.entry == "" then
        return nil, "ERR_MANIFEST_SCHEMA: Missing string 'entry'"
    end
    if type(manifest.permissions) ~= "table" then
        return nil, "ERR_MANIFEST_SCHEMA: Missing 'permissions' list"
    end
    if type(manifest.files) ~= "table" then
        return nil, "ERR_MANIFEST_SCHEMA: Missing 'files' SHA-256 map"
    end
    return manifest
end

local function verifyAndLoadAppBundle(appPath)
    appPath = BIOS.normalizePath(appPath)
    if not appPath:match("%.app$") then
        return nil, "ERR_BUNDLE_FORMAT: Bundle path must end with '.app' (" .. tostring(appPath) .. ")"
    end
    if not fs.exists(appPath) or not fs.isDir(appPath) then
        return nil, "ERR_BUNDLE_NOT_FOUND: Directory not found: " .. tostring(appPath)
    end

    local manifestPath = appPath .. "/manifest.lua"
    local sigPath = appPath .. "/signature.sig"

    local manifestSource, mReadErr = BIOS.readFileRaw(manifestPath)
    if not manifestSource then
        return nil, "ERR_CODESIGN_MISSING_MANIFEST: " .. tostring(mReadErr)
    end
    local sigText, sReadErr = BIOS.readFileRaw(sigPath)
    if not sigText then
        return nil, "ERR_CODESIGN_UNSIGNED: Missing signature.sig in " .. tostring(appPath) .. " (" .. tostring(sReadErr) .. ")"
    end

    local manifest, parseErr = parseManifestSafely(manifestSource, appPath)
    if not manifest then
        return nil, parseErr
    end

    -- Enforce permission tier policy before accepting bundle
    local permSet = {}
    for i = 1, #manifest.permissions do
        local perm = manifest.permissions[i]
        if type(perm) ~= "string" then
            return nil, "ERR_MANIFEST_SCHEMA: Permission entry must be string"
        end
        if manifest.type == "user" and SYSMODULE_ONLY_PERMISSIONS[perm] then
            return nil, "ERR_PERMISSION_POLICY: User app '" .. manifest.id .. "' cannot request sysmodule permission '" .. perm .. "'"
        end
        permSet[perm] = true
    end

    -- Verify RSA-SHA256 cryptographic signature over the canonical manifest
    local sigMeta, sigParseErr = BIOS.parseSigFile(sigText)
    if not sigMeta then
        return nil, "ERR_CODESIGN_CORRUPT_SIG: " .. tostring(sigParseErr)
    end
    if sigMeta.keyId and sigMeta.keyId ~= BIOS.rootPublicKey.keyId then
        return nil, "ERR_CODESIGN_UNTRUSTED_KEY: " .. tostring(sigMeta.keyId)
    end

    local canonicalManifest = BIOS.serializeCanonical(manifest)
    local expectedManifestHash = BIOS.sha256(canonicalManifest)
    if sigMeta.manifestSha256 and sigMeta.manifestSha256:lower() ~= expectedManifestHash:lower() then
        return nil, "ERR_CODESIGN_MANIFEST_TAMPERED: Manifest hash mismatch"
    end

    local signingPayload = "CC-jOS-APP-BUNDLE-v1\n" .. canonicalManifest
    local sigOk, sigErr = BIOS.verifySignature(signingPayload, sigMeta.signature, BIOS.rootPublicKey)
    if not sigOk then
        return nil, "ERR_CODESIGN_INVALID: " .. tostring(sigErr)
    end

    -- Verify every file on disk matches the signed manifest.files SHA-256 digests
    local diskFiles = listBundleFilesRecursive(appPath)
    local verifiedFileContents = {}
    local seenFiles = {}

    for i = 1, #diskFiles do
        local relPath = diskFiles[i]
        if relPath ~= "manifest.lua" and relPath ~= "signature.sig" then
            local expectedHash = manifest.files[relPath]
            if not expectedHash then
                return nil, "ERR_CODESIGN_UNSIGNED_FILE: Unlisted file '" .. relPath .. "' inside bundle"
            end
            local content, fErr = BIOS.readFileRaw(appPath .. "/" .. relPath)
            if not content then
                return nil, "ERR_BUNDLE_READ: " .. tostring(fErr)
            end
            local actualHash = BIOS.sha256(content)
            if actualHash:lower() ~= expectedHash:lower() then
                return nil, "ERR_CODESIGN_FILE_TAMPERED: SHA-256 mismatch for '" .. relPath .. "'"
            end
            verifiedFileContents[relPath] = content
            seenFiles[relPath] = true
        end
    end

    for relPath, _ in pairs(manifest.files) do
        if not seenFiles[relPath] then
            return nil, "ERR_CODESIGN_MISSING_FILE: Signed file '" .. relPath .. "' is missing from bundle"
        end
    end

    if not verifiedFileContents[manifest.entry] then
        return nil, "ERR_BUNDLE_ENTRY_MISSING: Entry script '" .. manifest.entry .. "' not found in signed files"
    end

    return {
        path = appPath,
        manifest = manifest,
        permissions = permSet,
        files = verifiedFileContents
    }
end

-- ============================================================================
-- 4. Permission Enforcer & Syscall Dispatcher
-- ============================================================================
local spawnAppProcess -- forward declaration

local function checkPermission(pcb, syscallName)
    local requiredPerm = SYSCALL_PERMISSIONS[syscallName]
    if not requiredPerm then
        recordAudit(pcb.pid, pcb.bundleId, syscallName, false, "Unknown syscall")
        return false, "ERR_INVALID_SYSCALL: Unknown syscall '" .. tostring(syscallName) .. "'"
    end
    if not pcb.permissions[requiredPerm] then
        recordAudit(pcb.pid, pcb.bundleId, syscallName, false, "Missing permission: " .. requiredPerm)
        return false, "ERR_PERMISSION_DENIED: Process '" .. pcb.bundleId .. "' (PID " .. pcb.pid .. ") lacks permission '" .. requiredPerm .. "' for syscall '" .. syscallName .. "'"
    end
    if SYSMODULE_ONLY_PERMISSIONS[requiredPerm] and pcb.type ~= "sysmodule" then
        recordAudit(pcb.pid, pcb.bundleId, syscallName, false, "Sysmodule tier required for " .. requiredPerm)
        return false, "ERR_PERMISSION_DENIED: Permission '" .. requiredPerm .. "' requires sysmodule privilege tier"
    end
    recordAudit(pcb.pid, pcb.bundleId, syscallName, true, requiredPerm)
    return true
end

local function dispatchSyscall(pcb, syscallName, ...)
    local allowed, err = checkPermission(pcb, syscallName)
    if not allowed then
        return false, err
    end

    local args = { ... }

    if syscallName == "console.write" then
        local text = tostring(args[1] or "")
        if term and term.write then
            term.write(text)
        else
            io.write(text)
        end
        return true

    elseif syscallName == "console.print" then
        local parts = {}
        for i = 1, select("#", ...) do
            parts[#parts + 1] = tostring(select(i, ...))
        end
        print(table.concat(parts, "\t"))
        return true

    elseif syscallName == "fb.info" then
        local w, h = fb.getSize()
        return true, BIOS.createReadOnlyProxy({
            width = w,
            height = h,
            isColor = (term and term.isColor and term.isColor()) or true
        }, "FramebufferInfo")

    elseif syscallName == "fb.clear" then
        fb.clear(args[1], args[2], args[3])
        return true

    elseif syscallName == "fb.setCell" then
        return true, fb.setCell(args[1], args[2], args[3], args[4], args[5])

    elseif syscallName == "fb.getCell" then
        local c, fgHex, bgHex = fb.getCell(args[1], args[2])
        if not c then
            return false, "ERR_FB_BOUNDS: Coordinates out of range"
        end
        return true, c, fgHex, bgHex

    elseif syscallName == "fb.writeText" then
        return true, fb.writeText(args[1], args[2], args[3], args[4], args[5])

    elseif syscallName == "fb.fillRect" then
        return true, fb.fillRect(args[1], args[2], args[3], args[4], args[5], args[6], args[7])

    elseif syscallName == "fb.blitRow" then
        return true, fb.blitRow(args[1], args[2], args[3], args[4], args[5])

    elseif syscallName == "fb.submitBatch" then
        local okBatch, batchErr = fb.submitBatch(args[1])
        if not okBatch then
            return false, "ERR_FB_BATCH: " .. tostring(batchErr)
        end
        return true

    elseif syscallName == "fb.present" then
        fb.present()
        return true

    elseif syscallName == "fb.snapshot" then
        return true, BIOS.createReadOnlyProxy(fb.getFrontbufferSnapshot(), "FramebufferSnapshot")

    elseif syscallName == "process.self" then
        local permList = {}
        for k in pairs(pcb.permissions) do
            permList[#permList + 1] = k
        end
        table.sort(permList)
        return true, BIOS.createReadOnlyProxy({
            pid = pcb.pid,
            bundleId = pcb.bundleId,
            name = pcb.name,
            version = pcb.version,
            type = pcb.type,
            permissions = permList
        }, "ProcessInfo")

    elseif syscallName == "process.list" then
        local list = {}
        for pid, proc in pairs(processes) do
            if proc.state ~= "dead" then
                list[#list + 1] = {
                    pid = pid,
                    bundleId = proc.bundleId,
                    name = proc.name,
                    type = proc.type,
                    state = proc.state
                }
            end
        end
        table.sort(list, function(a, b) return a.pid < b.pid end)
        return true, BIOS.createReadOnlyProxy(list, "ProcessList")

    elseif syscallName == "process.spawn" then
        local targetAppPath = args[1]
        local spawnArgs = args[2]
        local childPid, spawnErr = spawnAppProcess(targetAppPath, spawnArgs)
        if not childPid then
            return false, spawnErr
        end
        return true, childPid

    elseif syscallName == "process.kill" then
        local targetPid = tonumber(args[1])
        local target = targetPid and processes[targetPid]
        if not target or target.state == "dead" then
            return false, "ERR_NOPROC: Process not found"
        end
        if target.type == "sysmodule" and pcb.type ~= "sysmodule" then
            return false, "ERR_PERMISSION_DENIED: User process cannot kill a sysmodule"
        end
        target.state = "dead"
        return true

    elseif syscallName == "ipc.register" then
        local serviceName = tostring(args[1] or "")
        if serviceName == "" then
            return false, "ERR_IPC_INVALID: Service name cannot be empty"
        end
        ipcServices[serviceName] = pcb.pid
        return true

    elseif syscallName == "ipc.send" then
        local target = args[1]
        local message = args[2]
        local targetPid = (type(target) == "number") and target or ipcServices[tostring(target)]
        local destProc = targetPid and processes[targetPid]
        if not destProc or destProc.state == "dead" then
            return false, "ERR_IPC_TARGET_NOT_FOUND: " .. tostring(target)
        end
        destProc.ipcInbox[#destProc.ipcInbox + 1] = {
            fromPid = pcb.pid,
            fromBundle = pcb.bundleId,
            payload = message
        }
        return true

    elseif syscallName == "ipc.recv" then
        if #pcb.ipcInbox == 0 then
            return true, nil
        end
        local msg = table.remove(pcb.ipcInbox, 1)
        return true, msg

    elseif syscallName == "hw.fs" then
        -- Reserved exclusively for the userspace FS sysmodule (requires hw.fs.raw + type == "sysmodule")
        return true, fs

    elseif syscallName == "hw.term" then
        return true, term

    elseif syscallName == "kernel.audit" then
        return true, BIOS.createReadOnlyProxy(securityAuditLog, "SecurityAuditLog")
    end

    return false, "ERR_UNIMPLEMENTED_SYSCALL"
end

-- ============================================================================
-- 5. Userspace Sandbox Builder & Process Spawner
-- ============================================================================
local function createUserspaceEnvironment(pcb, bundle)
    local env = {}

    -- Safe standard Lua primitives only
    local safeGlobals = {
        "assert", "error", "ipairs", "next", "pairs", "pcall",
        "select", "tonumber", "tostring", "type", "unpack", "xpcall"
    }
    for i = 1, #safeGlobals do
        local k = safeGlobals[i]
        env[k] = _G[k]
    end

    env._VERSION = _G._VERSION
    env.math = BIOS.createReadOnlyProxy(math, "math")
    env.string = BIOS.createReadOnlyProxy(string, "string")
    env.table = BIOS.createReadOnlyProxy(table, "table")
    if _G.bit32 then
        env.bit32 = BIOS.createReadOnlyProxy(_G.bit32, "bit32")
    end
    env.coroutine = BIOS.createReadOnlyProxy(coroutine, "coroutine")

    -- Kernel syscall gateway for this specific process
    env.syscall = function(syscallName, ...)
        return dispatchSyscall(pcb, syscallName, ...)
    end

    -- Convenience print() routed strictly through the "console.print" syscall
    env.print = function(...)
        local ok, err = dispatchSyscall(pcb, "console.print", ...)
        if not ok then
            error(err, 2)
        end
    end

    -- Intra-bundle module loader (only loads hash-verified files from the bundle itself)
    local loadedModules = {}
    env.bundleRequire = function(relPath)
        relPath = tostring(relPath or "")
        if not relPath:match("%.lua$") then
            relPath = relPath .. ".lua"
        end
        if loadedModules["bundle:" .. relPath] then
            return loadedModules["bundle:" .. relPath]
        end
        local code = bundle.files[relPath]
        if not code then
            error("ERR_BUNDLE_MODULE_NOT_FOUND: '" .. relPath .. "' is not a signed file in " .. pcb.bundleId, 2)
        end
        local fn, err = BIOS.loadProtectedChunk(code, "@" .. pcb.bundleId .. "/" .. relPath, env)
        if not fn then
            error(err, 2)
        end
        local res = fn()
        loadedModules["bundle:" .. relPath] = res
        return res
    end

    -- Signed System Library & Bundle Module Loader (e.g. require("jvk"))
    env.require = function(modName)
        modName = tostring(modName or "")
        if loadedModules[modName] then
            return loadedModules[modName]
        end
        -- 1. Check if module exists inside the app's own verified bundle
        local relFile = modName:match("%.lua$") and modName or (modName .. ".lua")
        if bundle.files[relFile] then
            local res = env.bundleRequire(relFile)
            loadedModules[modName] = res
            return res
        end
        -- 2. Otherwise load from signed OS library directory (/System/Libraries/<modName>.lua)
        local cleanName = modName:gsub("%.lua$", "")
        if not cleanName:match("^[%w_%-]+$") then
            error("ERR_LIBRARY_NAME: Invalid system library name '" .. tostring(modName) .. "'", 2)
        end
        local libPath = "/System/Libraries/" .. cleanName .. ".lua"
        local sigPath = libPath .. ".sig"
        local okSig, libSourceOrErr = BIOS.verifySignedFile(libPath, sigPath)
        if not okSig then
            error("ERR_LIBRARY_CODESIGN: Failed to load signed system library '" .. cleanName .. "': " .. tostring(libSourceOrErr), 2)
        end
        local fn, compErr = BIOS.loadProtectedChunk(libSourceOrErr, "@" .. libPath, env)
        if not fn then
            error("ERR_LIBRARY_COMPILE: " .. tostring(compErr), 2)
        end
        local res = fn()
        loadedModules[modName] = res
        return res
    end

    env._G = env
    env._ENV = env
    return env
end

spawnAppProcess = function(appPath, args)
    local bundle, verifyErr = verifyAndLoadAppBundle(appPath)
    if not bundle then
        BIOS.log("ERROR", "Kernel", "Rejected bundle " .. tostring(appPath) .. ": " .. tostring(verifyErr))
        recordAudit(0, tostring(appPath), "bundle.verify", false, verifyErr)
        return nil, verifyErr
    end

    local pid = nextPid
    nextPid = nextPid + 1

    local pcb = {
        pid = pid,
        bundleId = bundle.manifest.id,
        name = bundle.manifest.name,
        version = bundle.manifest.version,
        type = bundle.manifest.type,
        path = bundle.path,
        permissions = bundle.permissions,
        ipcInbox = {},
        state = "ready",
        args = args or {}
    }

    local env = createUserspaceEnvironment(pcb, bundle)
    local entryCode = bundle.files[bundle.manifest.entry]
    local entryFn, compileErr = BIOS.loadProtectedChunk(
        entryCode,
        "@" .. bundle.manifest.id .. "/" .. bundle.manifest.entry,
        env
    )
    if not entryFn then
        return nil, "ERR_BUNDLE_COMPILE: " .. tostring(compileErr)
    end

    pcb.coro = coroutine.create(function()
        return entryFn(pcb.args)
    end)
    processes[pid] = pcb

    recordAudit(pid, pcb.bundleId, "process.spawn", true, "Spawned verified bundle " .. pcb.bundleId)
    return pid
end

-- ============================================================================
-- 6. Barebones Cooperative Scheduler Loop
-- ============================================================================
local function runScheduler()
    while true do
        local aliveCount = 0
        for pid = 1, nextPid - 1 do
            local pcb = processes[pid]
            if pcb and pcb.state ~= "dead" then
                aliveCount = aliveCount + 1
                pcb.state = "running"
                local ok, res = coroutine.resume(pcb.coro)
                if not ok then
                    pcb.state = "dead"
                    BIOS.log("ERROR", "Kernel", "Process " .. pcb.bundleId .. " (PID " .. pid .. ") crashed: " .. tostring(res))
                elseif coroutine.status(pcb.coro) == "dead" then
                    pcb.state = "dead"
                else
                    pcb.state = "ready"
                end
            end
        end
        if aliveCount == 0 then
            break
        end
    end
end

-- ============================================================================
-- 7. Kernel Entry Point: Initialize & Launch Userspace Init.app
-- ============================================================================
BIOS.log("INFO", "Kernel", "CC-jOS Kernel v" .. KERNEL_VERSION .. " initialized.")
BIOS.log("INFO", "Kernel", "Enforcing RSA-SHA256 codesigning & per-process capability permissions.")

local initAppPath = (bootConfig and bootConfig.initApp) or "/System/Apps/Init.app"
BIOS.log("INFO", "Kernel", "Launching initial userspace bundle: " .. initAppPath)

local initPid, initErr = spawnAppProcess(initAppPath, {})
if not initPid then
    BIOS.panic("Kernel", "Failed to launch initial userspace bundle (" .. tostring(initAppPath) .. "): " .. tostring(initErr))
end

runScheduler()

-- Expose kernel inspection hooks on rawHW for automated test harness verification if present
if type(rawHW._testHook) == "function" then
    rawHW._testHook({
        version = KERNEL_VERSION,
        spawnAppProcess = spawnAppProcess,
        verifyAndLoadAppBundle = verifyAndLoadAppBundle,
        runScheduler = runScheduler,
        securityAuditLog = securityAuditLog,
        processes = processes
    })
end
