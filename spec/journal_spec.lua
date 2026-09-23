-- ircagent/journal.lua: sequence numbers survive a reopen, a torn tail
-- is cut, damage starts a new epoch, and rotation keeps two files.

require "spec.helper"
local journal = require "ircagent.journal"

local function tmpdir()
	local p = os.tmpname()

	os.remove(p)
	os.execute("mkdir -m 700 " .. p)
	return p
end

local function ev(i, kind)
	return { kind = kind or "dm", from = "a", target = "b", text = "t" .. i, time = i }
end

local function slurp(p)
	local f = assert(io.open(p, "rb"))
	local d = f:read("a")

	f:close()
	return d
end

local function spit(p, d)
	local f = assert(io.open(p, "wb"))

	f:write(d)
	f:close()
end

describe("journal", function()
	local dir

	before_each(function()
		dir = tmpdir()
	end)

	after_each(function()
		os.execute("rm -rf " .. dir)
	end)

	it("numbers events from 1 and keeps counting after a reopen", function()
		local j = journal.open(dir)

		assert.equal(1, j:append(ev(1)))
		assert.equal(2, j:append(ev(2)))
		j:close()

		local k = journal.open(dir)

		assert.equal(j.epoch, k.epoch)
		assert.equal(1, k:oldest())
		assert.equal(2, k:newest())
		assert.equal(3, k:append(ev(3)))
		assert.equal("t2", k:after(1, function() return true end).ev.text)
		k:close()
	end)

	it("finds the first wanted event past a sequence", function()
		local j = journal.open(dir)

		for i = 1, 10 do
			j:append(ev(i, i % 3 == 0 and "dm" or "chan"))
		end

		local r = j:after(3, function(e) return e.kind == "dm" end)

		assert.equal(6, r.seq)
		assert.is_nil(j:after(9, function(e) return e.kind == "dm" end))
		j:close()
	end)

	it("drops a torn last record and reuses its number", function()
		local j = journal.open(dir)

		j:append(ev(1))
		j:append(ev(2))
		j:close()

		local d = slurp(dir .. "/events")

		spit(dir .. "/events", d:sub(1, -5))

		local k = journal.open(dir)

		assert.equal(j.epoch, k.epoch)
		assert.equal(1, k:newest())
		assert.equal(2, k:append(ev(2)))
		k:close()
		assert.equal(3, #journal.scan(slurp(dir .. "/events")) + 1)
	end)

	it("starts a new epoch when a record before the end is damaged", function()
		local j = journal.open(dir)

		j:append(ev(1))
		j:append(ev(2))
		j:close()

		local d = slurp(dir .. "/events")

		spit(dir .. "/events", d:sub(1, 20) .. "X" .. d:sub(22))

		local k = journal.open(dir)

		assert.are_not.equal(j.epoch, k.epoch)
		assert.truthy(k.reset)
		assert.equal(0, k:newest())
		k:close()
	end)

	it("starts a new epoch when the event files are gone", function()
		local j = journal.open(dir)

		j:append(ev(1))
		j:close()
		os.remove(dir .. "/events")

		local k = journal.open(dir)

		assert.are_not.equal(j.epoch, k.epoch)
		assert.equal(1, k:append(ev(1)))
		k:close()
	end)

	it("rotates into events.1 and drops the oldest file", function()
		local lv = { default = function(e) return e.kind == "dm" end,
		    chan = function() return true end }
		local j = journal.open(dir, { max = 200, levels = lv })

		for i = 1, 40 do
			j:append(ev(i, i == 2 and "dm" or "chan"))
		end
		assert.truthy(io.open(dir .. "/events.1"))
		assert.is_true(j:oldest() > 2)

		-- the dropped dm makes a cursor before it a gap at its level
		assert.is_true(j:gap(1, "default"))
		-- past the dropped dm, nothing wanted is lost
		assert.is_false(j:gap(2, "default"))
		assert.is_true(j:gap(2, "chan"))
		assert.is_false(j:gap(40, "default"))
		assert.is_true(j:gap(41, "default"))
		j:close()

		local k = journal.open(dir, { max = 200, levels = lv })

		assert.equal(j:oldest(), k:oldest())
		assert.equal(40, k:newest())
		-- after a reopen, what rotated out before is unknown
		assert.is_true(k:gap(2, "default"))
		k:close()
	end)
end)
