-- ircagent.lua: read and write irc-agent's sealed messages in WeeChat.
--
-- Boxes arriving on a watched server are opened in place, pieces of a
-- long message are held until the last one comes, and what you type to
-- an encrypted target is split, numbered and sealed the way the agents
-- do it. The crypto and framing are the irc-agent modules themselves
-- (ircagent/filter.lua), not a second copy.
--
-- Install:
--      ~/.local/share/weechat/lua/ircagent.lua
--      ~/.local/share/weechat/lua/ircagent/...   (the module tree)
-- and the shared key at ~/.config/ircagents/key, mode 0600.
--
--      /script load ircagent.lua
--      /ircagent                    status
--      /ircagent add [target]       encrypt to a channel or nick
--      /ircagent del [target]       stop
--      /ircagent probe [target]     does target run irc-agent, same key?
--
-- The first DM to a nick each session probes it too, and says in the
-- query buffer whether that nick can read what you send.
--      /ircagent reload             re-read options and key
--
-- Options (plugins.var.lua.ircagent.*):
--      servers   comma list of weechat server names  (offblast)
--      targets   comma list encrypted by default     (#agents)
--      key_file  path of the shared key              (~/.config/ircagents/key)
--      all_dms   encrypt every private message       (on)
--
-- WeeChat's lua plugin is Lua 5.3 on Debian; the modules keep to 5.3.

local NAME = "ircagent"

if not weechat.register(NAME, "mischief", "0.1.0", "MIT",
    "irc-agent chacha20-poly1305 boxes, opened and sealed", "", "") then
	return
end

local here = debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") or "."
local base = here:gsub("/autoload$", "")
local home = os.getenv("HOME") or ""

package.path = table.concat({
	base .. "/?.lua", base .. "/?/init.lua", package.path,
}, ";")

local function err(msg)
	weechat.print("", weechat.prefix("error") .. NAME .. ": " .. msg)
end

local ok, filter = pcall(require, "ircagent.filter")

if not ok then
	err(tostring(filter))
	return
end

local box = require "ircagent.box"
local probe = require "ircagent.probe"
local irc = require "ircagent.irc"

-- ---- options ----

local DEFAULTS = {
	servers = { "offblast", "weechat server names to watch" },
	targets = { "#agents", "channels and nicks encrypted by default" },
	key_file = { "~/.config/ircagents/key", "shared key file" },
	all_dms = { "on", "encrypt every private message on watched servers" },
}

for k, v in pairs(DEFAULTS) do
	if weechat.config_is_set_plugin(k) == 0 then
		weechat.config_set_plugin(k, v[1])
	end
	weechat.config_set_desc_plugin(k, v[2])
end

local function list(s)
	local t = {}

	for x in s:gmatch("[^,%s]+") do
		t[#t + 1] = x
	end
	return t
end

-- ---- state ----

local filters = {}   -- server -> filter
local probers = {}   -- server -> probe
local key

local function setup()
	local path = weechat.config_get_plugin("key_file"):gsub("^~/", home .. "/")
	local k, kerr = box.loadkey(path)

	filters, probers, key = {}, {}, k
	if not k then
		return err(kerr)
	end

	local targets = list(weechat.config_get_plugin("targets"))

	for _, s in ipairs(list(weechat.config_get_plugin("servers"))) do
		probers[s] = probe.new(k)
		filters[s] = filter.new({ key = k, targets = targets,
		    all_dms = weechat.config_string_to_boolean(
		        weechat.config_get_plugin("all_dms")) == 1 })
	end
end

setup()

-- ---- modifiers ----

-- irc_in2_privmsg: the line after charset decoding. Lines returned
-- newline-separated are handled as that many messages; an empty string
-- drops the line.
function ircagent_in(_, _, server, line)
	local f = filters[server]

	if not f then
		return line
	end

	local okk, out = pcall(f.inbound, f, line,
	    weechat.info_get("irc_nick", server), os.time())

	if not okk then
		err("inbound: " .. tostring(out))
		return line
	end
	return table.concat(out, "\n")
end

-- irc_out1_privmsg: before WeeChat's own 512-byte split, which would
-- otherwise cut plaintext into lines that no longer fit once sealed.
-- The first sealed line replaces this one; the rest go out with /quote,
-- come back through here as boxes, and are left alone.
function ircagent_out(_, _, server, line)
	local f = filters[server]

	if not f then
		return line
	end

	-- first DM to a nick this session: ask whether it can read us.
	-- The message still goes out sealed; the answer only tells you.
	local target = line:match("^PRIVMSG (%S+) ")
	local p = probers[server]

	if target and p and not irc.ischannel(target) and f:encrypts(target)
	    and not p.known[irc.lower(target)] and not p:pending_for(target) then
		weechat.command("", "/quote -server " .. server .. " PRIVMSG " ..
		    target .. " :\1" .. probe.VERB .. " " .. p:ask(target, os.time()) .. "\1")
	end

	local okk, out = pcall(f.outbound, f, line,
	    weechat.info_get("irc_nick", server))

	if not okk then
		-- refusing to send is the safe failure: a message meant to
		-- be sealed must not go out in the clear
		err("not sent: " .. tostring(out))
		return ""
	end
	for i = 2, #out do
		weechat.command("", "/quote -server " .. server .. " " .. out[i])
	end
	return out[1]
end

weechat.hook_modifier("irc_in2_privmsg", "ircagent_in", "")

local function pvbuffer(server, nick)
	local b = weechat.buffer_search("irc", server .. "." .. nick)

	if b == "" then
		b = weechat.buffer_search("irc", "server." .. server)
	end
	return b
end

local SAYS = {
	ok = "runs irc-agent with our key; messages are encrypted",
	["wrong key"] = "answers but holds a DIFFERENT key; it cannot read you",
	["no answer"] = "did not answer a probe: no irc-agent, or an old one; it may not read you",
}

local function report(server, nick, r)
	weechat.print(pvbuffer(server, nick), (r == "ok" and "" or
	    weechat.prefix("error")) .. NAME .. ": " .. nick .. " " .. SAYS[r])
end

-- answers to our probes, and probes from others, both arrive as CTCP:
-- a NOTICE for the answer, a PRIVMSG for the question. Hidden from the
-- buffer either way; the result is printed instead.
function ircagent_notice(_, _, server, line)
	local p = probers[server]
	local m = p and irc.parse(line)

	if not m or not m.nick then
		return line
	end

	local verb, arg = irc.isctcp(m.params[2] or "")

	if verb ~= probe.VERB then
		return line
	end

	local r = p:result(weechat.info_get("irc_nick", server), m.nick, arg, os.time())

	if r then
		report(server, m.nick, r)
	end
	return ""
end

function ircagent_ctcp(_, _, server, line)
	local p = probers[server]
	local m = p and irc.parse(line)

	if not m or not m.nick then
		return line
	end

	local verb, arg = irc.isctcp(m.params[2] or "")

	if verb ~= probe.VERB then
		return line
	end

	local body = p:reply(weechat.info_get("irc_nick", server), m.nick, arg)

	if body then
		weechat.command("", "/quote -server " .. server .. " NOTICE " ..
		    m.nick .. " :\1" .. probe.VERB .. " " .. body .. "\1")
	end
	return ""
end

weechat.hook_modifier("irc_in2_notice", "ircagent_notice", "")
-- runs before ircagent_in on the same line; returns it untouched
-- unless it is a probe
weechat.hook_modifier("1000|irc_in2_privmsg", "ircagent_ctcp", "")
weechat.hook_modifier("irc_out1_privmsg", "ircagent_out", "")

-- WeeChat prints what we typed from the line we returned above -- the
-- sealed one -- or, with echo-message, from the server's copy of it.
-- Either way the buffer shows our own box; put the text back. Lines
-- of ours carry self_msg; pieces after the first vanish.
function ircagent_line(_, line)
	local server = line.buffer_name:match("^irc%.([^.]+)%.")
	local f = server and filters[server]

	if not f or not line.message:find("u", 1, true) then
		return {}
	end

	local text = f:mine(line.message)

	if text == nil then
		return {}
	end
	if text == "" then
		return { buffer = "" }
	end
	return { message = text }
end

weechat.hook_line("", "irc.*", "irc_privmsg+self_msg", "ircagent_line", "")

function ircagent_timer()
	for s, p in pairs(probers) do
		for _, g in ipairs(p:expire(os.time())) do
			report(s, g.nick, g.result)
		end
	end
	for s, f in pairs(filters) do
		for _, msg in ipairs(f:expire(os.time())) do
			weechat.print(weechat.buffer_search("irc", "server." .. s),
			    weechat.prefix("error") .. NAME .. ": " .. msg)
		end
	end
	return weechat.WEECHAT_RC_OK
end

weechat.hook_timer(2 * 1000, 0, 0, "ircagent_timer", "")

-- ---- /ircagent ----

function ircagent_cmd(_, buffer, args)
	local verb, target = args:match("^(%S*)%s*(%S*)")
	local s = weechat.buffer_get_string(buffer, "localvar_server")
	local f = filters[s]

	if verb == "reload" then
		setup()
		weechat.print(buffer, NAME .. ": reloaded")
		return weechat.WEECHAT_RC_OK
	end
	if not f then
		weechat.print(buffer, NAME .. ": " .. (key and
		    ("server " .. (s ~= "" and s or "?") .. " not watched") or
		    "no key loaded"))
		return weechat.WEECHAT_RC_OK
	end
	if target == "" then
		target = weechat.buffer_get_string(buffer, "localvar_channel")
	end
	if verb == "probe" and target ~= "" then
		local p = probers[s]

		weechat.command("", "/quote -server " .. s .. " PRIVMSG " .. target ..
		    " :\1" .. probe.VERB .. " " .. p:ask(target, os.time()) .. "\1")
		weechat.print(buffer, NAME .. ": probing " .. target)
		return weechat.WEECHAT_RC_OK
	end
	if verb == "add" and target ~= "" then
		f:add(target)
		weechat.print(buffer, NAME .. ": encrypting to " .. target)
	elseif verb == "del" and target ~= "" then
		f:remove(target)
		weechat.print(buffer, NAME .. ": plaintext to " .. target)
	else
		local t = {}

		if f.all_dms then
			t[#t + 1] = "(all nicks)"
		end
		for k in pairs(f.targets) do
			t[#t + 1] = k:sub(1, 1) == "-" and "except " .. k:sub(2) or k
		end
		table.sort(t)
		weechat.print(buffer, ("%s: %s encrypting to %s"):format(NAME, s,
		    #t > 0 and table.concat(t, " ") or "nothing"))
	end
	return weechat.WEECHAT_RC_OK
end

weechat.hook_command(NAME, "irc-agent encryption",
    "[add|del|probe [target]] | reload",
    "   add: encrypt to target (default: this buffer)\n" ..
    "   del: stop encrypting to target\n" ..
    " probe: ask target whether it runs irc-agent with our key\n" ..
    "reload: re-read options and key",
    "add|del|probe|reload", "ircagent_cmd", "")
