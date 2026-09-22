-- ircagent/config.lua: defaults, file, flags, in that order of weight.

require "spec.helper"
local config = require "ircagent.config"

local function tmpfile(body)
	local p = os.tmpname()
	local f = assert(io.open(p, "w"))

	f:write(body)
	f:close()
	return p
end

describe("config", function()
	it("has defaults that reach the house server", function()
		local c = config.load({ "-f", "/nonexistent/x.lua", "me" })

		assert.equal("irc.offblast.org", c.server)
		assert.equal(6667, c.port)
		assert.same({ "#agents" }, c.channels)
		assert.matches("/ircagents/key$", c.key_file)
	end)

	it("lets the file override defaults and flags override the file",
	    function()
		local p = tmpfile([[return { port = 7000, server = "x.example",
		    key_file = "~/k" }]])
		local c, pos = config.load({ "-f", p, "-p7001",
		    "-c", "#a", "-c", "#b", "bot", "-x" })

		os.remove(p)
		assert.equal(7001, c.port)
		assert.equal("x.example", c.server)
		assert.same({ "#a", "#b" }, c.channels)
		assert.equal(os.getenv("HOME") .. "/k", c.key_file)
		-- flags stop at the first operand
		assert.same({ "bot", "-x" }, pos)
	end)

	it("refuses unknown flags and bad files", function()
		assert.has_error(function() config.args({ "-z" }) end)
		assert.has_error(function() config.args({ "-p", "x" }) end)
		assert.has_error(function() config.args({ "-s" }) end)

		local p = tmpfile("return 1")

		assert.has_error(function() config.file(p) end)
		os.remove(p)
	end)

	it("takes --help as -h", function()
		assert.is_true(config.args({ "--help" }).help)
		assert.is_true(config.args({ "-h" }).help)
	end)

	it("gives the file no globals", function()
		local p = tmpfile("return { x = os and 1 or 2 }")

		assert.equal(2, config.file(p).x)
		os.remove(p)
	end)
end)
