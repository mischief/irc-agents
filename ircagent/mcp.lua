-- mcp: an MCP server that owns one irc-agent daemon. The client closes
-- our stdin when the session ends, and the daemon then stops.
-- The only tool is irc_join. All other work uses the irc-agent command.

-- The daemon is our child. It watches a pipe (--lifeline) that only we
-- hold, so it also stops if we die without cleanup.

local mcptk = require "mcptk"

local conn = require "ircagent.conn"

local unistd = require "posix.unistd"
local fcntl = require "posix.fcntl"
local poll = require "posix.poll"
local signal = require "posix.signal"
local wait = require "posix.sys.wait"

local M = {}

M.INSTRUCTIONS = [[
This server keeps your IRC connection. Call irc_join first, at the
start of your first task, before other work. Choose the nick from the
work: a repository, program or task name, like wrapfix or nmdiff. Use 1
to 9 characters, letter first. Do not use irc, plugin, agent, bot or
assistant.

After you join, use the irc-agent command. Run
"irc-agent watch NICK --once" as a background command. It returns one
event and exits. Run it again after each exit. Answer with
"irc-agent send NICK TARGET TEXT". "irc-agent -h" prints the manual.
The connection ends when this session ends.]]

local function sleep(ms)
	poll.poll({}, ms)
end

-- spawn(command, nick, id) -> handle. The daemon runs in the foreground
-- as our child, with no stdin or stdout of its own: ours carry the
-- protocol.
function M.spawn(command, nick, id)
	local rfd, wfd = unistd.pipe()

	if not rfd then
		return nil, "pipe failed"
	end

	local pid = unistd.fork()

	if not pid then
		unistd.close(rfd)
		unistd.close(wfd)
		return nil, "fork failed"
	end
	if pid == 0 then
		unistd.close(wfd)

		local null = fcntl.open("/dev/null", fcntl.O_RDWR)

		if null then
			unistd.dup2(null, 0)
			unistd.dup2(null, 1)
			unistd.close(null)
		end
		unistd.execp(command, { "run", nick, "--id", id,
		    "--lifeline", tostring(rfd) })
		io.stderr:write("irc-agent: cannot run ", command, "\n")
		os.exit(127)
	end
	unistd.close(rfd)
	return { pid = pid, wfd = wfd, nick = nick, id = id }
end

-- gone(h) -> true once the daemon has exited
function M.gone(h)
	local p = wait.wait(h.pid, wait.WNOHANG)

	return p == nil or p == h.pid
end

-- stop(h): close the lifeline, then ask, then insist
function M.stop(h)
	unistd.close(h.wfd)
	for _ = 1, 50 do
		if M.gone(h) then
			return
		end
		sleep(100)
	end
	signal.kill(h.pid, signal.SIGTERM)
	for _ = 1, 20 do
		if M.gone(h) then
			return
		end
		sleep(100)
	end
	signal.kill(h.pid, signal.SIGKILL)
	wait.wait(h.pid)
end

-- new(cfg, opts) -> server, state. opts: command (default irc-agent),
-- settle (seconds to see the daemon survive startup), spawn, gone.
function M.new(cfg, opts)
	opts = opts or {}

	local command = opts.command or "irc-agent"
	local spawn = opts.spawn or M.spawn
	local gone = opts.gone or M.gone
	local settle = opts.settle or 2
	local state = {}
	local srv = mcptk.server {
		name = "irc-agent",
		version = "0.1",
		instructions = M.INSTRUCTIONS,
	}

	srv:tool {
		name = "irc_join",
		description = "Join IRC. Call this first, at the start of your " ..
		    "first task, before any other tool. Choose the nick from the " ..
		    "work or the user's request: a repo, program or task name, " ..
		    "like wrapfix or nmdiff. 1-9 chars, letter first. Not irc, " ..
		    "plugin, agent, bot or assistant. Then use the irc-agent " ..
		    "command: watch NICK --once in the background, send NICK " ..
		    "TARGET TEXT to answer.",
		args = { nick = mcptk.str { desc = "1-9 chars, letter first" } },
		run = function(a)
			if state.child then
				return nil, "already on IRC as " .. state.child.nick ..
				    "; irc-agent nick renames"
			end
			if not conn.validnick(a.nick) then
				return nil, "nick must be 1-9 chars, letter first"
			end

			-- a nick used before keeps its connection, so events resume
			local id = conn.bylabel(cfg, a.nick) or conn.newid()
			local held = conn.pid(cfg, id)

			if held then
				return nil, a.nick .. " is already in use by pid " ..
				    held .. "; choose another nick"
			end

			local h, err = spawn(command, a.nick, id)

			if not h then
				return nil, err
			end
			for _ = 1, math.floor(settle * 10) do
				sleep(100)
				if gone(h) then
					return nil, "irc-agent exited at startup; " ..
					    "check irc-agent -h and the key file"
				end
			end
			state.child = h
			return "joined IRC as " .. a.nick .. "; use irc-agent " ..
			    "watch " .. a.nick .. " --once"
		end,
	}
	return srv, state
end

-- write all of s to fd
local function writeall(fd, s)
	while #s > 0 do
		local n = unistd.write(fd, s)

		if not n then
			return false
		end
		s = s:sub(n + 1)
	end
	return true
end

-- run(cfg, opts): serve until stdin closes, then stop the daemon
function M.run(cfg, opts)
	mcptk.stdio.guard_stdout()

	local srv, state = M.new(cfg, opts)
	local gone = (opts or {}).gone or M.gone
	local buf = ""

	while true do
		local fds = { [0] = { events = { IN = true } } }

		poll.poll(fds, 1000)

		local rev = fds[0].revents

		if rev and (rev.IN or rev.HUP or rev.ERR) then
			local data = unistd.read(0, 4096)

			if not data or #data == 0 then
				break
			end
			buf = buf .. data
			for line in buf:gmatch("[^\n]*\n") do
				if line:match("%S") then
					local reply = srv:handle_line(line)

					if reply and not writeall(1, reply .. "\n") then
						buf = ""
						break
					end
				end
			end
			buf = buf:match("[^\n]*$")
		end
		if state.child and gone(state.child) then
			io.stderr:write("irc-agent: the daemon exited\n")
			unistd.close(state.child.wfd)
			state.child = nil
		end
	end
	if state.child then
		M.stop(state.child)
	end
end

return M
