-- ircagent/chunk.lua: split, number, seal; open, reassemble.

require "spec.helper"
local chunk = require "ircagent.chunk"
local box = require "ircagent.box"
local irc = require "ircagent.irc"

local KEY = ("k"):rep(32)
local ID = "abcd"

local function relayed(nick, to, w)
	return ":" .. nick .. "!" .. ("u"):rep(10) .. "@" .. ("h"):rep(63) ..
	    " " .. irc.privmsg(to, w)
end

describe("chunk header", function()
	it("packs and unpacks", function()
		local id, n, m, p = chunk.unpack(chunk.pack(ID, 2, 3, "x"))

		assert.same({ ID, 2, 3, "x" }, { id, n, m, p })
	end)

	it("refuses nonsense counts", function()
		assert.is_nil(chunk.unpack(chunk.pack(ID, 0, 3, "")))
		assert.is_nil(chunk.unpack(chunk.pack(ID, 4, 3, "")))
		assert.is_nil(chunk.unpack(chunk.pack(ID, 1, 0, "")))
		assert.is_nil(chunk.unpack(chunk.pack(ID, 1, chunk.MAX_PIECES + 1, "")))
		assert.is_nil(chunk.unpack("short"))
	end)
end)

describe("chunk seal and reassembly", function()
	local text = ("the quick brown fox \xe2\x9c\x93\n"):rep(200)

	it("numbers every piece 1..m under one id", function()
		local b = chunk.bodies("#agents", text, ID)

		assert.is_true(#b > 1)
		for i, body in ipairs(b) do
			local id, n, m = chunk.unpack(body)

			assert.same({ ID, i, #b }, { id, n, m })
		end
	end)

	it("fits every sealed line and rebuilds the text", function()
		local nick = ("n"):rep(9)
		local wires = chunk.seal(KEY, nick, "#agents", text)
		local a = chunk.assembler()
		local got

		for i, w in ipairs(wires) do
			assert.is_true(#relayed(nick, "#agents", w) <= irc.MAXLINE)

			local body = assert(box.open(KEY, nick, "#agents", w))
			local r = a:add(nick, "#agents", body, 0)

			if i < #wires then
				assert.is_nil(r)
			else
				got = r
			end
		end
		assert.equal(text, got)
		assert.equal(0, a.bytes)
	end)

	it("reassembles out of order", function()
		local b = chunk.bodies("x", text, ID)
		local a = chunk.assembler()
		local got

		for i = #b, 1, -1 do
			got = a:add("s", "x", b[i], 0) or got
		end
		assert.equal(text, got)
	end)

	it("passes a one-line message straight through", function()
		local b = chunk.bodies("x", "hi", ID)

		assert.equal(1, #b)
		assert.equal("hi", chunk.assembler():add("s", "x", b[1], 0))
	end)

	it("keeps senders and messages apart", function()
		local a = chunk.assembler()
		local b1 = chunk.bodies("x", text, "AAAA")
		local b2 = chunk.bodies("x", text, "AAAA")

		a:add("alice", "x", b1[1], 0)
		-- same id from someone else is someone else's message
		assert.is_nil(a:add("bob", "x", b2[2], 0))
		assert.equal(2, (function()
			local n = 0
			for _ in pairs(a.pending) do n = n + 1 end
			return n
		end)())
	end)

	it("refuses duplicates and changed counts", function()
		local a = chunk.assembler()

		a:add("s", "x", chunk.pack(ID, 1, 3, "a"), 0)
		assert.is_nil(select(1, a:add("s", "x", chunk.pack(ID, 1, 3, "a"), 0)))
		assert.equal("duplicate piece",
		    select(2, a:add("s", "x", chunk.pack(ID, 1, 3, "a"), 0)))
		assert.equal("piece count changed",
		    select(2, a:add("s", "x", chunk.pack(ID, 2, 4, "b"), 0)))
	end)

	it("gives up on a message after the timeout", function()
		local a = chunk.assembler({ timeout = 10 })

		a:add("s", "x", chunk.pack(ID, 1, 2, "a"), 0)
		assert.same({}, a:expire(5))

		local gone = a:expire(11)

		assert.equal(1, #gone)
		assert.equal(1, gone[1].got)
		assert.equal(2, gone[1].m)
		assert.equal(0, a.bytes)
		assert.is_nil(a:add("s", "x", chunk.pack(ID, 2, 2, "b"), 12))
	end)

	it("bounds what it holds", function()
		local a = chunk.assembler({ limit = 10 })

		a:add("s", "x", chunk.pack("aaaa", 1, 2, ("x"):rep(8)), 0)
		assert.equal("too much pending",
		    select(2, a:add("s", "x", chunk.pack("bbbb", 1, 2, "xxx"), 0)))
	end)

	it("refuses a message too long to send", function()
		assert.has_error(function()
			chunk.bodies("x", ("y"):rep(300 * (chunk.MAX_PIECES + 1)))
		end)
	end)
end)
