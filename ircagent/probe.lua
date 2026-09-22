-- probe: does that nick run irc-agent, with our key?
--
-- A CTCP challenge and a sealed answer:
--
--      A -> B   PRIVMSG B :\1IRCAGENT <token>\1
--      B -> A   NOTICE  A :\1IRCAGENT <box from B to A: "IRCAGENT <token>">\1
--
-- The token is 16 random bytes, fresh per probe, so an old answer
-- cannot be replayed; the box's AAD binds B and A, so an answer cannot
-- be lifted from another conversation. What an answer proves is what
-- the shared key proves: the other side holds the key. Not that it is
-- really B -- any key holder could answer as B.
--
-- Results, per nick:
--      ok          answered, and the box opened with our key
--      wrong key   answered, but the box did not open
--      no answer   nothing within the timeout: a human without the
--                  plugin, an old daemon, or somebody not there
--
-- Sans-io: the caller sends the lines and passes the clock in. The
-- daemon and the WeeChat script both use this.

local box = require "ircagent.box"
local cid = require "ircagent.cid"
local irc = require "ircagent.irc"

local M = {}

M.VERB = "IRCAGENT"
M.TIMEOUT = 6

local P = {}

P.__index = P

function M.new(key)
	return setmetatable({
		key = key,
		pending = {},  -- lower(nick) -> { token, sent, nick }
		known = {},    -- lower(nick) -> result
	}, P)
end

local function valid(token)
	return type(token) == "string" and #token >= 16 and #token <= 64 and
	    token:match("^[%w_-]+$") ~= nil
end

M.valid = valid

-- ask(nick, now) -> token to send as \1IRCAGENT token\1
function P:ask(nick, now)
	local token = cid.bases.u.enc(box.random(16))

	self.pending[irc.lower(nick)] = { token = token, sent = now, nick = nick }
	return token
end

function P:pending_for(nick)
	return self.pending[irc.lower(nick)] ~= nil
end

-- reply(me, asker, token) -> body for the NOTICE, or nil when the
-- token is not one
function P:reply(me, asker, token)
	if not valid(token) then
		return nil
	end
	return box.seal(self.key, me, asker, M.VERB .. " " .. token)
end

-- result(me, responder, body, now) -> "ok" | "wrong key", or nil when
-- we did not ask this nick anything
function P:result(me, responder, body, now)
	local l = irc.lower(responder)
	local p = self.pending[l]

	if not p then
		return nil
	end
	self.pending[l] = nil

	local text = box.open(self.key, responder, me, body or "")
	local r = text == M.VERB .. " " .. p.token and "ok" or "wrong key"

	self.known[l] = r
	return r
end

-- expire(now[, timeout]) -> list of { nick, result = "no answer" }
function P:expire(now, timeout)
	timeout = timeout or M.TIMEOUT

	local out = {}

	for l, p in pairs(self.pending) do
		if now - p.sent >= timeout then
			self.pending[l] = nil
			self.known[l] = "no answer"
			out[#out + 1] = { nick = p.nick, result = "no answer" }
		end
	end
	return out
end

return M
