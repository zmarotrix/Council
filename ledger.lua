-- The record: one numbered, hash-chained log per author, never edited. A correction is a new entry that points at
-- the old one. This file knows nothing of the game, so the harness can run many of these side by side.
--
-- store = { logs = { [author] = { [seq] = entry } }, verified = { [author] = { s, h } }, alarms = {}, ... }
-- entry = { a = author, s = seq, t = server time, k = kind, d = data, h = hash }
--
-- Trust (docs/council-v1.md section 4): the chain stops an entry being changed. It doesn't stop someone adding one in
-- another's name, since anyone can compute a hash. So an entry is only "verified" once it comes straight from its
-- author, whose name the server vouches for, or an officer's summary names its hash. Replay (state.lua) won't apply
-- an unverified decision.

Council = Council or {}
local Ledger = {}
Ledger.__index = Ledger
Council.Ledger = Ledger

local Write, Hash = Council.Serial.Write, Council.Hash

---Anyone's add-on may write these: what the game showed them.
Ledger.OBSERVATIONS = { sess = true, att = true, kill = true, loot = true, seen = true }
---Only officers' count: what the guild decided.
Ledger.DECISIONS = { award = true, fix = true, sr = true, plus = true, close = true, rules = true, revoke = true, grant = true, council = true }

local MAX_FUTURE = 86400   -- an entry dated further ahead than this is a broken clock or a lie
local MAX_PENDING = 800
local MAX_ALARMS = 100
local MAX_DATA_BYTES = 16000

local function fill(store)
  store.logs = store.logs or {}
  store.verified = store.verified or {}
  store.alarms = store.alarms or {}
  store.pending = store.pending or {}
  store.wanted = store.wanted or {}
  return store
end

---A ledger over a saved table. env = { me = "Name", now = function, onChange = function, restoring = bool }
function Ledger.New(store, env)
  local self = setmetatable({ store = fill(store), env = env }, Ledger)
  self.revision = 0
  -- A character with no entries of its own can be getting its history back: it takes its own old entries from
  -- others until it first writes. Otherwise an entry in our name that we don't hold is someone else's doing.
  self.restoring = self:Head(env.me) == 0
  return self
end

local function entryHash(entry, prev)
  return Hash(prev .. Write({ entry.a, entry.s, entry.t, entry.k, entry.d }))
end
Ledger.EntryHash = entryHash

function Ledger:Head(author)
  local log = self.store.logs[author]
  return log and #log or 0
end

function Ledger:HeadHash(author)
  local log = self.store.logs[author]
  local entry = log and log[#log]
  return entry and entry.h or ""
end

function Ledger:Entry(author, seq)
  local log = self.store.logs[author]
  return log and log[seq]
end

function Ledger:Authors()
  local out = {}
  for author, log in pairs(self.store.logs) do
    if #log > 0 then out[#out + 1] = author end
  end
  table.sort(out)
  return out
end

function Ledger:Changed()
  self.revision = self.revision + 1
  if self.env.onChange then self.env.onChange(self) end
end

function Ledger:Alarm(kind, author, seq, detail)
  local alarms = self.store.alarms
  for _, a in ipairs(alarms) do
    if a.kind == kind and a.author == author and a.seq == seq then return end
  end
  alarms[#alarms + 1] = { kind = kind, author = author, seq = seq, detail = detail, at = self.env.now() }
  while #alarms > MAX_ALARMS do table.remove(alarms, 1) end
  if self.env.onAlarm then self.env.onAlarm(alarms[#alarms]) end
end

---Writes an entry of ours. Returns it.
function Ledger:Append(kind, data, at)
  local me = self.env.me
  self.store.logs[me] = self.store.logs[me] or {}
  local log = self.store.logs[me]
  local entry = { a = me, s = #log + 1, t = at or self.env.now(), k = kind, d = data or {} }
  entry.h = entryHash(entry, self:HeadHash(me))
  log[entry.s] = entry
  self.store.verified[me] = { s = entry.s, h = entry.h }
  self.restoring = false
  self:Changed()
  return entry
end

function Ledger:IsVerified(entry)
  if entry.a == self.env.me then return true end
  local v = self.store.verified[entry.a]
  return v ~= nil and entry.s <= v.s
end

-- An entry from outside: is it even shaped like one? Peers can send anything.
local function wellFormed(entry, now)
  if type(entry) ~= "table" then return false end
  if type(entry.a) ~= "string" or entry.a == "" or #entry.a > 64 then return false end
  if type(entry.s) ~= "number" or entry.s < 1 or entry.s % 1 ~= 0 then return false end
  if type(entry.t) ~= "number" or entry.t > now + MAX_FUTURE then return false end
  if type(entry.h) ~= "string" or #entry.h ~= 16 then return false end
  if not (Ledger.OBSERVATIONS[entry.k] or Ledger.DECISIONS[entry.k]) then return false end
  if type(entry.d) ~= "table" then return false end
  local ok, text = pcall(Write, entry.d)
  return ok and #text <= MAX_DATA_BYTES
end

function Ledger:CheckWanted(author)
  local want = self.store.wanted[author]
  if want and self:Head(author) >= want.s then
    self.store.wanted[author] = nil
    self:Verify(author, want.s, want.h, want.by)
  end
end

---Someone we trust says author's entry number seq has hash h. Marks everything up to it verified: the chain makes
---a match at seq vouch for all before it.
function Ledger:Verify(author, seq, h, by)
  local have = self:Entry(author, seq)
  if not have then
    local want = self.store.wanted[author]
    if not want or want.s < seq then self.store.wanted[author] = { s = seq, h = h, by = by } end
    return "waiting"
  end
  if have.h ~= h then
    self:Alarm("mismatch", author, seq, by)
    return "mismatch"
  end
  local v = self.store.verified[author]
  if not v or v.s < seq then
    self.store.verified[author] = { s = seq, h = h }
    self:Changed()
    return "verified"
  end
  return "known"
end

local function truncate(log, from)
  for i = #log, from, -1 do log[i] = nil end
end

---An entry that arrived from `from` (server-vouched), possibly relaying someone else's. Returns "new", "dup",
---"gap", "bad", "conflict" or "ignored". Never raises, whatever it's given.
function Ledger:Ingest(entry, from)
  local now = self.env.now()
  if not wellFormed(entry, now) then return "bad" end
  local author, seq = entry.a, entry.s
  local direct = from == author
  local me = self.env.me

  -- our own name, from someone else: we'd know if we wrote it, unless we're getting our history back
  if author == me and not self.restoring then
    local mine = self:Entry(me, seq)
    if mine and mine.h == entry.h then return "dup" end
    self:Alarm("impersonated", me, seq, from)
    return "ignored"
  end

  self.store.logs[author] = self.store.logs[author] or {}
  local log = self.store.logs[author]
  local head = #log
  if seq <= head then
    local have = log[seq]
    if have.h == entry.h then
      if direct then self:Verify(author, seq, entry.h, from) end
      return "dup"
    end
    if direct then
      -- from the author's own hand, that's the truth: whatever we were told is dropped, and pulled again
      local prev = seq > 1 and log[seq - 1].h or ""
      if entryHash(entry, prev) ~= entry.h then return "bad" end
      self:Alarm("replaced", author, seq, from)
      truncate(log, seq)
      log[seq] = { a = entry.a, s = entry.s, t = entry.t, k = entry.k, d = entry.d, h = entry.h }
      self.store.verified[author] = { s = seq, h = entry.h }
      self:Changed()
      return "new"
    end
    self:Alarm("conflict", author, seq, from)
    return "conflict"
  end
  if seq > head + 1 then
    local pending = self.store.pending[author] or {}
    self.store.pending[author] = pending
    if seq - head <= MAX_PENDING then pending[seq] = entry end
    return "gap"
  end
  if entryHash(entry, self:HeadHash(author)) ~= entry.h then return "bad" end
  log[seq] = { a = entry.a, s = entry.s, t = entry.t, k = entry.k, d = entry.d, h = entry.h }

  -- anything that was waiting for this one
  local pending = self.store.pending[author]
  while pending do
    local nextEntry = pending[#log + 1]
    if not nextEntry then break end
    pending[#log + 1] = nil
    if entryHash(nextEntry, log[#log].h) ~= nextEntry.h then break end
    log[#log + 1] = { a = nextEntry.a, s = nextEntry.s, t = nextEntry.t, k = nextEntry.k, d = nextEntry.d, h = nextEntry.h }
  end
  if pending and next(pending) == nil then self.store.pending[author] = nil end

  if direct then self.store.verified[author] = { s = #log, h = log[#log].h } end
  self:CheckWanted(author)
  self:Changed()
  return "new"
end

---Every entry, oldest first, in an order every client agrees on.
function Ledger:All()
  local out = {}
  for _, log in pairs(self.store.logs) do
    for i = 1, #log do out[#out + 1] = log[i] end
  end
  table.sort(out, function(x, y)
    if x.t ~= y.t then return x.t < y.t end
    if x.a ~= y.a then return x.a < y.a end
    return x.s < y.s
  end)
  return out
end

---{ [author] = { s, h } } for everyone we hold.
function Ledger:Vector()
  local out = {}
  for author, log in pairs(self.store.logs) do
    if #log > 0 then out[author] = { s = #log, h = log[#log].h } end
  end
  return out
end

---One short string that's equal only if two clients hold exactly the same record.
function Ledger:Digest()
  local parts = {}
  for _, author in ipairs(self:Authors()) do
    parts[#parts + 1] = author .. ":" .. self:Head(author) .. ":" .. self:HeadHash(author)
  end
  return Hash(table.concat(parts, ";"))
end
