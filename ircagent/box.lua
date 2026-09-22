-- box: what goes inside a PRIVMSG when everyone holding the key may
-- read it and nobody else may.
--
-- One shared 32-byte key, AEAD_CHACHA20_POLY1305 (RFC 8439), and the
-- result carried as a CID with the literal bytes inline:
--
--      u <base64url( cidv1 | CODEC | identity | len | payload )>
--      payload = nonce[12] .. sealed(time[8] .. text) .. tag[16]
--
-- The CID is what makes the line self-describing: version, codec and
-- length come with it, cid.lua decodes it by the spec, and a reader
-- that meets a codec it does not know says so rather than guessing.
-- The identity multihash (0x00) is how a CID holds data rather than an
-- address of it. base64url is the densest base the spec's multibase
-- table has, which matters with 512 bytes a line; the reader takes any
-- base cid.lua knows.
--
-- The pieces and why:
--
--   - The nonce is 12 random bytes per message. With one key shared by
--     every agent there is no counter anyone could keep, and at 2^96 a
--     collision is not a thing that happens on a chat server.
--   - The AAD is the CID header, then "from\0to", both lowercased the
--     rfc1459 way. The header in the AAD means the codec cannot be
--     swapped under a valid tag; from and to mean a key holder cannot
--     lift a DM meant for one agent and replay it into another's query
--     as if the first had said it.
--   - The plaintext starts with the sending time, big-endian seconds.
--     open() hands it back and the caller drops anything too old or
--     already seen: a replayed line is authentic, so the AEAD alone
--     does not stop it.
--
-- Splitting happens before sealing, never after: each piece is its own
-- box and opens on its own, so a lost line is a lost piece rather than
-- a message nobody can read.

local aead = require "ircagent.crypto.aead"
local irc = require "ircagent.irc"
local cid = require "ircagent.cid"

local M = {}

-- Private-use multicodec range (0x300000-0x3fffff): "irc-agent
-- chacha20-poly1305 box, version 1". Not registered, and does not need
-- to be; a new format takes the next number.
M.CODEC = 0x300001
M.BASE = "u"
M.KEY_LEN = aead.KEY_LEN
M.NONCE_LEN = aead.NONCE_LEN
M.TAG_LEN = aead.TAG_LEN

-- bytes a box adds to its text before encoding
M.OVERHEAD = M.NONCE_LEN + 8 + M.TAG_LEN

-- ---- randomness and keys ----

function M.random(n)
	local f = assert(io.open("/dev/urandom", "rb"))
	local s = f:read(n)

	f:close()
	assert(s and #s == n, "short read from /dev/urandom")
	return s
end

local function hex(s)
	return (s:gsub(".", function(c)
		return ("%02x"):format(c:byte())
	end))
end

-- a new key, as the one line of hex a key file holds.
function M.genkey()
	return hex(M.random(M.KEY_LEN))
end

-- read a key file: 64 hex digits, whitespace ignored. Refuses a file
-- anyone but the owner can read, the way ssh does, since a key that
-- leaked is a key that has to be changed on every agent at once.
function M.loadkey(path)
	local ok, st = pcall(require, "posix.sys.stat")

	if ok then
		local s = st.stat(path)

		if s and (s.st_mode & 0x3f) ~= 0 then
			return nil, path .. ": readable by group or other"
		end
	end

	local f, err = io.open(path, "rb")

	if not f then
		return nil, err
	end

	local h = f:read("a"):gsub("%s", "")

	f:close()
	if #h ~= M.KEY_LEN * 2 or h:find("%X") then
		return nil, path .. ": want " .. M.KEY_LEN * 2 .. " hex digits"
	end
	return (h:gsub("%x%x", function(b)
		return string.char(tonumber(b, 16))
	end))
end

-- ---- sealing ----

local function header(len)
	return cid.uvarint(cid.V1) .. cid.uvarint(M.CODEC) ..
	    cid.uvarint(cid.IDENTITY) .. cid.uvarint(len)
end

local function aad(hdr, from, to)
	return hdr .. irc.lower(from) .. "\0" .. irc.lower(to)
end

-- seal(key, from, to, text[, now[, nonce]]) -> wire string
-- now and nonce are for tests; left out they are the clock and
-- /dev/urandom.
function M.seal(key, from, to, text, now, nonce)
	now = now or os.time()
	nonce = nonce or M.random(M.NONCE_LEN)

	local hdr = header(M.OVERHEAD + #text)
	local sealed = aead.seal(key, nonce, string.pack(">i8", now) .. text,
	    aad(hdr, from, to))

	return cid.tostring(hdr .. nonce .. sealed, M.BASE)
end

-- open(key, from, to, wire) -> text, time, nonce; or nil and a reason.
-- "not a box" is the one reason that means plaintext rather than an
-- attack or a bug: the line does not parse as a CID of our codec.
function M.open(key, from, to, wire)
	if type(wire) ~= "string" or wire:find("%s") then
		return nil, "not a box"
	end

	local c = cid.parse(wire)

	if not c or c.version ~= 1 or c.codec ~= M.CODEC then
		return nil, "not a box"
	end
	if c.hash ~= cid.IDENTITY or #c.digest < M.OVERHEAD then
		return nil, "malformed"
	end

	local raw = c.digest
	local hdr = c.bytes:sub(1, #c.bytes - #raw)
	local nonce = raw:sub(1, M.NONCE_LEN)
	local pt = aead.open(key, nonce, raw:sub(M.NONCE_LEN + 1),
	    aad(hdr, from, to))

	if not pt then
		return nil, "forged or wrong key"
	end
	return pt:sub(9), string.unpack(">i8", pt), nonce
end

-- whether a PRIVMSG body is a box at all, without the key.
function M.isbox(s)
	if type(s) ~= "string" or s:find("%s") then
		return false
	end

	local c = cid.parse(s)

	return c ~= nil and c.version == 1 and c.codec == M.CODEC
end

-- ---- splitting ----

-- Room for the text of one piece. The server relays our line with our
-- full prefix in front, which we do not know exactly, so assume the
-- worst hybrid allows: nick 9, user 10, host 63.
local PREFIXMAX = 1 + 9 + 1 + 10 + 1 + 63 + 1

function M.room(to)
	local frame = PREFIXMAX + #("PRIVMSG " .. to .. " ") + 2
	-- one character of multibase prefix, then 6 bits a character
	local bytes = ((irc.MAXLINE - frame - 1) * 6) // 8
	return bytes - #header(0xffff) - M.OVERHEAD
end

-- cut text into pieces of at most n bytes, after a newline or space
-- where one is near and never inside a utf-8 sequence. Lossless: the
-- separator stays on the end of its piece, so concatenating the pieces
-- gives back the text exactly, which is what chunk.lua relies on.
function M.split(text, n)
	local out = {}

	while #text > n do
		local cut = n

		-- back off utf-8 continuation bytes
		while cut > 1 and (text:byte(cut + 1) or 0) & 0xc0 == 0x80 do
			cut = cut - 1
		end

		local ws = text:sub(1, cut):match(".*()[ \n]")

		if ws and ws > cut // 2 then
			out[#out + 1] = text:sub(1, ws)
			text = text:sub(ws + 1)
		else
			out[#out + 1] = text:sub(1, cut)
			text = text:sub(cut + 1)
		end
	end
	if #text > 0 or #out == 0 then
		out[#out + 1] = text
	end
	return out
end

return M
