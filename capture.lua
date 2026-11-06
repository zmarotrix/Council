-- What the game shows every client: who got what, who was there, what died. Any member's add-on can record this, so
-- history doesn't need an officer in the group. CHAT_MSG_LOOT isn't flagged secret, which makes it the backbone.
--
-- To keep 25 clients from writing 25 copies of one line, each waits a moment and only writes what nobody else has yet.
-- At the end, one small "seen" entry from each client says which lines it saw: that's the witness count on a line.

local Core = NorgannonCore
local C = Council
if C.disabled then return end

local Capture = { current = nil, secretLines = 0, bossName = nil, bossAt = 0, groupRolls = {} }
C.Capture = Capture

local JITTER_MAX = 3          -- seconds a client waits before writing what someone else may write first
local BOSS_WINDOW = 600       -- loot this long after a kill counts as that boss's
local KEEP_SEEN_DAYS = 30

local lootPatterns

local function buildPatterns()
  lootPatterns = {}
  local function add(global, selfLoot)
    local pattern, order = C.Pattern(rawget(_G, global))
    if pattern then lootPatterns[#lootPatterns + 1] = { pattern = pattern, order = order, selfLoot = selfLoot } end
  end
  add("LOOT_ITEM_MULTIPLE")
  add("LOOT_ITEM")
  add("LOOT_ITEM_SELF_MULTIPLE", true)
  add("LOOT_ITEM_SELF", true)
end

local function parseLoot(text)
  if not lootPatterns then buildPatterns() end
  for _, p in ipairs(lootPatterns) do
    local args = C.Match(text, p.pattern, p.order)
    if args then
      if p.selfLoot then return C.Me(), args[1], tonumber(args[2]) or 1 end
      return C.Short(args[1]), args[2], tonumber(args[3]) or 1
    end
  end
end
Capture.ParseLoot = parseLoot

local function worthRecording(rec, id, link)
  -- the link says, on this client; if it doesn't and the item isn't cached, keep it rather than lose it
  local quality = C.LinkQuality(link) or C.In("C_Item", "GetItemQualityByID", id)
  if type(quality) ~= "number" then return true end
  return quality >= rec:State().rules.minQuality
end

local function localOf(rec, sid)
  rec.store.seen = rec.store.seen or {}
  local seen = rec.store.seen[sid]
  if not seen then
    seen = { at = C.Now(), counts = {}, keys = {} }
    rec.store.seen[sid] = seen
  end
  return seen
end

local function forgetOldSeen(rec)
  local oldest = C.Now() - KEEP_SEEN_DAYS * 86400
  for sid, seen in pairs(rec.store.seen or {}) do
    if seen.at < oldest then rec.store.seen[sid] = nil end
  end
end

---The current session, starting one if the group doesn't have one. Returns the record and the session id.
function Capture:Ensure()
  if self.current then return self.current.rec, self.current.id end
  local name, kind, _, _, size, _, _, map = C.Global("GetInstanceInfo")
  if not map then return nil end
  local rec = C:RecordForGroup()
  local names = C.GroupNames()
  local found = C.State.FindSession(rec:State(), map, size, C.Now(), names)
  local id = found and found.id
  if not id then
    id = map .. "-" .. tostring(C.Me()) .. "-" .. C.Now()
    rec:Append("sess", { id = id, map = map, name = name, size = size, kind = kind, ros = names })
  end
  self.current = { rec = rec, id = id, map = map }
  forgetOldSeen(rec)
  return rec, id
end

---Adds to the session whoever's here that it doesn't know about.
function Capture:NoteAttendance()
  if not self.current then return end
  local rec, id = self.current.rec, self.current.id
  local s = rec:State().sessionById[id]
  if not s then return end
  local add = {}
  for _, name in ipairs(C.GroupNames()) do
    if not s.people[name] then add[#add + 1] = name end
  end
  if #add > 0 then rec:Append("att", { s = id, add = add }) end
end

---Where we are decides whether a session is running. Leaving writes what this client saw.
function Capture:Refresh()
  local inside, kind = C.Global("IsInInstance")
  local grouped = C.Global("IsInGroup")
  local _, _, _, _, _, _, _, map = C.Global("GetInstanceInfo")
  local here = inside and grouped and (kind == "raid" or kind == "party") and map or nil
  if self.current and self.current.map ~= here then self:Leave() end
  if here and not self.current then
    C.Later(math.random(1, JITTER_MAX + 2), function()
      if self.current then return end
      local nowInside, nowKind = C.Global("IsInInstance")
      if nowInside and C.Global("IsInGroup") and (nowKind == "raid" or nowKind == "party") then
        self:Ensure()
        self:NoteAttendance()
      end
    end)
  elseif self.current then
    C.Later(math.random(1, JITTER_MAX + 2), function() self:NoteAttendance() end)
  end
end

---This client's "seen" entry for the session it's leaving. Lines it wrote count already, so this is the witness vote.
function Capture:Leave()
  local cur = self.current
  self.current = nil
  if not cur then return end
  self:WriteSeen(cur.rec, cur.id)
end

function Capture:WriteSeen(rec, id)
  if rec.personal then return end
  local seen = rec.store.seen and rec.store.seen[id]
  if not seen or seen.sent or next(seen.keys) == nil then return end
  local keys = {}
  for key in pairs(seen.keys) do keys[#keys + 1] = key end
  table.sort(keys)
  seen.sent = true
  rec:Append("seen", { s = id, keys = keys })
end

function Capture:SessionLineCount()
  if not self.current then return 0 end
  local s = self.current.rec:State().sessionById[self.current.id]
  return s and #s.lines or 0
end

local function onLootText(text)
  if Core.IsSecret(text) then
    Capture.secretLines = Capture.secretLines + 1
    return
  end
  if type(text) ~= "string" then return end
  local player, link, count = parseLoot(text)
  if not player or not link then return end
  local id = tonumber(link:match("item:(%d+)"))
  if not id then return end
  if not (C.Global("IsInGroup")) then return end
  local rec, sid = Capture:Ensure()
  if not rec or not worthRecording(rec, id, link) then return end

  local seen = localOf(rec, sid)
  local tag = player .. "|" .. id
  local n = (seen.counts[tag] or 0) + 1
  seen.counts[tag] = n
  seen.keys[C.State.SeenKey(player, id, n)] = true
  seen.sent = nil
  local boss = (C.Clock() - Capture.bossAt) < BOSS_WINDOW and Capture.bossName or nil
  local rolled = Capture.groupRolls[tag]
  Capture.groupRolls[tag] = nil

  local function write()
    local s = rec:State().sessionById[sid]
    local line = s and s.lineByKey[player .. "|" .. id .. "|" .. n]
    if line and line.observed then return end
    rec:Append("loot", { s = sid, p = player, i = id, n = n, l = link, b = boss, c = count > 1 and count or nil, r = rolled })
  end
  if rec.personal then write() else C.Later(math.random() * JITTER_MAX, write) end
end
Capture.OnLootText = onLootText

-- A boss died: one entry, from whoever gets there first
local function onKill(name)
  if type(name) ~= "string" then return end
  Capture.bossName, Capture.bossAt = name, C.Clock()
  local rec, sid = Capture:Ensure()
  if not rec then return end
  local function write()
    local s = rec:State().sessionById[sid]
    if s and s.killSeen[name] then return end
    rec:Append("kill", { s = sid, b = name })
  end
  if rec.personal then write() else C.Later(math.random() * JITTER_MAX, write) end
  C.Later(math.random(1, 5), function() Capture:NoteAttendance() end)
end

Core:On("CHAT_MSG_LOOT", "council.capture", function(_, text) onLootText(text) end)
Core:On("ENCOUNTER_END", "council.capture", function(_, _, name, _, _, success)
  if Core.IsSecret(name) or Core.IsSecret(success) then return end
  if success == 1 then onKill(name) end
end)
Core:On("BOSS_KILL", "council.capture", function(_, _, name)
  if not Core.IsSecret(name) and name ~= Capture.bossName then onKill(name) end
end)

-- Group loot: the game's own rolls, when it keeps them. The roll goes on the line the loot message writes.
Core:On("LOOT_HISTORY_UPDATE_DROP", "council.capture", function(_, encounterId, key)
  if Core.IsSecret(encounterId) or Core.IsSecret(key) then return end
  local drop = C.In("C_LootHistory", "GetSortedInfoForDrop", encounterId, key)
  if type(drop) ~= "table" or Core.IsSecret(drop) or not drop.winner then return end
  local link = Core.Safe(drop.itemHyperlink)
  local player = C.Short(Core.Safe(drop.winner.playerName))
  local roll = Core.Safe(drop.winner.roll)
  local id = type(link) == "string" and tonumber(link:match("item:(%d+)"))
  if player and id and type(roll) == "number" then Capture.groupRolls[player .. "|" .. id] = roll end
end)

for _, event in ipairs({ "PLAYER_ENTERING_WORLD", "ZONE_CHANGED_NEW_AREA", "GROUP_ROSTER_UPDATE", "GROUP_LEFT" }) do
  Core:On(event, "council.capture", function()
    if C.db then Capture:Refresh() end
  end)
end
-- A logout writes the same as leaving: it's saved, and goes out with the next summary.
Core:On("PLAYER_LOGOUT", "council.capture", function()
  if C.db and Capture.current then Capture:WriteSeen(Capture.current.rec, Capture.current.id) end
end)
