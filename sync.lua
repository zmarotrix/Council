-- How the record moves. No game calls in here: io does the sending, so the harness can run many clients over a network
-- that delays, drops and reorders. Nothing here has to arrive: the record on disk is the truth, a broadcast only
-- saves a wait, and a later summary finds anything that was missed.
--
--   H  digest    "here's what I hold" on GUILD, rarely. Different from yours? Ask them for the detail.
--   Q            "send me your vector", whispered.
--   V  vector    who has written how much, with the latest hash. From an officer or the author, it also vouches.
--   P  need      "send me these authors, from these numbers", whispered. One batch per ask, so the asker sets the pace.
--   E  entries   entries, live on GUILD or in answer to P.
--
-- io = { me, now(), send(msg, channel, target, priority), isOfficer(name), isMember(name), random(a, b), canSend(), onlineCount() }

Council = Council or {}
local Sync = {}
Sync.__index = Sync
Council.Sync = Sync

Sync.LOGIN_MIN, Sync.LOGIN_MAX = 10, 40
Sync.OFFICER_EVERY = 900         -- seconds between an officer's summaries
Sync.MEMBER_EVERY = 1800         -- a member sends one only after hearing none for this long
Sync.BATCH_BYTES = 1800          -- about seven messages' worth, so one batch can't hog the channel
Sync.PULL_TIMEOUT = 45
Sync.ASK_GAP = 60                -- at most one Q to anyone in this long
Sync.ANSWERERS = 4               -- about how many members answer a summary that differs from theirs
Sync.ANSWER_DELAY = 30
Sync.MAX_SERVING = 3             -- how many people one client feeds per minute's worth of batches
Sync.SERVE_WINDOW = 20

function Sync.New(ledger, io)
  local self = setmetatable({ ledger = ledger, io = io, nextSummary = nil, lastHeard = 0, lastAsk = 0, pull = nil, serving = {}, peers = {} }, Sync)
  return self
end

function Sync:Start()
  self.nextSummary = self.io.now() + self.io.random(Sync.LOGIN_MIN, Sync.LOGIN_MAX)
end

function Sync:Send(msg, channel, target, priority)
  if self.io.canSend and not self.io.canSend() then return false end
  self.io.send(msg, channel, target, priority or "NORMAL")
  return true
end

---A new entry of ours goes out now. If it doesn't arrive, summaries find it later.
function Sync:Broadcast(entry)
  self:Send({ m = "E", es = { entry } }, "GUILD", nil, "NORMAL")
end

function Sync:Summarise()
  self.lastSent = self.io.now()
  self:Send({ m = "H", d = self.ledger:Digest(), n = self:Total() }, "GUILD", nil, "BULK")
end

---How many entries we hold in all.
function Sync:Total()
  local n = 0
  for _, author in ipairs(self.ledger:Authors()) do n = n + self.ledger:Head(author) end
  return n
end

-- An officer's digest matches ours: the digest covers every author's latest hash, so that vouches for everything we hold.
function Sync:VouchAll(by)
  for _, author in ipairs(self.ledger:Authors()) do
    self.ledger:Verify(author, self.ledger:Head(author), self.ledger:HeadHash(author), by)
  end
end

---Call about once a second.
function Sync:Tick()
  local now = self.io.now()
  if self.nextSummary and now >= self.nextSummary then
    local officer = self.io.isOfficer(self.io.me)
    -- a member stays quiet while summaries are being heard, so 40 people don't all talk
    if officer or now - self.lastHeard >= Sync.MEMBER_EVERY then self:Summarise() end
    local every = officer and Sync.OFFICER_EVERY or Sync.MEMBER_EVERY
    self.nextSummary = now + every + self.io.random(0, 60)
  end
  local answer = self.answering
  if answer and now >= answer.at then
    self.answering = nil
    if not self.pull then
      self:Send({ m = "H", d = self.ledger:Digest(), n = self:Total(), r = true }, "WHISPER", answer.to, "BULK")
      self:Ask(answer.to)
    end
  end
  local pull = self.pull
  if pull and now - pull.asked > Sync.PULL_TIMEOUT then
    self:NextPeer()
  end
end

function Sync:NextPeer()
  local pull = self.pull
  if not pull then return end
  for peer in pairs(self.peers) do
    if peer ~= pull.peer and not pull.tried[peer] then
      pull.peer = peer
      pull.tried[peer] = true
      self:AskPull()
      return
    end
  end
  self.pull = nil
end

local function needFrom(ledger, vector)
  local need
  for author, head in pairs(vector) do
    if type(author) == "string" and type(head) == "table" and type(head.s) == "number" and head.s > ledger:Head(author) then
      need = need or {}
      need[author] = ledger:Head(author) + 1
    end
  end
  return need
end

function Sync:AskPull()
  local pull = self.pull
  if not pull then return end
  local need = needFrom(self.ledger, pull.vector)
  if not need then
    self.pull = nil
    if self.io.onCaughtUp then self.io.onCaughtUp() end
    return
  end
  pull.asked = self.io.now()
  self:Send({ m = "P", need = need }, "WHISPER", pull.peer, "BULK")
end

function Sync:Ask(peer)
  local now = self.io.now()
  if now - self.lastAsk < Sync.ASK_GAP then return end
  self.lastAsk = now
  self:Send({ m = "Q" }, "WHISPER", peer, "BULK")
end

local handlers = {}

function handlers.H(self, msg, sender)
  if type(msg.d) ~= "string" then return end
  local now = self.io.now()
  self.peers[sender] = true
  -- a reply only says "ask me"; it doesn't count as hearing a summary, or answer in turn
  if not msg.r then self.lastHeard = now end
  if msg.d == self.ledger:Digest() then
    if self.io.isOfficer(sender) then self:VouchAll(sender) end
    return
  end
  if self.pull then return end
  if msg.r then
    self:Ask(sender)
    return
  end
  if self.answering then return end
  -- They hold more than we do, so we're behind and must ask. Otherwise they may be, so a few of those who differ answer:
  -- an officer always, a member by chance, so a client with nothing doesn't draw an answer from everyone online.
  local behind = type(msg.n) == "number" and msg.n > self:Total()
  if not behind then
    local chance = 1
    if not self.io.isOfficer(self.io.me) and self.io.onlineCount then
      chance = math.min(1, Sync.ANSWERERS / math.max(1, self.io.onlineCount()))
    end
    if self.io.random(1, 1000) > chance * 1000 then return end
  end
  self.answering = { to = sender, at = now + self.io.random(1, Sync.ANSWER_DELAY) }
end

function handlers.Q(self, _, sender)
  self:Send({ m = "V", v = self.ledger:Vector() }, "WHISPER", sender, "BULK")
end

function handlers.V(self, msg, sender)
  if type(msg.v) ~= "table" then return end
  self.peers[sender] = true
  local officer = self.io.isOfficer(sender)
  local ledger = self.ledger
  local refetch
  for author, head in pairs(msg.v) do
    if type(author) == "string" and type(head) == "table" and type(head.s) == "number" and type(head.h) == "string" then
      if officer or author == sender then
        local result = ledger:Verify(author, head.s, head.h, sender)
        -- the author themselves disagrees with what we were told: start again from what we'd vouched for
        if result == "mismatch" and author == sender then
          local v = ledger.store.verified[author]
          refetch = refetch or {}
          refetch[author] = v and (v.s + 1) or 1
        end
      end
    end
  end
  if refetch then
    self:Send({ m = "P", need = refetch }, "WHISPER", sender, "BULK")
    return
  end
  if needFrom(ledger, msg.v) then
    self.pull = { peer = sender, vector = msg.v, tried = { [sender] = true }, asked = 0 }
    self:AskPull()
  end
end

function handlers.P(self, msg, sender)
  if type(msg.need) ~= "table" then return end
  local now = self.io.now()
  for name, at in pairs(self.serving) do
    if now - at > Sync.SERVE_WINDOW then self.serving[name] = nil end
  end
  local count = 0
  for _ in pairs(self.serving) do count = count + 1 end
  if not self.serving[sender] and count >= Sync.MAX_SERVING then return end   -- they'll time out and try another
  self.serving[sender] = now
  local batch, bytes = {}, 0
  local Write = Council.Serial.Write
  local authors = {}
  for author in pairs(msg.need) do
    if type(author) == "string" then authors[#authors + 1] = author end
  end
  table.sort(authors)
  for _, author in ipairs(authors) do
    local from = msg.need[author]
    if type(from) == "number" and from >= 1 then
      local seq = math.floor(from)
      while bytes < Sync.BATCH_BYTES do
        local entry = self.ledger:Entry(author, seq)
        if not entry then break end
        batch[#batch + 1] = entry
        bytes = bytes + #Write(entry)
        seq = seq + 1
      end
    end
    if bytes >= Sync.BATCH_BYTES then break end
  end
  if #batch > 0 then self:Send({ m = "E", es = batch }, "WHISPER", sender, "BULK") end
end

function handlers.E(self, msg, sender)
  if type(msg.es) ~= "table" then return end
  local gapAuthor, progress
  local count = 0
  for _, entry in ipairs(msg.es) do
    count = count + 1
    if count > 500 then break end
    local result = self.ledger:Ingest(entry, sender)
    if result == "gap" then gapAuthor = entry.a end
    if result == "new" then progress = true end
  end
  self.peers[sender] = true
  if self.pull and self.pull.peer == sender then
    -- a peer feeding us nothing we can use isn't asked again, or a bad batch could loop forever
    if progress then self:AskPull() else self:NextPeer() end
  elseif gapAuthor and not self.pull then
    -- we missed something: ask whoever just showed us it exists
    self:Ask(sender)
  end
end

---A message from sender, whose name the server vouches for. Peers can send anything, so nothing here may raise.
function Sync:Receive(sender, msg)
  if type(msg) ~= "table" or type(sender) ~= "string" or sender == self.io.me then return end
  if self.io.isMember and not self.io.isMember(sender) then return end
  local handler = handlers[msg.m]
  if handler then handler(self, msg, sender) end
end
