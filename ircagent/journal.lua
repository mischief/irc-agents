-- journal: every event the daemon emits, numbered and kept on disk so
-- a client can resume from its cursor. Two files, events and events.1,
-- each up to opts.max bytes; a full events file rotates to events.1.
-- events.meta holds the epoch. A new epoch means sequences restarted,
-- and a cursor from the old epoch is a gap.

local fcntl = require "posix.fcntl"
local unistd = require "posix.unistd"
local stat = require "posix.sys.stat"

local rpc = require "ircagent.rpc"

local M = {}

M.MAGIC = "IAJR"
M.VERSION = 1
M.MAX = 1024 * 1024

local HDR = ">c4BI8I4"
local HDRLEN = HDR:packsize()

local CRC = {}

for i = 0, 255 do
	local c = i

	for _ = 1, 8 do
		c = (c & 1) ~= 0 and (0xEDB88320 ~ (c >> 1)) or (c >> 1)
	end
	CRC[i] = c
end

function M.crc32(s)
	local c = 0xFFFFFFFF

	for i = 1, #s do
		c = CRC[(c ~ s:byte(i)) & 0xFF] ~ (c >> 8)
	end
	return c ~ 0xFFFFFFFF
end

function M.record(seq, payload)
	local h = HDR:pack(M.MAGIC, M.VERSION, seq, #payload) .. payload

	return h .. (">I4"):pack(M.crc32(h))
end

-- scan(data) -> records, good length, corrupt. A bad record at the end
-- is a torn write and is dropped; a bad record before good data is not.
function M.scan(data)
	local recs, off = {}, 1

	while off <= #data do
		if #data - off + 1 < HDRLEN then
			return recs, off - 1, false
		end

		local magic, ver, seq, len = HDR:unpack(data, off)
		local pend = off + HDRLEN + len

		if magic ~= M.MAGIC or ver ~= M.VERSION then
			return recs, off - 1, true
		end
		if pend + 3 > #data then
			return recs, off - 1, false
		end

		local crc = (">I4"):unpack(data, pend)
		local ev = crc == M.crc32(data:sub(off, pend - 1)) and
		    rpc.unevent(data:sub(off + HDRLEN, pend - 1))

		if not ev then
			-- a bad checksum on the last record is a torn write
			return recs, off - 1, not (crc and pend + 3 == #data and
			    crc ~= M.crc32(data:sub(off, pend - 1)))
		end
		recs[#recs + 1] = { seq = seq, ev = ev }
		off = pend + 4
	end
	return recs, #data, false
end

local function readfile(path)
	local f = io.open(path, "rb")

	if not f then
		return nil
	end

	local d = f:read("a")

	f:close()
	return d
end

local function newepoch()
	local f = io.open("/dev/urandom", "rb")
	local r = f and f:read(8)

	if f then
		f:close()
	end
	if not r or #r ~= 8 then
		r = ("<I4I4"):pack(os.time(), unistd.getpid())
	end
	return (r:gsub(".", function(c) return ("%02x"):format(c:byte()) end))
end

local function writeatomic(path, data)
	local tmp = path .. ".tmp"
	local fd = fcntl.open(tmp, fcntl.O_WRONLY | fcntl.O_CREAT | fcntl.O_TRUNC,
	    tonumber("600", 8))

	if not fd then
		return nil, "cannot create " .. tmp
	end

	local n = unistd.write(fd, data)

	if unistd.fsync then
		unistd.fsync(fd)
	end
	unistd.close(fd)
	if n ~= #data then
		os.remove(tmp)
		return nil, "short write to " .. tmp
	end
	return os.rename(tmp, path)
end

M.writeatomic = writeatomic

local J = {}

J.__index = J

-- open(dir, opts) -> journal. Recovers what survives in dir.
function M.open(dir, opts)
	opts = opts or {}

	local j = setmetatable({
		dir = dir,
		path = dir .. "/events",
		old = dir .. "/events.1",
		meta = dir .. "/events.meta",
		max = opts.max or M.MAX,
		recs = {},
		next = 1,
		-- level -> want(ev), and the newest dropped seq each wanted
		levels = opts.levels or {},
		dropped = {},
	}, J)

	local epoch = (readfile(j.meta) or ""):match("^(%x+)\n")
	local cur, prev = readfile(j.path), readfile(j.old)
	local ok = epoch and (cur or prev)

	if ok then
		local r1, good1, bad1 = M.scan(prev or "")
		local r2, good2, bad2 = M.scan(cur or "")

		-- events.1 was whole when it rotated; any tail there is damage
		ok = not bad1 and not bad2 and good1 == #(prev or "")
		for _, r in ipairs(r1) do
			r.file = j.old
		end
		for _, r in ipairs(r2) do
			r.file = j.path
			r1[#r1 + 1] = r
		end
		-- sequences run on by one across both files
		for i = 2, #r1 do
			ok = ok and r1[i].seq == r1[i - 1].seq + 1
		end
		if ok then
			j.recs = r1
			j.next = #r1 > 0 and r1[#r1].seq + 1 or 1
			if cur and good2 < #cur then
				unistd.truncate(j.path, good2)
				j.torn = #cur - good2
			end
		end
	end
	if not ok then
		if cur or prev then
			j.reset = "journal damaged; new epoch"
			os.rename(j.path, j.path .. ".bad")
			os.remove(j.old)
		end
		epoch = newepoch()
		j.recs, j.next = {}, 1
		assert(writeatomic(j.meta, epoch .. "\n"))
	end
	j.epoch = epoch
	-- what rotated out before this open is unknown
	j.known = j:oldest()
	j.fd = assert(fcntl.open(j.path, fcntl.O_WRONLY | fcntl.O_APPEND | fcntl.O_CREAT,
	    tonumber("600", 8)))

	local st = stat.fstat(j.fd)

	j.size = st and st.st_size or 0
	return j
end

function J:oldest()
	return #self.recs > 0 and self.recs[1].seq or self.next
end

function J:newest()
	return self.next - 1
end

function J:rotate()
	unistd.close(self.fd)
	assert(os.rename(self.path, self.old))
	self.fd = assert(fcntl.open(self.path,
	    fcntl.O_WRONLY | fcntl.O_APPEND | fcntl.O_CREAT, tonumber("600", 8)))
	self.size = 0

	-- keep in memory only what events.1 and events hold
	local keep = {}

	for _, r in ipairs(self.recs) do
		if r.file == self.path then
			r.file = self.old
			keep[#keep + 1] = r
		else
			for lv, want in pairs(self.levels) do
				if want(r.ev) then
					self.dropped[lv] = r.seq
				end
			end
		end
	end
	self.recs = keep
end

-- gap(seq, level): true when an event past seq that level wants is no
-- longer here, or when seq is not a sequence of this journal.
function J:gap(seq, level)
	if seq > self:newest() then
		return true
	end
	if seq + 1 >= self:oldest() then
		return false
	end
	return seq + 1 < self.known or seq < (self.dropped[level] or 0)
end

-- append(ev) -> seq, or nil and error. The record is on disk before
-- this returns.
function J:append(ev)
	if self.failed then
		return nil, self.failed
	end

	local seq = self.next
	local rec = M.record(seq, rpc.event(ev))
	local n, err = unistd.write(self.fd, rec)

	if n ~= #rec then
		-- a torn record here would make the next one look corrupt
		self.failed = "journal write: " .. tostring(err or "short write")
		return nil, self.failed
	end
	if unistd.fsync then
		unistd.fsync(self.fd)
	end
	self.next = seq + 1
	self.size = self.size + #rec
	self.recs[#self.recs + 1] = { seq = seq, ev = ev, file = self.path }
	if self.size >= self.max then
		local ok, rerr = pcall(self.rotate, self)

		if not ok then
			self.failed = "journal rotate: " .. tostring(rerr)
		end
	end
	return seq
end

-- after(seq, want) -> first record past seq for which want(ev) holds
function J:after(seq, want)
	local recs = self.recs
	local lo, hi = 1, #recs + 1

	while lo < hi do
		local mid = (lo + hi) // 2

		if recs[mid].seq <= seq then
			lo = mid + 1
		else
			hi = mid
		end
	end
	for i = lo, #recs do
		if want(recs[i].ev) then
			return recs[i]
		end
	end
	return nil
end

function J:close()
	if self.fd then
		unistd.close(self.fd)
		self.fd = nil
	end
end

return M
