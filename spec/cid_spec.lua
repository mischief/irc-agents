-- ircagent/cid.lua against ipfs/specs src/cid.md and the multiformats
-- rules it cites.

local H = require "spec.helper"
local cid = require "ircagent.cid"

-- src/cid.md: CIDv1, raw, sha2-256 of "hello"
local HELLO_HEX = "01551220" ..
    "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
local HELLO_B32 = "bafkreibm6jg3ux5qumhcn2b3flc3tyu6dmlb4xa7u5bf44yegnrjhc4yeq"

describe("cid varint", function()
	it("encodes the multiformats examples", function()
		-- unsigned-varint README
		local V = { { 1, "01" }, { 127, "7f" }, { 128, "8001" },
		    { 255, "ff01" }, { 300, "ac02" }, { 16384, "808001" } }

		for _, v in ipairs(V) do
			H.equal_hex(v[2], cid.uvarint(v[1]))
			assert.equal(v[1], (cid.read_uvarint(H.unhex(v[2]))))
		end
	end)

	it("rejects non-minimal, truncated and overlong varints", function()
		assert.is_nil(cid.read_uvarint("\x81\x00"))
		assert.is_nil(cid.read_uvarint("\x80"))
		assert.is_nil(cid.read_uvarint(("\xff"):rep(10)))
	end)
end)

describe("cid #kat", function()
	it("decodes the spec's hello example", function()
		local c = assert(cid.parse(HELLO_B32))

		assert.equal(1, c.version)
		assert.equal(cid.RAW, c.codec)
		assert.equal(cid.SHA2_256, c.hash)
		H.equal_hex(HELLO_HEX, c.bytes)
		assert.equal("b", c.base)
	end)

	it("encodes it back", function()
		local c = cid.parse(HELLO_B32)

		assert.equal(HELLO_B32,
		    cid.tostring(cid.encode(cid.RAW, cid.SHA2_256, c.digest)))
	end)

	it("reads the same cid in every base", function()
		local b = H.unhex(HELLO_HEX)

		for _, p in ipairs { "b", "B", "z", "k", "f", "F", "m", "u" } do
			local s = cid.multibase(p, b)

			assert.equal(b, assert(cid.parse(s)).bytes, p)
		end
		assert.equal("f" .. HELLO_HEX, cid.multibase("f", b))
	end)

	it("decodes a CIDv0", function()
		-- the IPFS empty directory
		local c = assert(cid.parse("QmUNLLsPACCz1vLxQVkXqqLX5R1X345qqfHbsf67hvA3Nn"))

		assert.equal(0, c.version)
		assert.equal(cid.DAG_PB, c.codec)
		assert.equal(32, #c.digest)
	end)
end)

describe("cid decoding rules", function()
	local digest = ("\1"):rep(32)
	local good = cid.encode(cid.RAW, cid.SHA2_256, digest)

	it("rejects trailing bytes and truncated digests", function()
		assert.is_not_nil(cid.decode(good))
		assert.is_nil(cid.decode(good .. "\0"))
		assert.is_nil(cid.decode(good:sub(1, -2)))
	end)

	it("rejects versions that are not 1, and 0x12 without 0x20", function()
		for _, v in ipairs { 0, 2, 3 } do
			assert.is_nil(cid.decode(string.char(v) .. good:sub(2)))
		end
		assert.is_nil(cid.decode("\x12\x20" .. digest .. "\0"))
		assert.is_nil(cid.decode("\x12\x21" .. digest .. "\0"))
	end)

	it("rejects a non-minimal field", function()
		assert.is_nil(cid.decode("\x81\x00\x55\x12\x20" .. digest))
	end)

	it("rejects junk strings", function()
		assert.is_nil(cid.parse(""))
		assert.is_nil(cid.parse("?abc"))
		assert.is_nil(cid.parse("b1"))
		assert.is_nil(cid.parse("zQmUNLLsPACCz1vLxQVkXqqLX5R1X345qqfHbsf67hvA3Nn"))
	end)

	it("carries literal data with the identity hash", function()
		local c = cid.parse(cid.tostring(cid.inline(cid.RAW, "hello")))

		assert.equal(cid.IDENTITY, c.hash)
		assert.equal("hello", c.digest)
	end)

	it("round-trips leading zero bytes through the radix bases", function()
		local s = "\0\0\1\2"

		for _, p in ipairs { "z", "k" } do
			assert.equal(s, cid.unmultibase(cid.multibase(p, s)))
		end
	end)
end)
