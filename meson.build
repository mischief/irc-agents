# Pure Lua: nothing is built, only installed and tested. The crypto
# picks up ircagent.crypto.native if one is ever there and stays on the
# Lua path if it is not.
project('irc-agent', version : '0.1.0', meson_version : '>= 0.64.0',
        license : 'MIT')

lua_version = get_option('lua_version')

lua = find_program('lua' + lua_version, 'lua', required : true)
luadir = get_option('datadir') / 'lua' / lua_version

install_subdir('ircagent', install_dir : luadir)

install_data('bin/irc-agent.lua', install_dir : get_option('bindir'),
             rename : 'irc-agent', install_mode : 'rwxr-xr-x')

# The WeeChat script, beside the modules it requires. Copy or link it
# and ircagent/ into ~/.local/share/weechat/lua to use it.
install_data('weechat/ircagent.lua',
             install_dir : get_option('datadir') / 'irc-agent' / 'weechat')

busted = find_program('busted', required : get_option('tests'))

if busted.found()
  test('spec', busted,
       args : ['--lua=' + lua.full_path(), '--output=plainTerminal'],
       workdir : meson.current_source_dir(),
       timeout : 300)

  luacov = find_program('luacov', required : false)
  if luacov.found()
    run_target('luacov',
      command : [find_program('sh'), '-c',
                 'cd "$0" && "$1" --lua="$2" --coverage && "$3"',
                 meson.current_source_dir(), busted.full_path(),
                 lua.full_path(), luacov.full_path()])
  endif
endif
