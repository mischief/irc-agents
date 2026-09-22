-- ircagent/box.lua: the wire form around the AEAD.
--
-- The AEAD itself is proven against RFC 8439 in aead_spec.lua. What is
-- left to test here is the framing: the CID around it (cid_spec.lua
-- has the CID itself), the binding of sender and target, and that
-- every piece of a split message fits in one line.

local H = require "spec.helper"
local box = require "ircagent.box"
local irc = require "ircagent.irc"
local cid = require "ircagent.cid"

local KEY = ("k"):rep(32)
local NONCE = ("n"):rep(12)

describe("box seal and open", function()
	it("opens what it sealed, with the time", function()
		local w = box.seal(KEY, "alice", "bob", "hello", 1234567890)
		local text, t, n = box.open(KEY, "alice", "bob", w)

		assert.equal("hello", text)
		assert.equal(1234567890, t)
		assert.equal(12, #n)
	end)

	it("is deterministic given the nonce", function()
		local a = box.seal(KEY, "a", "b", "x", 1, NONCE)

		assert.equal(a, box.seal(KEY, "a", "b", "x", 1, NONCE))
	end)

	it("is a cid with the box inline", function()
		local w = box.seal(KEY, "a", "b", "xyz", 1, NONCE)
		local c = assert(cid.parse(w))

		assert.equal("u", w:sub(1, 1))
		assert.equal(1, c.version)
		assert.equal(box.CODEC, c.codec)
		assert.equal(cid.IDENTITY, c.hash)
		assert.equal(box.OVERHEAD + 3, #c.digest)
		H.equal_hex(("6e"):rep(12), c.digest:sub(1, 12))
		assert.is_true(box.isbox(w))
	end)

	it("uses a fresh nonce each time", function()
		assert.not_equal(box.seal(KEY, "a", "b", "x", 1),
		    box.seal(KEY, "a", "b", "x", 1))
	end)

	it("binds the sender and target", function()
		local w = box.seal(KEY, "alice", "bob", "hi", 1)

		assert.is_nil(box.open(KEY, "mallory", "bob", w))
		assert.is_nil(box.open(KEY, "alice", "carol", w))
		assert.equal("hi", box.open(KEY, "ALICE", "Bob", w))
	end)

	it("refuses the wrong key, junk and plaintext", function()
		local w = box.seal(KEY, "a", "b", "hi", 1)

		assert.is_nil(box.open(("K"):rep(32), "a", "b", w))
		assert.is_nil(box.open(KEY, "a", "b", "uAAAA"))
		assert.is_nil(box.open(KEY, "a", "b", "u!!"))
		-- a real cid of another codec is not ours
		assert.is_nil(box.open(KEY, "a", "b",
		    cid.tostring(cid.inline(cid.RAW, "hi"))))
		assert.is_nil(box.open(KEY, "a", "b", "hi"))
		assert.is_false(box.isbox("hi"))
	end)

	it("refuses the same payload under another codec", function()
		local w = box.seal(KEY, "a", "b", "hi", 1)
		local c = cid.parse(w)
		local other = cid.tostring(cid.inline(box.CODEC + 1, c.digest), "u")

		assert.is_nil(box.open(KEY, "a", "b", other))
	end)

	it("reads any multibase", function()
		local w = box.seal(KEY, "a", "b", "hi", 1)
		local c = cid.parse(w)

		assert.equal("hi", box.open(KEY, "a", "b", cid.tostring(c.bytes, "b")))
		assert.equal("hi", box.open(KEY, "a", "b", cid.tostring(c.bytes, "z")))
	end)

	it("carries newlines and utf-8 untouched", function()
		local s = "one\ntwo \xe2\x9c\x93"

		assert.equal(s, box.open(KEY, "a", "b", box.seal(KEY, "a", "b", s)))
	end)
end)

describe("box split", function()
	it("leaves short text alone", function()
		assert.same({ "hi" }, box.split("hi", 10))
		assert.same({ "" }, box.split("", 10))
	end)

	it("breaks at a space when there is one", function()
		assert.same({ "hello ", "world" }, box.split("hello world", 8))
		assert.equal("a b\nc d", table.concat(box.split("a b\nc d", 2)))
	end)

	it("does not cut inside a utf-8 sequence", function()
		local s = ("\xe2\x9c\x93"):rep(10)

		for _, p in ipairs(box.split(s, 7)) do
			assert.is_true(utf8.len(p) ~= nil)
		end
		assert.equal(s, table.concat(box.split(s, 7)))
	end)

	it("makes every piece a line the server accepts", function()
		local to = "#agents"
		local text = ("word "):rep(400)
		local nick, user, host = ("n"):rep(9), ("u"):rep(10), ("h"):rep(63)

		for _, p in ipairs(box.split(text, box.room(to))) do
			local w = box.seal(KEY, nick, to, p)
			local relayed = ":" .. nick .. "!" .. user .. "@" .. host ..
			    " " .. irc.privmsg(to, w)

			assert.is_true(#relayed <= irc.MAXLINE)
			assert.equal(p, box.open(KEY, nick, to, w))
		end
	end)
end)
