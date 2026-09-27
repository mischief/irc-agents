-- conn: connections by id. Each daemon owns <dir>/<id>; the IRC nick
-- is state and can change. <id>/meta holds "label L" and "nick N" (the
-- nick wanted); <id>/nick holds the nick the server gave us. A
-- directory without meta uses its name as id, label and nick.

local dirent = require "posix.dirent"
local stat = require "posix.sys.stat"
local signal = require "posix.signal"

local irc = require "ircagent.irc"
local journal = require "ircagent.journal"

local M = {}

function M.validnick(n)
	return type(n) == "string" and #n >= 1 and #n <= 9 and
	    n:match("^[%a%[%]\\`_^{|}][%w%[%]\\`_^{|}-]*$") ~= nil
end

-- an id is a path name, so it must not hold a slash or dots
function M.validid(id)
	return type(id) == "string" and #id <= 32 and id:match("^%a[%w_-]*$") ~= nil
end

-- a label is one line of printable text without spaces
function M.validlabel(l)
	return type(l) == "string" and #l >= 1 and #l <= 128 and l:match("^[%g]+$") ~= nil
end

-- a letter, then five letters or digits: a valid nick, so the daemon can
-- use it when the server refuses the nick it wants
function M.newid()
	local f = assert(io.open("/dev/urandom", "rb"))
	local b = f:read(6)
	local A = "abcdefghijklmnopqrstuvwxyz"
	local AN = A .. "0123456789"
	local t = { A:sub(b:byte(1) % 26 + 1, b:byte(1) % 26 + 1) }

	f:close()
	for i = 2, 6 do
		local k = b:byte(i) % 36 + 1

		t[i] = AN:sub(k, k)
	end
	return table.concat(t)
end

function M.dir(cfg, id)
	return cfg.dir .. "/" .. id
end

function M.exists(cfg, id)
	local st = M.validid(id) and stat.stat(M.dir(cfg, id))

	return st and stat.S_ISDIR(st.st_mode) ~= 0 or false
end

local function readline(path)
	local f = io.open(path, "r")

	if not f then
		return nil
	end

	local l = f:read("l")

	f:close()
	return l
end

-- meta(cfg, id) -> { id, label, nick }
function M.meta(cfg, id)
	local m = { id = id, label = id, nick = id }
	local f = io.open(M.dir(cfg, id) .. "/meta", "r")

	if f then
		for l in f:lines() do
			local k, v = l:match("^(%a+) (.+)$")

			if k == "label" or k == "nick" then
				m[k] = v
			end
		end
		f:close()
	end
	return m
end

function M.setmeta(cfg, id, m)
	return journal.writeatomic(M.dir(cfg, id) .. "/meta",
	    ("label %s\nnick %s\n"):format(m.label, m.nick))
end

-- the nick the daemon holds on the server, or nil
function M.held(cfg, id)
	local n = readline(M.dir(cfg, id) .. "/nick")

	return n ~= "" and n or nil
end

-- pid of a live daemon for id, or nil
function M.pid(cfg, id)
	local pid = tonumber(readline(M.dir(cfg, id) .. "/pid") or "")

	if pid and signal.kill(pid, 0) == 0 then
		return pid
	end
	return nil
end

-- list(cfg) -> every connection, live or not, sorted by id
function M.list(cfg)
	local r = {}
	local ok, it = pcall(dirent.files, cfg.dir)

	if not ok then
		return r
	end
	for name in it do
		if name ~= "." and name ~= ".." and M.exists(cfg, name) then
			local m = M.meta(cfg, name)

			m.pid = M.pid(cfg, name)
			m.held = m.pid and M.held(cfg, name)
			r[#r + 1] = m
		end
	end
	table.sort(r, function(a, b) return a.id < b.id end)
	return r
end

local MATCH = {
	function(c, name) return c.label == name end,
	function(c, name) return c.held and irc.same(c.held, name) end,
	function(c, name) return irc.same(c.nick, name) end,
}

local function pick(all, name, live)
	for _, match in ipairs(MATCH) do
		local hit = {}

		for _, c in ipairs(all) do
			if (c.pid ~= nil) == live and match(c, name) then
				hit[#hit + 1] = c.id
			end
		end
		if #hit == 1 then
			return hit[1]
		end
		if #hit > 1 then
			return nil, ("%s names more than one connection: %s; use an id")
			    :format(name, table.concat(hit, " "))
		end
	end
end

-- resolve(cfg, name) -> id, or nil and error. name is an id, a label or
-- a nick. Live connections win over dead ones; within each, an id wins
-- over a label, then over the nick held, then over the nick wanted.
function M.resolve(cfg, name)
	local all = M.list(cfg)

	for _, live in ipairs { true, false } do
		if M.exists(cfg, name) and (M.pid(cfg, name) ~= nil) == live then
			return name
		end

		local id, err = pick(all, name, live)

		if id or err then
			return id, err
		end
	end
	return nil, "no connection named " .. name .. "; start one: irc-agent start NICK"
end

-- bylabel(cfg, label) -> the id of the connection with this label (or
-- this id), live first, or nil
function M.bylabel(cfg, label)
	local dead

	for _, c in ipairs(M.list(cfg)) do
		if c.label == label then
			if c.pid then
				return c.id
			end
			dead = dead or c.id
		end
	end
	return dead
end

return M
