-- rpcc: the client side of rpc, and "watch NICK --once". The cursor
-- file holds the epoch and sequence of the last event printed. It moves
-- only after the event is on stdout, so a failed print repeats it.

local socket = require "posix.sys.socket"
local unistd = require "posix.unistd"
local stat = require "posix.sys.stat"
local signal = require "posix.signal"
local imsg = require "imsg"

local rpc = require "ircagent.rpc"
local journal = require "ircagent.journal"

local M = {}

-- seconds to keep trying the socket after a daemon goes away mid-wait
M.RECONNECT = 30

function M.paths(cfg, nick, consumer)
	local d = cfg.dir .. "/" .. nick

	return { dir = d, rpc = d .. "/rpc",
	    cursor = d .. "/watch/" .. consumer .. ".cursor" }
end

function M.loadcursor(path)
	local f = io.open(path, "r")

	if not f then
		return nil
	end

	local epoch, seq = (f:read("a") or ""):match("^(%x+) (%d+)\n$")

	f:close()
	return epoch and { epoch = epoch, seq = math.tointeger(tonumber(seq)) } or nil
end

function M.savecursor(path, cur)
	return journal.writeatomic(path, ("%s %d\n"):format(cur.epoch, cur.seq))
end

-- the socket must be ours and closed to everyone else
local function checkowner(path)
	local st = stat.stat(path)

	if not st then
		return nil, "missing"
	end
	if stat.S_ISSOCK(st.st_mode) == 0 then
		return nil, path .. " is not a socket"
	end
	if st.st_uid ~= unistd.getuid() or st.st_mode & tonumber("077", 8) ~= 0 then
		return nil, path .. " is not private to this user"
	end
	return true
end

local C = {}

C.__index = C

function M.connect(path)
	local ok, err = checkowner(path)

	if not ok then
		return nil, err
	end

	local fd = assert(socket.socket(socket.AF_UNIX, socket.SOCK_STREAM, 0))
	local cok, cerr = socket.connect(fd, { family = socket.AF_UNIX, path = path })

	if not cok then
		unistd.close(fd)
		return nil, "connect " .. path .. ": " .. tostring(cerr)
	end

	local buf = imsg.new(fd)

	buf:set_maxsize(rpc.MAXMSG)
	return setmetatable({ buf = buf, id = 0 }, C)
end

function C:close()
	self.buf:close(true)
end

function C:send(typ, opcode, seq, body)
	self.id = self.id + 1
	self.buf:compose(typ, self.id, 0, -1, rpc.header(opcode, seq, body))
	self.buf:flush()
	return self.id
end

-- recv() -> type, decoded payload; nil, "closed" at EOF
function C:recv()
	while true do
		local m = self.buf:get()

		if m then
			local p, _, why = rpc.decode(m:type(), m:data())

			if not p then
				return nil, "bad reply: " .. why
			end
			return m:type(), p
		end
		if not self.buf:read() then
			return nil, "closed"
		end
	end
end

-- call(): send, then wait for the reply; errors become nil, message
function C:call(typ, seq, body)
	local ok, err = pcall(self.send, self, typ, rpc.OP[typ], seq, body)

	if not ok then
		return nil, tostring(err)
	end

	local rok, rtyp, p = pcall(self.recv, self)

	if not rok then
		return nil, tostring(rtyp)
	end
	if not rtyp then
		return nil, p
	end
	if rtyp == rpc.T.ERROR then
		return nil, p.body, p
	end
	return rtyp, p
end

local function gapmsg(nick, e)
	return ("gap: events were lost (%s); oldest kept is %d.\n" ..
	    "  see what is left: irc-agent read %s 50\n" ..
	    "  then skip to now: irc-agent watch %s --reset"):format(
	    e.body, e.seq, nick, nick)
end

local function sleep(s)
	require("posix.poll").poll({}, math.floor(s * 1000))
end

-- once(cfg, nick, opts) -> true, or nil and error. opts: consumer,
-- level, reset, pid (function: is the daemon alive).
function M.once(cfg, nick, opts)
	local p = M.paths(cfg, nick, opts.consumer or "default")
	local level = opts.level or "default"
	local cur = M.loadcursor(p.cursor)
	local deadline

	-- a daemon that exits mid-write is an error to report, not a kill
	signal.signal(signal.SIGPIPE, signal.SIG_IGN)
	stat.mkdir(p.dir .. "/watch", tonumber("700", 8))
	while true do
		local c, err = M.connect(p.rpc)

		if not c then
			if err ~= "missing" and not err:find("^connect ") then
				return nil, err
			end
			if not deadline then
				if not opts.pid() then
					return nil, nick .. " is not running; start it: irc-agent start " .. nick
				end
				if err == "missing" then
					return nil, nick .. " has no rpc socket; the daemon is too old: " ..
					    "irc-agent stop " .. nick .. "; irc-agent start " .. nick
				end
				deadline = os.time() + M.RECONNECT
			end
			if os.time() > deadline then
				return nil, "lost the daemon: " .. err
			end
			sleep(1)
		else
			local typ, h, e = c:call(rpc.T.HELLO, cur and cur.seq or 0,
			    rpc.hello(nick, level, cur and cur.epoch))

			if not typ then
				c:close()
				if e and e.opcode == rpc.E.RESET and not opts.reset then
					return nil, gapmsg(nick, e)
				end
				if not e or opts.reset then
					if e then
						cur = nil
					end
					deadline = deadline or os.time() + M.RECONNECT
					goto retry
				end
				return nil, "hello: " .. h
			end

			local r = rpc.unhellor(h.body)

			if not r then
				c:close()
				return nil, "bad hello reply"
			end
			if opts.reset or not cur then
				cur = { epoch = r.epoch, seq = r.newest }

				local ok, serr = M.savecursor(p.cursor, cur)

				if not ok then
					c:close()
					return nil, serr
				end
				if opts.reset then
					c:close()
					io.stdout:write(("%s: cursor at %d\n"):format(nick, r.newest))
					return true
				end
			end

			local ntyp, ev, ne = c:call(rpc.T.NEXT, cur.seq, rpc.next(level))

			if ntyp == rpc.T.EVENT then
				local d = rpc.unevent(ev.body)

				if not d then
					c:close()
					return nil, "bad event"
				end
				if not (io.stdout:write(rpc.format(d), "\n") and io.stdout:flush()) then
					c:close()
					return nil, "cannot write the event"
				end

				local ok, serr = M.savecursor(p.cursor, { epoch = r.epoch, seq = ev.seq })

				pcall(c.send, c, rpc.T.ACK, rpc.OP[rpc.T.ACK], ev.seq)
				c:close()
				if not ok then
					return nil, "event printed, cursor not saved: " .. tostring(serr)
				end
				return true
			end
			c:close()
			if ne and ne.opcode == rpc.E.RESET then
				return nil, gapmsg(nick, ne)
			end
			if ne then
				return nil, rpc.ENAME[ne.opcode] .. ": " .. ev
			end
			if ntyp then
				return nil, "unexpected reply type " .. ntyp
			end
			-- the daemon went away while we waited: try again
			deadline = os.time() + M.RECONNECT
		end
		::retry::
	end
end

return M
