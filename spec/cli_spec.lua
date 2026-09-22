-- ircagent/cli.lua: the default event filter, the one thing every
-- agent sees through, and the log reading under watch and read.

require "spec.helper"
local cli = require "ircagent.cli"

local function ev(kind, from, to, text)
	return ("2026-01-02T03:04:05Z %s %s %s %s"):format(kind, from, to, text)
end

describe("cli.shown", function()
	it("shows what is addressed to you, and problems", function()
		for _, k in ipairs { "dm", "mention", "plain", "bad", "error", "probe" } do
			assert.is_true(cli.shown(ev(k, "a", "#x", "t")), k)
		end
	end)

	it("shows other channel talk only at level chan or all", function()
		assert.is_false(cli.shown(ev("chan", "a", "#x", "t")))
		assert.is_true(cli.shown(ev("chan", "a", "#x", "t"), "chan"))
		assert.is_true(cli.shown(ev("chan", "a", "#x", "t"), "all"))
		assert.is_false(cli.shown(ev("join", "a", "#x", ""), "chan"))
	end)

	it("shows the connection coming and going, not other info", function()
		assert.is_true(cli.shown(ev("info", "-", "-", "connected to h as n")))
		assert.is_true(cli.shown(ev("info", "-", "-", "disconnected: x")))
		assert.is_true(cli.shown(ev("info", "-", "-", "exit")))
		assert.is_false(cli.shown(ev("info", "-", "-", "queued until connected: msg")))
	end)

	it("hides presence churn unless asked", function()
		for _, k in ipairs { "join", "part", "quit", "nick", "online", "offline" } do
			assert.is_false(cli.shown(ev(k, "a", "#x", "")), k)
			assert.is_true(cli.shown(ev(k, "a", "#x", ""), "all"), k)
		end
	end)
end)

describe("cli.read", function()
	it("prints the last N shown events", function()
		local dir = os.tmpname()

		os.remove(dir)
		os.execute("mkdir -p " .. dir .. "/n")

		local f = assert(io.open(dir .. "/n/out", "w"))

		for i = 1, 5 do
			f:write(ev("chan", "a", "#x", "m" .. i), "\n")
			f:write(ev("join", "b", "#x", ""), "\n")
		end
		f:write("partial line with no newline")
		f:close()

		local got = {}
		local real = io.stdout

		io.stdout = { write = function(_, ...)
			got[#got + 1] = table.concat({ ... })
		end, flush = function() end }
		cli.read({ dir = dir }, "n", 2, "chan")
		io.stdout = real
		os.execute("rm -rf " .. dir)

		assert.equal(2, #got)
		assert.matches("m4\n$", got[1])
		assert.matches("m5\n$", got[2])
	end)
end)

describe("cli.classify", function()
	local cfg = { owners = { "mischief" }, broadcast = { "all", "agents" } }
	local function k(text, from, isdm)
		return cli.classify(text, "grug", from or "mcc", isdm, cfg)
	end

	it("dm first, then a mention, then owner, then broadcast", function()
		assert.equal("dm", k("all: hi", "mischief", true))
		assert.equal("mention", k("GRUG: look", "mischief"))
		assert.equal("owner", k("hello babies", "Mischief"))
		assert.equal("broadcast", k("all: restart at 6", "mcc"))
		assert.equal("broadcast", k("  Agents, stop", "mcc"))
		assert.equal("chan", k("mcc: done", "bitbake"))
	end)

	it("wants the keyword as the first word", function()
		assert.equal("chan", k("not all: of it", "mcc"))
		assert.equal("chan", k("allright: fine", "mcc"))
	end)
end)
