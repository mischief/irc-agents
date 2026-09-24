-- ircagent/rpc.lua: payload encode and decode, and imsg framing over a
-- socketpair.

require "spec.helper"
local rpc = require "ircagent.rpc"

describe("rpc.decode", function()
	it("round-trips a header and body", function()
		local p = rpc.header(1, 42, "body")
		local d = assert(rpc.decode(rpc.T.NEXT, p))

		assert.equal(1, d.opcode)
		assert.equal(42, d.seq)
		assert.equal("body", d.body)
	end)

	it("rejects an unknown version", function()
		local p = rpc.header(1, 0, "")
		local bad = string.char(9) .. p:sub(2)
		local d, code = rpc.decode(rpc.T.NEXT, bad)

		assert.is_nil(d)
		assert.equal(rpc.E.VERSION, code)
	end)

	it("rejects a bad opcode, flags, length and trailing bytes", function()
		local function code(typ, p)
			return select(2, rpc.decode(typ, p))
		end

		assert.equal(rpc.E.MALFORMED, code(rpc.T.NEXT, rpc.header(9, 0, "")))
		assert.equal(rpc.E.MALFORMED, code(rpc.T.NEXT, rpc.header(1, 0, "", 1)))
		assert.equal(rpc.E.MALFORMED, code(rpc.T.NEXT, rpc.header(1, 0, "x") .. "y"))
		assert.equal(rpc.E.MALFORMED, code(rpc.T.NEXT, rpc.header(1, 0, "xy"):sub(1, -2)))
		assert.equal(rpc.E.MALFORMED, code(rpc.T.NEXT, "short"))
		assert.equal(rpc.E.MALFORMED, code(rpc.T.ERROR, rpc.header(200, 0, "")))
	end)

	it("takes an error code as the opcode of an error", function()
		local d = assert(rpc.decode(rpc.T.ERROR, rpc.header(rpc.E.RESET, 7, "gone")))

		assert.equal(rpc.E.RESET, d.opcode)
		assert.equal(7, d.seq)
	end)
end)

describe("rpc bodies", function()
	it("round-trips an event, long multiline text included", function()
		local text = ("line\n"):rep(20000)
		local ev = { kind = "dm", from = "a", target = "b", text = text, time = 1767322800 }
		local d = assert(rpc.unevent(rpc.event(ev)))

		assert.same(ev, d)
	end)

	it("rejects an event with trailing bytes or no kind", function()
		local b = rpc.event { kind = "dm", text = "x", time = 1 }

		assert.is_nil(rpc.unevent(b .. "z"))
		assert.is_nil(rpc.unevent(b:sub(1, -2)))
		assert.is_nil(rpc.unevent(rpc.event { kind = "", time = 1 }))
	end)

	it("formats an event as the out line", function()
		local l = rpc.format { kind = "mention", from = "m", target = "#a",
		    text = "a\\b\nc\1", time = 0 }

		assert.equal("1970-01-01T00:00:00Z mention m #a a\\\\b\\nc", l)
	end)

	it("round-trips hello, its reply and next", function()
		assert.same({ nick = "clod", level = "chan", epoch = "ab" },
		    rpc.unhello(rpc.hello("clod", "chan", "ab")))
		assert.same({ epoch = "ab", oldest = 3, newest = 9 },
		    rpc.unhellor(rpc.hellor("ab", 3, 9)))
		assert.equal("all", rpc.unnext(rpc.next("all")))
		assert.is_nil(rpc.unhello(rpc.hello("clod", "loud")))
		assert.is_nil(rpc.unnext(rpc.next("loud")))
	end)
end)

describe("rpc over imsg", function()
	it("carries type, id and a payload over the imsg limit", function()
		local socket = require "posix.sys.socket"
		local imsg = require "imsg"
		local fcntl = require "posix.fcntl"
		local a, b = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM, 0)

		for _, fd in ipairs { a, b } do
			fcntl.fcntl(fd, fcntl.F_SETFL, fcntl.fcntl(fd, fcntl.F_GETFL) | fcntl.O_NONBLOCK)
		end

		local ba, bb = imsg.new(a), imsg.new(b)

		ba:set_maxsize(rpc.MAXMSG)
		bb:set_maxsize(rpc.MAXMSG)

		local body = rpc.event { kind = "dm", text = ("x"):rep(100000), time = 5 }
		local p = rpc.header(rpc.OP[rpc.T.EVENT], 11, body)

		ba:compose(rpc.T.EVENT, 77, 0, -1, p)

		local m

		-- the socket buffer is smaller than the message: write and
		-- read in turn
		while not m do
			if ba:queuelen() > 0 then
				ba:write()
			end
			bb:read()
			m = bb:get()
		end
		assert.equal(rpc.T.EVENT, m:type())
		assert.equal(77, m:id())

		local d = assert(rpc.decode(m:type(), m:data()))

		assert.equal(11, d.seq)
		assert.equal(100000, #rpc.unevent(d.body).text)
		ba:close(true)
		bb:close(true)
	end)
end)

describe("rpc control", function()
	it("round-trips a send and refuses an empty target", function()
		local r = rpc.uncontrol(rpc.control("send", "#agents", "a\nb"))

		assert.same({ cmd = "send", target = "#agents", text = "a\nb" }, r)
		assert.is_nil(rpc.uncontrol(rpc.control("send", "", "x")))
		assert.is_nil(rpc.uncontrol("status"))
	end)
end)
