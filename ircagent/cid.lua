-- cid: CIDv1 (and CIDv0 on the way in), per ipfs/specs src/cid.md.
--
--      <cidv1> ::= <version=0x01><content-type><multihash>
--      <multihash> ::= <hash-code><digest-length><digest>
--
-- Every field is an unsigned varint (multiformats unsigned-varint):
-- little-endian groups of seven bits, the high bit meaning "more". The
-- spec's two hard rules are enforced here and not left to callers:
-- a varint must be minimally encoded, and nothing may follow the digest.
--
-- The identity multihash (code 0x00) makes the "digest" the bytes
-- themselves, which is how a CID carries literal data rather than an
-- address of it. box.lua wraps each sealed message that way.
--
-- String forms go through multibase: one prefix character naming the
-- encoding. Readers here take b (base32), z (base58btc), f (base16),
-- k (base36) -- the four the spec says to support -- plus m and u
-- (base64 and base64url, no padding). A 46-character "Qm..." string is
-- a CIDv0 in implicit base58btc.

local M = {}

M.V1 = 0x01
M.RAW = 0x55
M.DAG_PB = 0x70
M.IDENTITY = 0x00
M.SHA2_256 = 0x12

-- varints are capped at 9 bytes (63 bits) by the unsigned-varint spec.
M.VARINT_MAX = 9

-- ---- varint ----

function M.uvarint(n)
	assert(math.type(n) == "integer" and n >= 0, "uvarint: bad value")

	local out = {}

	repeat
		local b = n & 0x7f

		n = n >> 7
		out[#out + 1] = string.char(n > 0 and (b | 0x80) or b)
	until n == 0
	return table.concat(out)
end

-- read a varint at s[i]; returns value, next index -- or nil, reason.
function M.read_uvarint(s, i)
	i = i or 1

	local n, shift = 0, 0

	for k = 0, M.VARINT_MAX - 1 do
		local b = s:byte(i + k)

		if not b then
			return nil, "truncated varint"
		end
		n = n | ((b & 0x7f) << shift)
		if b & 0x80 == 0 then
			-- a final zero group after the first is padding: the
			-- same value had a shorter spelling.
			if b == 0 and k > 0 then
				return nil, "non-minimal varint"
			end
			return n, i + k + 1
		end
		shift = shift + 7
	end
	return nil, "varint too long"
end

-- ---- binary ----

-- encode(codec, hashcode, digest) -> binary CIDv1
function M.encode(codec, hashcode, digest)
	return M.uvarint(M.V1) .. M.uvarint(codec) .. M.uvarint(hashcode) ..
	    M.uvarint(#digest) .. digest
end

-- a CID whose content is the bytes themselves.
function M.inline(codec, data)
	return M.encode(codec, M.IDENTITY, data)
end

-- decode(bytes) -> { version, codec, hash, digest } or nil, reason
function M.decode(b)
	if type(b) ~= "string" then
		return nil, "not a string"
	end

	if #b == 34 and b:sub(1, 2) == "\x12\x20" then
		return { version = 0, codec = M.DAG_PB, hash = M.SHA2_256,
		    digest = b:sub(3) }
	end

	local v, i = M.read_uvarint(b, 1)

	if not v then
		return nil, i
	end
	if v ~= M.V1 then
		return nil, "not a cid (leading " .. v .. ")"
	end

	local codec, hash, len

	codec, i = M.read_uvarint(b, i)
	if not codec then
		return nil, i
	end
	hash, i = M.read_uvarint(b, i)
	if not hash then
		return nil, i
	end
	len, i = M.read_uvarint(b, i)
	if not len then
		return nil, i
	end
	if #b - i + 1 < len then
		return nil, "truncated digest"
	end
	if #b - i + 1 > len then
		return nil, "trailing bytes"
	end
	return { version = 1, codec = codec, hash = hash, digest = b:sub(i) }
end

-- ---- bases ----

-- RFC 4648 bit-group bases: no padding, alphabet by bits per char.
local function bitenc(s, alpha, bits)
	local out, acc, nacc = {}, 0, 0
	local mask = (1 << bits) - 1

	for i = 1, #s do
		acc = (acc << 8) | s:byte(i)
		nacc = nacc + 8
		while nacc >= bits do
			nacc = nacc - bits
			local v = (acc >> nacc) & mask

			out[#out + 1] = alpha:sub(v + 1, v + 1)
		end
		acc = acc & ((1 << nacc) - 1)
	end
	if nacc > 0 then
		local v = (acc << (bits - nacc)) & mask

		out[#out + 1] = alpha:sub(v + 1, v + 1)
	end
	return table.concat(out)
end

local function bitdec(s, alpha, bits)
	local rev = {}

	for i = 1, #alpha do
		rev[alpha:byte(i)] = i - 1
	end

	local out, acc, nacc = {}, 0, 0

	for i = 1, #s do
		local v = rev[s:byte(i)]

		if not v then
			return nil
		end
		acc = (acc << bits) | v
		nacc = nacc + bits
		if nacc >= 8 then
			nacc = nacc - 8
			out[#out + 1] = string.char((acc >> nacc) & 0xff)
		end
		acc = acc & ((1 << nacc) - 1)
	end
	-- leftover bits must be zero and fewer than a character's worth,
	-- or the string was not produced by an encoder.
	if acc ~= 0 or nacc >= bits then
		return nil
	end
	return table.concat(out)
end

-- base-N by long division, leading zero bytes as leading zero digits
-- (base58btc and base36 both work this way).
local function radixenc(s, alpha)
	local base = #alpha
	local digits = {}
	local zeros = #s:match("^%z*")

	for i = zeros + 1, #s do
		local carry = s:byte(i)

		for j = 1, #digits do
			carry = carry + digits[j] * 256
			digits[j] = carry % base
			carry = carry // base
		end
		while carry > 0 do
			digits[#digits + 1] = carry % base
			carry = carry // base
		end
	end

	local out = { alpha:sub(1, 1):rep(zeros) }

	for j = #digits, 1, -1 do
		out[#out + 1] = alpha:sub(digits[j] + 1, digits[j] + 1)
	end
	return table.concat(out)
end

local function radixdec(s, alpha)
	local base = #alpha
	local rev = {}

	for i = 1, base do
		rev[alpha:byte(i)] = i - 1
	end

	local z = alpha:sub(1, 1)
	local zeros = 0

	while s:sub(zeros + 1, zeros + 1) == z do
		zeros = zeros + 1
	end

	local bytes = {}

	for i = zeros + 1, #s do
		local carry = rev[s:byte(i)]

		if not carry then
			return nil
		end
		for j = 1, #bytes do
			carry = carry + bytes[j] * base
			bytes[j] = carry & 0xff
			carry = carry >> 8
		end
		while carry > 0 do
			bytes[#bytes + 1] = carry & 0xff
			carry = carry >> 8
		end
	end

	local out = { ("\0"):rep(zeros) }

	for j = #bytes, 1, -1 do
		out[#out + 1] = string.char(bytes[j])
	end
	return table.concat(out)
end

local B32 = "abcdefghijklmnopqrstuvwxyz234567"
local B58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
local B36 = "0123456789abcdefghijklmnopqrstuvwxyz"
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64U = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
local B16 = "0123456789abcdef"

M.bases = {
	b = { name = "base32",
	    enc = function(s) return bitenc(s, B32, 5) end,
	    -- base32 is case-insensitive; B is its uppercase spelling
	    dec = function(s) return bitdec(s:lower(), B32, 5) end },
	z = { name = "base58btc",
	    enc = function(s) return radixenc(s, B58) end,
	    dec = function(s) return radixdec(s, B58) end },
	k = { name = "base36",
	    enc = function(s) return radixenc(s, B36) end,
	    dec = function(s) return radixdec(s:lower(), B36) end },
	f = { name = "base16",
	    enc = function(s) return bitenc(s, B16, 4) end,
	    dec = function(s) return bitdec(s:lower(), B16, 4) end },
	m = { name = "base64",
	    enc = function(s) return bitenc(s, B64, 6) end,
	    dec = function(s) return bitdec(s, B64, 6) end },
	u = { name = "base64url",
	    enc = function(s) return bitenc(s, B64U, 6) end,
	    dec = function(s) return bitdec(s, B64U, 6) end },
}
M.bases.B = M.bases.b
M.bases.K = M.bases.k
M.bases.F = M.bases.f

-- multibase(prefix, bytes) -> string
function M.multibase(prefix, s)
	local b = assert(M.bases[prefix], "unknown multibase " .. tostring(prefix))

	return prefix .. b.enc(s)
end

-- unmultibase(string) -> bytes, prefix; or nil, reason
function M.unmultibase(s)
	local b = M.bases[s:sub(1, 1)]

	if not b then
		return nil, "unknown multibase prefix"
	end

	local out = b.dec(s:sub(2))

	if not out then
		return nil, "bad " .. b.name
	end
	return out, s:sub(1, 1)
end

-- ---- strings ----

-- tostring(bytes[, base]) -> CID string. base32 by default, as the spec
-- and every IPFS tool writes CIDv1.
function M.tostring(b, prefix)
	return M.multibase(prefix or "b", b)
end

-- parse(string) -> decoded table (with .bytes and .base), or nil, reason
function M.parse(s)
	if type(s) ~= "string" or s == "" then
		return nil, "empty"
	end

	local bytes, base

	if #s == 46 and s:sub(1, 2) == "Qm" then
		bytes, base = M.bases.z.dec(s), nil
		if not bytes then
			return nil, "bad base58btc"
		end
	else
		bytes, base = M.unmultibase(s)
		if not bytes then
			return nil, base
		end
	end

	local c, err = M.decode(bytes)

	if not c then
		return nil, err
	end
	if c.version == 0 and base then
		return nil, "cidv0 has no multibase prefix"
	end
	c.bytes, c.base = bytes, base
	return c
end

return M
