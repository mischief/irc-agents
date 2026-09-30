-- ircagent/mcp: the irc_join tool, with the daemon faked.

require "spec.helper"
local mcp = require "ircagent.mcp"
local json = require "mcptk.json"

local function tmpcfg()
	local p = os.tmpname()

	os.remove(p)
	os.execute("mkdir -m 700 " .. p)
	return { dir = p }
end

local function call(srv, name, args)
	local line = json.encode { jsonrpc = "2.0", id = 1, method = "tools/call",
	    params = { name = name, arguments = args } }

	return json.decode(srv:handle_line(line)).result
end

describe("mcp", function()
	local spawned, exited

	local function fake(cfg)
		spawned, exited = {}, false
		return mcp.new(cfg, {
			settle = 0,
			spawn = function(_, nick, id)
				local h = { nick = nick, id = id }

				spawned[#spawned + 1] = h
				return h
			end,
			gone = function() return exited end,
		})
	end

	it("lists irc_join and tells the model to call it first", function()
		local srv = fake(tmpcfg())
		local r = json.decode(srv:handle_line(json.encode {
		    jsonrpc = "2.0", id = 1, method = "tools/list" })).result

		assert.equal(1, #r.tools)
		assert.equal("irc_join", r.tools[1].name)
		assert.truthy(mcp.INSTRUCTIONS:find("irc_join", 1, true))
	end)

	it("starts the daemon once", function()
		local srv = fake(tmpcfg())
		local r = call(srv, "irc_join", { nick = "wrapfix" })

		assert.is_falsy(r.isError)
		assert.equal(1, #spawned)
		assert.equal("wrapfix", spawned[1].nick)

		r = call(srv, "irc_join", { nick = "other" })
		assert.is_true(r.isError)
		assert.equal(1, #spawned)
	end)

	it("refuses a bad nick", function()
		local srv = fake(tmpcfg())
		local r = call(srv, "irc_join", { nick = "9lives" })

		assert.is_true(r.isError)
		assert.equal(0, #spawned)
	end)

	it("reports a daemon that exits at startup", function()
		local srv = mcp.new(tmpcfg(), {
			settle = 0.1,
			spawn = function() return {} end,
			gone = function() return true end,
		})
		local r = call(srv, "irc_join", { nick = "wrapfix" })

		assert.is_true(r.isError)

		-- and it may join again, because nothing is running
		r = call(srv, "irc_join", { nick = "wrapfix" })
		assert.is_true(r.isError)
	end)
end)
