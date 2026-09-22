-- config: defaults, then the config file, then the command line.
--
-- The file is Lua returning a table, the shape clm uses:
--
--      -- ~/.config/ircagents/config.lua
--      return {
--              server = "irc.offblast.org",
--              port = 6667,
--              channels = { "#agents" },
--              key_file = "~/.config/ircagents/key",
--      }
--
-- The key itself does not live here. This file is the one people paste
-- into a chat to ask why something does not connect; the key goes in a
-- file of its own, mode 0600, which box.loadkey refuses otherwise.
--
-- $IRCAGENTS_CONFIG names another file. A missing file is not an error:
-- the defaults are enough to reach the house server.

local M = {}

local function home()
	return os.getenv("HOME") or "."
end

local function confdir()
	local x = os.getenv("XDG_CONFIG_HOME")

	return (x and x ~= "" and x or home() .. "/.config") .. "/ircagents"
end

local function statedir()
	local x = os.getenv("XDG_RUNTIME_DIR")

	return (x and x ~= "" and x or "/tmp") .. "/ircagents"
end

M.DEFAULTS = {
	server = "irc.offblast.org",
	port = 6667,
	channels = { "#agents" },
	key_file = confdir() .. "/key",
	-- per nick: <dir>/<nick>/{in,out,who}
	dir = statedir(),
	realname = "irc-agent",
	-- seconds; doubles per failure up to max, with jitter. The house
	-- ircd throttles one connect per IP per second, so the floor sits
	-- just above that.
	backoff = 2,
	backoff_max = 300,
	-- commands written to in while disconnected wait for the next
	-- connection, up to this many
	queue_max = 100,
	-- a box older than this is dropped as a replay
	max_age = 300,
	-- accept plaintext PRIVMSG as well, marked as such in out
	plaintext = false,
}

function M.path()
	return os.getenv("IRCAGENTS_CONFIG") or confdir() .. "/config.lua"
end

-- ~ at the front of a path, which a config file will have.
function M.expand(p)
	if type(p) ~= "string" then
		return p
	end
	return (p:gsub("^~/", home() .. "/"))
end

local function copy(t)
	local o = {}

	for k, v in pairs(t) do
		o[k] = type(v) == "table" and copy(v) or v
	end
	return o
end

-- the file's table, or {} when there is none. A file that exists and
-- does not load is an error: silently falling back to defaults would
-- connect with the wrong settings and look like it worked.
function M.file(path)
	path = path or M.path()

	local f = io.open(path, "r")

	if not f then
		return {}
	end
	f:close()

	local chunk, err = loadfile(path, "t", {})

	if not chunk then
		error(err, 0)
	end

	local ok, t = pcall(chunk)

	if not ok then
		error(path .. ": " .. tostring(t), 0)
	end
	if type(t) ~= "table" then
		error(path .. ": must return a table", 0)
	end
	return t
end

-- Command line flags, through luaposix getopt (short options only;
-- luaposix has no getopt_long). "+" stops at the first operand, so the
-- nick or subcommand ends the flags; ":" reports a missing argument
-- apart from an unknown flag.
--
--      -s host   -p port   -c chan (repeatable)   -k keyfile
--      -d dir    -f config -r realname  -a maxage  -P (plaintext)
--      -h        help
--
-- "--help" is accepted too, since it is the first thing anyone tries.
M.OPTSTRING = "+:hPs:p:c:k:d:f:r:a:"

local OPTS = {
	s = "server", p = "port", c = "channels", k = "key_file",
	d = "dir", f = "config", r = "realname", a = "max_age",
	P = "plaintext", h = "help",
}

-- args(argv) -> overrides, operands. argv is Lua's arg table; errors
-- with a message on a bad flag.
function M.args(argv)
	local getopt = require("posix.unistd").getopt
	local a = { [0] = argv[0] or "irc-agent" }

	for i = 1, #argv do
		a[i] = argv[i] == "--help" and "-h" or argv[i]
	end

	local o, last = {}, 1

	for r, optarg, optind in getopt(a, M.OPTSTRING) do
		last = optind
		if r == "?" then
			error("unknown flag -" .. (a[optind - 1] or ""):sub(2), 0)
		elseif r == ":" then
			error("flag " .. a[optind - 1] .. " wants a value", 0)
		end

		local key = OPTS[r]

		if key == "channels" then
			o.channels = o.channels or {}
			o.channels[#o.channels + 1] = optarg
		elseif key == "port" or key == "max_age" then
			o[key] = tonumber(optarg) or
			    error("-" .. r .. ": not a number: " .. optarg, 0)
		elseif key == "plaintext" or key == "help" then
			o[key] = true
		else
			o[key] = optarg
		end
	end

	local pos = {}

	for i = last, #a do
		pos[#pos + 1] = a[i]
	end
	return o, pos
end

-- load(argv) -> config table, positionals
function M.load(argv)
	local cli, pos = M.args(argv or {})
	local c = copy(M.DEFAULTS)

	for k, v in pairs(M.file(cli.config)) do
		c[k] = v
	end
	for k, v in pairs(cli) do
		c[k] = v
	end
	c.config = nil
	c.key_file = M.expand(c.key_file)
	c.dir = M.expand(c.dir)
	return c, pos
end

return M
