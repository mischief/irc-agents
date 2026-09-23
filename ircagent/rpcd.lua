-- rpcd: the daemon's side of rpc. A unix socket beside the other state
-- files; each client says hello, then asks for the next event past its
-- cursor. A request with nothing to answer waits for a later event.
-- The daemon's poll loop drives it: pollfds() before poll, service()
-- after, notify() after each journal append.

local socket = require "posix.sys.socket"
local fcntl = require "posix.fcntl"
local unistd = require "posix.unistd"
local stat = require "posix.sys.stat"
local imsg = require "imsg"

local rpc = require "ircagent.rpc"

local M = {}

M.MAXCLIENTS = 32
-- a client that leaves more than this many replies unread is dropped
M.MAXQUEUE = 4

local S = {}

S.__index = S

local function nonblock(fd)
	local fl = fcntl.fcntl(fd, fcntl.F_GETFL)

	return fcntl.fcntl(fd, fcntl.F_SETFL, fl | fcntl.O_NONBLOCK)
end

-- new{ path, nick, journal, want = function(ev, level) }
function M.new(o)
	os.remove(o.path)

	local fd = assert(socket.socket(socket.AF_UNIX, socket.SOCK_STREAM, 0))
	local ok, err = socket.bind(fd, { family = socket.AF_UNIX, path = o.path })

	if not ok then
		unistd.close(fd)
		return nil, "bind " .. o.path .. ": " .. tostring(err)
	end
	stat.chmod(o.path, tonumber("600", 8))
	assert(socket.listen(fd, 8))
	nonblock(fd)
	return setmetatable({
		path = o.path, nick = o.nick, j = o.journal, want = o.want,
		fd = fd, clients = {},
	}, S)
end

function S:drop(c)
	if self.clients[c.fd] then
		self.clients[c.fd] = nil
		c.buf:close(true)
	end
end

local function send(self, c, typ, id, payload)
	local ok = pcall(c.buf.compose, c.buf, typ, id, 0, -1, payload)

	if not ok or c.buf:queuelen() > M.MAXQUEUE then
		return self:drop(c)
	end
	if not pcall(c.buf.write, c.buf) then
		self:drop(c)
	end
end

local function fail(self, c, id, code, seq, text)
	send(self, c, rpc.T.ERROR, id, rpc.header(code, seq, text))
	c.closing = true
end

-- answer c's waiting request if the journal has what it wants
local function deliver(self, c)
	local w = c.waiting

	if not w then
		return
	end

	local j = self.j

	if j.failed then
		return fail(self, c, w.id, rpc.E.JOURNAL, 0, j.failed)
	end
	if j:gap(w.seq, w.level) then
		return fail(self, c, w.id, rpc.E.RESET, j:oldest(),
		    ("events after %d are gone; oldest is %d"):format(w.seq, j:oldest()))
	end

	local r = j:after(w.seq, function(ev)
		return self.want(ev, w.level)
	end)

	if r then
		c.waiting = nil
		send(self, c, rpc.T.EVENT, w.id,
		    rpc.header(rpc.OP[rpc.T.EVENT], r.seq, rpc.event(r.ev)))
	end
end

local function handle(self, c, m)
	local typ, id = m:type(), m:id()
	local p, code, why = rpc.decode(typ, m:data())

	if not p then
		return fail(self, c, id, code, 0, why)
	end
	if typ == rpc.T.HELLO then
		local h = rpc.unhello(p.body)
		local j = self.j

		if not h then
			return fail(self, c, id, rpc.E.MALFORMED, 0, "bad hello")
		end
		if h.nick ~= self.nick then
			return fail(self, c, id, rpc.E.NICK, 0, "this is " .. self.nick)
		end
		if h.epoch ~= "" and h.epoch ~= j.epoch then
			return fail(self, c, id, rpc.E.RESET, j:oldest(), "journal epoch changed")
		end
		c.hello = h
		return send(self, c, rpc.T.HELLO, id, rpc.header(rpc.OP[rpc.T.HELLO],
		    j:newest(), rpc.hellor(j.epoch, j:oldest(), j:newest())))
	end
	if not c.hello then
		return fail(self, c, id, rpc.E.STATE, 0, "hello first")
	end
	if typ == rpc.T.NEXT then
		local level = rpc.unnext(p.body)

		if not level then
			return fail(self, c, id, rpc.E.MALFORMED, 0, "bad next")
		end
		c.waiting = { id = id, seq = p.seq, level = level }
		return deliver(self, c)
	end
	if typ == rpc.T.ACK then
		c.acked = p.seq
		return
	end
	if typ == rpc.T.CONTROL then
		return fail(self, c, id, rpc.E.DISABLED, 0, "control is disabled")
	end
	return fail(self, c, id, rpc.E.MALFORMED, 0, "unexpected type " .. typ)
end

local function accept(self)
	while true do
		local fd = socket.accept(self.fd)

		if not fd then
			return
		end
		if #self:list() >= M.MAXCLIENTS then
			unistd.close(fd)
		else
			nonblock(fd)

			local buf = imsg.new(fd)

			buf:set_maxsize(rpc.MAXMSG)
			self.clients[fd] = { fd = fd, buf = buf }
		end
	end
end

local function readable(self, c)
	local ok, got = pcall(c.buf.read, c.buf)

	if not ok or not got then
		return self:drop(c)
	end
	while self.clients[c.fd] and not c.closing do
		local gok, m = pcall(c.buf.get, c.buf)

		if not gok then
			return fail(self, c, 0, rpc.E.MALFORMED, 0, "bad imsg")
		end
		if not m then
			return
		end
		handle(self, c, m)
	end
end

function S:list()
	local t = {}

	for _, c in pairs(self.clients) do
		t[#t + 1] = c
	end
	return t
end

function S:pollfds(fds)
	fds[self.fd] = { events = { IN = true } }
	for fd, c in pairs(self.clients) do
		fds[fd] = { events = { IN = true, OUT = c.buf:queuelen() > 0 } }
	end
end

function S:service(fds)
	local r = fds[self.fd] and fds[self.fd].revents

	if r and r.IN then
		accept(self)
	end
	for _, c in ipairs(self:list()) do
		local rv = fds[c.fd] and fds[c.fd].revents

		if rv and (rv.IN or rv.HUP or rv.ERR) then
			readable(self, c)
		end
		if self.clients[c.fd] and rv and rv.OUT then
			if not pcall(c.buf.write, c.buf) then
				self:drop(c)
			end
		end
		if self.clients[c.fd] and c.closing and c.buf:queuelen() == 0 then
			self:drop(c)
		end
	end
end

-- a new event is in the journal
function S:notify()
	for _, c in ipairs(self:list()) do
		if not c.closing then
			deliver(self, c)
		end
	end
end

function S:close()
	for _, c in ipairs(self:list()) do
		self:drop(c)
	end
	unistd.close(self.fd)
	os.remove(self.path)
end

return M
