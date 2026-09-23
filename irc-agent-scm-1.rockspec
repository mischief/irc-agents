rockspec_format = '3.0'
package = 'irc-agent'
version = 'scm-1'

source = {
  url = 'git+https://git.offblast.org/mischief/irc-agent.git',
  branch = 'main',
}

description = {
  summary = 'An IRC connection per agent, as files, with sealed messages',
  detailed = [[
An ii-shaped daemon holding one IRC connection for one agent: commands
in through a fifo, events out as one line each to a log, presence in a
file. Every PRIVMSG is AEAD_CHACHA20_POLY1305 under a shared key,
carried as a CIDv1 with the box inline, split and numbered to fit the
512-byte line. A WeeChat script reads and writes the same boxes.
]],
  homepage = 'https://git.offblast.org/mischief/irc-agent',
  license = 'MIT',
  labels = { 'irc', 'agents', 'chacha20-poly1305', 'cid' },
}

supported_platforms = { 'unix' }

dependencies = {
  'lua >= 5.3',
  'luaposix',
  'imsg >= 0.2',
}

build = {
  type = 'builtin',
  modules = {
    ['ircagent.box'] = 'ircagent/box.lua',
    ['ircagent.chunk'] = 'ircagent/chunk.lua',
    ['ircagent.cli'] = 'ircagent/cli.lua',
    ['ircagent.cid'] = 'ircagent/cid.lua',
    ['ircagent.config'] = 'ircagent/config.lua',
    ['ircagent.crypto.aead'] = 'ircagent/crypto/aead.lua',
    ['ircagent.crypto.chacha20'] = 'ircagent/crypto/chacha20.lua',
    ['ircagent.crypto.poly1305'] = 'ircagent/crypto/poly1305.lua',
    ['ircagent.crypto.util'] = 'ircagent/crypto/util.lua',
    ['ircagent.filter'] = 'ircagent/filter.lua',
    ['ircagent.irc'] = 'ircagent/irc.lua',
    ['ircagent.journal'] = 'ircagent/journal.lua',
    ['ircagent.probe'] = 'ircagent/probe.lua',
    ['ircagent.rpc'] = 'ircagent/rpc.lua',
    ['ircagent.rpcc'] = 'ircagent/rpcc.lua',
    ['ircagent.rpcd'] = 'ircagent/rpcd.lua',
  },
  install = {
    bin = {
      ['irc-agent'] = 'bin/irc-agent.lua',
    },
  },
  copy_directories = { 'weechat' },
}

test_dependencies = {
  'busted >= 2.0',
}

test = {
  type = 'busted',
}
