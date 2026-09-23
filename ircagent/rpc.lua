-- rpc: payloads between a daemon and its local event clients, sent as
-- imsg over a unix socket. Sans-io. Each payload is a header, then body:
--
--      u8 version  u8 opcode  u16 flags  u64 sequence  u32 body_length
--
-- The imsg type is the class (M.T); the imsg id is the request id.

local M = {}

M.VERSION = 1

-- imsg types
M.T = {
	NEXT = 1,       -- client: next event after sequence
	EVENT = 2,      -- daemon: one event
	ACK = 3,        -- client: event at sequence printed and saved
	CONTROL = 4,    -- client: control request (disabled)
	CONTROL_R = 5,  -- daemon: control response
	ERROR = 6,      -- daemon: error, opcode is the code
	HELLO = 7,      -- both: version, nick, cursor, level; journal range
}

-- opcode of each type; ERROR carries an error code instead
M.OP = {
	[M.T.NEXT] = 1, [M.T.EVENT] = 1, [M.T.ACK] = 1, [M.T.CONTROL] = 1,
	[M.T.CONTROL_R] = 1, [M.T.HELLO] = 1,
}

M.E = {
	VERSION = 1,    -- unknown protocol version
	MALFORMED = 2,  -- payload fails to decode
	RESET = 3,      -- cursor outside the journal; sequence = oldest
	DISABLED = 4,   -- control requests are off
	STATE = 5,      -- request out of order, such as NEXT before HELLO
	NICK = 6,       -- hello names another nick
	JOURNAL = 7,    -- the daemon cannot write its journal
}

M.ENAME = {}

for k, v in pairs(M.E) do
	M.ENAME[v] = k:lower()
end

M.HDR = ">BBI2I8I4"
M.HDRLEN = string.packsize(M.HDR)

-- The largest body. A reassembled message can reach chunk.MAX_PENDING
-- (256 KiB), so both ends raise the imsg limit to M.MAXMSG.
M.MAXBODY = 512 * 1024
M.MAXMSG = M.HDRLEN + M.MAXBODY

M.LEVELS = { default = true, chan = true, all = true }

function M.header(opcode, seq, body, flags)
	body = body or ""
	assert(#body <= M.MAXBODY, "rpc: body too long")
	return M.HDR:pack(M.VERSION, opcode, flags or 0, seq or 0, #body) .. body
end

-- decode(typ, payload) -> { opcode, seq, body } or nil, error code, text
function M.decode(typ, payload)
	if #payload < M.HDRLEN then
		return nil, M.E.MALFORMED, "short header"
	end

	local ver, op, flags, seq, len = M.HDR:unpack(payload)

	if ver ~= M.VERSION then
		return nil, M.E.VERSION, "protocol version " .. ver .. ", want " .. M.VERSION
	end
	if typ ~= M.T.ERROR and M.OP[typ] ~= op then
		return nil, M.E.MALFORMED, ("type %d opcode %d"):format(typ, op)
	end
	if typ == M.T.ERROR and not M.ENAME[op] then
		return nil, M.E.MALFORMED, "unknown error code " .. op
	end
	if flags ~= 0 then
		return nil, M.E.MALFORMED, "unknown flags " .. flags
	end
	if len > M.MAXBODY or M.HDRLEN + len ~= #payload then
		return nil, M.E.MALFORMED, "bad body length"
	end
	if seq < 0 then
		return nil, M.E.MALFORMED, "sequence out of range"
	end
	return { opcode = op, seq = seq, body = payload:sub(M.HDRLEN + 1) }
end

-- run fmt:unpack over the whole of s; nil unless it fits exactly
local function unpackall(fmt, s)
	local ok, r = pcall(function()
		local t = table.pack(fmt:unpack(s))

		if t[t.n] ~= #s + 1 then
			return nil
		end
		t[t.n], t.n = nil, t.n - 1
		return t
	end)

	return ok and r or nil
end

-- ---- event ----

local EV = ">s1s1s1s4I8"

-- ev = { kind, from, target, text, time }
function M.event(ev)
	return EV:pack(ev.kind, ev.from or "-", ev.target or "-", ev.text or "",
	    ev.time or 0)
end

function M.unevent(body)
	local t = unpackall(EV, body)

	if not t or t[1] == "" or t[5] < 0 then
		return nil
	end
	return { kind = t[1], from = t[2], target = t[3], text = t[4], time = t[5] }
end

local function esc(s)
	return (tostring(s):gsub("\\", "\\\\"):gsub("\n", "\\n")
	    :gsub("[%z\1-\31\127]", ""))
end

M.esc = esc

-- the out file's line for an event: TIME KIND FROM TARGET TEXT
function M.format(ev)
	return ("%s %s %s %s %s"):format(os.date("!%Y-%m-%dT%H:%M:%SZ", ev.time),
	    ev.kind, ev.from or "-", ev.target or "-", esc(ev.text or ""))
end

-- ---- hello ----
--
-- client: sequence = cursor; body = nick, level, epoch ("" for none)
-- daemon: sequence = newest; body = epoch, oldest, newest

local HELLO = ">s1s1s1"
local HELLO_R = ">s1I8I8"

function M.hello(nick, level, epoch)
	return HELLO:pack(nick, level, epoch or "")
end

function M.unhello(body)
	local t = unpackall(HELLO, body)

	if not t or not M.LEVELS[t[2]] then
		return nil
	end
	return { nick = t[1], level = t[2], epoch = t[3] }
end

function M.hellor(epoch, oldest, newest)
	return HELLO_R:pack(epoch, oldest, newest)
end

function M.unhellor(body)
	local t = unpackall(HELLO_R, body)

	if not t or t[1] == "" or t[2] < 0 or t[3] < 0 then
		return nil
	end
	return { epoch = t[1], oldest = t[2], newest = t[3] }
end

-- ---- next ----
--
-- sequence = last delivered; body = level

local NEXT = ">s1"

function M.next(level)
	return NEXT:pack(level)
end

function M.unnext(body)
	local t = unpackall(NEXT, body)

	if not t or not M.LEVELS[t[1]] then
		return nil
	end
	return t[1]
end

return M
