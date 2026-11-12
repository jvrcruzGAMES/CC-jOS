-- ============================================================================
-- CC-jOS BIOS (startup.lua)
-- Immutable Hardware Root of Trust & Low-Level Utility Layer
-- ============================================================================

-- Disable Ctrl+T termination immediately during early boot
local rawOS = _G.os or {}
local rawPullEventRaw = rawOS.pullEventRaw
local rawPullEvent = rawOS.pullEvent
if rawPullEventRaw then
    rawOS.pullEvent = rawPullEventRaw
end

-- Capture raw hardware interfaces before locking down the environment
local function cloneTable(t)
    if type(t) ~= "table" then return t end
    local copy = {}
    for k, v in pairs(t) do
        copy[k] = v
    end
    return copy
end

local rawFS = cloneTable(_G.fs)
local rawTerm = cloneTable(_G.term)
local rawHTTP = cloneTable(_G.http)
local rawColors = cloneTable(_G.colors or _G.colours)
local rawKeys = cloneTable(_G.keys)

-- ============================================================================
-- 1. Embedded Root of Trust (RSA-512 / SHA-256 Public Key)
-- ============================================================================
local ROOT_PUBLIC_KEY = {
    keyId = "CC-jOS-Root-CA-v1",
    algorithm = "RSA-SHA256",
    n = "9bd6755d0f32ec7f7b09e4419c66c220fd2b7eaeaee019735c2dc1af6644d098d0ed2f9e41dfc720ed770b0959af3b64ba18a244a30c18a41a8013f85088a559",
    e = "010001"
}

-- ============================================================================
-- 2. Pure-Lua Cryptographic Engine (SHA-256 & BigInt RSA Verification)
-- ============================================================================
local bit_lib = rawget(_G, "bit32") or rawget(_G, "bit")
local band, bor, bxor, bnot, rshift, lshift

if bit_lib then
    band = bit_lib.band
    bor = bit_lib.bor
    bxor = bit_lib.bxor
    bnot = bit_lib.bnot
    rshift = bit_lib.rshift
    lshift = bit_lib.lshift
else
    local MOD = 2^32
    function bnot(a) return (MOD - 1 - (a % MOD)) % MOD end
    function bxor(a, b)
        local res, c = 0, 1
        a, b = a % MOD, b % MOD
        while a > 0 or b > 0 do
            local ra, rb = a % 2, b % 2
            if ra ~= rb then res = res + c end
            a, b, c = (a - ra) / 2, (b - rb) / 2, c * 2
        end
        return res
    end
    function band(a, b)
        local res, c = 0, 1
        a, b = a % MOD, b % MOD
        while a > 0 and b > 0 do
            local ra, rb = a % 2, b % 2
            if ra == 1 and rb == 1 then res = res + c end
            a, b, c = (a - ra) / 2, (b - rb) / 2, c * 2
        end
        return res
    end
    function bor(a, b)
        local res, c = 0, 1
        a, b = a % MOD, b % MOD
        while a > 0 or b > 0 do
            local ra, rb = a % 2, b % 2
            if ra == 1 or rb == 1 then res = res + c end
            a, b, c = (a - ra) / 2, (b - rb) / 2, c * 2
        end
        return res
    end
    function rshift(a, disp)
        if disp <= 0 then return a % MOD end
        if disp >= 32 then return 0 end
        return math.floor((a % MOD) / (2 ^ disp))
    end
    function lshift(a, disp)
        if disp <= 0 then return a % MOD end
        if disp >= 32 then return 0 end
        return ((a * (2 ^ disp)) % MOD)
    end
end

local function rrotate(x, n)
    n = n % 32
    if n == 0 then return x % (2^32) end
    return bor(rshift(x, n), lshift(x, 32 - n)) % (2^32)
end

local SHA256_K = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
}

local function sha256(msg)
    msg = tostring(msg or "")
    local bit_len = #msg * 8
    msg = msg .. string.char(0x80)
    local pad_len = (56 - (#msg % 64)) % 64
    msg = msg .. string.rep(string.char(0), pad_len)

    local hi = math.floor(bit_len / (2^32))
    local lo = bit_len % (2^32)
    local function word2bytes(w)
        return string.char(
            band(rshift(w, 24), 0xff),
            band(rshift(w, 16), 0xff),
            band(rshift(w, 8), 0xff),
            band(w, 0xff)
        )
    end
    msg = msg .. word2bytes(hi) .. word2bytes(lo)

    local H0, H1, H2, H3 = 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a
    local H4, H5, H6, H7 = 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19

    local W = {}
    for i = 1, #msg, 64 do
        for t = 1, 16 do
            local idx = i + (t - 1) * 4
            local b1, b2, b3, b4 = string.byte(msg, idx, idx + 3)
            W[t] = ((b1 * 256 + b2) * 256 + b3) * 256 + b4
        end
        for t = 17, 64 do
            local v15 = W[t - 15]
            local s0 = bxor(rrotate(v15, 7), bxor(rrotate(v15, 18), rshift(v15, 3)))
            local v2 = W[t - 2]
            local s1 = bxor(rrotate(v2, 17), bxor(rrotate(v2, 19), rshift(v2, 10)))
            W[t] = (W[t - 16] + s0 + W[t - 7] + s1) % (2^32)
        end

        local a, b, c, d, e, f, g, h = H0, H1, H2, H3, H4, H5, H6, H7
        for t = 1, 64 do
            local S1 = bxor(rrotate(e, 6), bxor(rrotate(e, 11), rrotate(e, 25)))
            local ch = bxor(band(e, f), band(bnot(e), g))
            local temp1 = (h + S1 + ch + SHA256_K[t] + W[t]) % (2^32)
            local S0 = bxor(rrotate(a, 2), bxor(rrotate(a, 13), rrotate(a, 22)))
            local maj = bxor(band(a, b), bxor(band(a, c), band(b, c)))
            local temp2 = (S0 + maj) % (2^32)

            h = g
            g = f
            f = e
            e = (d + temp1) % (2^32)
            d = c
            c = b
            b = a
            a = (temp1 + temp2) % (2^32)
        end

        H0 = (H0 + a) % (2^32)
        H1 = (H1 + b) % (2^32)
        H2 = (H2 + c) % (2^32)
        H3 = (H3 + d) % (2^32)
        H4 = (H4 + e) % (2^32)
        H5 = (H5 + f) % (2^32)
        H6 = (H6 + g) % (2^32)
        H7 = (H7 + h) % (2^32)
    end

    return string.format(
        "%08x%08x%08x%08x%08x%08x%08x%08x",
        H0, H1, H2, H3, H4, H5, H6, H7
    )
end

-- BigInt modular exponentiation (base 2^16 limbs)
local BASE = 65536
local function trim(a)
    while #a > 1 and a[#a] == 0 do a[#a] = nil end
    if #a == 0 then a[1] = 0 end
    return a
end

local function fromHex(hex)
    hex = hex:gsub("^0x", ""):gsub("%s+", "")
    if #hex % 4 ~= 0 then
        hex = string.rep("0", 4 - (#hex % 4)) .. hex
    end
    local limbs = {}
    for i = #hex, 1, -4 do
        limbs[#limbs + 1] = tonumber(hex:sub(i - 3, i), 16) or 0
    end
    return trim(limbs)
end

local function toHex(a)
    a = trim(a)
    local parts = { string.format("%x", a[#a]) }
    for i = #a - 1, 1, -1 do
        parts[#parts + 1] = string.format("%04x", a[i])
    end
    local res = table.concat(parts)
    if #res % 2 == 1 then res = "0" .. res end
    return res
end

local function compareBig(a, b)
    if #a ~= #b then return (#a > #b) and 1 or -1 end
    for i = #a, 1, -1 do
        if a[i] ~= b[i] then return (a[i] > b[i]) and 1 or -1 end
    end
    return 0
end

local function subBig(a, b)
    local res, borrow = {}, 0
    for i = 1, #a do
        local diff = a[i] - (b[i] or 0) - borrow
        if diff < 0 then
            diff = diff + BASE
            borrow = 1
        else
            borrow = 0
        end
        res[i] = diff
    end
    return trim(res)
end

local function mulBig(a, b)
    local res = {}
    for i = 1, #a + #b do res[i] = 0 end
    for i = 1, #a do
        local carry, ai = 0, a[i]
        for j = 1, #b do
            local idx = i + j - 1
            local prod = res[idx] + ai * b[j] + carry
            res[idx] = prod % BASE
            carry = math.floor(prod / BASE)
        end
        res[i + #b] = res[i + #b] + carry
    end
    return trim(res)
end

local function modBig(a, m)
    if compareBig(a, m) < 0 then
        local copy = {}
        for i = 1, #a do copy[i] = a[i] end
        return trim(copy)
    end
    local rem = { 0 }
    local mLen = #m
    local mTop = m[mLen]
    for i = #a, 1, -1 do
        if not (#rem == 1 and rem[1] == 0) then
            table.insert(rem, 1, a[i])
        else
            rem[1] = a[i]
        end
        trim(rem)
        if compareBig(rem, m) >= 0 then
            local rLen = #rem
            local num = (rLen > mLen) and (rem[rLen] * BASE + (rem[rLen - 1] or 0)) or rem[rLen]
            local q = math.floor(num / (mTop + 1))
            if q > 0 then
                rem = subBig(rem, mulBig(m, { q }))
            end
            while compareBig(rem, m) >= 0 do
                rem = subBig(rem, m)
            end
        end
    end
    return trim(rem)
end

local function modExpBig(base, exp, mod)
    local result = { 1 }
    local b = modBig(base, mod)
    for i = 1, #exp do
        local limb = exp[i]
        for _ = 0, 15 do
            if limb % 2 == 1 then
                result = modBig(mulBig(result, b), mod)
            end
            limb = math.floor(limb / 2)
            if i < #exp or limb > 0 then
                b = modBig(mulBig(b, b), mod)
            else
                break
            end
        end
    end
    return result
end

local function buildPaddedDigest(message, modulusHex)
    local digestHex = sha256(message)
    local modBytes = math.floor(#modulusHex / 2)
    local digestBytes = 32
    if modBytes <= digestBytes + 11 then
        return digestHex
    end
    local ffCount = modBytes - digestBytes - 3
    return "01" .. string.rep("ff", ffCount) .. "00" .. digestHex
end

local function verifySignature(message, signatureHex, publicKey)
    publicKey = publicKey or ROOT_PUBLIC_KEY
    if type(signatureHex) ~= "string" or #signatureHex == 0 then
        return false, "Missing or non-string signature"
    end
    if not signatureHex:match("^[0-9a-fA-F]+$") then
        return false, "Signature contains non-hex characters"
    end
    local expectedHex = buildPaddedDigest(message, publicKey.n):lower():gsub("^0+", "")
    local s = fromHex(signatureHex)
    local e = fromHex(publicKey.e)
    local n = fromHex(publicKey.n)
    if compareBig(s, n) >= 0 then
        return false, "Signature integer exceeds modulus"
    end
    local recovered = toHex(modExpBig(s, e, n)):lower():gsub("^0+", "")
    if recovered == expectedHex then
        return true
    end
    return false, "RSA-SHA256 cryptographic signature mismatch"
end

-- ============================================================================
-- 3. BIOS Immutability Enforcement & Low-Level Utilities
-- ============================================================================
local function normalizePath(p)
    if type(p) ~= "string" then return "" end
    if rawFS and rawFS.combine then
        return "/" .. rawFS.combine("", p)
    end
    local clean = p:gsub("\\", "/"):gsub("/+", "/")
    if clean:sub(1, 1) ~= "/" then clean = "/" .. clean end
    if #clean > 1 and clean:sub(-1) == "/" then clean = clean:sub(1, -2) end
    return clean
end

local function isBIOSPath(p)
    local norm = normalizePath(p):lower()
    return norm == "/startup.lua" or norm == "/startup"
end

-- Protect any FS table so /startup.lua is strictly immutable after install
local function createImmutableFSWrapper(backingFS)
    if not backingFS then return nil end
    local protected = {}
    for k, v in pairs(backingFS) do
        protected[k] = v
    end
    protected.isReadOnly = function(path)
        if isBIOSPath(path) then return true end
        return backingFS.isReadOnly and backingFS.isReadOnly(path) or false
    end
    protected.open = function(path, mode)
        mode = tostring(mode or "r")
        if isBIOSPath(path) and (mode:find("w") or mode:find("a") or mode:find("+")) then
            error("BIOS_IMMUTABLE: /startup.lua cannot be modified after installation", 2)
        end
        return backingFS.open(path, mode)
    end
    protected.delete = function(path)
        if isBIOSPath(path) or normalizePath(path) == "/" then
            error("BIOS_IMMUTABLE: /startup.lua cannot be deleted", 2)
        end
        return backingFS.delete(path)
    end
    protected.move = function(src, dest)
        if isBIOSPath(src) or isBIOSPath(dest) then
            error("BIOS_IMMUTABLE: /startup.lua cannot be moved or overwritten", 2)
        end
        return backingFS.move(src, dest)
    end
    protected.copy = function(src, dest)
        if isBIOSPath(dest) then
            error("BIOS_IMMUTABLE: /startup.lua cannot be overwritten", 2)
        end
        return backingFS.copy(src, dest)
    end
    return protected
end

-- Apply BIOS immutability wrapper to both rawHW.fs and _G.fs
rawFS = createImmutableFSWrapper(rawFS)
if rawget(_G, "fs") then
    _G.fs = createImmutableFSWrapper(_G.fs)
end

-- Canonical deterministic serializer for manifests and signing payloads
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

-- Read-only proxy builder to protect BIOS and Kernel structures
local function createReadOnlyProxy(tbl, label)
    local proxy = {}
    local mt = {
        __index = function(_, k)
            local v = tbl[k]
            if type(v) == "table" then
                return createReadOnlyProxy(v, label)
            end
            return v
        end,
        __newindex = function()
            error("SECURITY_VIOLATION: Attempt to mutate read-only " .. (label or "table"), 2)
        end,
        __metatable = "locked"
    }
    return setmetatable(proxy, mt)
end

-- Safe chunk loader (rejects binary bytecode chunks, sets sandboxed environment)
local function loadProtectedChunk(source, chunkName, env)
    if type(source) ~= "string" then
        return nil, "Chunk source must be a string"
    end
    if source:byte(1) == 27 then
        return nil, "SECURITY_VIOLATION: Binary Lua bytecode is forbidden"
    end
    if setfenv and loadstring then
        local fn, err = loadstring(source, chunkName)
        if not fn then return nil, err end
        if env then setfenv(fn, env) end
        return fn
    else
        return load(source, chunkName, "t", env or _G)
    end
end

-- Raw file reader via BIOS hardware handle
local function readFileRaw(path)
    if not rawFS or not rawFS.exists or not rawFS.exists(path) then
        return nil, "File not found: " .. tostring(path)
    end
    if rawFS.isDir and rawFS.isDir(path) then
        return nil, "Path is a directory: " .. tostring(path)
    end
    local handle, err = rawFS.open(path, "r")
    if not handle then
        return nil, err or ("Cannot open file: " .. tostring(path))
    end
    local content = handle.readAll()
    handle.close()
    return content or ""
end

-- Parse key=value signature file safely without executing code
local function parseSigFile(text)
    if type(text) ~= "string" then return nil, "Empty signature file" end
    local data = {}
    for line in text:gmatch("[^\r\n]+") do
        local trimmed = line:match("^%s*(.-)%s*$")
        if trimmed ~= "" and trimmed:sub(1, 1) ~= "#" and trimmed:sub(1, 2) ~= "--" then
            local k, v = trimmed:match("^([%w_%-]+)%s*=%s*(.+)$")
            if k and v then
                v = v:match('^"(.*)"$') or v:match("^'(.*)'$") or v
                data[k] = v
            end
        end
    end
    if not data.signature then
        return nil, "Signature file missing 'signature' field"
    end
    return data
end

-- Verify a signed OS file (such as /boot/bootloader.lua or /System/Kernel/kernel.lua)
local function verifySignedFile(filePath, sigPath)
    sigPath = sigPath or (filePath .. ".sig")
    local content, readErr = readFileRaw(filePath)
    if not content then
        return false, "Missing target file (" .. tostring(filePath) .. "): " .. tostring(readErr)
    end
    local sigText, sigReadErr = readFileRaw(sigPath)
    if not sigText then
        return false, "Missing signature file (" .. tostring(sigPath) .. "): " .. tostring(sigReadErr)
    end
    local sigMeta, parseErr = parseSigFile(sigText)
    if not sigMeta then
        return false, "Corrupt signature file (" .. tostring(sigPath) .. "): " .. tostring(parseErr)
    end
    if sigMeta.keyId and sigMeta.keyId ~= ROOT_PUBLIC_KEY.keyId then
        return false, "Untrusted signing keyId: " .. tostring(sigMeta.keyId)
    end
    local actualHash = sha256(content)
    if sigMeta.sha256 and sigMeta.sha256:lower() ~= actualHash:lower() then
        return false, "SHA-256 digest mismatch for " .. tostring(filePath)
    end
    local payload = "CC-jOS-FILE-SIG-v1\n" .. actualHash
    local ok, verifyErr = verifySignature(payload, sigMeta.signature, ROOT_PUBLIC_KEY)
    if not ok then
        return false, "Signature verification failed for " .. tostring(filePath) .. ": " .. tostring(verifyErr)
    end
    return true, content, actualHash
end

-- ============================================================================
-- 3.5. BIOS Pixelwise Framebuffer System (Sanjuuni-Style 2x3 Teletext Subpixels)
-- ============================================================================
-- In CC:Tweaked, characters 128..159 (0x80..0x9F) encode a 2x3 grid of sub-pixels
-- per character cell, doubling horizontal resolution and tripling vertical resolution
-- (e.g. a 51x19 terminal becomes a 102x57 pixel framebuffer).

local COLOR_INT_TO_HEX = {
    [1] = "0",     [2] = "1",     [4] = "2",     [8] = "3",
    [16] = "4",    [32] = "5",    [64] = "6",    [128] = "7",
    [256] = "8",   [512] = "9",   [1024] = "a",  [2048] = "b",
    [4096] = "c",  [8192] = "d",  [16384] = "e", [32768] = "f"
}

local COLOR_NAME_TO_HEX = {
    white = "0", orange = "1", magenta = "2", lightBlue = "3",
    yellow = "4", lime = "5", pink = "6", gray = "7", grey = "7",
    lightGray = "8", lightGrey = "8", cyan = "9", purple = "a",
    blue = "b", brown = "c", green = "d", red = "e", black = "f"
}

local HEX_TO_COLOR_INT = {
    ["0"] = 1,     ["1"] = 2,     ["2"] = 4,     ["3"] = 8,
    ["4"] = 16,    ["5"] = 32,    ["6"] = 64,    ["7"] = 128,
    ["8"] = 256,   ["9"] = 512,   ["a"] = 1024,  ["b"] = 2048,
    ["c"] = 4096,  ["d"] = 8192,  ["e"] = 16384, ["f"] = 32768
}

-- Standard CC:Tweaked 16-color palette RGB values for Sanjuuni-style 2-color block quantization
local PALETTE_RGB = {
    ["0"] = { 240, 240, 240 }, ["1"] = { 242, 178,  51 },
    ["2"] = { 229, 127, 216 }, ["3"] = { 153, 178, 242 },
    ["4"] = { 222, 222, 108 }, ["5"] = { 127, 204,  25 },
    ["6"] = { 242, 178, 204 }, ["7"] = {  76,  76,  76 },
    ["8"] = { 153, 153, 153 }, ["9"] = {  76, 153, 178 },
    ["a"] = { 178, 102, 229 }, ["b"] = {  51, 102, 204 },
    ["c"] = { 127, 102,  76 }, ["d"] = {  87, 166,  78 },
    ["e"] = { 204,  76,  76 }, ["f"] = {  17,  17,  17 }
}

local TELETEXT_CHARS = {}
for mask = 0, 31 do
    TELETEXT_CHARS[mask] = string.char(128 + mask)
end

local function colorDistSq(cA, cB)
    if cA == cB then return 0 end
    local rgbA = PALETTE_RGB[cA] or PALETTE_RGB["f"]
    local rgbB = PALETTE_RGB[cB] or PALETTE_RGB["f"]
    local dr = rgbA[1] - rgbB[1]
    local dg = rgbA[2] - rgbB[2]
    local db = rgbA[3] - rgbB[3]
    return dr * dr + dg * dg + db * db
end

local function toBlitHex(col, defaultHex)
    defaultHex = defaultHex or "0"
    if col == nil then return defaultHex end
    if type(col) == "number" then
        return COLOR_INT_TO_HEX[col] or defaultHex
    elseif type(col) == "string" then
        if #col == 1 and col:match("^[0-9a-fA-F]$") then
            return col:lower()
        end
        return COLOR_NAME_TO_HEX[col] or defaultHex
    end
    return defaultHex
end

-- Built-in 3x5 Pixel Bitmap Font (each glyph is 15 bits: 5 rows of 3 bits, MSB top-left)
local FONT_3X5 = {
    [" "] = { 0,0,0, 0,0,0, 0,0,0, 0,0,0, 0,0,0 },
    ["!"] = { 0,1,0, 0,1,0, 0,1,0, 0,0,0, 0,1,0 },
    ['"'] = { 1,0,1, 1,0,1, 0,0,0, 0,0,0, 0,0,0 },
    ["#"] = { 1,0,1, 1,1,1, 1,0,1, 1,1,1, 1,0,1 },
    ["'"] = { 0,1,0, 0,1,0, 0,0,0, 0,0,0, 0,0,0 },
    ["("] = { 0,1,1, 1,0,0, 1,0,0, 1,0,0, 0,1,1 },
    [")"] = { 1,1,0, 0,0,1, 0,0,1, 0,0,1, 1,1,0 },
    ["*"] = { 1,0,1, 0,1,0, 1,1,1, 0,1,0, 1,0,1 },
    ["+"] = { 0,0,0, 0,1,0, 1,1,1, 0,1,0, 0,0,0 },
    [","] = { 0,0,0, 0,0,0, 0,0,0, 0,1,0, 1,0,0 },
    ["-"] = { 0,0,0, 0,0,0, 1,1,1, 0,0,0, 0,0,0 },
    ["."] = { 0,0,0, 0,0,0, 0,0,0, 0,0,0, 0,1,0 },
    ["/"] = { 0,0,1, 0,0,1, 0,1,0, 1,0,0, 1,0,0 },
    ["0"] = { 1,1,1, 1,0,1, 1,0,1, 1,0,1, 1,1,1 },
    ["1"] = { 0,1,0, 1,1,0, 0,1,0, 0,1,0, 1,1,1 },
    ["2"] = { 1,1,1, 0,0,1, 1,1,1, 1,0,0, 1,1,1 },
    ["3"] = { 1,1,1, 0,0,1, 0,1,1, 0,0,1, 1,1,1 },
    ["4"] = { 1,0,1, 1,0,1, 1,1,1, 0,0,1, 0,0,1 },
    ["5"] = { 1,1,1, 1,0,0, 1,1,1, 0,0,1, 1,1,1 },
    ["6"] = { 1,1,1, 1,0,0, 1,1,1, 1,0,1, 1,1,1 },
    ["7"] = { 1,1,1, 0,0,1, 0,1,0, 0,1,0, 0,1,0 },
    ["8"] = { 1,1,1, 1,0,1, 1,1,1, 1,0,1, 1,1,1 },
    ["9"] = { 1,1,1, 1,0,1, 1,1,1, 0,0,1, 1,1,1 },
    [":"] = { 0,0,0, 0,1,0, 0,0,0, 0,1,0, 0,0,0 },
    [";"] = { 0,0,0, 0,1,0, 0,0,0, 0,1,0, 1,0,0 },
    ["<"] = { 0,0,1, 0,1,0, 1,0,0, 0,1,0, 0,0,1 },
    ["="] = { 0,0,0, 1,1,1, 0,0,0, 1,1,1, 0,0,0 },
    [">"] = { 1,0,0, 0,1,0, 0,0,1, 0,1,0, 1,0,0 },
    ["?"] = { 1,1,1, 0,0,1, 0,1,1, 0,0,0, 0,1,0 },
    ["["] = { 1,1,1, 1,0,0, 1,0,0, 1,0,0, 1,1,1 },
    ["]"] = { 1,1,1, 0,0,1, 0,0,1, 0,0,1, 1,1,1 },
    ["_"] = { 0,0,0, 0,0,0, 0,0,0, 0,0,0, 1,1,1 },
    ["A"] = { 0,1,0, 1,0,1, 1,1,1, 1,0,1, 1,0,1 },
    ["B"] = { 1,1,0, 1,0,1, 1,1,0, 1,0,1, 1,1,0 },
    ["C"] = { 0,1,1, 1,0,0, 1,0,0, 1,0,0, 0,1,1 },
    ["D"] = { 1,1,0, 1,0,1, 1,0,1, 1,0,1, 1,1,0 },
    ["E"] = { 1,1,1, 1,0,0, 1,1,0, 1,0,0, 1,1,1 },
    ["F"] = { 1,1,1, 1,0,0, 1,1,0, 1,0,0, 1,0,0 },
    ["G"] = { 0,1,1, 1,0,0, 1,0,1, 1,0,1, 0,1,1 },
    ["H"] = { 1,0,1, 1,0,1, 1,1,1, 1,0,1, 1,0,1 },
    ["I"] = { 1,1,1, 0,1,0, 0,1,0, 0,1,0, 1,1,1 },
    ["J"] = { 1,1,1, 0,1,0, 0,1,0, 1,1,0, 0,1,0 },
    ["K"] = { 1,0,1, 1,0,1, 1,1,0, 1,0,1, 1,0,1 },
    ["L"] = { 1,0,0, 1,0,0, 1,0,0, 1,0,0, 1,1,1 },
    ["M"] = { 1,0,1, 1,1,1, 1,0,1, 1,0,1, 1,0,1 },
    ["N"] = { 1,1,1, 1,0,1, 1,0,1, 1,0,1, 1,0,1 },
    ["O"] = { 0,1,0, 1,0,1, 1,0,1, 1,0,1, 0,1,0 },
    ["P"] = { 1,1,0, 1,0,1, 1,1,0, 1,0,0, 1,0,0 },
    ["Q"] = { 0,1,0, 1,0,1, 1,0,1, 1,1,1, 0,1,1 },
    ["R"] = { 1,1,0, 1,0,1, 1,1,0, 1,0,1, 1,0,1 },
    ["S"] = { 0,1,1, 1,0,0, 0,1,0, 0,0,1, 1,1,0 },
    ["T"] = { 1,1,1, 0,1,0, 0,1,0, 0,1,0, 0,1,0 },
    ["U"] = { 1,0,1, 1,0,1, 1,0,1, 1,0,1, 1,1,1 },
    ["V"] = { 1,0,1, 1,0,1, 1,0,1, 1,0,1, 0,1,0 },
    ["W"] = { 1,0,1, 1,0,1, 1,0,1, 1,1,1, 1,0,1 },
    ["X"] = { 1,0,1, 1,0,1, 0,1,0, 1,0,1, 1,0,1 },
    ["Y"] = { 1,0,1, 1,0,1, 0,1,0, 0,1,0, 0,1,0 },
    ["Z"] = { 1,1,1, 0,0,1, 0,1,0, 1,0,0, 1,1,1 }
}

local termW, termH = 51, 19
if rawTerm and rawTerm.getSize then
    local w, h = rawTerm.getSize()
    if type(w) == "number" and type(h) == "number" and w > 0 and h > 0 then
        termW, termH = math.floor(w), math.floor(h)
    end
end

-- Sub-pixel dimensions: 2 pixels per terminal column, 3 pixels per terminal row
local fbWidth  = termW * 2
local fbHeight = termH * 3

local fbPixels = {}
local frontPixelRows = {}
local frontTextRows = {}
local frontFgRows = {}
local frontBgRows = {}
local backDrawnTexts = {}
local frontDrawnTexts = {}
local presentCount = 0

local function initPixelBuffer(bgHex)
    bgHex = toBlitHex(bgHex, "f")
    for y = 1, fbHeight do
        local row = {}
        for x = 1, fbWidth do
            row[x] = bgHex
        end
        fbPixels[y] = row
    end
    backDrawnTexts = {}
end

initPixelBuffer("f")

local function fbGetSize()
    return fbWidth, fbHeight, termW, termH
end

local function fbClear(bgColor)
    initPixelBuffer(bgColor or "f")
    return true
end

local function fbSetPixel(x, y, color)
    x = math.floor(tonumber(x) or 0)
    y = math.floor(tonumber(y) or 0)
    if x < 1 or x > fbWidth or y < 1 or y > fbHeight then
        return false
    end
    fbPixels[y][x] = toBlitHex(color, fbPixels[y][x])
    return true
end

-- Alias for compatibility: fbSetCell(x, y, charOrColor, fgColor, bgColor)
local function fbSetCell(x, y, charOrColor, fgColor, bgColor)
    local col = fgColor or bgColor or charOrColor or "0"
    return fbSetPixel(x, y, col)
end

local function fbGetPixel(x, y)
    x = math.floor(tonumber(x) or 0)
    y = math.floor(tonumber(y) or 0)
    if x < 1 or x > fbWidth or y < 1 or y > fbHeight then
        return nil
    end
    return fbPixels[y][x]
end

local function fbFillRect(x, y, w, h, colorOrChar, fgColor, bgColor)
    x = math.floor(tonumber(x) or 1)
    y = math.floor(tonumber(y) or 1)
    w = math.floor(tonumber(w) or 0)
    h = math.floor(tonumber(h) or 0)
    if w <= 0 or h <= 0 then return false end
    local colHex = toBlitHex(bgColor or fgColor or colorOrChar, "f")

    local x0 = math.max(1, x)
    local y0 = math.max(1, y)
    local x1 = math.min(fbWidth, x + w - 1)
    local y1 = math.min(fbHeight, y + h - 1)

    for py = y0, y1 do
        local row = fbPixels[py]
        for px = x0, x1 do
            row[px] = colHex
        end
    end
    return true
end

local function fbDrawLine(x0, y0, x1, y1, color)
    x0 = math.floor((tonumber(x0) or 1) + 0.5)
    y0 = math.floor((tonumber(y0) or 1) + 0.5)
    x1 = math.floor((tonumber(x1) or 1) + 0.5)
    y1 = math.floor((tonumber(y1) or 1) + 0.5)
    local colHex = toBlitHex(color, "0")
    local dx = math.abs(x1 - x0)
    local dy = -math.abs(y1 - y0)
    local sx = (x0 < x1) and 1 or -1
    local sy = (y0 < y1) and 1 or -1
    local err = dx + dy
    local guard = 0
    while true do
        if x0 >= 1 and x0 <= fbWidth and y0 >= 1 and y0 <= fbHeight then
            fbPixels[y0][x0] = colHex
        end
        if x0 == x1 and y0 == y1 then break end
        local e2 = 2 * err
        if e2 >= dy then err = err + dy; x0 = x0 + sx end
        if e2 <= dx then err = err + dx; y0 = y0 + sy end
        guard = guard + 1
        if guard > 1024 then break end
    end
    return true
end

-- Renders text pixel-by-pixel into fbPixels using the built-in 3x5 pixel bitmap font
local function fbWriteText(x, y, text, fgColor, bgColor, scale)
    x = math.floor(tonumber(x) or 1)
    y = math.floor(tonumber(y) or 1)
    text = tostring(text or "")
    scale = math.max(1, math.floor(tonumber(scale) or 1))
    if #text == 0 then return false end

    local fgHex = toBlitHex(fgColor, "0")
    local bgHex = bgColor and toBlitHex(bgColor, "f") or nil
    backDrawnTexts[#backDrawnTexts + 1] = text

    local curX = x
    for i = 1, #text do
        local ch = text:sub(i, i):upper()
        local glyph = FONT_3X5[ch] or FONT_3X5["?"]
        if bgHex then
            fbFillRect(curX, y, 4 * scale, 5 * scale, bgHex)
        end
        for gy = 0, 4 do
            for gx = 0, 2 do
                if glyph[gy * 3 + gx + 1] == 1 then
                    for sy = 0, scale - 1 do
                        for sx = 0, scale - 1 do
                            fbSetPixel(curX + gx * scale + sx, y + gy * scale + sy, fgHex)
                        end
                    end
                end
            end
        end
        curX = curX + 4 * scale
    end
    return true
end

-- Blit a horizontal row of pixel hex characters ("0".."f") into fbPixels[y] starting at x
local function fbBlitPixelRow(x, y, pixelHexStr)
    x = math.floor(tonumber(x) or 1)
    y = math.floor(tonumber(y) or 1)
    pixelHexStr = tostring(pixelHexStr or "")
    if y < 1 or y > fbHeight or #pixelHexStr == 0 then
        return false
    end
    local row = fbPixels[y]
    for i = 1, #pixelHexStr do
        local px = x + i - 1
        if px >= 1 and px <= fbWidth then
            row[px] = toBlitHex(pixelHexStr:sub(i, i), row[px])
        end
    end
    return true
end

-- Sanjuuni-style 2x3 sub-pixel block quantizer: converts a 2x3 block of pixel colors
-- into (teletextChar, fgHex, bgHex) where teletextChar is in \128..\159
local function encodeTeletextBlock(p1, p2, p3, p4, p5, p6)
    -- Fast path: all 6 sub-pixels share the exact same color
    if p1 == p6 and p2 == p6 and p3 == p6 and p4 == p6 and p5 == p6 then
        return "\128", p6, p6
    end

    -- Count frequencies of colors in this 2x3 block
    local counts = {}
    local order = {}
    local pix = { p1, p2, p3, p4, p5, p6 }
    for i = 1, 6 do
        local c = pix[i]
        if not counts[c] then
            counts[c] = 1
            order[#order + 1] = c
        else
            counts[c] = counts[c] + 1
        end
    end

    local c1, c2 = order[1], order[2] or order[1]
    if #order > 2 then
        table.sort(order, function(a, b) return counts[a] > counts[b] end)
        c1, c2 = order[1], order[2]
        for i = 1, 6 do
            local p = pix[i]
            if p ~= c1 and p ~= c2 then
                if colorDistSq(p, c1) <= colorDistSq(p, c2) then
                    pix[i] = c1
                else
                    pix[i] = c2
                end
            end
        end
    end

    -- In CC:Tweaked teletext characters 128..159, sub-pixel 6 (bottom-right) is ALWAYS background (bit 5 = 0)
    local bg = pix[6]
    local fg = (bg == c1) and c2 or c1
    local mask = 0
    if pix[1] == fg then mask = mask + 1 end
    if pix[2] == fg then mask = mask + 2 end
    if pix[3] == fg then mask = mask + 4 end
    if pix[4] == fg then mask = mask + 8 end
    if pix[5] == fg then mask = mask + 16 end

    return TELETEXT_CHARS[mask], fg, bg
end

local function fbPresent()
    presentCount = presentCount + 1
    if rawTerm and rawTerm.setCursorBlink then
        rawTerm.setCursorBlink(false)
    end

    for py = 1, fbHeight do
        frontPixelRows[py] = table.concat(fbPixels[py])
    end

    frontDrawnTexts = {}
    for i = 1, #backDrawnTexts do
        frontDrawnTexts[i] = backDrawnTexts[i]
    end

    for cy = 1, termH do
        local py0 = (cy - 1) * 3 + 1
        local r1 = fbPixels[py0]
        local r2 = fbPixels[py0 + 1]
        local r3 = fbPixels[py0 + 2]
        local tChars, tFg, tBg = {}, {}, {}

        for cx = 1, termW do
            local px0 = (cx - 1) * 2 + 1
            local ch, fg, bg = encodeTeletextBlock(
                r1[px0], r1[px0 + 1],
                r2[px0], r2[px0 + 1],
                r3[px0], r3[px0 + 1]
            )
            tChars[cx] = ch
            tFg[cx] = fg
            tBg[cx] = bg
        end

        local tRow = table.concat(tChars)
        local fRow = table.concat(tFg)
        local bRow = table.concat(tBg)
        frontTextRows[cy] = tRow
        frontFgRows[cy] = fRow
        frontBgRows[cy] = bRow

        if rawTerm then
            if rawTerm.setCursorPos then
                rawTerm.setCursorPos(1, cy)
            end
            if rawTerm.blit then
                rawTerm.blit(tRow, fRow, bRow)
            elseif rawTerm.write then
                if rawTerm.setBackgroundColor then
                    rawTerm.setBackgroundColor(HEX_TO_COLOR_INT[bRow:sub(1, 1)] or 32768)
                end
                if rawTerm.setTextColor then
                    rawTerm.setTextColor(HEX_TO_COLOR_INT[fRow:sub(1, 1)] or 1)
                end
                rawTerm.write(tRow)
            end
        end
    end
    return true
end

local function fbSubmitBatch(commands)
    if type(commands) ~= "table" then
        return false, "Batch must be a table of commands"
    end
    for i = 1, #commands do
        local cmd = commands[i]
        if type(cmd) == "table" then
            local op = cmd.op
            if op == "clear" then
                fbClear(cmd.bg or cmd.color)
            elseif op == "pixel" or op == "cell" then
                fbSetPixel(cmd.x, cmd.y, cmd.color or cmd.fg or cmd.bg)
            elseif op == "line" then
                fbDrawLine(cmd.x0, cmd.y0, cmd.x1, cmd.y1, cmd.color or cmd.fg)
            elseif op == "text" then
                fbWriteText(cmd.x, cmd.y, cmd.text, cmd.fg, cmd.bg, cmd.scale)
            elseif op == "rect" then
                fbFillRect(cmd.x, cmd.y, cmd.w, cmd.h, cmd.color or cmd.bg or cmd.fg)
            elseif op == "blitPixels" or op == "blit" then
                fbBlitPixelRow(cmd.x, cmd.y, cmd.pixels or cmd.fg or cmd.bg)
            elseif op == "recordText" then
                backDrawnTexts[#backDrawnTexts + 1] = tostring(cmd.text or "")
            elseif op == "present" then
                fbPresent()
            end
        end
    end
    return true
end

local function fbGetFrontbufferSnapshot()
    local pixCopy, textCopy, fgCopy, bgCopy, drawnCopy = {}, {}, {}, {}, {}
    for py = 1, fbHeight do
        pixCopy[py] = frontPixelRows[py] or table.concat(fbPixels[py])
    end
    for cy = 1, termH do
        textCopy[cy] = frontTextRows[cy] or ""
        fgCopy[cy] = frontFgRows[cy] or ""
        bgCopy[cy] = frontBgRows[cy] or ""
    end
    for i = 1, #frontDrawnTexts do
        drawnCopy[i] = frontDrawnTexts[i]
    end
    return {
        width = fbWidth,
        height = fbHeight,
        termWidth = termW,
        termHeight = termH,
        presentCount = presentCount,
        pixelRows = pixCopy,
        textRows = textCopy,
        fgRows = fgCopy,
        bgRows = bgCopy,
        drawnTexts = drawnCopy
    }
end

-- Hardcoded BIOS Boot Screen:
-- Clears the pixelwise framebuffer to black ("f") and draws a crisp white ("0")
-- uppercase letter "J" centered horizontally and vertically in pixel space.
local function fbRenderBootSplash()
    fbClear("f")
    local centerX = math.floor((fbWidth + 1) / 2)
    local centerY = math.floor((fbHeight + 1) / 2)
    -- Render a crisp 5x7 pixel white uppercase "J" centered at (centerX, centerY)
    -- Top bar: dx = -1..+2, dy = -3
    for dx = -1, 2 do
        fbSetPixel(centerX + dx, centerY - 3, "0")
    end
    -- Vertical stem passing through exact center (centerX, centerY): dx = 0, dy = -2..+2
    for dy = -2, 2 do
        fbSetPixel(centerX, centerY + dy, "0")
    end
    -- Left hook: dx = -2, dy = +1..+2 and bottom curve dx = -1, dy = +3
    fbSetPixel(centerX - 2, centerY + 1, "0")
    fbSetPixel(centerX - 2, centerY + 2, "0")
    fbSetPixel(centerX - 1, centerY + 3, "0")
    backDrawnTexts[#backDrawnTexts + 1] = "J"
    fbPresent()
    return centerX, centerY
end

local FB_INTERNAL = {
    getSize = fbGetSize,
    toBlitHex = toBlitHex,
    clear = fbClear,
    setPixel = fbSetPixel,
    getPixel = fbGetPixel,
    setCell = fbSetCell,
    getCell = fbGetPixel,
    drawLine = fbDrawLine,
    writeText = fbWriteText,
    drawText = fbWriteText,
    fillRect = fbFillRect,
    blitPixelRow = fbBlitPixelRow,
    blitRow = fbBlitPixelRow,
    submitBatch = fbSubmitBatch,
    present = fbPresent,
    getFrontbufferSnapshot = fbGetFrontbufferSnapshot,
    renderBootSplash = fbRenderBootSplash
}

-- In-memory boot log ring buffer so low-level boot stages do not overwrite
-- the centered white "J" boot screen before the start app takes over rendering.
local bootLogs = {}
local function biosLog(level, component, msg)
    bootLogs[#bootLogs + 1] = {
        seq = #bootLogs + 1,
        level = tostring(level),
        component = tostring(component),
        message = tostring(msg)
    }
end

local function biosGetBootLogs()
    local copy = {}
    for i = 1, #bootLogs do
        local entry = bootLogs[i]
        copy[i] = {
            seq = entry.seq,
            level = entry.level,
            component = entry.component,
            message = entry.message
        }
    end
    return copy
end

local function biosPanic(component, reason)
    fbClear("e")
    fbWriteText(3, 3, "CC-JOS PANIC", "0", "e", 1)
    fbWriteText(3, 11, tostring(component):upper(), "4", "e", 1)
    fbWriteText(3, 19, tostring(reason):sub(1, 24), "0", "e", 1)
    fbPresent()
    error("CC_JOS_PANIC:" .. tostring(component) .. ":" .. tostring(reason), 0)
end

-- Construct the immutable BIOS API table exposed to Bootloader & Kernel
local BIOS_INTERNAL = {
    version = "1.1.0-jOS",
    rootPublicKey = ROOT_PUBLIC_KEY,
    sha256 = sha256,
    verifySignature = verifySignature,
    verifySignedFile = verifySignedFile,
    parseSigFile = parseSigFile,
    serializeCanonical = serializeCanonical,
    createReadOnlyProxy = createReadOnlyProxy,
    loadProtectedChunk = loadProtectedChunk,
    readFileRaw = readFileRaw,
    normalizePath = normalizePath,
    isBIOSPath = isBIOSPath,
    fb = FB_INTERNAL,
    log = biosLog,
    getBootLogs = biosGetBootLogs,
    panic = biosPanic
}

local BIOS = createReadOnlyProxy(BIOS_INTERNAL, "BIOS")

-- Privileged Hardware Handle Table passed down the verified chain (BIOS -> Bootloader -> Kernel)
local rawHW = {
    fs = rawFS,
    term = rawTerm,
    fb = FB_INTERNAL,
    os = {
        pullEventRaw = rawPullEventRaw,
        pullEvent = rawPullEvent,
        queueEvent = rawOS.queueEvent,
        startTimer = rawOS.startTimer,
        cancelTimer = rawOS.cancelTimer,
        clock = rawOS.clock,
        time = rawOS.time,
        epoch = rawOS.epoch,
        day = rawOS.day,
        computerID = rawOS.computerID or rawOS.getComputerID,
        computerLabel = rawOS.computerLabel or rawOS.getComputerLabel,
        shutdown = rawOS.shutdown,
        reboot = rawOS.reboot,
        _testHook = rawOS._testHook,
        _testMode = rawOS._testMode
    },
    http = rawHTTP,
    colors = rawColors,
    keys = rawKeys
}

-- ============================================================================
-- 4. Verified Boot Chain Stage 1: Render Boot Screen & Execute Bootloader
-- ============================================================================
-- Immediately display the hardcoded boot screen (centered white uppercase "J")
-- via the BIOS framebuffer. It remains on screen until the start app launches.
BIOS.fb.renderBootSplash()
BIOS.log("INFO", "BIOS", "CC-jOS BIOS v" .. BIOS.version .. " initializing...")
BIOS.log("INFO", "BIOS", "Root CA: " .. ROOT_PUBLIC_KEY.keyId .. " (" .. ROOT_PUBLIC_KEY.algorithm .. ")")

local BOOTLOADER_PATH = "/boot/bootloader.lua"
local BOOTLOADER_SIG  = "/boot/bootloader.lua.sig"

local ok, bootSourceOrErr = BIOS.verifySignedFile(BOOTLOADER_PATH, BOOTLOADER_SIG)
if not ok then
    BIOS.panic("BIOS", "Bootloader verification failed: " .. tostring(bootSourceOrErr))
end

BIOS.log("OK", "BIOS", "Bootloader signature verified. Handing off control...")

local bootEnv = setmetatable({}, { __index = _G })
local bootFn, loadErr = BIOS.loadProtectedChunk(bootSourceOrErr, "@bootloader.lua", bootEnv)
if not bootFn then
    BIOS.panic("BIOS", "Failed to compile bootloader: " .. tostring(loadErr))
end

local runOk, runErr = pcall(bootFn, BIOS, rawHW)
if not runOk then
    if tostring(runErr):find("^CC_JOS_PANIC:") then
        error(runErr, 0)
    end
    BIOS.panic("Bootloader", runErr)
end
