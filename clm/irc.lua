-- irc.lua: keep a clm agent on IRC through irc-agent. Opt-in: put it in
-- <plugins>/opt/, enable with plugins = { "irc" } or -P irc.
-- tools.irc.nick sets the nick; without it the model calls irc_join, and
-- the nick is kept in $CLM_SCRATCH so a resumed session rejoins.
-- tools.irc.kinds lists event kinds (default dm, mention, owner, broadcast).
-- The daemon is a child of clm (irc-agent run), so it stops when clm does.
-- Events come from irc-agent watch --once; its cursor file keeps the place.

local cfg = clm.config or {}
local IRC = cfg.command or "irc-agent"

local kinds = {}
for _, k in ipairs(cfg.kinds or { "dm", "mention", "owner", "broadcast" }) do
    kinds[k] = true
end

local nick
local run_wait, watch_wait = 1000, 500

local function valid_nick(n)
    return type(n) == "string" and n:match("^%a[%w_%-]*$") ~= nil and #n <= 9
end

local function trim(s)
    return ((s or ""):gsub("%s+$", ""))
end

-- Run the daemon. Another daemon for the same nick (started by hand or
-- by another session) makes run exit; then we use that one and try to
-- take over again later.
local function run()
    local h = clm.spawn({ IRC, "run", nick }, {
        on_exit = function(code, signal, stderr)
            local why = trim(stderr)
            if not why:match("already running") then
                clm.notify("irc: the irc-agent daemon exited (" ..
                    tostring(code or "signal " .. signal) .. ")" ..
                    (why ~= "" and ": " .. why or "") .. "; restarting")
            end
            clm.after(run_wait, run)
            run_wait = math.min(run_wait * 2, 60000)
        end,
    })
    -- A daemon that stays up resets the wait.
    clm.after(30000, function()
        if h:running() then run_wait = 1000 end
    end)
end

local function deliver(line)
    -- TIME KIND FROM TARGET TEXT
    local kind = line:match("^%S+ (%S+) ")
    if kind == nil or kinds[kind] then
        clm.notify("irc event: " .. line)
    end
end

local function watch()
    local lines = {}
    clm.spawn({ IRC, "watch", nick, "--once" }, {
        on_line = function(line)
            if line ~= "" then lines[#lines + 1] = line end
        end,
        on_exit = function(code, signal, stderr)
            for _, l in ipairs(lines) do deliver(l) end
            local why = trim(stderr)
            if code == 0 then
                watch_wait = 500
                watch()
            elseif why:match("^gap:") then
                clm.notify("irc: " .. why)
                watch()
            else
                -- Usually the daemon is not up yet.
                clm.after(watch_wait, watch)
                watch_wait = math.min(watch_wait * 2, 10000)
            end
        end,
    })
end

local saved = clm.getenv("CLM_SCRATCH")
saved = saved and saved .. "/irc-nick"

local function join(n)
    nick = n
    run()
    watch()
end

clm.tool_register("irc_send", {
    description = "Send a message on IRC. target is a channel (#agents) " ..
        "or a nick. Long and multi-line text is fine.",
    params_schema = {
        type = "object",
        properties = {
            target = { type = "string", description = "channel or nick" },
            text = { type = "string", description = "message text" },
        },
        required = { "target", "text" },
    },
    invoke = function(args, ctx)
        if nick == nil then
            ctx:fail("not on IRC yet: call irc_join first")
            return
        end
        local r = clm.exec({ IRC, "send", nick, args.target, "-" },
            { stdin = args.text })
        if r.code == 0 then
            ctx:complete("sent to " .. args.target)
        else
            ctx:fail("irc-agent send failed: " .. trim(r.stderr) ..
                " (the daemon may be restarting; try again shortly)")
        end
    end,
})

local last = saved and trim(clm.read_file(saved))

if valid_nick(cfg.nick) then
    join(cfg.nick)
elseif valid_nick(last) then
    join(last)
else
    clm.tool_register("irc_join", {
        description = "Join IRC. Call this first, at the start of your " ..
            "first task, before any other tool. Choose the nick from the " ..
            "work or the user's request: a repo, program or task name, " ..
            "like mcc, wrapfix or nmdiff. 1-9 chars, letter first. Not " ..
            "irc, plugin, agent, bot or assistant. After joining, IRC " ..
            "events arrive as messages; answer them with irc_send.",
        params_schema = {
            type = "object",
            properties = { nick = { type = "string" } },
            required = { "nick" },
        },
        invoke = function(args, ctx)
            if nick ~= nil then
                ctx:fail("already on IRC as " .. nick)
            elseif not valid_nick(args.nick) then
                ctx:fail("nick must be 1-9 chars, letter first")
            else
                join(args.nick)
                if saved then clm.write_file(saved, args.nick .. "\n") end
                -- One join per session: without the tool the model
                -- cannot call it again on every new request.
                if clm.tool_remove then clm.tool_remove("irc_join") end
                ctx:complete("joined IRC as " .. args.nick ..
                    "; events arrive as messages")
            end
        end,
    })
end
