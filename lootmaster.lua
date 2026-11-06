-- The loot night: drops in the open loot window, who's in line, rolls, and giving the item. Only one person runs it: the
-- master looter, or the raid leader if the game isn't using master loot. The game settles who that is, so there's no
-- election, and everyone else sees the same panel read-only through a small message on raid chat.
--
-- Nothing here hands out an item without a click. GiveMasterLoot is undocumented; the game's own UI calls it from a click,
-- so that's the only way we call it too. /roll results arrive as system chat, which goes secret in lockdown.

local Core = NorgannonCore
local C = Council
if C.disabled then return end
local Ladder = C.Ladder

local LM = { drops = {}, remote = nil, rollsSecret = false, lootOpen = false, method = nil }
C.LootMaster = LM

local BROADCAST_GAP = 1
local KEEP_HOURS = 8
local MAX_CANDIDATES = 40

-------------------------------------------------------------------------------------------
-- Who's running it
-------------------------------------------------------------------------------------------

local function unitName(unit) return C.Short((C.Global("UnitName", unit))) end

local function lootMethod()
  local method, partyId, raidId = C.In("C_PartyInfo", "GetLootMethod")
  if method ~= nil then return method, partyId, raidId end
  return C.Global("GetLootMethod")
end

function LM:IsMasterLoot()
  local method = lootMethod()
  local enum = rawget(_G, "Enum") and Enum.LootMethod
  return method == "master" or (enum and method == enum.Masterlooter) or false
end

function LM:MethodName()
  local method = lootMethod()
  local enum = rawget(_G, "Enum") and Enum.LootMethod
  if type(method) == "number" and enum then
    for name, value in pairs(enum) do
      if value == method then return name end
    end
  end
  return method
end

local function leaderName()
  if C.Global("UnitIsGroupLeader", "player") then return C.Me() end
  if C.Global("IsInRaid") then
    for i = 1, C.Global("GetNumGroupMembers") or 0 do
      local name, rank = C.Global("GetRaidRosterInfo", i)
      if rank == 2 then return C.Short(name) end
    end
  else
    for i = 1, 4 do
      if C.Global("UnitIsGroupLeader", "party" .. i) then return unitName("party" .. i) end
    end
  end
end

---Who's running the loot, by the game's rules.
function LM:MasterName()
  local _, partyId, raidId = lootMethod()
  if self:IsMasterLoot() then
    if type(raidId) == "number" then return unitName("raid" .. raidId) end
    if partyId == 0 then return C.Me() end
    if type(partyId) == "number" then return unitName("party" .. partyId) end
  end
  return leaderName()
end

function LM:IsMaster()
  if not C.Global("IsInGroup") then return false end
  return self:MasterName() == C.Me()
end

-------------------------------------------------------------------------------------------
-- The drops, in the loot window
-------------------------------------------------------------------------------------------

function LM:Selected()
  local list = self:View()
  for _, d in ipairs(list) do
    if d.key == self.selected then return d end
  end
  return list[1]
end

---The drops to show: ours if we're running it, otherwise the last the loot master told us.
function LM:View()
  if not self:IsMaster() and self.remote then return self.remote.drops or {} end
  return self.drops
end

local function saved()
  C.db.live = C.db.live or { drops = {} }
  return C.db.live
end

function LM:Save()
  local live = saved()
  live.drops, live.at, live.selected = self.drops, C.Now(), self.selected
end

function LM:Restore()
  local live = saved()
  if live.at and C.Now() - live.at < KEEP_HOURS * 3600 then
    self.drops, self.selected = live.drops or {}, live.selected
    for _, d in ipairs(self.drops) do d.slot = nil end
  end
end

local function hasDrop(self, key)
  for _, d in ipairs(self.drops) do
    if d.key == key then return d end
  end
end

local function readWindow()
  local count = C.Global("GetNumLootItems") or 0
  local rec = C:RecordForGroup()
  local minQuality = rec:State().rules.minQuality
  local seenTags, fresh = {}, false
  for _, d in ipairs(LM.drops) do d.slot = nil end
  for slot = 1, count do
    local _, name, _, _, quality = C.Global("GetLootSlotInfo", slot)
    local link = C.Global("GetLootSlotLink", slot)
    local id = type(link) == "string" and tonumber(link:match("item:(%d+)"))
    if id and type(quality) == "number" and quality >= minQuality then
      local source = C.Global("GetLootSourceInfo", slot) or "?"
      local tag = source .. "|" .. id
      seenTags[tag] = (seenTags[tag] or 0) + 1
      local key = tag .. "|" .. seenTags[tag]
      local drop = hasDrop(LM, key)
      if not drop then
        drop = { key = key, id = id, link = link, name = name, quality = quality, boss = C.Capture.bossName, state = "open", rolls = {} }
        table.insert(LM.drops, drop)
        fresh = true
      end
      drop.slot = slot
    end
  end
  return fresh
end

Core:On("LOOT_OPENED", "council.lootmaster", function()
  if not C.db or not LM:IsMaster() then return end
  LM.lootOpen = true
  local fresh = readWindow()
  if fresh then
    if not LM.selected then LM.selected = LM.drops[1] and LM.drops[1].key end
    LM:Save()
    LM:Broadcast()
    if C.db.autoOpen and C.Window and not C.Global("InCombatLockdown") then C.Window:Open("loot") end
  end
  if C.Window then C.Window:Changed() end
end)
Core:On("LOOT_CLOSED", "council.lootmaster", function()
  LM.lootOpen = false
  for _, d in ipairs(LM.drops) do d.slot = nil end
  if C.Window then C.Window:Changed() end
end)

-------------------------------------------------------------------------------------------
-- Rolling
-------------------------------------------------------------------------------------------

local function record() return C:RecordForGroup() end

local function chatKind()
  if C.Global("IsInRaid") then return "RAID" end
  if C.Global("IsInGroup") then return "PARTY" end
end

---Says a line in group chat. Only ever called from a click: the client flags chat from add-ons as restricted.
function LM:Say(text)
  local kind = chatKind()
  if not kind or not C.db.announce then return false end
  local api = rawget(_G, "C_ChatInfo")
  local fn = (api and api.SendChatMessage) or rawget(_G, "SendChatMessage")
  if not fn then return false end
  return (pcall(fn, text, kind))
end

local function listOf(rec) return rec:State().reserves end

local function linkOrName(d) return d.link or C.ItemName(d.id) end

---Starts the roll on a drop, on the first rung that applies, and says so.
function LM:Start(drop)
  local rec = record()
  local state, list = rec:State(), listOf(rec)
  drop.state, drop.rolls, drop.ignored, drop.only = "rolling", {}, {}, nil
  drop.rung = drop.rung or Ladder.StartRung(list, state, drop.id)
  self.activeKey = drop.key
  self:Announce(drop, rec)
  self:Save()
  self:Broadcast()
end

function LM:Announce(drop, rec)
  local state, list = rec:State(), listOf(rec)
  if drop.rung == "sr" then
    local names = {}
    for _, r in ipairs(Ladder.Reservers(list, state, drop.id)) do
      names[#names + 1] = r.p .. (r.bonus > 0 and string.format(" (+%d)", r.bonus) or "")
    end
    self:Say(string.format("Roll on %s: reserved by %s. Only they count.", linkOrName(drop), table.concat(names, ", ")))
  else
    local title = "Roll"
    for _, r in ipairs(Ladder.RUNGS) do
      if r.key == drop.rung then title = r.title end
    end
    self:Say(string.format("%s: /roll for %s", title, linkOrName(drop)))
  end
end

---On to the next rule: nobody on this rung wanted it.
function LM:NextRung(drop)
  local rec = record()
  local at = 1
  for i, r in ipairs(Ladder.RUNGS) do
    if r.key == (drop.rung or Ladder.StartRung(listOf(rec), rec:State(), drop.id)) then at = i end
  end
  local nextRung = Ladder.RUNGS[math.min(at + 1, #Ladder.RUNGS)]
  drop.rung, drop.rolls, drop.ignored, drop.state = nextRung.key, {}, {}, "rolling"
  self.activeKey = drop.key
  self:Announce(drop, rec)
  self:Save()
  self:Broadcast()
end

---Those tied roll again, and only they count.
function LM:Reroll(drop, tied)
  drop.only = {}
  for _, name in ipairs(tied) do
    drop.only[name] = true
    drop.rolls[name] = nil
  end
  self.activeKey = drop.key
  self:Say(string.format("Tie on %s: %s, roll again.", linkOrName(drop), table.concat(tied, " and ")))
  self:Save()
  self:Broadcast()
end

---Rolls and what they beat, for the panel.
function LM:Rank(drop)
  local rec = record()
  local rung = drop.rung or Ladder.StartRung(listOf(rec), rec:State(), drop.id)
  return Ladder.Rank(rung, listOf(rec), rec:State(), drop.id, drop.rolls or {}, rec:State().rules.tie)
end

local rollPattern, rollOrder

local function onSystem(text)
  if Core.IsSecret(text) then
    if LM.activeKey and not LM.rollsSecret then
      LM.rollsSecret = true
      if C.Window then C.Window:Changed() end
    end
    return
  end
  if type(text) ~= "string" or not LM.activeKey then return end
  if not rollPattern then
    rollPattern, rollOrder = C.Pattern(rawget(_G, "RANDOM_ROLL_RESULT"))
    if not rollPattern then return end
  end
  local args = C.Match(text, rollPattern, rollOrder)
  if not args then return end
  local name, roll, low, high = C.Short(args[1]), tonumber(args[2]), tonumber(args[3]), tonumber(args[4])
  if not (name and roll) or low ~= 1 or high ~= 100 then return end
  LM.rollsSecret = false
  local drop = hasDrop(LM, LM.activeKey)
  if not drop or drop.state ~= "rolling" then return end
  if drop.rolls[name] then return end   -- only the first roll counts
  local rec = record()
  local eligible = Ladder.Eligible(drop.rung, listOf(rec), rec:State(), drop.id)
  if (eligible and not eligible[name]) or (drop.only and not drop.only[name]) then
    drop.ignored = drop.ignored or {}
    drop.ignored[name] = roll
  else
    drop.rolls[name] = roll
  end
  LM:Save()
  LM:Broadcast()
  if C.Window then C.Window:Changed() end
end
LM.OnSystem = onSystem
Core:On("CHAT_MSG_SYSTEM", "council.lootmaster", function(_, text) onSystem(text) end)

-------------------------------------------------------------------------------------------
-- Giving
-------------------------------------------------------------------------------------------

local function candidateIndex(slot, name)
  for i = 1, MAX_CANDIDATES do
    local candidate = C.Global("GetMasterLootCandidate", slot, i)
    if candidate and C.Short(candidate) == name then return i end
  end
end

-- which copy of this item this is for this player, for a loot line to find its award
local function nextCopy(rec, sid, player, id)
  local s = rec:State().sessionById[sid]
  local n = 1
  if s then
    for _, line in ipairs(s.lines) do
      if line.player == player and line.item == id and line.by then n = n + 1 end
    end
  end
  return n
end

---What can go wrong before giving: a reason, or nil.
function LM:GiveProblem(drop, player)
  if not self:IsMasterLoot() then return nil end   -- group loot: this only records
  if not self.lootOpen or not drop.slot then return "Open the loot window on this corpse first." end
  if not candidateIndex(drop.slot, player) then return player .. " can't receive this: the game doesn't list them." end
end

---Gives the item if the game's using master loot, and either way records who it went to and why.
---Must come from a click. Returns true, or false and why.
function LM:Give(drop, player)
  local why = self:GiveProblem(drop, player)
  if why then return false, why end
  local giving = self:IsMasterLoot()
  if giving then
    local index = candidateIndex(drop.slot, player)
    local ok = pcall(GiveMasterLoot, drop.slot, index)
    if not ok then return false, "The game refused to hand it over." end
  end
  local rec, sid = C.Capture:Ensure()
  if not rec then return false, "There's no session to record it in." end
  local state, list = rec:State(), listOf(rec)
  local rung = drop.rung or Ladder.StartRung(list, state, drop.id)
  local only = rung == "sr" and Ladder.OnlyReserver(list, state, drop.id) == player
  local roll = drop.rolls and drop.rolls[player]
  local bonus = rung == "sr" and (C.State.Plus(state, player, drop.id) * state.rules.bonus) or 0
  local text = Ladder.Why(rung, roll, bonus, only)
  rec:Append("award", { s = sid, p = player, i = drop.id, n = nextCopy(rec, sid, player, drop.id), rung = rung, roll = roll, bonus = bonus > 0 and bonus or nil, why = text, b = drop.boss })
  drop.winner, drop.why, drop.state = player, text, "done"
  if self.activeKey == drop.key then self.activeKey = nil end
  self:Save()
  self:Broadcast()
  self:Say(string.format("%s goes to %s: %s.", linkOrName(drop), player, text))
  return true
end

---Clears the panel, for when the night's done.
function LM:Clear()
  self.drops, self.selected, self.activeKey = {}, nil, nil
  self:Save()
  self:Broadcast()
end

---The game's own roll window, for everyone with or without the add-on: the fallback when /roll can't be read.
function LM:RequestRoll(drop)
  if not drop.slot then return false end
  return (pcall(DoMasterLootRoll, drop.slot))
end

-------------------------------------------------------------------------------------------
-- Everyone else's copy of the panel
-------------------------------------------------------------------------------------------

function LM:Broadcast()
  if not self:IsMaster() or self.broadcastDue then return end
  self.broadcastDue = true
  C.Later(BROADCAST_GAP, function()
    self.broadcastDue = nil
    local kind = chatKind()
    if not kind then return end
    local out = {}
    for _, d in ipairs(self.drops) do
      out[#out + 1] = { key = d.key, id = d.id, link = d.link, boss = d.boss, state = d.state, rung = d.rung, rolls = d.rolls, winner = d.winner, why = d.why }
    end
    C.Transport:Send({ m = "L", drops = out, sel = self.selected }, kind, nil, "NORMAL", true)
  end)
end

function LM:ReceiveLive(sender, msg)
  if sender ~= self:MasterName() or type(msg.drops) ~= "table" then return end
  local clean = {}
  for _, d in ipairs(msg.drops) do
    if type(d) == "table" and type(d.id) == "number" and type(d.key) == "string" then
      d.rolls = type(d.rolls) == "table" and d.rolls or {}
      clean[#clean + 1] = d
    end
  end
  self.remote = { drops = clean, from = sender, at = C.Now() }
  if not self.selected and type(msg.sel) == "string" then self.selected = msg.sel end
  if C.Window then C.Window:Changed() end
end

Core:OnLogin(function() if C.db then LM:Restore() end end)
