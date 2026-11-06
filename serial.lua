-- One way of turning a value into text and back. It's canonical (keys sorted, one spelling per number), so the
-- same entry hashes the same on every client, and the reader treats its input as hostile: anyone in the guild can
-- send anything, so it never runs code, and it gives up rather than raises on nonsense.
--
--   n<number>;   s<length>:<bytes>   T   F   a<count>; <values>   t <key value>... e

Council = Council or {}
local Serial = {}
Council.Serial = Serial

local format, sub, find, byte = string.format, string.sub, string.find, string.byte
local concat, sort = table.concat, table.sort

local MAX_DEPTH = 12
local MAX_NODES = 60000

local function keyOrder(a, b)
  local ta, tb = type(a), type(b)
  if ta ~= tb then return ta == "number" end
  return a < b
end

local function isSequence(t)
  local n = #t
  local count = 0
  for k in pairs(t) do
    count = count + 1
    if type(k) ~= "number" or k < 1 or k > n or k % 1 ~= 0 then return false end
  end
  return count == n, n
end

local function write(v, out, depth)
  local kind = type(v)
  if kind == "number" then
    out[#out + 1] = "n" .. format("%.14g", v) .. ";"
  elseif kind == "string" then
    out[#out + 1] = "s" .. #v .. ":" .. v
  elseif kind == "boolean" then
    out[#out + 1] = v and "T" or "F"
  elseif kind == "table" then
    if depth >= MAX_DEPTH then error("too deep") end
    local seq, n = isSequence(v)
    if seq then
      out[#out + 1] = "a" .. n .. ";"
      for i = 1, n do write(v[i], out, depth + 1) end
    else
      local keys = {}
      for k in pairs(v) do
        local tk = type(k)
        if tk ~= "string" and tk ~= "number" then error("bad key") end
        keys[#keys + 1] = k
      end
      sort(keys, keyOrder)
      out[#out + 1] = "t"
      for _, k in ipairs(keys) do
        write(k, out, depth + 1)
        write(v[k], out, depth + 1)
      end
      out[#out + 1] = "e"
    end
  else
    error("can't write a " .. kind)
  end
end

---The value as canonical text. Errors on values that can't be written, so only pass our own data.
function Serial.Write(v)
  local out = {}
  write(v, out, 0)
  return concat(out)
end

local read
local BYTE_E = byte("e")

-- returns value, next position; nil position means the text is bad
function read(text, pos, depth, budget)
  budget.n = budget.n + 1
  if budget.n > MAX_NODES or depth > MAX_DEPTH then return nil, nil end
  local tag = sub(text, pos, pos)
  if tag == "n" then
    local stop = find(text, ";", pos, true)
    if not stop or stop - pos > 32 then return nil, nil end
    local n = tonumber(sub(text, pos + 1, stop - 1))
    if not n or n ~= n or n == math.huge or n == -math.huge then return nil, nil end
    return n, stop + 1
  elseif tag == "s" then
    local colon = find(text, ":", pos, true)
    if not colon or colon - pos > 12 then return nil, nil end
    local len = tonumber(sub(text, pos + 1, colon - 1))
    if not len or len < 0 or len % 1 ~= 0 or colon + len > #text then return nil, nil end
    return sub(text, colon + 1, colon + len), colon + len + 1
  elseif tag == "T" then
    return true, pos + 1
  elseif tag == "F" then
    return false, pos + 1
  elseif tag == "a" then
    local stop = find(text, ";", pos, true)
    if not stop or stop - pos > 12 then return nil, nil end
    local n = tonumber(sub(text, pos + 1, stop - 1))
    if not n or n < 0 or n % 1 ~= 0 or n > MAX_NODES then return nil, nil end
    local t = {}
    local at = stop + 1
    for i = 1, n do
      local value, nextPos = read(text, at, depth + 1, budget)
      if nextPos == nil then return nil, nil end
      t[i], at = value, nextPos
    end
    return t, at
  elseif tag == "t" then
    local t = {}
    local at = pos + 1
    while true do
      if at > #text then return nil, nil end
      if byte(text, at) == BYTE_E then return t, at + 1 end
      local key, afterKey = read(text, at, depth + 1, budget)
      if afterKey == nil then return nil, nil end
      local tk = type(key)
      if tk ~= "string" and tk ~= "number" then return nil, nil end
      local value, afterValue = read(text, afterKey, depth + 1, budget)
      if afterValue == nil then return nil, nil end
      t[key], at = value, afterValue
    end
  end
  return nil, nil
end

---The value in text, or nil if it isn't exactly one well-formed value.
function Serial.Read(text)
  if type(text) ~= "string" or text == "" then return nil end
  local value, pos = read(text, 1, 0, { n = 0 })
  if pos == nil or pos ~= #text + 1 then return nil end
  return value
end
