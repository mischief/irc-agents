-- ircagent/irc.lua: lines in, messages out, and back again.
--
-- The library is sans-io, so every case here is a string written down
-- rather than a connection arranged. Ported from lua-os's
-- test/host_irc.lua, one tap line to one assertion.
--
-- Two properties get most of the attention. A line that goes out must
-- be one line, whatever a user typed into it; and a line that comes
-- back must parse to what it was built from.

require "spec.helper"
local irc = require "ircagent.irc"

describe("irc.parse", function()
	it("splits a prefix, command and trailing parameter", function()
		local m = irc.parse(":nick!user@host PRIVMSG #chan :hello there")

		assert.equal("PRIVMSG", m.cmd)
		assert.equal("nick", m.nick)
		assert.equal("user", m.user)
		assert.equal("host", m.host)
		assert.equal("#chan", m.params[1])
		assert.equal("hello there", m.params[2])
		assert.equal(2, #m.params)
	end)

	it("reads a server prefix as the name", function()
		local m = irc.parse(":irc.example.org 001 me :Welcome")

		assert.equal("001", m.cmd)
		assert.equal("irc.example.org", m.nick)
		assert.is_nil(m.user)
		assert.equal("Welcome", m.params[2])
	end)

	it("takes a line with no prefix", function()
		local m = irc.parse("PING :12345")

		assert.equal("PING", m.cmd)
		assert.is_nil(m.prefix)
		assert.equal("12345", m.params[1])
	end)

	it("keeps an empty trailing parameter", function()
		local m = irc.parse(":a!b@c QUIT :")

		assert.equal("", m.params[1])
		assert.equal(1, #m.params)
	end)

	it("treats a colon inside the trailing text as text", function()
		assert.equal("see: this",
		    irc.parse(":a!b@c PRIVMSG #x :see: this").params[2])
	end)

	it("keeps middles before the trailing parameter", function()
		local m = irc.parse(":s 353 me = #chan :alice bob carol")

		assert.equal("#chan", m.params[3])
		assert.equal("alice bob carol", m.params[4])
		assert.equal(4, #m.params)
	end)

	it("reads tags, with and without values", function()
		local m = irc.parse("@id=123;flag :a!b@c PRIVMSG #x :hi")

		assert.equal("123", m.tags.id)
		assert.is_true(m.tags.flag)
		assert.equal("PRIVMSG", m.cmd)
	end)

	it("undoes tag escapes", function()
		assert.equal("a b;c", irc.parse("@k=a\\sb\\:c PING :x").tags.k)
	end)

	it("refuses what is not a message", function()
		assert.is_nil(irc.parse(""))
		assert.is_nil(irc.parse(":prefix-only"))
		assert.is_not_nil(irc.parse("PING x\r\n"))
	end)
end)

describe("irc builders", function()
	it("colon only where needed", function()
		assert.equal("PRIVMSG #chan :hello there\r\n",
		    irc.privmsg("#chan", "hello there"))
		assert.equal("PRIVMSG #chan hello\r\n", irc.privmsg("#chan", "hello"))
	end)

	it("puts parameters where each command wants them", function()
		assert.equal("JOIN #chan\r\n", irc.join("#chan"))
		assert.equal("JOIN #chan secret\r\n", irc.join("#chan", "secret"))
		assert.equal("PART #chan :bye now\r\n", irc.part("#chan", "bye now"))
		assert.equal("USER me 0 * :Me Myself\r\n", irc.user("me", "Me Myself"))
		assert.equal("PONG 12345\r\n", irc.pong("12345"))
		assert.equal("QUIT :\r\n", irc.quit())
	end)

	it("cuts CR and LF so one call is one line", function()
		local line = irc.privmsg("#chan", "hi\r\nQUIT :owned")

		assert.equal("PRIVMSG #chan :hiQUIT :owned\r\n", line)
		assert.equal(1, select(2, line:gsub("\r\n", "")))
		assert.equal(1, select(2, irc.line("JOIN", "#a\r\nPART #b")
		    :gsub("\r\n", "")))
	end)

	it("round-trips through parse", function()
		local cases = {
			{ "PRIVMSG", "#chan", "hello there" },
			{ "PRIVMSG", "nick", "one" },
			{ "TOPIC", "#chan", "a: b c" },
			{ "PART", "#chan", "" },
			{ "MODE", "#chan", "+o", "someone" },
		}

		for _, c in ipairs(cases) do
			local m = irc.parse(irc.line(table.unpack(c)))

			assert.equal(c[1], m.cmd)
			assert.same({ table.unpack(c, 2) }, m.params)
		end
	end)
end)

describe("irc casemapping", function()
	it("compares rfc1459 style", function()
		assert.is_true(irc.same("#Foo", "#foo"))
		assert.is_true(irc.same("Nick[a]", "nick{a}"))
		assert.is_false(irc.same("alice", "bob"))
	end)

	it("knows the channel prefixes", function()
		assert.is_true(irc.ischannel("#chan"))
		assert.is_true(irc.ischannel("&local"))
		assert.is_true(irc.ischannel("+modeless"))
		assert.is_false(irc.ischannel("nick"))
	end)
end)

describe("irc ctcp", function()
	it("wraps and unwraps an action", function()
		local m = irc.parse(irc.action("#chan", "waves"))
		local verb, arg = irc.isctcp(m.params[2])

		assert.equal("ACTION", verb)
		assert.equal("waves", arg)
		assert.is_nil(irc.isctcp("ordinary text"))
	end)
end)

describe("irc.reader", function()
	it("holds a half line until the rest comes", function()
		local r = irc.reader()

		r:feed("PING :one\r\nPRIV")
		assert.equal("PING :one", r:next())
		assert.is_nil(r:next())
		r:feed("MSG #x :hi\r\n")
		assert.equal("PRIVMSG #x :hi", r:next())
		assert.is_nil(r:next())
	end)

	it("gives several lines from one read, skipping empty ones", function()
		local r = irc.reader()
		local got = {}

		r:feed("a\r\nb\r\n\r\nc\r\n")
		for l in r:lines() do
			got[#got + 1] = l
		end
		assert.same({ "a", "b", "c" }, got)
	end)

	it("drops an overlong line and keeps working", function()
		local r = irc.reader(64)

		r:feed(string.rep("x", 100))
		assert.is_nil(r:next())
		assert.equal(1, r.dropped)
		r:feed("PING :after\r\n")
		assert.equal("PING :after", r:next())
	end)
end)
