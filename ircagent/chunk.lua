-- chunk: one message too big for a line, as several that each fit.
--
-- The order is split, then number, then seal:
--
--      text -> pieces -> id|n|m|piece -> box.seal each -> one PRIVMSG each
--
-- so every line on the wire is a complete box that opens alone, and the
-- numbering is inside the ciphertext where nobody without the key can
-- read it, reorder it, or splice a piece of one message into another.
-- The header, big-endian:
--
--      id[4]  random per message, grouping its pieces
--      n[2]   this piece, 1-based
--      m[2]   pieces in the message
--
-- A one-line message is 1/1 and goes through the same path; there is no
-- second format to keep straight.
--
-- The assembler is sans-io like the rest: feed it opened pieces, it
-- hands back whole messages. It holds partial ones for a while and then
-- gives up on them, and it bounds how much it will hold, because the
-- pieces come off a network and a sender that never finishes is a
-- sender that grows our memory.

local box = require "ircagent.box"
local irc = require "ircagent.irc"

local M = {}

M.HEADER = 8
M.MAX_PIECES = 64
M.TIMEOUT = 120
M.MAX_PENDING = 256 * 1024

function M.pack(id, n, m, piece)
	return string.pack(">c4I2I2", id, n, m) .. piece
end

-- unpack(body) -> id, n, m, piece; or nil, reason
function M.unpack(body)
	if #body < M.HEADER then
		return nil, "short chunk"
	end

	local id, n, m = string.unpack(">c4I2I2", body)

	if m < 1 or m > M.MAX_PIECES or n < 1 or n > m then
		return nil, ("bad chunk %d/%d"):format(n, m)
	end
	return id, n, m, body:sub(M.HEADER + 1)
end

-- bodies(to, text[, id]) -> list of numbered bodies, each fitting one
-- sealed line to `to`. Errors when the text needs more than MAX_PIECES:
-- better the sender hears it than the receiver drops it.
function M.bodies(to, text, id)
	id = id or box.random(4)

	local pieces = box.split(text, box.room(to) - M.HEADER)

	if #pieces > M.MAX_PIECES then
		error(("message needs %d lines, limit %d"):format(#pieces,
		    M.MAX_PIECES), 0)
	end

	local out = {}

	for i, p in ipairs(pieces) do
		out[i] = M.pack(id, i, #pieces, p)
	end
	return out
end

-- seal(key, from, to, text) -> list of wire strings, one per line
function M.seal(key, from, to, text)
	local out = {}

	for i, b in ipairs(M.bodies(to, text)) do
		out[i] = box.seal(key, from, to, b)
	end
	return out
end

-- ---- reassembly ----

local Asm = {}

Asm.__index = Asm

function M.assembler(opts)
	opts = opts or {}
	return setmetatable({
		timeout = opts.timeout or M.TIMEOUT,
		limit = opts.limit or M.MAX_PENDING,
		pending = {},  -- key -> { m, got, parts, bytes, born, from, to }
		bytes = 0,
		dropped = 0,
	}, Asm)
end

local function keyof(from, to, id)
	return irc.lower(from) .. "\0" .. irc.lower(to) .. "\0" .. id
end

function Asm:forget(k)
	local p = self.pending[k]

	if p then
		self.bytes = self.bytes - p.bytes
		self.pending[k] = nil
	end
end

-- expire(now) -> list of { from, to, got, m } given up on
function Asm:expire(now)
	local gone = {}

	for k, p in pairs(self.pending) do
		if now - p.born > self.timeout then
			gone[#gone + 1] = { from = p.from, to = p.to, got = p.got, m = p.m }
			self:forget(k)
			self.dropped = self.dropped + 1
		end
	end
	return gone
end

-- add(from, to, body, now) -> text when the message is whole, else nil.
-- A second reason comes back when the piece was refused.
function Asm:add(from, to, body, now)
	local id, n, m, piece = M.unpack(body)

	if not id then
		return nil, n
	end
	if m == 1 then
		return piece
	end

	local k = keyof(from, to, id)
	local p = self.pending[k]

	if not p then
		if self.bytes + #piece > self.limit then
			return nil, "too much pending"
		end
		p = { m = m, got = 0, parts = {}, bytes = 0, born = now,
		    from = from, to = to }
		self.pending[k] = p
	end
	if p.m ~= m then
		return nil, "piece count changed"
	end
	if p.parts[n] then
		return nil, "duplicate piece"
	end
	if self.bytes + #piece > self.limit then
		return nil, "too much pending"
	end

	p.parts[n] = piece
	p.got = p.got + 1
	p.bytes = p.bytes + #piece
	self.bytes = self.bytes + #piece

	if p.got < p.m then
		return nil
	end

	local text = table.concat(p.parts, "", 1, p.m)

	self:forget(k)
	return text
end

return M
