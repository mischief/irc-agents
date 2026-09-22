-- ircagent/filter.lua: the line rewriting a client plugin does.

require "spec.helper"
local filter = require "ircagent.filter"
local chunk = require "ircagent.chunk"
local irc = require "ircagent.irc"

local KEY = ("k"):rep(32)
local T = os.time()

local function from(nick, line)
	return ":" .. nick .. "!u@h " .. line:gsub("\r\n$", "")
end

describe("filter", function()
	it("opens a channel box in place", function()
		local f = filter.new({ key = KEY, targets = { "#agents" } })
		local w = chunk.seal(KEY, "grug", "#agents", "hi there")[1]
		local out = f:inbound(from("grug", irc.privmsg("#agents", w)), "me", T)

		assert.same({ ":grug!u@h PRIVMSG #agents :" .. filter.LOCK .. "hi there" }, out)
	end)

	it("holds pieces and gives the whole message as lines", function()
		local f = filter.new({ key = KEY })
		local text = ("word "):rep(200) .. "\nsecond line"
		local wires = chunk.seal(KEY, "grug", "#agents", text)
		local got

		for i, w in ipairs(wires) do
			local out = f:inbound(from("grug", irc.privmsg("#agents", w)), "me", T)

			if i < #wires then
				assert.same({}, out)
			else
				got = out
			end
		end
		assert.equal(2, #got)
		assert.matches("second line$", got[2])
	end)

	it("marks what does not open", function()
		local f = filter.new({ key = ("x"):rep(32) })
		local w = chunk.seal(KEY, "grug", "#agents", "hi")[1]
		local out = f:inbound(from("grug", irc.privmsg("#agents", w)), "me", T)

		assert.matches(filter.BAD, out[1], 1, true)
	end)

	it("leaves plaintext and other commands alone", function()
		local f = filter.new({ key = KEY })
		local l = ":a!b@c PRIVMSG #agents :hello"

		assert.same({ l }, f:inbound(l, "me", T))
		assert.same({ "PING :x" }, f:inbound("PING :x", "me", T))
	end)

	it("seals outbound to targets only, and whole lines fit", function()
		local f = filter.new({ key = KEY, targets = { "#agents" } })
		local long = ("x"):rep(1500)
		local out = f:outbound("PRIVMSG #agents :" .. long, "mischief")

		assert.is_true(#out > 1)

		local back = filter.new({ key = KEY })
		local got

		for _, l in ipairs(out) do
			-- worst relayed prefix ":" nick9 "!" user10 "@" host63 " " is 86
			assert.is_true(#l + 2 + 86 <= irc.MAXLINE)
			got = back:inbound(from("mischief", l), "grug", os.time())[1] or got
		end
		assert.matches(long .. "$", got)
		assert.same({ "PRIVMSG #other :hi" },
		    f:outbound("PRIVMSG #other :hi", "mischief"))
		assert.same({ "PRIVMSG #agents :\1ACTION waves\1" },
		    f:outbound("PRIVMSG #agents :\1ACTION waves\1", "mischief"))
	end)

	it("learns to encrypt back to a nick that sent a box", function()
		local f = filter.new({ key = KEY })
		local w = chunk.seal(KEY, "grug", "me", "psst")[1]

		assert.is_false(f:encrypts("grug"))
		f:inbound(from("grug", irc.privmsg("me", w)), "me", T)
		assert.is_true(f:encrypts("GRUG"))
	end)

	it("drops a replay", function()
		local f = filter.new({ key = KEY })
		local l = from("grug", irc.privmsg("#a", chunk.seal(KEY, "grug", "#a", "x")[1]))

		f:inbound(l, "me", os.time())
		assert.matches("replayed", f:inbound(l, "me", os.time())[1])
	end)

	it("shows our own echoed lines as text", function()
		local f = filter.new({ key = KEY, targets = { "#agents" } })
		local text = ("y"):rep(700)
		local out = f:outbound("PRIVMSG #agents :" .. text, "me")
		local w1 = irc.parse(out[1]).params[2]
		local w2 = irc.parse(out[2]).params[2]

		assert.equal(filter.LOCK .. text, f:mine(w1))
		assert.equal("", f:mine(w2))
		assert.is_nil(f:mine(w1))
		assert.is_nil(f:mine("plain words"))
		assert.equal("me\t" .. filter.LOCK .. "hi",
		    f:mine("me\t" .. irc.parse(f:outbound("PRIVMSG #agents hi", "me")[1]).params[2]))
	end)
end)
