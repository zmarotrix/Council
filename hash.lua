-- SHA-256 in Lua, because the client has no hashing of its own (C_EncodingUtil only compresses and encodes). The
-- chain and the summaries keep the first 16 hex digits: 64 bits, enough that a member can't craft another entry
-- with the same hash. This makes tampering visible. It isn't a signature: nothing in this client can sign.

Council = Council or {}

local bit = rawget(_G, "bit")
local band, bor, bxor, rshift, lshift, bnot
if bit then band, bor, bxor, rshift, lshift, bnot = bit.band, bit.bor, bit.bxor, bit.rshift, bit.lshift, bit.bnot end

local TWO32 = 4294967296
local format, byte, rep, char = string.format, string.byte, string.rep, string.char

local K = {
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

-- The client's bit functions may answer as signed numbers, so every result goes through this.
local function u(x) return x % TWO32 end
local function rr(x, n) return u(bor(rshift(x, n), lshift(x, 32 - n))) end

local function digest(text)
  local h0, h1, h2, h3, h4, h5, h6, h7 = 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
  local bits = #text * 8
  local padded = text .. char(128) .. rep("\0", (55 - #text) % 64)
    .. rep("\0", 4)
    .. char(math.floor(bits / 16777216) % 256, math.floor(bits / 65536) % 256, math.floor(bits / 256) % 256, bits % 256)
  local w = {}
  for block = 0, #padded / 64 - 1 do
    for i = 1, 16 do
      local at = block * 64 + (i - 1) * 4 + 1
      local a, b, c, d = byte(padded, at, at + 3)
      w[i] = a * 16777216 + b * 65536 + c * 256 + d
    end
    for i = 17, 64 do
      local x, y = w[i - 15], w[i - 2]
      local s0 = u(bxor(rr(x, 7), rr(x, 18), rshift(x, 3)))
      local s1 = u(bxor(rr(y, 17), rr(y, 19), rshift(y, 10)))
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) % TWO32
    end
    local a, b, c, d, e, f, g, h = h0, h1, h2, h3, h4, h5, h6, h7
    for i = 1, 64 do
      local s1 = u(bxor(rr(e, 6), rr(e, 11), rr(e, 25)))
      local ch = u(bxor(band(e, f), band(u(bnot(e)), g)))
      local t1 = (h + s1 + ch + K[i] + w[i]) % TWO32
      local s0 = u(bxor(rr(a, 2), rr(a, 13), rr(a, 22)))
      local maj = u(bxor(band(a, b), band(a, c), band(b, c)))
      local t2 = (s0 + maj) % TWO32
      h, g, f, e, d, c, b, a = g, f, e, (d + t1) % TWO32, c, b, a, (t1 + t2) % TWO32
    end
    h0, h1, h2, h3 = (h0 + a) % TWO32, (h1 + b) % TWO32, (h2 + c) % TWO32, (h3 + d) % TWO32
    h4, h5, h6, h7 = (h4 + e) % TWO32, (h5 + f) % TWO32, (h6 + g) % TWO32, (h7 + h) % TWO32
  end
  return format("%08x%08x%08x%08x%08x%08x%08x%08x", h0, h1, h2, h3, h4, h5, h6, h7)
end

Council.Sha256 = digest

---The first 16 hex digits of text's SHA-256.
function Council.Hash(text)
  return string.sub(digest(text), 1, 16)
end
