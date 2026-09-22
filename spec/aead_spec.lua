-- ChaCha20 and Poly1305 against every vector RFC 8439 publishes, once
-- per implementation.
--
-- The constants are not here: spec/vectors.lua is generated from the RFC
-- text by spec/extract.lua. See the note at the top of that file for why
-- that distinction is worth the machinery.
--
-- When the C module is built, every case below runs twice -- once
-- against the Lua implementation and once against C -- which makes the
-- two a differential test of each other for nothing. That is why the Lua
-- versions stay reachable as `.pure` instead of being replaced.

local H = require "spec.helper"
local V = require "spec.vectors"
local chacha20 = require "ircagent.crypto.chacha20"
local poly1305 = require "ircagent.crypto.poly1305"

local function impls(mod)
  local t = { { name = "lua", impl = mod.pure } }
  if mod.native then t[#t + 1] = { name = "c", impl = mod.native } end
  return t
end

for _, imp in ipairs(impls(chacha20)) do
  local xor, block = imp.impl.xor, imp.impl.block

  describe("chacha20 (" .. imp.name .. ") #kat", function()
    it("has vectors to run", function()
      assert.is_true(#V.chacha20 >= 3)
    end)

    for i, v in ipairs(V.chacha20) do
      it("encrypts RFC 8439 A.2 vector " .. i, function()
        H.equal_hex(v.ciphertext,
          xor(H.unhex(v.key), v.counter, H.unhex(v.nonce),
              H.unhex(v.plaintext)))
      end)

      it("decrypts RFC 8439 A.2 vector " .. i, function()
        H.equal_hex(v.plaintext,
          xor(H.unhex(v.key), v.counter, H.unhex(v.nonce),
              H.unhex(v.ciphertext)))
      end)
    end

    it("agrees with its own block function across a boundary", function()
      local key, nonce = ("\0"):rep(32), ("\0"):rep(12)
      local whole = xor(key, 0, nonce, ("\0"):rep(128))
      assert.equal(whole:sub(1, 64), block(key, 0, nonce))
      assert.equal(whole:sub(65, 128), block(key, 1, nonce))
    end)

    it("handles lengths either side of a block", function()
      local key, nonce = ("k"):rep(32), ("n"):rep(12)
      for _, n in ipairs { 0, 1, 63, 64, 65, 127, 128, 129 } do
        local data = ("x"):rep(n)
        assert.equal(n, #xor(key, 7, nonce, data))
        assert.equal(data, xor(key, 7, nonce, xor(key, 7, nonce, data)))
      end
    end)

    it("wraps the block counter at 2^32", function()
      -- Two blocks starting at 0xffffffff: the second must be counter 0.
      local key, nonce = ("k"):rep(32), ("n"):rep(12)
      local two = xor(key, 0xffffffff, nonce, ("\0"):rep(128))
      assert.equal(block(key, 0xffffffff, nonce), two:sub(1, 64))
      assert.equal(block(key, 0, nonce), two:sub(65, 128))
    end)
  end)
end

for _, imp in ipairs(impls(poly1305)) do
  local auth = imp.impl.auth

  describe("poly1305 (" .. imp.name .. ") #kat", function()
    it("has vectors to run", function()
      assert.is_true(#V.poly1305 >= 11)
    end)

    for i, v in ipairs(V.poly1305) do
      it("authenticates RFC 8439 A.3 vector " .. i, function()
        H.equal_hex(v.tag, auth(H.unhex(v.onetimepoly1305key),
                                H.unhex(v.texttomac)))
      end)
    end

    it("handles message lengths either side of a block", function()
      local key = H.unhex(V.poly1305[4].onetimepoly1305key)
      for _, n in ipairs { 0, 1, 15, 16, 17, 31, 32, 33 } do
        assert.equal(16, #auth(key, ("y"):rep(n)))
      end
    end)
  end)
end

-- The two implementations against each other directly, on input no
-- published vector covers. Skipped, not failed, when there is no C.
describe("chacha20 and poly1305, lua against c", function()
  if not chacha20.native then
    pending "no native module built"
    return
  end

  it("agree on awkward lengths and counters", function()
    local key, nonce = ("K"):rep(32), ("N"):rep(12)
    for _, n in ipairs { 0, 1, 7, 63, 64, 65, 191, 4096, 4097 } do
      local data = ("m"):rep(n)
      for _, ctr in ipairs { 0, 1, 42, 0xfffffffe } do
        assert.equal(chacha20.pure.xor(key, ctr, nonce, data),
                     chacha20.native.xor(key, ctr, nonce, data),
                     ("length %d counter %d"):format(n, ctr))
      end
      assert.equal(poly1305.pure.auth(key, data),
                   poly1305.native.auth(key, data),
                   "length " .. n)
    end
  end)
end)

describe("poly1305 streaming", function()
  it("streams the same tag as a one-shot", function()
    local key = H.unhex(V.poly1305[4].onetimepoly1305key)
    local msg = ("abcdefghij"):rep(17)   -- 170 bytes: not a block multiple
    local s = poly1305.new(key)
    local i = 1
    while i <= #msg do
      s:update(msg:sub(i, i + 6))         -- 7 at a time, straddling blocks
      i = i + 7
    end
    assert.equal(poly1305.auth(key, msg), s:final())
  end)
end)

-- AEAD_CHACHA20_POLY1305 itself: the IETF construction, which is not the
-- one SSH uses. chacha20-poly1305@openssh.com has two keys and encrypts
-- the length field separately; this is RFC 8439 2.8, and it is what TLS
-- 1.3 and QUIC want.
describe("aead_chacha20_poly1305 #kat", function()
  local aead = require "ircagent.crypto.aead"
  local A = V.aead
  local unhex = H.unhex

  local key, nonce = unhex(A.key), unhex(A.nonce)
  local aad, plaintext = unhex(A.aad), unhex(A.plaintext)

  it("seals RFC 8439 2.8.2", function()
    H.equal_hex(A.ciphertext .. A.tag, aead.seal(key, nonce, plaintext, aad))
  end)

  it("opens RFC 8439 2.8.2", function()
    assert.equal(plaintext,
                 aead.open(key, nonce, unhex(A.ciphertext .. A.tag), aad))
  end)

  it("rejects a flipped ciphertext bit", function()
    local sealed = aead.seal(key, nonce, plaintext, aad)
    local bad = string.char(sealed:byte(1) ~ 1) .. sealed:sub(2)
    assert.is_nil(aead.open(key, nonce, bad, aad))
  end)

  it("rejects a flipped tag bit", function()
    local sealed = aead.seal(key, nonce, plaintext, aad)
    local bad = sealed:sub(1, #sealed - 1)
                .. string.char(sealed:byte(#sealed) ~ 0x80)
    assert.is_nil(aead.open(key, nonce, bad, aad))
  end)

  it("rejects the wrong AAD", function()
    local sealed = aead.seal(key, nonce, plaintext, aad)
    assert.is_nil(aead.open(key, nonce, sealed, aad .. "\0"))
  end)

  it("rejects anything shorter than a tag", function()
    assert.is_nil(aead.open(key, nonce, ("x"):rep(15), aad))
  end)

  -- Lengths either side of the 16-byte padding boundary for both the AAD
  -- and the plaintext: the padding and the length trailer are what stop
  -- a message being re-split between the two, and an off-by-one there
  -- passes every equal-length test.
  it("round-trips across the padding boundary", function()
    for _, alen in ipairs { 0, 1, 15, 16, 17 } do
      for _, plen in ipairs { 0, 1, 15, 16, 17, 64 } do
        local a, p = ("a"):rep(alen), ("p"):rep(plen)
        local sealed = aead.seal(key, nonce, p, a)
        assert.equal(#p + 16, #sealed)
        assert.equal(p, aead.open(key, nonce, sealed, a))
      end
    end
  end)
end)
