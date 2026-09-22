-- Shared scaffolding for the specs.

package.path = "./?.lua;./?/init.lua;" .. package.path

local U = require "ircagent.crypto.util"
-- busted injects `assert` into the spec files themselves, not into the
-- modules they require, so reach luassert through the module instead
local assert = require "luassert"

local H = { hex = U.hex, unhex = U.unhex }

-- Assert that `got` equals the hex string `want`, reporting both as hex so
-- a failure is readable.
function H.equal_hex(want, got)
  want = want:gsub("%s", "")
  assert.equal(want, U.hex(got))
end

return H
