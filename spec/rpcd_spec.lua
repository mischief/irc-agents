-- ircagent/rpcd.lua and ircagent/rpcc.lua: a daemon's rpc socket and
-- "watch --once" against it. The server runs in a child process so the
-- client can block the way it does for real.

require "spec.helper"
local rpc = require "ircagent.rpc"
local rpcd = require "ircagent.rpcd"
local rpcc = require "ircagent.rpcc"
local journal = require "ircagent.journal"
local cli = require "ircagent.cli"
local unistd = require "posix.unistd"
local wait = require "posix.sys.wait"
local poll = require "posix.poll"
local signal = require "posix.signal"
local ptime = require "posix.time"

local NICK = "clod"

local function tmpdir()
	local p = os.tmpname()

	os.remove(p)
	os.execute("mkdir -m 700 " .. p .. " " .. p .. "/" .. NICK .. " " ..
	    p .. "/" .. NICK .. "/watch")
	return p
end

local function clock()
	local t = ptime.clock_gettime(ptime.CLOCK_MONOTONIC)

	return t.tv_sec + t.tv_nsec / 1e9
end

local function want(ev, level)
	return cli.showkind(ev.kind, ev.text, level)
end

local levels = {}

for lv in pairs(rpc.LEVELS) do
	levels[lv] = function(ev) return want(ev, lv) end
end

local function ev(kind, text)
	return { kind = kind, from = "mischief", target = "#agents", text = text, time = 0 }
end

-- a daemon without IRC: the journal and the socket
local function daemon(dir, control)
	local j = journal.open(dir .. "/" .. NICK, { levels = levels })
	local srv = assert(rpcd.new { path = dir .. "/" .. NICK .. "/rpc", nick = NICK,
	    journal = j, want = want, control = control })

	return {
		j = j, srv = srv,
		add = function(kind, text)
			j:append(ev(kind, text))
			srv:notify()
		end,
		pump = function(ms)
			local fds = {}

			srv:pollfds(fds)
			if poll.poll(fds, ms or 0) > 0 then
				srv:service(fds)
			end
		end,
		close = function()
			srv:close()
			j:close()
		end,
	}
end

-- run steps in a child daemon: { { at = seconds, fn = function(d) } }
local function serve(dir, steps, limit, control)
	local pid = unistd.fork()

	if pid == 0 then
		local ok = pcall(function()
			local d = daemon(dir, control)
			local t0, i = clock(), 1

			while clock() - t0 < (limit or 3) do
				d.pump(10)
				while steps[i] and clock() - t0 >= steps[i].at do
					d = steps[i].fn(d) or d
					i = i + 1
				end
			end
			d.close()
		end)

		unistd._exit(ok and 0 or 1)
	end
	-- wait for the socket
	for _ = 1, 100 do
		if require("posix.sys.stat").stat(dir .. "/" .. NICK .. "/rpc") then
			break
		end
		poll.poll({}, 10)
	end
	return pid
end

local function reap(pid)
	signal.kill(pid, signal.SIGTERM)
	wait.wait(pid)
end

-- run once() with stdout captured; returns ok, err, output
local function once(dir, opts)
	local cfg = { dir = dir }
	local out = io.tmpfile()
	local saved = io.stdout

	opts = opts or {}
	opts.pid = opts.pid or function() return 1 end
	io.stdout = opts.stdout or out

	local ok, a, b = pcall(rpcc.once, cfg, NICK, opts)

	io.stdout = saved
	out:seek("set")

	local text = out:read("a")

	out:close()
	if not ok then
		error(a)
	end
	return a, b, text
end

local function cursor(dir, consumer)
	return rpcc.loadcursor(dir .. "/" .. NICK .. "/watch/" .. (consumer or "default") .. ".cursor")
end

describe("rpcd in process", function()
	local dir, d

	before_each(function()
		dir = tmpdir()
		d = daemon(dir)
	end)

	after_each(function()
		d.close()
		os.execute("rm -rf " .. dir)
	end)

	local function call(c, typ, seq, body)
		c:send(typ, rpc.OP[typ], seq, body)
		for _ = 1, 50 do
			d.pump(10)
		end

		local rtyp, p = c:recv()

		return rtyp, p
	end

	it("answers hello with the journal range", function()
		d.add("dm", "one")
		d.add("dm", "two")

		local c = assert(rpcc.connect(dir .. "/" .. NICK .. "/rpc"))
		local typ, p = call(c, rpc.T.HELLO, 0, rpc.hello(NICK, "default"))

		assert.equal(rpc.T.HELLO, typ)
		assert.same({ epoch = d.j.epoch, oldest = 1, newest = 2 }, rpc.unhellor(p.body))
		c:close()
	end)

	it("refuses a request before hello, control, and another nick", function()
		local c = assert(rpcc.connect(dir .. "/" .. NICK .. "/rpc"))
		local typ, p = call(c, rpc.T.NEXT, 0, rpc.next("default"))

		assert.equal(rpc.T.ERROR, typ)
		assert.equal(rpc.E.STATE, p.opcode)
		c:close()

		c = assert(rpcc.connect(dir .. "/" .. NICK .. "/rpc"))
		typ, p = call(c, rpc.T.HELLO, 0, rpc.hello("other", "default"))
		assert.equal(rpc.E.NICK, p.opcode)
		c:close()

		c = assert(rpcc.connect(dir .. "/" .. NICK .. "/rpc"))
		call(c, rpc.T.HELLO, 0, rpc.hello(NICK, "default"))
		typ, p = call(c, rpc.T.CONTROL, 0, rpc.control("send", "bob", "hi"))
		assert.equal(rpc.E.DISABLED, p.opcode)
		c:close()
	end)

	it("answers a malformed payload with an error", function()
		local c = assert(rpcc.connect(dir .. "/" .. NICK .. "/rpc"))

		c.buf:compose(rpc.T.HELLO, 1, 0, -1, "junk")
		c.buf:flush()
		for _ = 1, 20 do
			d.pump(10)
		end

		local m

		while not m do
			c.buf:read()
			m = c.buf:get()
		end
		assert.equal(rpc.T.ERROR, m:type())
		assert.equal(rpc.E.MALFORMED, rpc.decode(m:type(), m:data()).opcode)
		c:close()
	end)

	it("skips events below the level and holds until one arrives", function()
		d.add("chan", "noise")

		local c = assert(rpcc.connect(dir .. "/" .. NICK .. "/rpc"))

		call(c, rpc.T.HELLO, 0, rpc.hello(NICK, "default"))
		c:send(rpc.T.NEXT, 1, 0, rpc.next("default"))
		for _ = 1, 10 do
			d.pump(10)
		end
		assert.equal(0, c.buf:readlen())

		d.add("mention", "clod: hi")
		for _ = 1, 10 do
			d.pump(10)
		end

		local typ, p = c:recv()

		assert.equal(rpc.T.EVENT, typ)
		assert.equal(2, p.seq)
		assert.equal("clod: hi", rpc.unevent(p.body).text)
		c:close()
	end)

	it("sends every waiting client the event", function()
		local cs = {}

		for i = 1, 3 do
			cs[i] = assert(rpcc.connect(dir .. "/" .. NICK .. "/rpc"))
			call(cs[i], rpc.T.HELLO, 0, rpc.hello(NICK, "default"))
			cs[i]:send(rpc.T.NEXT, 1, 0, rpc.next("default"))
		end
		for _ = 1, 10 do
			d.pump(10)
		end
		d.add("dm", "all of you")
		for i = 1, 3 do
			local typ, p = cs[i]:recv()

			assert.equal(rpc.T.EVENT, typ)
			assert.equal(1, p.seq)
			cs[i]:close()
		end
	end)

	it("drops a client that never reads", function()
		local fcntl = require "posix.fcntl"
		local c = assert(rpcc.connect(dir .. "/" .. NICK .. "/rpc"))
		local fd = c.buf:fileno()
		local hello = rpc.header(1, 0, rpc.hello(NICK, "default"))

		-- one process plays both ends: the client must not block
		signal.signal(signal.SIGPIPE, signal.SIG_IGN)
		fcntl.fcntl(fd, fcntl.F_SETFL, fcntl.fcntl(fd, fcntl.F_GETFL) | fcntl.O_NONBLOCK)

		for i = 1, 20000 do
			c.buf:compose(rpc.T.HELLO, i, 0, -1, hello)
			if i % 100 == 0 then
				-- fails once the daemon hangs up
				if not pcall(c.buf.write, c.buf) then
					break
				end
				d.pump(0)
			end
		end
		for _ = 1, 50 do
			d.pump(10)
		end
		assert.equal(0, #d.srv:list())
		c:close()
	end)
end)

describe("watch --once", function()
	local dir

	before_each(function()
		dir = tmpdir()
	end)

	after_each(function()
		os.execute("rm -rf " .. dir)
	end)

	it("starts at now, then waits for the next event", function()
		local pid = serve(dir, {
			{ at = 0, fn = function(d) d.add("dm", "old") end },
			{ at = 0.5, fn = function(d) d.add("dm", "new\nline") end },
		})

		poll.poll({}, 100)

		local ok, err, out = once(dir)

		reap(pid)
		assert.is_true(ok, err)
		assert.matches("^%S+ dm mischief #agents new\\nline\n$", out)
		assert.equal(2, cursor(dir).seq)
	end)

	it("resumes from the cursor after a delay", function()
		local pid = serve(dir, {
			{ at = 0, fn = function(d)
				d.add("dm", "one")
				d.add("chan", "skip")
				d.add("dm", "two")
				d.add("mention", "three")
			end },
		})
		local j = journal.open(dir .. "/" .. NICK)
		local epoch = j.epoch

		j:close()
		poll.poll({}, 100)
		assert(rpcc.savecursor(dir .. "/" .. NICK .. "/watch/default.cursor", { epoch = epoch, seq = 1 }))

		local ok, err, out = once(dir)

		assert.is_true(ok, err)
		assert.matches(" dm mischief #agents two\n$", out)
		ok, err, out = once(dir)
		reap(pid)
		assert.is_true(ok, err)
		assert.matches(" mention mischief #agents three\n$", out)
		assert.equal(4, cursor(dir).seq)
	end)

	it("repeats an event whose print failed", function()
		local pid = serve(dir, {
			{ at = 0.3, fn = function(d) d.add("dm", "once") end },
		})
		local ok, err, out = once(dir, { consumer = "a" })
		local bad = io.open("/dev/full", "w")

		assert.is_true(ok, err)
		-- move the cursor back and fail the print
		rpcc.savecursor(dir .. "/" .. NICK .. "/watch/a.cursor",
		    { epoch = cursor(dir, "a").epoch, seq = 0 })
		ok, err = once(dir, { consumer = "a", stdout = bad })
		bad:close()
		assert.is_nil(ok)
		assert.matches("cannot write", err)
		assert.equal(0, cursor(dir, "a").seq)
		ok, err, out = once(dir, { consumer = "a" })
		reap(pid)
		assert.is_true(ok, err)
		assert.matches(" dm mischief #agents once\n$", out)
	end)

	it("reconnects when the daemon restarts mid-wait", function()
		local pid = serve(dir, {
			{ at = 0.3, fn = function(d) d.close() end },
			{ at = 0.8, fn = function() return daemon(dir) end },
			{ at = 1.0, fn = function(d) d.add("dm", "after restart") end },
		})
		local ok, err, out = once(dir)

		reap(pid)
		assert.is_true(ok, err)
		assert.matches(" dm mischief #agents after restart\n$", out)
	end)

	it("reports a gap when the journal epoch changed", function()
		local pid = serve(dir, {}, 1)

		assert(rpcc.savecursor(dir .. "/" .. NICK .. "/watch/default.cursor", { epoch = "0123", seq = 5 }))

		local ok, err = once(dir)

		assert.is_nil(ok)
		assert.matches("^gap: ", err)
		ok, err = once(dir, { reset = true })
		reap(pid)
		assert.is_true(ok, err)
		assert.are_not.equal("0123", cursor(dir).epoch)
	end)

	it("keeps a cursor per consumer", function()
		local pid = serve(dir, {
			{ at = 0.3, fn = function(d) d.add("dm", "x") end },
		})
		local j = journal.open(dir .. "/" .. NICK)
		local epoch = j.epoch

		j:close()
		for _, c in ipairs { "a", "b" } do
			rpcc.savecursor(dir .. "/" .. NICK .. "/watch/" .. c .. ".cursor",
			    { epoch = epoch, seq = 0 })
		end
		for _, c in ipairs { "a", "b" } do
			local ok, err, out = once(dir, { consumer = c })

			assert.is_true(ok, err)
			assert.matches(" dm mischief #agents x\n$", out)
		end
		reap(pid)
	end)

	it("says so when the daemon has no rpc socket", function()
		local ok, err = once(dir)

		assert.is_nil(ok)
		assert.matches("too old", err)
		ok, err = once(dir, { pid = function() return nil end })
		assert.is_nil(ok)
		assert.matches("not running", err)
	end)
end)

describe("send over rpc", function()
	local dir

	before_each(function()
		dir = tmpdir()
	end)

	after_each(function()
		os.execute("rm -rf " .. dir)
	end)

	local function send(target, text, pid)
		return rpcc.send({ dir = dir }, NICK, target, text,
		    pid or function() return 1 end)
	end

	it("waits for the daemon to answer", function()
		local pending

		local pid = serve(dir, {
			{ at = 0.5, fn = function() pending(nil, "sent") end },
		}, 2, function(req, done)
			if req.cmd == "send" and req.target == "bob" and req.text == "hi\nthere" then
				pending = done
			else
				done(rpc.E.UNSENT, "bad request")
			end
		end)
		local t0 = clock()

		assert.is_true(send("bob", "hi\nthere"))
		assert.is_true(clock() - t0 >= 0.4)
		reap(pid)
	end)

	it("returns the daemon's refusal", function()
		local pid = serve(dir, {}, 2, function(req, done)
			done(rpc.E.NOSUCH, req.target .. " is not in #agents")
		end)
		local ok, err = send("bob", "hi")

		assert.is_nil(ok)
		assert.equal("bob is not in #agents", err)
		reap(pid)
	end)

	it("says so when the daemon has no rpc send", function()
		local pid = serve(dir, {}, 2)
		local ok, err = send("bob", "hi")

		assert.is_nil(ok)
		assert.matches("too old", err)
		reap(pid)
		ok, err = send("bob", "hi", function() return nil end)
		assert.is_nil(ok)
		assert.matches("not running", err)
	end)

	it("drops an answer for a client that left", function()
		local pending
		local d = daemon(dir, function(_, done) pending = done end)
		local c = assert(rpcc.connect(dir .. "/" .. NICK .. "/rpc"))

		c:send(rpc.T.HELLO, rpc.OP[rpc.T.HELLO], 0, rpc.hello(NICK, "default"))
		c:send(rpc.T.CONTROL, rpc.OP[rpc.T.CONTROL], 0, rpc.control("send", "bob", "hi"))
		for _ = 1, 20 do
			d.pump(10)
		end
		assert.is_function(pending)
		c:close()
		for _ = 1, 20 do
			d.pump(10)
		end
		assert.equal(0, #d.srv:list())
		pending(nil, "sent")
		d.close()
	end)
end)

describe("watch --once cursor lock", function()
	it("refuses a second run on one cursor, and names the holder", function()
		local path = os.tmpname()
		local r, w = unistd.pipe()
		local pid = unistd.fork()

		if pid == 0 then
			unistd.close(r)
			assert(rpcc.lock(path))
			unistd.write(w, "x")
			unistd.sleep(5)
			os.exit(0)
		end
		unistd.close(w)
		unistd.read(r, 1)

		local fd, err = rpcc.lock(path)

		signal.kill(pid, signal.SIGKILL)
		wait.wait(pid)
		assert.is_nil(fd)
		assert.matches("another watch %-%-once is running on this cursor %(pid " .. pid .. "%)", err)
		assert.truthy(rpcc.lock(path))
		os.remove(path)
	end)
end)
