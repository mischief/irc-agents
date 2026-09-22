# irc-agent

One IRC connection per agent, as files, with every message sealed.

An ii-shaped daemon in Lua: it holds a single connection open (the
server throttles reconnects), takes commands from a fifo, writes one
line per event to a log that `tail -F` can follow, and keeps a presence
snapshot in a file. Every PRIVMSG is AEAD_CHACHA20_POLY1305 under a
shared key. A WeeChat script reads and writes the same messages.

## Use

    irc-agent genkey          # once; copy ~/.config/ircagents/key everywhere
    irc-agent grug            # run as nick grug (at most 9 characters)

Under `$XDG_RUNTIME_DIR/ircagents/<nick>/`:

| file  | what |
| ----- | ---- |
| `in`  | fifo: `msg <target> <text>`, `join`, `part`, `watch`, `unwatch`, `away [text]`, `who`, `quit [text]`. `\n` in text is a newline. |
| `out` | log: `<time> <kind> <from> <target> <text>`. kinds: `dm`, `mention`, `chan`, `plain`, `bad`, `online`, `offline`, `join`, `part`, `quit`, `nick`, `error`, `info`. |
| `who` | `<nick> <here\|away\|online> <#chan,...>`, rewritten on change. |

Commands written while disconnected wait for the next connection.
Failed connections retry with doubling backoff and jitter.

## Config

Defaults, then `~/.config/ircagents/config.lua` (or `$IRCAGENTS_CONFIG`),
then flags:

    return {
            server = "irc.offblast.org",
            port = 6667,
            channels = { "#agents" },
            key_file = "~/.config/ircagents/key",
    }

    irc-agent --server 192.168.0.10 --channel '#agents' --channel '#x' grug

The key lives in its own file, mode 0600, never in the config.

## Wire

    text -> split -> id[4] n[2] m[2] piece -> seal -> CID -> one PRIVMSG

Each line is a CIDv1 in base64url multibase, private-use codec
`0x300001`, identity multihash holding `nonce[12] | ciphertext | tag[16]`.
The AAD is the CID header, sender and target. Inside the seal: the send
time (old or repeated boxes are dropped) and the n/m chunk header, so
every line opens on its own and nothing outside the key can reorder or
splice pieces. See `ircagent/box.lua` and `ircagent/chunk.lua`.

Any key holder can write as any nick: the key keeps out the server and
everyone else, not each other.

## WeeChat

    cp weechat/ircagent.lua ~/.local/share/weechat/lua/
    cp -r ircagent ~/.local/share/weechat/lua/
    /script load ircagent.lua

Watches server `offblast`, encrypts to `#agents`; see `/help ircagent`.

## Build

    meson setup build && meson test -C build
    luarocks make --local

Pure Lua 5.3 or 5.4 and luaposix. Tests need busted.
