-- irc.lua: keep a clm agent on IRC through irc-agent (-P irc). Config:
-- tools.irc.nick, .kinds (default dm mention owner broadcast), .reply.
-- The daemon is a child of clm, labeled clm:<session>; $CLM_SCRATCH/irc-conn
-- keeps its id and nick, so a resumed session gets its events back.
-- The model sees tools and [irc] messages, never the irc-agent command.

local cfg = clm.config or {}
local IRC = cfg.command or "irc-agent"

local kinds = {}
for _, k in ipairs(cfg.kinds or { "dm", "mention", "owner", "broadcast" }) do
    kinds[k] = true
end

local scratch = clm.getenv("CLM_SCRATCH")
local saved = scratch and scratch .. "/irc-conn"
local label = "clm:" .. (scratch and scratch:match("([^/]+)/*$") or "none")

-- id: the connection; want: the nick asked for; held: the nick the
-- server gave us, nil while not connected
local id, want, held
local running, watching = false, false
local run_wait, watch_wait = 1000, 500
local down_timer
local run, watch

local function valid_nick(n)
    return type(n) == "string" and n:match("^%a[%w_%-]*$") ~= nil and #n <= 9
end

local function trim(s)
    return ((s or ""):gsub("%s+$", ""))
end

local function save()
    if saved then
        clm.write_file(saved, ("id %s\nnick %s\n"):format(id or "", want or ""))
    end
end

-- The system prompt part: changes cost a prompt-cache miss, so it
-- follows joins, renames and lasting outages only.
local shown_prompt
local function set_prompt()
    if not clm.prompt_set then return end
    local text
    if want == nil then
        text = nil
    elseif held then
        text = "You are on IRC as " .. held ..
            (held ~= want and " (you asked for " .. want ..
                ", which is in use; the daemon keeps asking for it)" or "") ..
            ". IRC events arrive as messages that start with [irc]. " ..
            "Answer them with irc_send. irc_status shows who is on; " ..
            "irc_read shows recent channel lines; irc_nick renames you."
    else
        text = "You asked to be on IRC as " .. want ..
            ", but the connection is not up; it connects by itself. " ..
            "irc_status shows its state."
    end
    if text ~= shown_prompt then
        shown_prompt = text
        clm.prompt_set("irc", text)
    end
end

-- With tools.irc.reply, the final text of a turn goes to whoever asked:
-- the sender of a dm, or the channel of a mention or owner line. The model
-- says NOREPLY, or nothing, to stay quiet. Needs clm.on.
local reply_kinds = { dm = true, mention = true, owner = true }
local asked = {}    -- reply targets for the running turn, in order
local answered = {} -- targets irc_send reached this turn

local function note_asker(kind, from, target)
    if not reply_kinds[kind] then return end
    local to = target:sub(1, 1) == "#" and target or from
    for _, t in ipairs(asked) do
        if t == to then return end
    end
    asked[#asked + 1] = to
end

-- the event line escapes \n and \\
local function unescape(s)
    return (s:gsub("\\(.)", { n = "\n", ["\\"] = "\\" }))
end

local function connected(nick)
    held = nick
    if down_timer then
        down_timer:cancel()
        down_timer = nil
    end
    set_prompt()
end

-- A short outage is not worth a turn; tell the model after 60 s.
local function disconnected(why)
    held = nil
    if down_timer then return end
    down_timer = clm.after(60000, function()
        down_timer = nil
        if held == nil and want ~= nil then
            set_prompt()
            clm.notify("[irc] the connection is down (" .. why ..
                "); it reconnects by itself.")
        end
    end)
end

local function event(kind, from, target, text)
    if kind == "info" then
        local as = text:match("^connected to %S+ as (%S+)$")
        if as then
            connected(as)
        elseif text:match("^disconnected") then
            disconnected(text:match("^disconnected: (.*)$") or "no reason")
        end
        return
    end
    if kind == "state" then
        local now = text:match("^now (%S+)")
        local using = text:match("; using (%S+)%.")
        if now then
            connected(now)
            clm.notify("[irc] your IRC nick is now " .. now)
        else
            if using then connected(using) end
            clm.notify("[irc] " .. text:gsub("%. rename: .*$", "") ..
                (using and ". Keep it, or pick another nick with irc_nick." or ""))
        end
        return
    end
    if not kinds[kind] then return end
    if cfg.reply then note_asker(kind, from, target) end
    local msg
    if kind == "dm" then
        msg = ("[irc] dm from %s: %s\n(answer with irc_send target=%s)")
            :format(from, text, from)
    elseif kind == "mention" then
        msg = ("[irc] %s in %s: %s\n(answer with irc_send target=%s)")
            :format(from, target, text, target)
    else
        -- owner: a human in charge, to you or to everyone; broadcast:
        -- anyone else, to everyone
        local who = kind == "owner" and from .. ", a human in charge," or from
        msg = ("[irc] %s in %s: %s\n(act on it if it applies to you; " ..
            "answer with irc_send target=%s only if it asks for an answer)")
            :format(who, target, text, target)
    end
    clm.notify(msg)
end

local function deliver(line)
    -- TIME KIND FROM TARGET TEXT
    local kind, from, target, text = line:match("^%S+ (%S+) (%S+) (%S+) ?(.*)$")
    if kind then event(kind, from, target, unescape(text)) end
end

local function retry_run()
    clm.after(run_wait, run)
    run_wait = math.min(run_wait * 2, 60000)
end

run = function()
    if running or want == nil then return end
    running = true
    local argv = { IRC, "run", want, "--label", label }
    if id then
        argv[#argv + 1] = "--id"
        argv[#argv + 1] = id
    end
    local h = clm.spawn(argv, {
        on_line = function(line)
            local got = line:match("^id (%S+)$")
            if got and got ~= id then
                id = got
                save()
            end
            if got and not watching then
                watching = true
                watch()
            end
        end,
        on_exit = function(_, _, stderr)
            running = false
            disconnected("the daemon exited")
            -- the same connection live elsewhere: another clm on this session
            if trim(stderr):match("already running") then
                clm.notify("[irc] another process runs this session's IRC " ..
                    "connection; retrying.")
            end
            retry_run()
        end,
    })
    -- A daemon that stays up resets the wait.
    clm.after(30000, function()
        if h:running() then run_wait = 1000 end
    end)
end

watch = function()
    if not running or id == nil then
        watching = false
        return
    end
    local lines = {}
    clm.spawn({ IRC, "watch", id, "--once" }, {
        on_line = function(line)
            if line ~= "" then lines[#lines + 1] = line end
        end,
        on_exit = function(code, _, stderr)
            for _, l in ipairs(lines) do deliver(l) end
            local why = trim(stderr)
            if code == 0 then
                watch_wait = 500
                watch()
            elseif why:match("gap:") then
                clm.notify("[irc] some IRC events were lost; irc_read " ..
                    "shows what is left.")
                clm.spawn({ IRC, "watch", id, "--reset" },
                    { on_exit = function() watch() end })
            else
                -- Usually the daemon is not up yet.
                clm.after(watch_wait, watch)
                watch_wait = math.min(watch_wait * 2, 10000)
            end
        end,
    })
end

local function join(n)
    want = n
    save()
    set_prompt()
    run()
end

-- tool helpers: fail unless joined, run irc-agent, report stderr
local function need_join(ctx)
    if want == nil then
        ctx:fail("not on IRC: call irc_join first")
        return true
    end
    if id == nil then
        ctx:fail("the IRC connection is starting; try again shortly")
        return true
    end
end

local function exec_tool(ctx, argv, opts, ok_text)
    local r = clm.exec(argv, opts)
    if r.code == 0 then
        ctx:complete(ok_text or trim(r.stdout))
    else
        ctx:fail(trim(r.stderr) ~= "" and trim(r.stderr) or trim(r.stdout))
    end
    return r.code == 0
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
        if need_join(ctx) then return end
        if exec_tool(ctx, { IRC, "send", id, args.target, "-" },
            { stdin = args.text }, "sent to " .. args.target) then
            answered[args.target] = true
        end
    end,
})

clm.tool_register("irc_status", {
    description = "Show your IRC nick, whether you are connected, and " ..
        "who is in the channel.",
    params_schema = { type = "object", properties = {} },
    invoke = function(_, ctx)
        if need_join(ctx) then return end
        exec_tool(ctx, { IRC, "status", id })
    end,
})

clm.tool_register("irc_read", {
    description = "Show recent IRC lines for context: messages to you, " ..
        "and with channel=true other channel talk too.",
    params_schema = {
        type = "object",
        properties = {
            count = { type = "integer", description = "lines, default 30" },
            channel = { type = "boolean", description = "include channel talk" },
        },
    },
    invoke = function(args, ctx)
        if need_join(ctx) then return end
        local n = math.tointeger(args.count) or 30
        local argv = { IRC, "read", id, tostring(math.max(1, math.min(n, 500))) }
        if args.channel then argv[#argv + 1] = "chan" end
        exec_tool(ctx, argv)
    end,
})

clm.tool_register("irc_nick", {
    description = "Change your IRC nick. 1-9 chars, letter first.",
    params_schema = {
        type = "object",
        properties = { nick = { type = "string" } },
        required = { "nick" },
    },
    invoke = function(args, ctx)
        if need_join(ctx) then return end
        if not valid_nick(args.nick) then
            ctx:fail("nick must be 1-9 chars, letter first")
            return
        end
        want = args.nick
        save()
        if exec_tool(ctx, { IRC, "nick", id, args.nick }) then
            connected(args.nick)
        else
            set_prompt()
        end
    end,
})

local function register_join()
    clm.tool_register("irc_join", {
        description = "Join IRC. Call this first, at the start of your " ..
            "first task, before any other tool. Choose the nick from the " ..
            "work or the user's request: a repo, program or task name, " ..
            "like wrapfix or nmdiff. 1-9 chars, letter first. Not " ..
            "irc, plugin, agent, bot or assistant. After joining, IRC " ..
            "events arrive as messages; answer them with irc_send.",
        params_schema = {
            type = "object",
            properties = { nick = { type = "string" } },
            required = { "nick" },
        },
        invoke = function(args, ctx)
            if want ~= nil then
                ctx:fail("already on IRC as " .. (held or want) ..
                    "; irc_nick renames")
            elseif not valid_nick(args.nick) then
                ctx:fail("nick must be 1-9 chars, letter first")
            else
                join(args.nick)
                -- One join per session: without the tool the model
                -- cannot call it again on every new request.
                if clm.tool_remove then clm.tool_remove("irc_join") end
                ctx:complete("joining IRC as " .. args.nick ..
                    "; events arrive as [irc] messages")
            end
        end,
    })
end

-- the saved connection, or the nick file of older plugins
local function load_saved()
    if not saved then return end
    local s = clm.read_file(saved) or ""
    local sid, snick = s:match("id (%S*)\nnick (%S*)")
    if sid and sid ~= "" then id = sid end
    if valid_nick(snick) then return snick end
    local old = trim(clm.read_file(scratch .. "/irc-nick"))
    if valid_nick(old) then return old end
end

local last = load_saved()

if valid_nick(cfg.nick) then
    join(cfg.nick)
elseif last then
    join(last)
else
    register_join()
end

if cfg.reply and clm.on then
    clm.on("turn_end", function(t)
        local targets, sent = asked, answered
        asked, answered = {}, {}
        local text = trim(t.text):gsub("^%s+", "")
        if id == nil or t.status ~= 0 or text == "" or
            text:match("^NOREPLY") then
            return
        end
        for _, to in ipairs(targets) do
            if not sent[to] then
                clm.spawn({ IRC, "send", id, to, "-" }, {
                    stdin = text,
                    on_exit = function(code, _, stderr)
                        if code ~= 0 then
                            clm.notify("[irc] reply to " .. to ..
                                " failed: " .. trim(stderr))
                        end
                    end,
                })
            end
        end
    end)
end
