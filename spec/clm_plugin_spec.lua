-- clm/irc.lua against a fake clm: what it runs, and what the model sees.

require "spec.helper"

local function load(config, files)
	local S = { spawns = {}, notes = {}, prompts = {}, tools = {}, files = files or {} }

	_G.clm = {
		config = config,
		getenv = function(k) return k == "CLM_SCRATCH" and "/s/sess1" or nil end,
		read_file = function(p) return S.files[p] end,
		write_file = function(p, t) S.files[p] = t end,
		spawn = function(argv, o)
			S.spawns[#S.spawns + 1] = { argv = table.concat(argv, " "), o = o }
			return { running = function() return true end }
		end,
		after = function() return { cancel = function() end } end,
		notify = function(t) S.notes[#S.notes + 1] = t end,
		prompt_set = function(_, t) S.prompts[#S.prompts + 1] = t end,
		tool_register = function(n) S.tools[n] = true end,
		on = function() end,
	}
	-- callbacks reach clm at run time, so it stays until the next load
	dofile("clm/irc.lua")
	return S
end

describe("clm irc plugin", function()
	it("runs the daemon with a session label, then watches by id", function()
		local S = load { nick = "grug" }

		assert.equal("irc-agent run grug --label clm:sess1", S.spawns[1].argv)
		S.spawns[1].o.on_line("id ab12cd")
		assert.equal("irc-agent watch ab12cd --once", S.spawns[2].argv)
		assert.equal("id ab12cd\nnick grug\n", S.files["/s/sess1/irc-conn"])
		assert.is_nil(S.tools.irc_join)
		assert.is_true(S.tools.irc_nick)
	end)

	it("resumes the saved connection by id", function()
		local S = load({}, { ["/s/sess1/irc-conn"] = "id ab12cd\nnick grug\n" })

		assert.equal("irc-agent run grug --label clm:sess1 --id ab12cd", S.spawns[1].argv)
	end)

	it("tells the model what an event is and how to answer", function()
		local S = load { nick = "grug" }

		S.spawns[1].o.on_line("id ab12cd")

		local w = S.spawns[2].o

		w.on_line("T state - - nick grug is in use; using ab12cd. rename: irc-agent nick ab12cd NICK")
		w.on_line("T info - - connected to 10.0.0.1 as ab12cd")
		w.on_line("T dm bob ab12cd two\\nlines")
		w.on_line("T mention bob #agents grug: hi")
		w.on_line("T owner mischief #agents all: stop")
		w.on_line("T chan bob #agents noise")
		w.on_line("T state - - now grug")
		w.on_exit(0, nil, "")
		assert.same({
			"[irc] nick grug is in use; using ab12cd. Keep it, or pick another nick with irc_nick.",
			"[irc] dm from bob: two\nlines\n(answer with irc_send target=bob)",
			"[irc] bob in #agents: grug: hi\n(answer with irc_send target=#agents)",
			"[irc] mischief, a human in charge, in #agents: all: stop\n" ..
			    "(act on it if it applies to you; answer with irc_send " ..
			    "target=#agents only if it asks for an answer)",
			"[irc] your IRC nick is now grug",
		}, S.notes)
		assert.matches("^You are on IRC as grug%.", S.prompts[#S.prompts])
		-- no mention of the command line
		for _, t in ipairs(S.prompts) do
			assert.is_nil(t:find("irc%-agent"))
		end
	end)
end)
