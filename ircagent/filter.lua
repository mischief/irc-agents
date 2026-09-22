-- filter: raw IRC lines in, raw IRC lines out, boxes opened and sealed
-- on the way through.
--
-- For a client that owns its own socket and only lets us rewrite lines
-- -- WeeChat's irc_in2_privmsg and irc_out1_privmsg modifiers are the
-- case this exists for. Sans-io like the rest: no clock and no client
-- API in here, both are passed in, so the spec drives it with strings.
--
--      local f = filter.new{ key = key, targets = { "#agents" } }
--      lines = f:inbound(line, mynick, now)    -- list, maybe empty
--      lines = f:outbound(line, mynick)        -- list
--
-- Inbound, a box that opens becomes the same PRIVMSG with the text in
-- place of the box, one line per line of text; a piece of a longer
-- message becomes nothing until the last piece arrives. A box that does
-- not open is shown, marked, rather than hidden: somebody sending junk
-- into the channel is worth seeing.
--
-- Outbound, a PRIVMSG to a target in the list is split, numbered and
-- sealed the same way the daemon does it (chunk.lua). A nick that sends
-- us a box is added to the list, so replying to an agent's DM is
-- encrypted without being told to.

local irc = require "ircagent.irc"
local box = require "ircagent.box"
local chunk = require "ircagent.chunk"

local M = {}

local F = {}

F.__index = F

M.LOCK = "[e] "
M.BAD = "[!] "

function M.new(opts)
	local f = setmetatable({
		key = assert(opts.key, "filter: no key"),
		targets = {},
		asm = chunk.assembler(),
		seen = {},
		max_age = opts.max_age or 300,
		learn = opts.learn ~= false,
	}, F)

	for _, t in ipairs(opts.targets or {}) do
		f.targets[irc.lower(t)] = true
	end
	return f
end

function F:encrypts(target)
	return self.targets[irc.lower(target)] == true
end

function F:add(target)
	self.targets[irc.lower(target)] = true
end

function F:remove(target)
	self.targets[irc.lower(target)] = nil
end

local function fresh(self, nonce, t, now)
	for k, exp in pairs(self.seen) do
		if exp < now then
			self.seen[k] = nil
		end
	end
	if math.abs(now - t) > self.max_age or self.seen[nonce] then
		return false
	end
	self.seen[nonce] = now + 2 * self.max_age
	return true
end

-- the same message with another text, keeping tags and prefix.
local function rewrite(m, target, text)
	return irc.format({ prefix = m.prefix, cmd = "PRIVMSG",
	    params = { target, text } }):gsub("\r\n$", "")
end

-- lines of text, each a PRIVMSG of its own: a client shows one line a
-- message, and a newline inside one would be cut by irc.format anyway.
local function aslines(m, target, prefix, text)
	local out = {}

	for l in (text .. "\n"):gmatch("([^\n]*)\n") do
		out[#out + 1] = rewrite(m, target, prefix .. l)
	end
	return out
end

-- inbound(line, mynick, now) -> list of lines to hand the client
function F:inbound(line, mynick, now)
	local m = irc.parse(line)

	if not m or m.cmd ~= "PRIVMSG" or not m.nick then
		return { line }
	end

	local target, text = m.params[1], m.params[2] or ""

	if not box.isbox(text) then
		return { line }
	end

	-- the AAD names the target as the sender wrote it: our nick for a
	-- DM, the channel otherwise. Both are compared lowercased.
	local pt, t, nonce = box.open(self.key, m.nick, target, text)

	if not pt then
		return { rewrite(m, target, M.BAD .. t) }
	end
	if not fresh(self, nonce, t, now) then
		return { rewrite(m, target, M.BAD .. "stale or replayed") }
	end

	local whole, why = self.asm:add(m.nick, target, pt, now)

	if not whole then
		if why then
			return { rewrite(m, target, M.BAD .. why) }
		end
		return {}
	end
	if self.learn and irc.same(target, mynick) then
		self:add(m.nick)
	end
	return aslines(m, target, M.LOCK, whole)
end

-- outbound(line, mynick) -> list of lines to send instead
function F:outbound(line, mynick)
	local m = irc.parse(line)

	if not m or m.cmd ~= "PRIVMSG" or #m.params < 2 then
		return { line }
	end

	local target, text = m.params[1], m.params[2]

	-- ctcp (/me included) stays plain: the other side's client has to
	-- see the \1 to know what it is.
	if not self:encrypts(target) or irc.isctcp(text) or box.isbox(text) then
		return { line }
	end

	local out = {}

	for _, w in ipairs(chunk.seal(self.key, mynick, target, text)) do
		out[#out + 1] = (irc.privmsg(target, w):gsub("\r\n$", ""))
	end
	return out
end

-- for a timer: pieces that never completed, as text worth showing.
function F:expire(now)
	local out = {}

	for _, g in ipairs(self.asm:expire(now)) do
		out[#out + 1] = ("incomplete message from %s to %s: %d of %d pieces"):format(
		    g.from, g.to, g.got, g.m)
	end
	return out
end

return M
