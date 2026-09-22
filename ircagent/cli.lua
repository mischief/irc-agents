-- cli: the subcommands that drive a running daemon, so an agent never
-- has to assemble a tail pipeline or guess at a filter.
--
--      start NICK             fork the daemon, wait for it to connect
--      send NICK TARGET TEXT  one message ("-" for TEXT reads stdin)
--      watch NICK [chan|all]  follow events, one per line, forever
--      read NICK [N] [chan|all]  the last N events (default 20), then exit
--      status NICK            running? connected? who is around
--      stop NICK              quit and wait for exit
--      probe NICK OTHER...    does OTHER run irc-agent with our key?
--      paste put FILE|-       seal, upload, print the URL
--      paste get URL [FILE]   fetch, open, write stdout or FILE
--      paste send NICK TARGET FILE|- [TEXT]   put, and send TARGET the URL
--
-- Every one of them knows the state directory layout, checks the
-- daemon is alive before touching the fifo (a write to a fifo with no
-- reader blocks forever), and filters events the same way (M.SHOWN).

local unistd = require "posix.unistd"
local fcntl = require "posix.fcntl"
local stat = require "posix.sys.stat"
local signal = require "posix.signal"
local ptime = require "posix.time"

local M = {}

-- What a stream wakes an agent for. Three levels:
--
--      default   dm, mention, owner, broadcast, and problems: what is
--                addressed to you, and what the humans say
--      chan      also other channel messages
--      all       also presence (join part quit nick online offline)
--
-- The default is deliberately narrow. Every line an agent sees costs it
-- a turn, and agents shown channel talk answered it and retold it to
-- their users -- who read the channel themselves. Channel context is
-- there on demand: "irc-agent read NICK 30 chan".
M.SHOWN = {
	dm = true, mention = true, owner = true, broadcast = true, plain = true,
	bad = true, error = true, probe = true,
}

M.LEVELS = { chan = { chan = true }, all = { chan = true, all = true } }

-- classify(text, me, from, isdm, cfg) -> kind of a message that opened.
-- In order: dm; mention (names you); owner (a human in charge said
-- it); broadcast ("all: ..."); chan. A mention beats owner so that a
-- human naming you reads as meant for you.
function M.classify(text, me, from, isdm, cfg)
	local irc = require "ircagent.irc"

	if isdm then
		return "dm"
	end
	if irc.lower(text):find(irc.lower(me), 1, true) then
		return "mention"
	end
	for _, o in ipairs(cfg.owners or {}) do
		if irc.same(o, from) then
			return "owner"
		end
	end

	local word = irc.lower(text):match("^%s*([%w_-]+)%s*[:,]")

	for _, b in ipairs(cfg.broadcast or {}) do
		if word == irc.lower(b) then
			return "broadcast"
		end
	end
	return "chan"
end

local CONNINFO = { "connected to ", "disconnected", "exit", "start " }

-- shown(line, level) with level nil, "chan" or "all"
function M.shown(line, level)
	local lv = M.LEVELS[level] or {}

	if lv.all then
		return true
	end

	local kind, rest = line:match("^%S+ (%S+) (.*)$")

	if not kind then
		return false
	end
	if M.SHOWN[kind] or (kind == "chan" and lv.chan) then
		return true
	end
	if kind == "info" then
		local text = rest:match("^%S+ %S+ (.*)$") or ""

		for _, p in ipairs(CONNINFO) do
			if text:sub(1, #p) == p then
				return true
			end
		end
	end
	return false
end

local function paths(cfg, nick)
	local d = cfg.dir .. "/" .. nick

	return { dir = d, ["in"] = d .. "/in", out = d .. "/out",
	    who = d .. "/who", pid = d .. "/pid" }
end

M.paths = paths

-- pid of a live daemon for nick, or nil
function M.pid(cfg, nick)
	local f = io.open(paths(cfg, nick).pid, "r")

	if not f then
		return nil
	end

	local pid = tonumber(f:read("l"))

	f:close()
	if pid and signal.kill(pid, 0) == 0 then
		return pid
	end
	return nil
end

-- poll with no descriptors is a sleep every luaposix has; nanosleep
-- is not exported everywhere (see now() in bin/irc-agent.lua).
local function sleep(s)
	if ptime.nanosleep then
		ptime.nanosleep({ tv_sec = math.floor(s),
		    tv_nsec = math.floor((s % 1) * 1e9) })
	else
		require("posix.poll").poll({}, math.floor(s * 1000))
	end
end

M.sleep = sleep

local function size(path)
	local st = stat.stat(path)

	return st and st.st_size or 0
end

-- lines of path from byte offset off, and the new offset
local function readfrom(path, off)
	local f = io.open(path, "rb")

	if not f then
		return {}, off
	end

	local st = stat.stat(path)

	-- truncated or replaced: start over
	if st and st.st_size < off then
		off = 0
	end
	f:seek("set", off)

	local data = f:read("a") or ""

	f:close()

	-- only whole lines; a half-written one waits for the next look
	local last = data:match(".*()\n")

	if not last then
		return {}, off
	end

	local lines = {}

	for l in data:sub(1, last):gmatch("([^\n]*)\n") do
		lines[#lines + 1] = l
	end
	return lines, off + last
end

-- ---- send ----

-- one command line to the fifo, without blocking. Newlines in the text
-- become the \n escape the daemon turns back into newlines.
function M.command(cfg, nick, line)
	if not M.pid(cfg, nick) then
		return nil, nick .. " is not running; start it: irc-agent start " .. nick
	end

	local fd = fcntl.open(paths(cfg, nick)["in"],
	    fcntl.O_WRONLY | fcntl.O_NONBLOCK)

	if not fd then
		return nil, nick .. ": cannot open the in fifo"
	end

	local data = line:gsub("\r?\n", "\\n") .. "\n"
	local n, err = unistd.write(fd, data)

	unistd.close(fd)
	if n ~= #data then
		return nil, nick .. ": write to in failed: " .. tostring(err)
	end
	return true
end

-- ---- watch / read ----

local function emitline(l)
	io.stdout:write(l, "\n")
	io.stdout:flush()
end

function M.read(cfg, nick, n, all)
	local p = paths(cfg, nick)
	local lines = readfrom(p.out, 0)
	local keep = {}

	for _, l in ipairs(lines) do
		if M.shown(l, all) then
			keep[#keep + 1] = l
		end
	end
	for i = math.max(1, #keep - n + 1), #keep do
		emitline(keep[i])
	end
	return true
end

-- follow out from its current end, forever. Survives the file being
-- replaced (a restarted daemon) and the daemon exiting: it keeps
-- watching, so a supervisor sees "exit" and later "start".
function M.watch(cfg, nick, all)
	local p = paths(cfg, nick)
	local off = size(p.out)

	if not M.pid(cfg, nick) then
		io.stderr:write("irc-agent: ", nick, " is not running; watching anyway\n")
	end
	while true do
		local lines

		lines, off = readfrom(p.out, off)
		for _, l in ipairs(lines) do
			if M.shown(l, all) then
				emitline(l)
			end
		end
		sleep(0.25)
	end
end

-- ---- probe ----

-- probe(cfg, nick, others) -> true when every one answered ok. Prints
-- one line per nick: NICK ok | wrong key | no answer
function M.probe(cfg, nick, others, timeout)
	local p = paths(cfg, nick)
	local off = size(p.out)
	local ok, err = M.command(cfg, nick, "probe " .. table.concat(others, " "))

	if not ok then
		return nil, err
	end

	local irc = require "ircagent.irc"
	local want, left, allok = {}, #others, true

	for _, o in ipairs(others) do
		want[irc.lower(o)] = o
	end

	local deadline = os.time() + (timeout or 10)

	while left > 0 and os.time() <= deadline do
		local lines

		lines, off = readfrom(p.out, off)
		for _, l in ipairs(lines) do
			local from, result = l:match("^%S+ probe (%S+) %S+ (.*)$")
			local o = from and want[irc.lower(from)]

			if o then
				want[irc.lower(from)] = nil
				left = left - 1
				allok = allok and result == "ok"
				io.stdout:write(o, " ", result, "\n")
			end
		end
		sleep(0.25)
	end
	for _, o in pairs(want) do
		allok = false
		io.stdout:write(o, " no answer\n")
	end
	return allok
end

-- ---- paste ----
--
-- Pastes are sealed with the shared key before they leave: the paste
-- server stores one box (the same CID text as on IRC) and only key
-- holders can read it back with "paste get". The AAD names no nick, so
-- any key holder can open any paste.

local box = require "ircagent.box"

M.PASTE_FROM, M.PASTE_TO = "irc-agent", "paste"

local function shquote(x)
	return "'" .. x:gsub("'", "'\\''") .. "'"
end

local function curl(args)
	local p = io.popen("curl -sS -m 120 " .. args .. " 2>&1")
	local out = p:read("a") or ""
	local ok = p:close()

	return ok, out
end

local function readall(path)
	if path == "-" then
		return io.stdin:read("a")
	end

	local f, err = io.open(path, "rb")

	if not f then
		return nil, err
	end

	local d = f:read("a")

	f:close()
	return d
end

-- sealed size of n bytes of plaintext, as uploaded
local function sealedsize(n)
	return 8 + math.ceil((n + box.OVERHEAD + 8) * 4 / 3)
end

M.sealedsize = sealedsize

-- largest plaintext that fits paste_max once sealed
function M.pastelimit(cfg)
	return math.floor((cfg.paste_max - 8) * 3 / 4) - box.OVERHEAD - 8
end

-- put(cfg, data) -> url
function M.put(cfg, data)
	if not data or #data == 0 then
		return nil, "nothing to paste"
	end
	if #data > M.pastelimit(cfg) then
		return nil, ("%d bytes is over the paste limit of %d; split it, or commit it and send the hash"):format(
		    #data, M.pastelimit(cfg))
	end

	local key, kerr = box.loadkey(cfg.key_file)

	if not key then
		return nil, kerr
	end

	local tmp = os.tmpname()
	local f = assert(io.open(tmp, "wb"))

	f:write(box.seal(key, M.PASTE_FROM, M.PASTE_TO, data))
	f:close()

	local _, out = curl("--data-binary @" .. shquote(tmp) .. " " .. shquote(cfg.paste_url))

	os.remove(tmp)

	local url = out:match("(https?://%S+)")

	if not url then
		return nil, "paste failed: " .. (out ~= "" and out:gsub("%s+$", "") or "no answer from " .. cfg.paste_url)
	end
	-- the server answers http://, which only redirects; hand out what
	-- works, in the scheme paste_url was given in
	if cfg.paste_url:match("^https:") then
		url = url:gsub("^http:", "https:")
	end
	return url
end

-- the paste's tag from a URL on our paste server, or a bare tag
local function tagof(cfg, ref)
	if ref:match("^[%w]+$") then
		return ref
	end

	local host = cfg.paste_url:match("^https?://([^/]+)")
	local h, tag = ref:match("^https?://([^/]+)/(%w+)/?$")

	if not h or h ~= host then
		return nil, "not a paste on " .. cfg.paste_url .. ": " .. ref
	end
	return tag
end

-- get(cfg, ref) -> data
function M.get(cfg, ref)
	local tag, terr = tagof(cfg, ref)

	if not tag then
		return nil, terr
	end

	local key, kerr = box.loadkey(cfg.key_file)

	if not key then
		return nil, kerr
	end

	local ok, out = curl("-f " .. shquote(cfg.paste_url:gsub("/+$", "") .. "/" .. tag))

	if not ok then
		return nil, "fetch failed: " .. out:gsub("%s+$", "")
	end

	local data, why = box.open(key, M.PASTE_FROM, M.PASTE_TO, (out:gsub("%s+$", "")))

	if not data then
		if why == "not a box" then
			return nil, "paste " .. tag .. " is not sealed (plain paste, read it with curl)"
		end
		return nil, "paste " .. tag .. ": " .. why
	end
	return data
end

-- describe(data) -> "N lines, M bytes: first line"
function M.describe(data)
	local lines = select(2, data:gsub("\n", "")) + (data:sub(-1) == "\n" and 0 or 1)
	local first = (data:match("^%s*([^\n]*)") or ""):sub(1, 80)

	return ("%d line%s, %d bytes: %s"):format(lines, lines == 1 and "" or "s", #data, first)
end

-- pastesend(cfg, nick, target, path, note): put, then tell target
function M.pastesend(cfg, nick, target, path, note)
	if not M.pid(cfg, nick) then
		return nil, nick .. " is not running; start it: irc-agent start " .. nick
	end

	local data, err = readall(path)

	if not data then
		return nil, err
	end

	local url, perr = M.put(cfg, data)

	if not url then
		return nil, perr
	end
	io.stdout:write(url, "\n")

	local msg = "paste " .. url .. " (" .. M.describe(data) ..
	    "; read: irc-agent paste get " .. url .. ")"

	if note and note ~= "" then
		msg = note .. " " .. msg
	end
	return M.command(cfg, nick, "msg " .. target .. " " .. msg)
end

M.readall = readall

-- ---- start / stop / status ----

-- after the fork, in the parent: wait for the child to connect, fail,
-- or give up waiting. Prints the relevant lines.
function M.waitstart(cfg, nick, off, timeout)
	local p = paths(cfg, nick)
	local deadline = os.time() + timeout
	local lasterr

	while os.time() <= deadline do
		local lines

		lines, off = readfrom(p.out, off)
		for _, l in ipairs(lines) do
			if l:find(" info %- %- connected to ") then
				emitline(l)
				return true
			end
			if l:find(" error ") then
				lasterr = l
			end
		end
		if not M.pid(cfg, nick) and os.time() > deadline - timeout + 2 then
			if lasterr then
				emitline(lasterr)
			end
			return nil, nick .. " exited during startup; see " .. p.out
		end
		sleep(0.25)
	end
	if lasterr then
		emitline(lasterr)
	end
	io.stdout:write(nick, " running but not connected yet; it keeps retrying.\n")
	return true
end

function M.stop(cfg, nick)
	local pid = M.pid(cfg, nick)

	if not pid then
		return nil, nick .. " is not running"
	end

	local ok, err = M.command(cfg, nick, "quit")

	if not ok then
		return nil, err
	end
	for _ = 1, 40 do
		if signal.kill(pid, 0) ~= 0 then
			io.stdout:write(nick, " stopped\n")
			return true
		end
		sleep(0.25)
	end
	signal.kill(pid, signal.SIGTERM)
	io.stdout:write(nick, " did not quit in 10s; sent SIGTERM\n")
	return true
end

function M.status(cfg, nick)
	local p = paths(cfg, nick)
	local pid = M.pid(cfg, nick)

	if not pid then
		io.stdout:write(nick, ": not running\n")
		return nil
	end

	local state = "unknown"

	for _, l in ipairs((readfrom(p.out, 0))) do
		if l:find(" info %- %- connected to ") then
			state = "connected"
		elseif l:find(" info %- %- disconnected") or l:find(" info %- %- start ") then
			state = "connecting"
		end
	end
	io.stdout:write(("%s: running, pid %d, %s\n"):format(nick, pid, state))

	local f = io.open(p.who, "r")

	if f then
		io.stdout:write("who:\n")
		for l in f:lines() do
			io.stdout:write("  ", l, "\n")
		end
		f:close()
	end
	return true
end

return M
