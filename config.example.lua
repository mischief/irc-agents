-- irc-agent config: copy to ~/.config/ircagents/config.lua, or name
-- another file with $IRCAGENTS_CONFIG or -f. Every key is optional.
-- The values here are the defaults. Flags override this file.
--
-- The key does not go here. Run "irc-agent genkey" and copy the key
-- file, mode 0600, to every machine with agents.

return {
	-- IRC server, plain TCP (-s, -p)
	server = "irc.offblast.org",
	port = 6667,
	-- channels to join (-c, repeatable)
	channels = { "#agents" },
	-- shared key file (-k)
	key_file = "~/.config/ircagents/key",
	-- state for each connection; default $XDG_RUNTIME_DIR/ircagents (-d)
	-- dir = "/run/user/1000/ircagents",
	realname = "irc-agent",

	-- humans in charge: their mentions and broadcasts are "owner"
	-- events. Any key holder can use these nicks.
	owners = {},
	-- owners = { "yournick" },

	-- a channel line that starts with one of these words, then ":" or
	-- ",", is a "broadcast" event for every agent. Case-insensitive.
	broadcast = { "all", "agents", "everyone" },
	-- every DM a daemon sends is copied here, sealed. "" turns it off.
	log_channel = "#agents-log",

	-- pastebin for "irc-agent paste": POST the bytes, get a URL back.
	-- Content is sealed before upload. Larger files are refused.
	paste_url = "https://p.offblast.org",
	paste_max = 10 * 1024 * 1024,

	-- seconds; a box with a time this far from the clock is dropped
	-- as a replay (-a)
	max_age = 300,
	-- accept unencrypted PRIVMSG too, marked as such (-P)
	plaintext = false,

	-- reconnect delay in seconds: doubles each failure, up to the max
	backoff = 2,
	backoff_max = 300,
	-- seconds idle before a PING, and before the link counts as dead
	idle_ping = 60,
	idle_timeout = 120,
	-- seconds "send" waits for the server, plus one per queued line
	send_wait = 10,
	-- commands held while disconnected
	queue_max = 100,
}
