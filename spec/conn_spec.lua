-- ircagent/conn.lua: connection ids, meta, and name resolution.

require "spec.helper"
local conn = require "ircagent.conn"
local unistd = require "posix.unistd"

local LIVE, DEAD = unistd.getpid(), 999999999

local function tmpcfg()
	local p = os.tmpname()

	os.remove(p)
	os.execute("mkdir -m 700 " .. p)
	return { dir = p }
end

-- add(cfg, id, meta, pid, held): a connection directory
local function add(cfg, id, m, pid, held)
	os.execute("mkdir -m 700 " .. conn.dir(cfg, id))
	if m then
		assert(conn.setmeta(cfg, id, m))
	end
	if pid then
		local f = assert(io.open(conn.dir(cfg, id) .. "/pid", "w"))

		f:write(pid, "\n")
		f:close()
	end
	if held then
		local f = assert(io.open(conn.dir(cfg, id) .. "/nick", "w"))

		f:write(held, "\n")
		f:close()
	end
end

describe("conn", function()
	it("makes ids that are valid nicks", function()
		for _ = 1, 50 do
			local id = conn.newid()

			assert.is_true(conn.validnick(id))
			assert.is_true(conn.validid(id))
		end
	end)

	it("refuses ids that are not one path name", function()
		assert.is_false(conn.validid("../x"))
		assert.is_false(conn.validid("a/b"))
		assert.is_false(conn.validid(".x"))
		assert.is_false(conn.validid(""))
	end)

	it("reads a directory without meta as id, label and nick", function()
		local cfg = tmpcfg()

		add(cfg, "grug", nil, LIVE)
		assert.same({ id = "grug", label = "grug", nick = "grug" }, conn.meta(cfg, "grug"))
		assert.equal("grug", conn.resolve(cfg, "grug"))
	end)

	it("resolves an id, a label, the nick held and the nick wanted", function()
		local cfg = tmpcfg()

		add(cfg, "k3x9q2", { label = "clm:85e0", nick = "mccbuild" }, LIVE, "mccbld2")
		assert.equal("k3x9q2", conn.resolve(cfg, "k3x9q2"))
		assert.equal("k3x9q2", conn.resolve(cfg, "clm:85e0"))
		assert.equal("k3x9q2", conn.resolve(cfg, "MCCBLD2"))
		assert.equal("k3x9q2", conn.resolve(cfg, "mccbuild"))

		local id, err = conn.resolve(cfg, "nobody")

		assert.is_nil(id)
		assert.matches("no connection named nobody", err)
	end)

	it("prefers a live connection over a dead one", function()
		local cfg = tmpcfg()

		add(cfg, "mcc", nil, DEAD)
		add(cfg, "a11111", { label = "x", nick = "mcc" }, LIVE, "mcc")
		assert.equal("a11111", conn.resolve(cfg, "mcc"))
		assert.equal("mcc", conn.bylabel(cfg, "mcc"))
	end)

	it("refuses a name that fits two live connections", function()
		local cfg = tmpcfg()

		add(cfg, "a11111", { label = "l", nick = "grug" }, LIVE)
		add(cfg, "b22222", { label = "l", nick = "bob" }, LIVE)

		local id, err = conn.resolve(cfg, "l")

		assert.is_nil(id)
		assert.matches("a11111 b22222", err)
	end)

	it("finds a dead connection by label, to reuse its directory", function()
		local cfg = tmpcfg()

		add(cfg, "a11111", { label = "clm:s1", nick = "grug" }, DEAD)
		assert.equal("a11111", conn.bylabel(cfg, "clm:s1"))
		assert.is_nil(conn.bylabel(cfg, "clm:s2"))
	end)
end)
