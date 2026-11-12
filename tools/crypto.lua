-- CC-jOS Pure-Lua Cryptographic Library (SHA-256 + Asymmetric RSA-SHA256)
-- Compatible with CC:Tweaked (Cobalt / Lua 5.2 bit32) and standard Lua 5.1+

local Crypto = {}

-- Bitwise operations abstraction (uses bit32 or bit if available, pure Lua fallback)
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
    function bnot(a)
        return (MOD - 1 - (a % MOD)) % MOD
    end
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

-- SHA-256 Constants
local K = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
}

function Crypto.sha256(msg)
    msg = tostring(msg or "")
    local len = #msg
    local bit_len = len * 8

    -- Append 0x80 and pad with zeros until length % 64 == 56
    msg = msg .. string.char(0x80)
    local pad_len = (56 - (#msg % 64)) % 64
    msg = msg .. string.rep(string.char(0), pad_len)

    -- Append 64-bit big-endian bit length
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

    local H0 = 0x6a09e667
    local H1 = 0xbb67ae85
    local H2 = 0x3c6ef372
    local H3 = 0xa54ff53a
    local H4 = 0x510e527f
    local H5 = 0x9b05688c
    local H6 = 0x1f83d9ab
    local H7 = 0x5be0cd19

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
            local temp1 = (h + S1 + ch + K[t] + W[t]) % (2^32)
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

-- BigInt arithmetic (base 2^16 little-endian limbs) for fast, exact RSA modular exponentiation in pure Lua
local BASE = 65536
local BigInt = {}

local function trim(a)
    while #a > 1 and a[#a] == 0 do
        a[#a] = nil
    end
    if #a == 0 then a[1] = 0 end
    return a
end

function BigInt.fromHex(hex)
    hex = hex:gsub("^0x", ""):gsub("%s+", "")
    if #hex % 4 ~= 0 then
        hex = string.rep("0", 4 - (#hex % 4)) .. hex
    end
    local limbs = {}
    for i = #hex, 1, -4 do
        local chunk = hex:sub(i - 3, i)
        limbs[#limbs + 1] = tonumber(chunk, 16) or 0
    end
    return trim(limbs)
end

function BigInt.toHex(a)
    a = trim(a)
    local parts = {}
    parts[1] = string.format("%x", a[#a])
    for i = #a - 1, 1, -1 do
        parts[#parts + 1] = string.format("%04x", a[i])
    end
    local res = table.concat(parts)
    if #res % 2 == 1 then res = "0" .. res end
    return res
end

function BigInt.compare(a, b)
    if #a ~= #b then
        return (#a > #b) and 1 or -1
    end
    for i = #a, 1, -1 do
        if a[i] ~= b[i] then
            return (a[i] > b[i]) and 1 or -1
        end
    end
    return 0
end

function BigInt.sub(a, b)
    local res = {}
    local borrow = 0
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

function BigInt.mul(a, b)
    local res = {}
    for i = 1, #a + #b do res[i] = 0 end
    for i = 1, #a do
        local carry = 0
        local ai = a[i]
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

function BigInt.mod(a, m)
    if BigInt.compare(a, m) < 0 then
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
        if BigInt.compare(rem, m) >= 0 then
            local rLen = #rem
            local num
            if rLen > mLen then
                num = rem[rLen] * BASE + (rem[rLen - 1] or 0)
            else
                num = rem[rLen]
            end
            local q = math.floor(num / (mTop + 1))
            if q > 0 then
                rem = BigInt.sub(rem, BigInt.mul(m, { q }))
            end
            while BigInt.compare(rem, m) >= 0 do
                rem = BigInt.sub(rem, m)
            end
        end
    end
    return trim(rem)
end

function BigInt.modExp(base, exp, mod)
    local result = { 1 }
    local b = BigInt.mod(base, mod)
    for i = 1, #exp do
        local limb = exp[i]
        for bit = 0, 15 do
            if limb % 2 == 1 then
                result = BigInt.mod(BigInt.mul(result, b), mod)
            end
            limb = math.floor(limb / 2)
            if i < #exp or limb > 0 then
                b = BigInt.mod(BigInt.mul(b, b), mod)
            else
                break
            end
        end
    end
    return result
end

Crypto.BigInt = BigInt

-- Asymmetric RSA-SHA256 Signing & Verification
-- Signature format: modular exponentiation over padded digest (0001ffff...ff00 || sha256(message))
local function buildPaddedDigest(message, modulusHex)
    local digestHex = Crypto.sha256(message)
    local modBytes = math.floor(#modulusHex / 2)
    local digestBytes = 32
    if modBytes <= digestBytes + 11 then
        return digestHex
    end
    local ffCount = modBytes - digestBytes - 3
    return "01" .. string.rep("ff", ffCount) .. "00" .. digestHex
end

function Crypto.sign(message, privateKey)
    local paddedHex = buildPaddedDigest(message, privateKey.n)
    local m = BigInt.fromHex(paddedHex)
    local d = BigInt.fromHex(privateKey.d)
    local n = BigInt.fromHex(privateKey.n)
    local sig = BigInt.modExp(m, d, n)
    return BigInt.toHex(sig)
end

function Crypto.verify(message, signatureHex, publicKey)
    if type(signatureHex) ~= "string" or #signatureHex == 0 then
        return false, "Malformed signature"
    end
    if not signatureHex:match("^[0-9a-fA-F]+$") then
        return false, "Signature is not valid hex"
    end
    local expectedHex = buildPaddedDigest(message, publicKey.n):lower()
    local s = BigInt.fromHex(signatureHex)
    local e = BigInt.fromHex(publicKey.e)
    local n = BigInt.fromHex(publicKey.n)
    if BigInt.compare(s, n) >= 0 then
        return false, "Signature out of range"
    end
    local recovered = BigInt.toHex(BigInt.modExp(s, e, n)):lower()
    -- Strip leading zeros for comparison
    expectedHex = expectedHex:gsub("^0+", "")
    recovered = recovered:gsub("^0+", "")
    if recovered == expectedHex then
        return true
    end
    return false, "Cryptographic signature verification failed"
end

return Crypto
