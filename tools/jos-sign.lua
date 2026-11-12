#!/usr/bin/env lua
-- ============================================================================
-- CC-jOS Code Signing & .app Bundle Packaging Tool (tools/jos-sign.lua)
-- Signs bootloader, kernel, and .app bundles using RSA-512 / SHA-256
-- ============================================================================

local Crypto = dofile("tools/crypto.lua")
local pubKey = dofile("keys/root_public.lua")
local privKey = dofile("keys/root_private.lua")

-- Canonical serializer matching BIOS.serializeCanonical
local function serializeCanonical(val)
    local t = type(val)
    if t == "nil" then
        return "nil"
    elseif t == "boolean" then
        return val and "true" or "false"
    elseif t == "number" then
        return tostring(val)
    elseif t == "string" then
        return string.format("%q", val)
    elseif t == "table" then
        local keys = {}
        for k in pairs(val) do
            keys[#keys + 1] = k
        end
        table.sort(keys, function(a, b)
            if type(a) == type(b) then
                return tostring(a) < tostring(b)
            end
            return type(a) < type(b)
        end)
        local parts = {}
        for i = 1, #keys do
            local k = keys[i]
            parts[#parts + 1] = "[" .. serializeCanonical(k) .. "]=" .. serializeCanonical(val[k])
        end
        return "{" .. table.concat(parts, ",") .. "}"
    else
        error("Cannot canonically serialize type: " .. t)
    end
end

local function readFile(path)
    local f, err = io.open(path, "rb")
    if not f then return nil, err end
    local content = f:read("*a")
    f:close()
    return content
end

local function writeFile(path, content)
    local f, err = io.open(path, "wb")
    if not f then error("Failed to write " .. tostring(path) .. ": " .. tostring(err)) end
    f:write(content)
    f:close()
end

-- List files recursively inside a directory (works on POSIX / Linux host & CC)
local function listBundleFiles(bundleDir)
    bundleDir = bundleDir:gsub("/+$", "")
    local files = {}
    local p = io.popen('find "' .. bundleDir .. '" -type f | sort')
    if not p then
        error("Failed to list directory: " .. bundleDir)
    end
    for line in p:lines() do
        local rel = line:sub(#bundleDir + 2)
        if rel ~= "" and rel ~= "manifest.lua" and rel ~= "signature.sig" then
            files[#files + 1] = rel
        end
    end
    p:close()
    return files
end

local function formatManifestLua(manifest)
    local lines = {}
    lines[#lines + 1] = "-- CC-jOS Signed Application Bundle Manifest"
    lines[#lines + 1] = "return {"
    lines[#lines + 1] = string.format("    id = %q,", manifest.id)
    lines[#lines + 1] = string.format("    name = %q,", manifest.name)
    lines[#lines + 1] = string.format("    version = %q,", manifest.version)
    lines[#lines + 1] = string.format("    type = %q,", manifest.type)
    lines[#lines + 1] = string.format("    entry = %q,", manifest.entry)
    lines[#lines + 1] = "    permissions = {"
    for i = 1, #manifest.permissions do
        lines[#lines + 1] = string.format("        %q,", manifest.permissions[i])
    end
    lines[#lines + 1] = "    },"
    lines[#lines + 1] = "    files = {"
    local fileKeys = {}
    for k in pairs(manifest.files) do fileKeys[#fileKeys + 1] = k end
    table.sort(fileKeys)
    for i = 1, #fileKeys do
        local k = fileKeys[i]
        lines[#lines + 1] = string.format("        [%q] = %q,", k, manifest.files[k])
    end
    lines[#lines + 1] = "    }"
    lines[#lines + 1] = "}\n"
    return table.concat(lines, "\n")
end

local function signFile(filePath)
    local content, err = readFile(filePath)
    if not content then
        error("Cannot read file " .. tostring(filePath) .. ": " .. tostring(err))
    end
    local digest = Crypto.sha256(content)
    local payload = "CC-jOS-FILE-SIG-v1\n" .. digest
    local sig = Crypto.sign(payload, privKey)
    local ok, vErr = Crypto.verify(payload, sig, pubKey)
    assert(ok, "Self-verification failed: " .. tostring(vErr))

    local sigPath = filePath .. ".sig"
    local sigContent = table.concat({
        "# CC-jOS Cryptographic File Signature",
        'format = "CC-jOS-FILE-SIG-v1"',
        'algorithm = "' .. pubKey.algorithm .. '"',
        'keyId = "' .. pubKey.keyId .. '"',
        'sha256 = "' .. digest .. '"',
        'signature = "' .. sig .. '"',
        ""
    }, "\n")
    writeFile(sigPath, sigContent)
    print(string.format("[SIGNED FILE] %s -> %s (sha256=%s...)", filePath, sigPath, digest:sub(1, 16)))
end

local function signAppBundle(bundleDir)
    bundleDir = bundleDir:gsub("/+$", "")
    local manifestPath = bundleDir .. "/manifest.lua"
    local manifestChunk, err = loadfile(manifestPath)
    if not manifestChunk then
        error("Cannot load manifest " .. manifestPath .. ": " .. tostring(err))
    end
    local manifest = manifestChunk()
    local relFiles = listBundleFiles(bundleDir)
    manifest.files = {}
    for i = 1, #relFiles do
        local rel = relFiles[i]
        local content = assert(readFile(bundleDir .. "/" .. rel))
        manifest.files[rel] = Crypto.sha256(content)
    end

    -- Write updated manifest with exact file SHA-256 digests
    writeFile(manifestPath, formatManifestLua(manifest))

    -- Re-load and serialize canonically
    local reloadedManifest = assert(loadfile(manifestPath))()
    local canonical = serializeCanonical(reloadedManifest)
    local manifestHash = Crypto.sha256(canonical)
    local payload = "CC-jOS-APP-BUNDLE-v1\n" .. canonical
    local sig = Crypto.sign(payload, privKey)
    local ok, vErr = Crypto.verify(payload, sig, pubKey)
    assert(ok, "Self-verification failed for bundle " .. bundleDir .. ": " .. tostring(vErr))

    local sigPath = bundleDir .. "/signature.sig"
    local sigContent = table.concat({
        "# CC-jOS Cryptographic .app Bundle Signature",
        'format = "CC-jOS-APP-BUNDLE-v1"',
        'bundleId = "' .. reloadedManifest.id .. '"',
        'algorithm = "' .. pubKey.algorithm .. '"',
        'keyId = "' .. pubKey.keyId .. '"',
        'manifestSha256 = "' .. manifestHash .. '"',
        'signature = "' .. sig .. '"',
        ""
    }, "\n")
    writeFile(sigPath, sigContent)
    print(string.format("[SIGNED APP]  %s (%s v%s, %d files)", bundleDir, reloadedManifest.id, reloadedManifest.version, #relFiles))
end

local cmd = arg and arg[1] or "sign-all"
if cmd == "sign-file" then
    assert(arg[2], "Usage: lua tools/jos-sign.lua sign-file <path>")
    signFile(arg[2])
elseif cmd == "sign-app" then
    assert(arg[2], "Usage: lua tools/jos-sign.lua sign-app <App.app>")
    signAppBundle(arg[2])
elseif cmd == "sign-all" then
    signFile("boot/bootloader.lua")
    signFile("System/Kernel/kernel.lua")
    signFile("System/Libraries/jvk.lua")
    signAppBundle("System/Apps/Launcher.app")
    signAppBundle("System/Apps/Dino.app")
else
    error("Unknown command: " .. tostring(cmd))
end
