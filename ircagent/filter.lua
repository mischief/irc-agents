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
		-- every nick, not only listed ones: on a server of agents a
		-- DM that goes out plain is a DM the agent drops unread
		all_dms = opts.all_dms ~= false,
		-- wire -> { text, first } for what we sealed, so a client
		-- that echoes its own line back can show the text instead
		sent = {},
		nsent = 0,
	}, F)

	for _, t in ipairs(opts.targets or {}) do
		f.targets[irc.lower(t)] = true
	end
	return f
end

function F:encrypts(target)
	local l = irc.lower(target)

	if self.targets["-" .. l] then
		return false
	end
	if self.all_dms and not irc.ischannel(target) then
		return true
	end
	return self.targets[l] == true
end

function F:add(target)
	local l = irc.lower(target)

	self.targets["-" .. l] = nil
	self.targets[l] = true
end

-- a removed nick is remembered as an exception, so "del" works for a
-- nick that all_dms would otherwise cover.
function F:remove(target)
	local l = irc.lower(target)

	self.targets[l] = nil
	if not irc.ischannel(target) then
		self.targets["-" .. l] = true
	end
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
	local wires = chunk.seal(self.key, mynick, target, text)

	-- bounded: a client that never shows its own lines must not grow
	-- this forever
	if self.nsent > 256 then
		self.sent, self.nsent = {}, 0
	end
	for i, w in ipairs(wires) do
		out[#out + 1] = (irc.privmsg(target, w):gsub("\r\n$", ""))
		self.sent[w] = { text = text, first = i == 1 }
		self.nsent = self.nsent + 1
	end
	return out
end

-- mine(shown) -> text, or "" to hide, or nil when shown holds no box we
-- sealed. For the client's own echo of what it sent: the first piece
-- becomes the whole text, the other pieces disappear.
function F:mine(shown)
	for w in shown:gmatch("u[%w_-]+") do
		local e = self.sent[w]

		if e then
			self.sent[w] = nil
			self.nsent = self.nsent - 1
			if not e.first then
				return ""
			end
			local i, j = shown:find(w, 1, true)

			return shown:sub(1, i - 1) .. M.LOCK .. e.text .. shown:sub(j + 1)
		end
	end
	return nil
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
