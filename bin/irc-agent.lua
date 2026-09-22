#!/usr/bin/env lua5.4
-- One agent's standing connection to IRC, as files. ii-shaped:
--
--      irc-agent [flags] nick      run, until killed
--      irc-agent genkey            write a new shared key file
--
--      --server host  --port n  --channel '#c' (repeatable)
--      --key-file p   --dir p   --config p  --realname s
--      --plaintext    --max-age secs
--
-- Defaults come from ircagent/config.lua and ~/.config/ircagents/config.lua.
--
-- Under <dir>/<nick>/:
--
--      in    fifo, one command per line:
--              msg <target> <text>     \n in text is a newline
--              join <#chan>            part <#chan>
--              watch <nick>            unwatch <nick>
--              away [text]             who
--              quit [text]
--      out   log, one event per line, appended, for tail -F:
--              <time> <kind> <from> <target> <text>
--            kinds: dm, mention, chan, plain, bad, online, offline,
--            join, part, quit, nick, error, info. Newlines and
--            backslashes in text are escaped as \n and \\.
--      who   presence snapshot, rewritten on change:
--              <nick> <here|away|online> <#chan,...>
--
-- Every PRIVMSG out is sealed with the shared key (ircagent/box.lua);
-- text too long for a line is split, each piece numbered n/m inside the
-- seal, and put back together on the far side (ircagent/chunk.lua).
-- One connection is held for as long as the process lives: the server
-- throttles fast reconnects, so failures back off rather than retry.

package.path = "./?.lua;./?/init.lua;" .. package.path

local irc = require "ircagent.irc"
local box = require "ircagent.box"
local config = require "ircagent.config"
local chunk = require "ircagent.chunk"

local socket = require "posix.sys.socket"
local poll = require "posix.poll"
local fcntl = require "posix.fcntl"
local unistd = require "posix.unistd"
local stat = require "posix.sys.stat"
local signal = require "posix.signal"
local errno = require "posix.errno"
local ptime = require "posix.time"

local function die(msg)
	io.stderr:write("irc-agent: ", msg, "\n")
	os.exit(1)
end

local ok, cfg, pos = pcall(config.load, arg)

if not ok then
	die(cfg)
end

-- ---- genkey ----

if pos[1] == "genkey" then
	local p = cfg.key_file

	if io.open(p, "r") then
		die(p .. " exists; remove it first")
	end
	os.execute("mkdir -p '" .. p:match("^(.*)/[^/]*$") .. "'")

	local fd = fcntl.open(p, fcntl.O_WRONLY | fcntl.O_CREAT | fcntl.O_EXCL,
	    tonumber("600", 8))

	if not fd then
		die("cannot create " .. p)
	end
	unistd.write(fd, box.genkey() .. "\n")
	unistd.close(fd)
	print(p)
	os.exit(0)
end

local want = pos[1] or die("usage: irc-agent [flags] nick | genkey")

if #want > 9 or not want:match("^[%a%[%]\\`_^{|}][%w%[%]\\`_^{|}-]*$") then
	die("nick must be 1-9 characters, a letter first")
end

local key, kerr = box.loadkey(cfg.key_file)

if not key then
	die(kerr .. "\n  make one: irc-agent genkey, then copy it to every agent")
end

-- ---- files ----

local dir = cfg.dir .. "/" .. want

os.execute("mkdir -p -m 700 '" .. dir .. "'")

local inpath, outpath, whopath = dir .. "/in", dir .. "/out", dir .. "/who"

if not stat.stat(inpath) then
	assert(stat.mkfifo(inpath, tonumber("600", 8)))
end

-- O_RDWR so a writer closing does not hand us EOF forever.
local infd = assert(fcntl.open(inpath, fcntl.O_RDWR | fcntl.O_NONBLOCK))
local out = assert(io.open(outpath, "a"))

out:setvbuf("line")

local function now()
	return ptime.clock_gettime(ptime.CLOCK_MONOTONIC).tv_sec
end

local function esc(s)
	return (tostring(s):gsub("\\", "\\\\"):gsub("\n", "\\n")
	    :gsub("[%z\1-\31\127]", ""))
end

local function emit(kind, from, target, text)
	out:write(("%s %s %s %s %s\n"):format(os.date("!%Y-%m-%dT%H:%M:%SZ"),
	    kind, from or "-", target or "-", esc(text or "")))
end

-- ---- state ----

local S = {
	nick = want,
	registered = false,
	channels = {},  -- lower(chan) -> { name, members = { lower -> nick } }
	away = {},      -- lower(nick) -> true when away
	online = {},    -- lower(nick) -> nick, from MONITOR
	watch = {},     -- lower(nick) -> nick
	seen = {},      -- nonce -> expiry
	lastrx = 0,
	pinged = false,
}

for _, c in ipairs(cfg.channels) do
	S.channels[irc.lower(c)] = { name = c, members = {}, joined = false }
end
for _, n in ipairs(cfg.watch or {}) do
	S.watch[irc.lower(n)] = n
end

local function writewho()
	local rows, byname = {}, {}

	local function add(n, chan)
		local l = irc.lower(n)
		local r = byname[l]

		if not r then
			r = { nick = n, chans = {} }
			byname[l] = r
			rows[#rows + 1] = r
		end
		if chan then
			r.chans[#r.chans + 1] = chan
		end
	end

	for _, c in pairs(S.channels) do
		for _, n in pairs(c.members) do
			add(n, c.name)
		end
	end
	for _, n in pairs(S.online) do
		add(n)
	end
	table.sort(rows, function(a, b) return irc.lower(a.nick) < irc.lower(b.nick) end)

	local tmp = whopath .. ".tmp"
	local f = assert(io.open(tmp, "w"))

	for _, r in ipairs(rows) do
		local l = irc.lower(r.nick)
		local st = S.away[l] and "away" or (#r.chans > 0 and "here" or "online")

		table.sort(r.chans)
		f:write(("%s %s %s\n"):format(r.nick, st,
		    #r.chans > 0 and table.concat(r.chans, ",") or "-"))
	end
	f:close()
	os.rename(tmp, whopath)
end

-- ---- connection ----

local sock
local rd = irc.reader()
local sendq, sendqi = {}, 1
local credit, lastcredit = 5, now()

local function send(line)
	sendq[#sendq + 1] = line
end

-- hybrid excess-flood: a burst of five, then about one line a second.
local function flush()
	local t = now()

	credit = math.min(5, credit + (t - lastcredit))
	lastcredit = t
	while sock and sendqi <= #sendq and credit >= 1 do
		local line = sendq[sendqi]
		local n, err = socket.send(sock, line)

		if not n then
			return nil, err
		end
		if n < #line then
			sendq[sendqi] = line:sub(n + 1)
			return true
		end
		sendq[sendqi] = nil
		sendqi = sendqi + 1
		credit = credit - 1
	end
	if sendqi > #sendq then
		sendq, sendqi = {}, 1
	end
	return true
end

local function connect()
	local addrs, err = socket.getaddrinfo(cfg.server, tostring(cfg.port),
	    { family = socket.AF_UNSPEC, socktype = socket.SOCK_STREAM })

	if not addrs then
		return nil, "resolve " .. cfg.server .. ": " .. tostring(err)
	end
	for _, a in ipairs(addrs) do
		local fd = socket.socket(a.family, socket.SOCK_STREAM, 0)

		if fd then
			local r, cerr = socket.connect(fd, a)

			if r then
				return fd
			end
			err = cerr
			unistd.close(fd)
		end
	end
	return nil, "connect " .. cfg.server .. ": " .. tostring(err)
end

local function hangup(why)
	if sock then
		unistd.close(sock)
	end
	sock = nil
	S.registered = false
	sendq, sendqi = {}, 1
	for _, c in pairs(S.channels) do
		c.members, c.joined = {}, false
	end
	S.online, S.away = {}, {}
	writewho()
	emit("info", "-", "-", "disconnected: " .. why)
end

-- ---- sending messages ----

local asm = chunk.assembler()

-- split, number, seal: see ircagent/chunk.lua.
local function say(target, text)
	local ok, wires = pcall(chunk.seal, key, S.nick, target, text)

	if not ok then
		return emit("error", "-", target, wires)
	end
	for _, w in ipairs(wires) do
		send(irc.privmsg(target, w))
	end
end

local function refreshwho(target)
	-- WHOX: token, nick, flags. H is here, G is gone.
	send(irc.line("WHO", target, "%tnf,42"))
end

local function monitor(op, n)
	send(irc.line("MONITOR", op, n))
end

-- ---- commands from in ----

local cmds = {}

function cmds.msg(rest)
	local target, text = rest:match("^(%S+)%s+(.+)$")

	if not target then
		return emit("error", "-", "-", "usage: msg <target> <text>")
	end
	say(target, (text:gsub("\\n", "\n")))
end

function cmds.join(rest)
	local c = rest:match("^(%S+)")

	if c then
		S.channels[irc.lower(c)] = S.channels[irc.lower(c)] or
		    { name = c, members = {}, joined = false }
		send(irc.join(c))
	end
end

function cmds.part(rest)
	local c = rest:match("^(%S+)")

	if c then
		S.channels[irc.lower(c)] = nil
		send(irc.part(c))
		writewho()
	end
end

function cmds.watch(rest)
	for n in rest:gmatch("%S+") do
		S.watch[irc.lower(n)] = n
		monitor("+", n)
	end
end

function cmds.unwatch(rest)
	for n in rest:gmatch("%S+") do
		S.watch[irc.lower(n)] = nil
		S.online[irc.lower(n)] = nil
		monitor("-", n)
	end
	writewho()
end

function cmds.away(rest)
	if rest ~= "" then
		send(irc.line("AWAY", rest))
	else
		send(irc.line("AWAY"))
	end
end

function cmds.who()
	for _, c in pairs(S.channels) do
		refreshwho(c.name)
	end
	writewho()
end

local quitting

function cmds.quit(rest)
	quitting = rest ~= "" and rest or "bye"
end

local inbuf = ""
local held = {}

local function run(line)
	local verb, rest = line:match("^%s*(%S+)%s*(.-)%s*$")
	local f = verb and cmds[verb:lower()]

	if not f then
		if verb then
			emit("error", "-", "-", "unknown command: " .. verb)
		end
		return
	end
	if sock and S.registered or verb:lower() == "quit" then
		return f(rest)
	end
	-- not connected: hold it for the next connection rather than
	-- dropping it. The agent that wrote it has no way to know.
	if #held >= cfg.queue_max then
		return emit("error", "-", "-", "queue full, dropped: " .. line)
	end
	held[#held + 1] = line
	emit("info", "-", "-", "queued until connected: " .. verb)
end

local function replay()
	local h = held

	held = {}
	for _, line in ipairs(h) do
		run(line)
	end
end

local function readin()
	while true do
		local s = unistd.read(infd, 4096)

		if not s or #s == 0 then
			break
		end
		inbuf = inbuf .. s
	end
	for line in inbuf:gmatch("([^\n]*)\n") do
		run(line)
	end
	inbuf = inbuf:match("[^\n]*$")
end

-- ---- messages from the server ----

local function member(chan, n)
	local c = S.channels[irc.lower(chan)]

	if c then
		c.members[irc.lower(n)] = n
	end
end

local function unmember(chan, n)
	local c = S.channels[irc.lower(chan)]

	if c then
		c.members[irc.lower(n)] = nil
	end
end

local function fresh(nonce, t)
	local wall = os.time()

	for k, exp in pairs(S.seen) do
		if exp < wall then
			S.seen[k] = nil
		end
	end
	if math.abs(wall - t) > cfg.max_age or S.seen[nonce] then
		return false
	end
	S.seen[nonce] = wall + 2 * cfg.max_age
	return true
end

local function privmsg(m)
	local target, text = m.params[1], m.params[2] or ""
	local isdm = irc.same(target, S.nick)

	if irc.isctcp(text) then
		local verb = irc.isctcp(text)

		if verb == "VERSION" and isdm then
			send(irc.notice(m.nick, "\1VERSION irc-agent\1"))
		end
		return
	end

	local kind

	if box.isbox(text) then
		local pt, t, nonce = box.open(key, m.nick, target, text)

		if not pt then
			return emit("bad", m.nick, target, t)
		end
		if not fresh(nonce, t) then
			return emit("bad", m.nick, target, "stale or replayed")
		end

		local whole, why = asm:add(m.nick, target, pt, now())

		if not whole then
			if why then
				emit("bad", m.nick, target, why)
			end
			return
		end
		text = whole
		if isdm then
			kind = "dm"
		elseif irc.lower(text):find(irc.lower(S.nick), 1, true) then
			kind = "mention"
		else
			kind = "chan"
		end
	else
		kind = "plain"
		if not cfg.plaintext then
			text = "(unencrypted, " .. #text .. " bytes, dropped)"
		end
	end
	emit(kind, m.nick, isdm and S.nick or target, text)
end

local numeric = {}

numeric["001"] = function(m)
	S.nick = m.params[1]
	S.registered = true
	emit("info", "-", "-", "connected to " .. cfg.server .. " as " .. S.nick)
	send(irc.line("MODE", S.nick, "+B"))
	for _, c in pairs(S.channels) do
		send(irc.join(c.name))
	end

	local w = {}

	for _, n in pairs(S.watch) do
		w[#w + 1] = n
	end
	if #w > 0 then
		monitor("+", table.concat(w, ","))
	end
	replay()
end

-- nick in use: take the next one that fits in nine.
numeric["433"] = function()
	if S.registered then
		return emit("error", "-", "-", "nick in use")
	end

	local base, n = S.nick:match("^(.-)(%d*)$")

	n = (tonumber(n) or 0) + 1
	S.nick = base:sub(1, 9 - #tostring(n)) .. n
	send(irc.nick(S.nick))
end

-- NAMES
numeric["353"] = function(m)
	for n in (m.params[4] or ""):gmatch("%S+") do
		member(m.params[3], (n:gsub("^[@+%%&~]+", "")))
	end
end

numeric["366"] = function(m)
	writewho()
	refreshwho(m.params[2])
end

-- WHOX reply: me 42 nick flags
numeric["354"] = function(m)
	if m.params[2] == "42" then
		S.away[irc.lower(m.params[3])] = (m.params[4] or ""):find("G") and true or nil
	end
end

numeric["315"] = function()
	writewho()
end

-- MONITOR online / offline: nick!user@host,...
numeric["730"] = function(m)
	for t in (m.params[2] or ""):gmatch("[^,]+") do
		local n = t:match("^[^!]+")

		S.online[irc.lower(n)] = n
		emit("online", n, "-", "")
	end
	writewho()
end

numeric["731"] = function(m)
	for n in (m.params[2] or ""):gmatch("[^,]+") do
		S.online[irc.lower(n)] = nil
		emit("offline", n, "-", "")
	end
	writewho()
end

local function handle(m)
	local c = m.cmd

	if c == "PING" then
		send(irc.pong(m.params[1] or ""))
	elseif c == "PRIVMSG" then
		privmsg(m)
	elseif c == "JOIN" then
		local chan = m.params[1]

		if irc.same(m.nick, S.nick) then
			local ch = S.channels[irc.lower(chan)]

			if ch then
				ch.joined = true
			end
		else
			emit("join", m.nick, chan, "")
		end
		member(chan, m.nick)
		writewho()
	elseif c == "PART" or c == "KICK" then
		local who = c == "KICK" and m.params[2] or m.nick

		unmember(m.params[1], who)
		if not irc.same(who, S.nick) then
			emit("part", who, m.params[1], m.params[c == "KICK" and 3 or 2])
		end
		writewho()
	elseif c == "QUIT" then
		for _, ch in pairs(S.channels) do
			ch.members[irc.lower(m.nick)] = nil
		end
		S.away[irc.lower(m.nick)] = nil
		emit("quit", m.nick, "-", m.params[1])
		writewho()
	elseif c == "NICK" then
		local new = m.params[1]

		if irc.same(m.nick, S.nick) then
			S.nick = new
		end
		for _, ch in pairs(S.channels) do
			if ch.members[irc.lower(m.nick)] then
				ch.members[irc.lower(m.nick)] = nil
				ch.members[irc.lower(new)] = new
			end
		end
		emit("nick", m.nick, new, "")
		writewho()
	elseif c == "ERROR" then
		emit("error", "-", "-", m.params[1])
	elseif numeric[c] then
		numeric[c](m)
	elseif c:match("^[45]%d%d$") then
		emit("error", m.nick, "-", table.concat(m.params, " ", 2))
	end
end

-- ---- the loop ----

local stop

for _, sig in ipairs { signal.SIGINT, signal.SIGTERM, signal.SIGHUP } do
	signal.signal(sig, function()
		stop = true
	end)
end
signal.signal(signal.SIGPIPE, signal.SIG_IGN)

local backoff = 0
local nextconnect = 0

math.randomseed(os.time(), unistd.getpid())

-- schedule the next attempt: double, cap, then up to a quarter of
-- jitter so agents started together do not knock together forever.
local function retry(why)
	backoff = backoff == 0 and cfg.backoff or
	    math.min(backoff * 2, cfg.backoff_max)

	local wait = backoff + math.random() * backoff / 4

	nextconnect = now() + wait
	emit("error", "-", "-", ("%s; retry in %.0fs"):format(why, wait))
end

emit("info", "-", "-", "start " .. want .. " pid " .. unistd.getpid())

while not stop do
	local t = now()

	if not sock and t >= nextconnect then
		local fd, err = connect()

		if fd then
			sock = fd
			rd = irc.reader()
			S.nick, S.lastrx, S.pinged = want, t, false
			send(irc.nick(S.nick))
			send(irc.user(want, cfg.realname))
		else
			retry(err)
		end
	end

	if quitting then
		if sock then
			credit = 5
			send(irc.quit(quitting))
			flush()
		end
		break
	end

	local fds = { [infd] = { events = { IN = true } } }

	if sock then
		fds[sock] = { events = { IN = true } }
	end

	local r = poll.poll(fds, sock and #sendq >= sendqi and 250 or 1000)

	if r and r > 0 then
		if fds[infd].revents and fds[infd].revents.IN then
			local rok, rerr = pcall(readin)

			if not rok then
				emit("error", "-", "-", "command: " .. tostring(rerr))
			end
		end

		local sr = sock and fds[sock].revents

		if sr and (sr.IN or sr.HUP or sr.ERR) then
			local data, err = socket.recv(sock, 4096)

			if not data or #data == 0 then
				hangup(err or "closed by server")
				retry("reconnect")
			else
				S.lastrx, S.pinged = now(), false
				rd:feed(data)
				for line in rd:lines() do
					local m = irc.parse(line)

					-- one bad line is a bug to log, not a
					-- reason to lose the connection
					local hok, herr = m and pcall(handle, m)

					if m and not hok then
						emit("error", "-", "-", "handling " .. line .. ": " .. tostring(herr))
					end
				end
				-- a session that got as far as welcome earns a
				-- fresh backoff
				if S.registered then
					backoff = 0
				end
			end
		end
	end

	for _, g in ipairs(asm:expire(now())) do
		emit("bad", g.from, g.to, ("incomplete message, %d of %d pieces"):format(g.got, g.m))
	end

	if sock then
		t = now()
		if t - S.lastrx > 240 and not S.pinged then
			send(irc.ping("irc-agent"))
			S.pinged = true
		elseif S.pinged and t - S.lastrx > 360 then
			hangup("ping timeout")
			retry("reconnect")
		end
	end

	if sock then
		local fok, ferr = flush()

		if not fok then
			hangup(tostring(ferr))
			retry("reconnect")
		end
	end
end

if sock and not quitting then
	credit = 5
	send(irc.quit("killed"))
	flush()
	unistd.close(sock)
end
emit("info", "-", "-", "exit")
