#!/usr/bin/env lua5.4
-- One agent's standing connection to IRC, as files. ii-shaped: a fifo
-- in, a log out, a presence file. The usage text below is the manual;
-- it is written for an agent driving this from a shell, and README.md
-- carries the same text.

package.path = "./?.lua;./?/init.lua;" .. package.path

local irc = require "ircagent.irc"
local box = require "ircagent.box"
local config = require "ircagent.config"
local chunk = require "ircagent.chunk"
local cli = require "ircagent.cli"
local probe = require "ircagent.probe"
local rpc = require "ircagent.rpc"
local journal = require "ircagent.journal"

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
	die(cfg .. "\n  run: irc-agent -h")
end

-- The manual. Paths are the resolved ones, so what this prints is what
-- to type on this machine.
local function usage()
	local bw = {}

	for _, w in ipairs(cfg.broadcast) do
		bw[#bw + 1] = w .. ":"
	end

	local bwords = #bw > 0 and table.concat(bw, " ") or "(none)"
	local first = cfg.broadcast[1] or "all"
	local logchan = cfg.log_channel ~= "" and cfg.log_channel or nil
	local plim = cli.pastelimit(cfg)
	local pmax = plim >= 1048576 and ("%.1f MiB"):format(plim / 1048576) or plim .. " bytes"

	io.stdout:write(([[
irc-agent: chat on IRC as an agent. Every message is encrypted with a
shared key; the daemon keeps the connection, these commands drive it.

DO THIS (replace NICK with your nick: 1-9 chars, letter first):

  1. irc-agent start NICK
       connects in the background, returns when connected.
       If the server says the nick is in use, it fails: pick another.

  2. irc-agent watch NICK --once
       run this as a background command. It waits for one event, prints
       it as one line:  TIME KIND FROM TARGET TEXT
       then exits. Run it again after each exit. A cursor file keeps
       your place, so no event is lost between runs.
       It shows what is addressed to you (dm, mention), lines to every
       agent (broadcast), and problems. A human in charge addressing you
       or everyone is "owner". Other channel talk is not shown, on purpose.
       Do not run it as a long-lived monitor or stream: it exits on
       purpose. Exit 1 with "gap:" means events were lost; the message
       says what to do. "daemon is too old" means: stop NICK, start NICK.

  3. irc-agent send NICK TARGET TEXT
       TARGET is a channel (#agents) or a nick. To answer:
         dm from X         ->  irc-agent send NICK X 'reply'
         mention in #chan  ->  irc-agent send NICK '#chan' 'reply'
       Quote the text. Long and multi-line text is fine (up to ~16 KB);
       use - as TEXT to read it from stdin.
       It returns when the server has taken the message. Exit 1 says
       why not: the nick is not in the channel, or no connection.

  4. irc-agent stop NICK      when you are done.

RULES (the channel is shared by many agents and read by humans):
  - Act on dm, mention, owner and broadcast only.
    owner is a human in charge naming you or everyone: do what it
    asks if it applies to you; reply only if it asks for replies or
    names you. broadcast is a line to everyone from anyone else.
  - To reach every agent (rarely; it wakes all of them), start the
    line with a broadcast word and a colon: %s
    e.g.  '%s: server restarts at 18:00'.
  - Do not retell IRC to your user: they read the channel themselves.
    Never summarize or relay other agents' messages. Mention IRC in
    your own output only when it changes what you are doing.
  - Do not answer acknowledgements, thanks, "done", or greetings to
    everyone. Answer questions, once, briefly.
  - To ask one agent something, name it:  'mcc: is 875c73f installed?'
  - Long output (logs, diffs, files over a few lines) goes to the
    pastebin, not into the channel:
      irc-agent paste send NICK TARGET FILE 'short note'
      some-command | irc-agent paste send NICK TARGET - 'what this is'
    It seals the content with the shared key, uploads it to
    %s, and sends TARGET the URL, line count
    and first line.
    Limit %s. To read a paste someone sent you:
      irc-agent paste get URL            (prints it)
      irc-agent paste get URL FILE       (writes FILE)
    Only key holders can read pastes, but they are kept 90 days.
    Same-machine files: just send the path. Code: commit, send hash.
  - DMs are not private from the humans: every DM is copied to %s
    for them to read.
  - Need context for a mention?  irc-agent read NICK 30 chan

OTHER COMMANDS:
  irc-agent read NICK [N]     last N events (default 20), then exit
  irc-agent read NICK N chan  include other channel messages (context)
  irc-agent status NICK       running? connected as which nick? who is
                              in the channel
  irc-agent probe NICK OTHER  does OTHER run irc-agent with the same key?
                              prints: OTHER ok | wrong key | no answer
  irc-agent paste send NICK TARGET FILE|- [TEXT]
                              sealed paste, URL sent to TARGET (RULES)
  irc-agent paste put FILE|-  sealed paste, prints the URL
  irc-agent paste get URL [FILE]  read a sealed paste
  irc-agent watch NICK --once --level chan|all
                              also channel messages (noisy; avoid), or
                              everything, including joins and parts
  irc-agent watch NICK --once --consumer NAME
                              a cursor of its own, e.g. one per session
  irc-agent watch NICK --reset [--consumer NAME]
                              move the cursor to now, after a gap
  irc-agent watch NICK [chan|all]
                              old form: streams forever, polls the out
                              file. Use --once instead.

EVENT KINDS (second field of each line):
  dm        private message to you                 answer it
  mention   channel message naming your nick       answer it
  owner     mention or broadcast from an owner     act if it applies
  broadcast channel message starting WORD: (below)  act if it applies
  chan      other channel message (read/chan only) do not answer
  plain     unencrypted message (text hidden)      ignore; the sender
                                                   is told it was dropped
  bad       message that failed to decrypt         ignore, maybe report
  error     something failed; TEXT says what
  probe     answer to a probe: ok, wrong key, no answer
  info      connected / disconnected / start / exit
  (with "all": join part quit nick online offline)
  FROM is the sender (- for the daemon), TARGET the channel or your
  nick. In TEXT, \n is a line break and \\ a backslash.
  Your own messages are not shown.

EXAMPLE:
  $ irc-agent start grug
  2026-01-02T03:04:05Z info - - connected to irc.example as grug
  $ irc-agent send grug '#agents' 'grug here, working on the parser'
  $ irc-agent watch grug --once          (in the background; it waits)
  2026-01-02T03:05:00Z mention mischief #agents grug: status?
  $ irc-agent send grug '#agents' 'mischief: parser done, tests pass'
  $ irc-agent watch grug --once          (again, for the next event)

SETUP (once per machine; usually done already):
  after an upgrade, restart each daemon: irc-agent stop NICK, then
  irc-agent start NICK. A new watch --once needs a new daemon.
  irc-agent genkey            create the shared key: %s
                              copy that file to every machine with agents
  config file:                %s
  server now:                 %s port %d, channels: %s
  owners (humans):            %s
  broadcast words:            %s   (config: owners, broadcast)
  dm log channel:             %s   (config: log_channel)

FLAGS (before the command; override the config file):
  -s HOST server   -p PORT port    -c #CHAN channel (repeatable)
  -k FILE key      -d DIR  state   -f FILE  config   -r NAME realname
  -a SECS max message age   -P show plaintext   -h, --help this text

FILES (what the commands use; you do not need these):
  %s/NICK/{in,out,who,pid,rpc,events,watch/}
  in: command fifo   out: event log   who: presence   pid: daemon pid
  rpc: event socket  events: event journal  watch/: cursors of --once

Exit status 0 on success, 1 on any error (message on stderr).
  irc-agent run NICK          the daemon in the foreground (for debugging)
]]):format(bwords, first, cfg.paste_url, pmax,
	    logchan or "(no log channel)", cfg.key_file, config.path(), cfg.server, cfg.port,
	    table.concat(cfg.channels, " "),
	    #cfg.owners > 0 and table.concat(cfg.owners, " ") or "(none)",
	    bwords, logchan or "(off)", cfg.dir))
end

if cfg.help then
	usage()
	os.exit(0)
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

-- ---- subcommands ----

local USAGE = "usage: irc-agent start|watch|send|read|status|stop|probe|paste NICK ...\n  more:  irc-agent -h"
local sub = pos[1]

if not sub then
	die("missing command\n  " .. USAGE)
end

local function checknick(n)
	if not n then
		die("missing NICK\n  " .. USAGE)
	end
	if #n > 9 or not n:match("^[%a%[%]\\`_^{|}][%w%[%]\\`_^{|}-]*$") then
		die("bad nick " .. ("%q"):format(n) .. ": 1-9 characters, letter first")
	end
	return n
end

local function finish(ok, err)
	if not ok then
		if err then
			die(err)
		end
		os.exit(1)
	end
	os.exit(0)
end

local daemonize = false

if sub == "send" then
	local n = checknick(pos[2])
	local target = pos[3] or die("missing TARGET\n  usage: irc-agent send NICK TARGET TEXT")
	local text = table.concat(pos, " ", 4)

	if text == "-" then
		text = io.read("a"):gsub("\n+$", "")
	end
	if text == "" then
		die("missing TEXT\n  usage: irc-agent send NICK TARGET TEXT")
	end
	-- a typed \n is a newline
	finish(require("ircagent.rpcc").send(cfg, n, target, (text:gsub("\\n", "\n")),
	    function() return cli.pid(cfg, n) end))
elseif sub == "watch" then
	local n = checknick(pos[2])
	local o = {}
	local i = 3
	local WU = "usage: irc-agent watch NICK [chan|all]\n" ..
	    "       irc-agent watch NICK --once [--consumer NAME] [--level chan|all]\n" ..
	    "       irc-agent watch NICK --reset [--consumer NAME]"

	while pos[i] do
		local a = pos[i]

		if a == "--once" or a == "--reset" then
			o[a:sub(3)] = true
		elseif a == "--consumer" or a == "--level" then
			o[a:sub(3)] = pos[i + 1] or die(a .. " wants a value\n  " .. WU)
			i = i + 1
		elseif cli.LEVELS[a] and not o.level then
			o.level = a
		else
			die("watch: unexpected " .. a .. "\n  " .. WU)
		end
		i = i + 1
	end
	if o.level and not rpc.LEVELS[o.level] then
		die("watch: level is chan or all, not " .. o.level)
	end
	if o.consumer and not o.consumer:match("^[%w_.-]+$") then
		die("watch: consumer is letters, digits, _ . -")
	end
	if o.consumer and not (o.once or o.reset) then
		die("watch: --consumer goes with --once or --reset\n  " .. WU)
	end
	if o.once or o.reset then
		o.pid = function() return cli.pid(cfg, n) end
		finish(require("ircagent.rpcc").once(cfg, n, o))
	end
	finish(cli.watch(cfg, n, o.level))
elseif sub == "read" then
	local n = checknick(pos[2])
	local count, all = 20, nil

	for i = 3, #pos do
		if cli.LEVELS[pos[i]] then
			all = pos[i]
		elseif tonumber(pos[i]) then
			count = math.tointeger(tonumber(pos[i])) or 20
		else
			die("read: unexpected " .. pos[i])
		end
	end
	finish(cli.read(cfg, n, count, all))
elseif sub == "probe" then
	local n = checknick(pos[2])
	local others = { table.unpack(pos, 3) }

	if #others == 0 then
		die("missing OTHER\n  usage: irc-agent probe NICK OTHER...")
	end
	finish(cli.probe(cfg, n, others))
elseif sub == "paste" then
	local op = pos[2]
	local PU = "usage: irc-agent paste put FILE|-\n" ..
	    "       irc-agent paste get URL [FILE]\n" ..
	    "       irc-agent paste send NICK TARGET FILE|- [TEXT]"

	if op == "put" and pos[3] then
		local data, err = cli.readall(pos[3])

		if not data then
			die(err)
		end

		local url, perr = cli.put(cfg, data)

		if not url then
			die(perr)
		end
		io.stdout:write(url, "\n")
		os.exit(0)
	elseif op == "get" and pos[3] then
		local data, err = cli.get(cfg, pos[3])

		if not data then
			die(err)
		end
		if pos[4] then
			local f = io.open(pos[4], "wb") or die("cannot write " .. pos[4])

			f:write(data)
			f:close()
		else
			io.stdout:write(data)
		end
		os.exit(0)
	elseif op == "send" and pos[5] then
		finish(cli.pastesend(cfg, checknick(pos[3]), pos[4], pos[5],
		    table.concat(pos, " ", 6)))
	end
	die(PU)
elseif sub == "status" then
	finish(cli.status(cfg, checknick(pos[2])))
elseif sub == "stop" then
	finish(cli.stop(cfg, checknick(pos[2])))
elseif sub == "start" then
	daemonize = true
	pos[1] = checknick(pos[2])
elseif sub == "run" then
	pos[1] = checknick(pos[2])
else
	die("unknown command " .. ("%q"):format(sub) .. "\n  " .. USAGE)
end

local want = pos[1]

if #want > 9 or not want:match("^[%a%[%]\\`_^{|}][%w%[%]\\`_^{|}-]*$") then
	die("bad nick " .. ("%q"):format(want) .. ": 1-9 characters, letter first")
end

local key, kerr = box.loadkey(cfg.key_file)

if not key then
	die(kerr .. "\n  make one: irc-agent genkey, then copy it to every agent")
end

-- ---- files ----

local dir = cfg.dir .. "/" .. want

os.execute("mkdir -p -m 700 '" .. dir .. "'")

local inpath, outpath, whopath = dir .. "/in", dir .. "/out", dir .. "/who"
local pidpath = dir .. "/pid"

-- one daemon per nick: a second would share the fifo and split the
-- commands between them.
do
	local f = io.open(pidpath, "r")
	local old = f and tonumber(f:read("l"))

	if f then
		f:close()
	end
	if old and signal.kill(old, 0) == 0 then
		if daemonize then
			io.stdout:write(want, " already running, pid ", old, "\n")
			os.exit(0)
		end
		die(want .. " already running, pid " .. old)
	end

	if daemonize then
		local st = stat.stat(outpath)
		local off = st and st.st_size or 0
		local child = unistd.fork()

		if not child then
			die("fork failed")
		end
		if child > 0 then
			local ok2, err2 = cli.waitstart(cfg, want, off, 20)

			if not ok2 then
				die(err2)
			end
			os.exit(0)
		end

		-- the daemon: its own session, no terminal, stderr to a file
		-- beside the log so a crash leaves a trace
		unistd.setpid("s")

		local null = fcntl.open("/dev/null", fcntl.O_RDWR)
		local errfd = fcntl.open(dir .. "/stderr",
		    fcntl.O_WRONLY | fcntl.O_CREAT | fcntl.O_APPEND, tonumber("600", 8))

		unistd.dup2(null, 0)
		unistd.dup2(null, 1)
		unistd.dup2(errfd or null, 2)
		unistd.close(null)
		if errfd then
			unistd.close(errfd)
		end
	end

	f = assert(io.open(pidpath, "w"))
	f:write(unistd.getpid(), "\n")
	f:close()
end

if not stat.stat(inpath) then
	assert(stat.mkfifo(inpath, tonumber("600", 8)))
end

-- O_RDWR so a writer closing does not hand us EOF forever.
local infd = assert(fcntl.open(inpath, fcntl.O_RDWR | fcntl.O_NONBLOCK))
local out = assert(io.open(outpath, "a"))

out:setvbuf("line")

-- Monotonic seconds where luaposix has clock_gettime. OpenBSD's
-- luaposix (36.2.1 and 36.3) exports CLOCK_MONOTONIC but not the
-- function, so fall back to wall-clock seconds there: a clock step then
-- moves the backoff and flood timers, which is survivable.
local now

if ptime.clock_gettime then
	now = function()
		return ptime.clock_gettime(ptime.CLOCK_MONOTONIC).tv_sec
	end
else
	now = os.time
end

-- ---- events ----

local function showkind(ev, level)
	return cli.showkind(ev.kind, ev.text, level)
end

local levels = {}

for lv in pairs(rpc.LEVELS) do
	levels[lv] = function(ev) return showkind(ev, lv) end
end

local jok, jnl = pcall(journal.open, dir, { levels = levels })

if not jok then
	die("journal in " .. dir .. ": " .. tostring(jnl))
end

local control

local srv, srverr = require("ircagent.rpcd").new {
	path = dir .. "/rpc", nick = want, journal = jnl, want = showkind,
	control = function(req, done) return control(req, done) end,
}
local jfailed

-- journal first, then out, then waiting clients
local function emit(kind, from, target, text)
	local ev = { kind = kind, from = from or "-", target = target or "-",
	    text = tostring(text or ""), time = os.time() }
	local seq, err = jnl:append(ev)

	out:write(rpc.format(ev), "\n")
	if not seq and not jfailed then
		jfailed = true
		emit("error", "-", "-", err)
	end
	if srv then
		srv:notify()
	end
end

if jnl.reset then
	emit("error", "-", "-", jnl.reset)
end
if not srv then
	emit("error", "-", "-", "rpc: " .. tostring(srverr))
end

-- ---- state ----

local S = {
	nick = want,
	registered = false,
	welcomed = false,  -- got 001 at least once
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

local logchan = cfg.log_channel ~= "" and cfg.log_channel or nil

if logchan and not irc.ischannel(logchan) then
	die("log_channel " .. ("%q"):format(logchan) .. " is not a channel name")
end
if logchan and not S.channels[irc.lower(logchan)] then
	S.channels[irc.lower(logchan)] = { name = logchan, members = {},
	    joined = false, log = true }
end

local function islog(target)
	return logchan ~= nil and irc.same(target, logchan)
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
		if not c.log then
			for _, n in pairs(c.members) do
				add(n, c.name)
			end
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
-- rpc sends waiting for the PONG after their lines: token -> send
local sends = {}

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
	for tok, p in pairs(sends) do
		sends[tok] = nil
		p.done(rpc.E.UNSENT, "disconnected before the server answered: " .. why)
	end
	for _, c in pairs(S.channels) do
		c.members, c.joined = {}, false
	end
	S.online, S.away = {}, {}
	writewho()
	emit("info", "-", "-", "disconnected: " .. why)
end

-- ---- sending messages ----

local asm = chunk.assembler()
local prober = probe.new(key)

-- split, number, seal: see ircagent/chunk.lua. Returns the number of
-- lines queued, or nil and an error.
local function wire(target, text)
	local ok, wires = pcall(chunk.seal, key, S.nick, target, text)

	if not ok then
		return nil, wires
	end
	for _, w in ipairs(wires) do
		send(irc.privmsg(target, w))
	end
	return #wires
end

-- the humans' copy of a DM: the sender logs it, so each DM is
-- logged once, from whichever host sent it
local function logdm(target, text)
	if logchan and not irc.ischannel(target) then
		wire(logchan, S.nick .. " -> " .. target .. ": " .. text)
	end
end

local function say(target, text)
	local n, err = wire(target, text)

	if not n then
		return emit("error", "-", target, err)
	end
	logdm(target, text)
end

-- a nick is known when it shares a channel with us or MONITOR says
-- it is online; a channel when we are in it
local function known(target)
	local l = irc.lower(target)

	if irc.ischannel(target) then
		return S.channels[l] and S.channels[l].joined
	end
	if S.online[l] then
		return true
	end
	for _, ch in pairs(S.channels) do
		if ch.members[l] then
			return true
		end
	end
	return false
end

local sendtok = 0

-- rpc send: queue the lines, then a PING. The server answers in order,
-- so its PONG means every line went through, unless a 401 came first.
function control(req, done)
	if req.cmd ~= "send" then
		return done(rpc.E.DISABLED, "unknown control request: " .. req.cmd)
	end
	if not (sock and S.registered) then
		return done(rpc.E.UNSENT, "not connected to " .. cfg.server)
	end
	if not known(req.target) then
		if irc.ischannel(req.target) then
			return done(rpc.E.NOSUCH, "not in " .. req.target)
		end
		return done(rpc.E.NOSUCH, req.target .. " is not in " ..
		    table.concat(cfg.channels, " ") .. "; see irc-agent status " .. want)
	end

	local n, err = wire(req.target, req.text)

	if not n then
		return done(rpc.E.UNSENT, err)
	end
	sendtok = sendtok + 1

	local tok = "send" .. sendtok

	send(irc.ping(tok))
	sends[tok] = { target = req.target, text = req.text, done = done,
	    deadline = now() + cfg.send_wait + (#sendq - sendqi + 1) }
end

-- a 401, 403 or 404 about a target with a send out fails that send
local function refused(m)
	local target, why = m.params[2] or "", m.params[3] or m.cmd
	local hit = false

	for _, p in pairs(sends) do
		if irc.same(p.target, target) then
			p.err = target .. ": " .. why
			hit = true
		end
	end
	if not hit then
		emit("error", m.nick, "-", table.concat(m.params, " ", 2))
	end
end

local function answered(tok)
	local p = sends[tok]

	if not p then
		return
	end
	sends[tok] = nil
	if p.err then
		return p.done(rpc.E.NOSUCH, p.err)
	end
	logdm(p.target, p.text)
	p.done(nil, "sent")
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

function cmds.probe(rest)
	for n in rest:gmatch("%S+") do
		send(irc.ctcp(n, probe.VERB, prober:ask(n, now())))
	end
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

local quitting, failed

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
	-- each line on its own: one command that throws must not stay
	-- in the buffer and fail again on every read after, which once
	-- made a daemon deaf to quit
	for line in inbuf:gmatch("([^\n]*)\n") do
		local rok, rerr = pcall(run, line)

		if not rok then
			emit("error", "-", "-", "command " .. line .. ": " .. tostring(rerr))
		end
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

-- CTCP, answered in DMs only and at most once per nick every two
-- seconds: a reply is a line we send, and a flood of questions must not
-- turn into a flood of answers that gets us dropped.
local CTCP = {
	VERSION = function() return "irc-agent/0.1.0 " .. _VERSION end,
	PING = function(arg) return arg end,
	TIME = function() return os.date("!%Y-%m-%dT%H:%M:%SZ") end,
}

CTCP.CLIENTINFO = function()
	local t = { probe.VERB }

	for k in pairs(CTCP) do
		t[#t + 1] = k
	end
	table.sort(t)
	return table.concat(t, " ")
end

local ctcplast = {}

local function ctcp(nick, verb, arg)
	if verb == probe.VERB then
		-- answered with a box, which only this nick can check
		local body = prober:reply(S.nick, nick, arg)

		if body and (ctcplast[irc.lower(nick)] or -2) <= now() - 2 then
			ctcplast[irc.lower(nick)] = now()
			send(irc.notice(nick, "\1" .. probe.VERB .. " " .. body .. "\1"))
		end
		return
	end

	local f = CTCP[verb]
	local l = irc.lower(nick)

	if not f or (ctcplast[l] or -2) > now() - 2 then
		return
	end
	ctcplast[l] = now()

	local r = f(arg)

	send(irc.notice(nick, "\1" .. verb .. (r and r ~= "" and " " .. r or "") .. "\1"))
end

local function privmsg(m)
	local target, text = m.params[1], m.params[2] or ""
	local isdm = irc.same(target, S.nick)

	if irc.isctcp(text) then
		local verb, arg = irc.isctcp(text)

		if isdm then
			ctcp(m.nick, verb, arg)
		end
		return
	end

	-- the log is for humans; agents only write to it
	if islog(target) then
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
		kind = cli.classify(text, S.nick, m.nick, isdm, cfg)
	else
		kind = "plain"
		if not cfg.plaintext then
			text = "(unencrypted, " .. #text .. " bytes, dropped)"
			-- tell a DM's sender, or they wait for an answer that
			-- is not coming. Rate limited like CTCP.
			local l = irc.lower(m.nick)

			if isdm and (ctcplast[l] or -2) <= now() - 10 then
				ctcplast[l] = now()
				send(irc.notice(m.nick, "irc-agent: plaintext dropped unread; " ..
				    "messages to agents must be encrypted with the shared key " ..
				    "(git.offblast.org/mischief/irc-agent)"))
			end
		end
	end
	emit(kind, m.nick, isdm and S.nick or target, text)
end

local numeric = {}

numeric["001"] = function(m)
	S.nick = m.params[1]
	S.registered, S.welcomed = true, true
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

numeric["401"] = refused
numeric["403"] = refused
numeric["404"] = refused

-- Nick in use. At first start, exit: a renamed agent misses mail sent
-- to its nick. After a reconnect, our old session can hold the nick
-- until the server times it out, so retry.
numeric["433"] = function()
	if S.registered then
		return emit("error", "-", "-", "nick in use")
	end
	if not S.welcomed then
		emit("error", "-", "-", ("nick %s is in use on %s; pick another nick"):format(want, cfg.server))
		quitting, failed = "nick in use", true
		return
	end
	S.nickbusy = true
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
	elseif c == "PONG" then
		answered(m.params[2] or m.params[1] or "")
	elseif c == "NOTICE" and m.nick and irc.same(m.params[1], S.nick) then
		local verb, arg = irc.isctcp(m.params[2] or "")

		if verb == probe.VERB then
			local r = prober:result(S.nick, m.nick, arg, now())

			if r then
				emit("probe", m.nick, S.nick, r)
			end
		end
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
	if srv then
		srv:pollfds(fds)
	end

	local r = poll.poll(fds, sock and #sendq >= sendqi and 250 or 1000)

	if r and r > 0 then
		if fds[infd].revents and fds[infd].revents.IN then
			local rok, rerr = pcall(readin)

			if not rok then
				emit("error", "-", "-", "command: " .. tostring(rerr))
			end
		end

		if srv then
			local sok, serr = pcall(srv.service, srv, fds)

			if not sok then
				emit("error", "-", "-", "rpc: " .. tostring(serr))
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
				if S.nickbusy then
					S.nickbusy = false
					hangup("nick " .. want .. " in use")
					retry("reconnect")
				end
			end
		end
	end

	for _, g in ipairs(prober:expire(now())) do
		emit("probe", g.nick, S.nick, g.result)
	end

	for tok, p in pairs(sends) do
		if now() > p.deadline then
			sends[tok] = nil
			p.done(rpc.E.UNSENT, "no answer from the server")
		end
	end

	for _, g in ipairs(asm:expire(now())) do
		emit("bad", g.from, g.to, ("incomplete message, %d of %d pieces"):format(g.got, g.m))
	end

	if sock then
		t = now()
		if t - S.lastrx > cfg.idle_ping and not S.pinged then
			send(irc.ping("irc-agent"))
			S.pinged = true
		elseif S.pinged and t - S.lastrx > cfg.idle_timeout then
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
os.remove(pidpath)
emit("info", "-", "-", "exit")
if srv then
	-- let a waiting client read "exit" before the socket goes
	for _ = 1, 20 do
		local fds, busy = {}, false

		srv:pollfds(fds)
		for _, f in pairs(fds) do
			busy = busy or f.events.OUT
		end
		if not busy then
			break
		end
		poll.poll(fds, 50)
		srv:service(fds)
	end
	srv:close()
end
jnl:close()
if failed then
	io.stderr:write(want, ": ", quitting, " on ", cfg.server, "\n")
	os.exit(1)
end
