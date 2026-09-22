-- ircagent/probe.lua: challenge, sealed answer, verdict.

require "spec.helper"
local probe = require "ircagent.probe"

local KEY = ("k"):rep(32)

describe("probe", function()
	it("says ok when the other side holds the key", function()
		local a, b = probe.new(KEY), probe.new(KEY)
		local token = a:ask("bob", 0)
		local body = b:reply("bob", "alice", token)

		assert.equal("ok", a:result("alice", "BOB", body, 1))
		assert.equal("ok", a.known.bob)
		assert.is_false(a:pending_for("bob"))
	end)

	it("says wrong key when the answer does not open", function()
		local a, b = probe.new(KEY), probe.new(("x"):rep(32))
		local token = a:ask("bob", 0)

		assert.equal("wrong key", a:result("alice", "bob", b:reply("bob", "alice", token), 1))
	end)

	it("refuses an answer to another probe, or from another nick", function()
		local a, b = probe.new(KEY), probe.new(KEY)
		local old = b:reply("bob", "alice", a:ask("bob", 0))

		a:result("alice", "bob", old, 1)
		a:ask("bob", 2)
		assert.equal("wrong key", a:result("alice", "bob", old, 3))

		local t = a:ask("carol", 4)

		assert.equal("wrong key", a:result("alice", "carol", b:reply("bob", "alice", t), 5))
	end)

	it("ignores answers nobody asked for", function()
		assert.is_nil(probe.new(KEY):result("alice", "bob", "x", 0))
	end)

	it("gives up after the timeout", function()
		local a = probe.new(KEY)

		a:ask("bob", 0)
		assert.same({}, a:expire(1))
		assert.same({ { nick = "bob", result = "no answer" } }, a:expire(probe.TIMEOUT))
		assert.equal("no answer", a.known.bob)
	end)

	it("will not answer junk tokens", function()
		local b = probe.new(KEY)

		assert.is_nil(b:reply("bob", "alice", "short"))
		assert.is_nil(b:reply("bob", "alice", ("a"):rep(20) .. " x"))
		assert.is_nil(b:reply("bob", "alice", nil))
	end)
end)
