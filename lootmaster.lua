-- The loot night: what's on the corpse, who's rolling, and giving it. Only one person runs it: the master looter, or the raid
-- leader if the game isn't using master loot. The game settles who that is, so there's no election, and everyone else sees the
-- same thing through a small message on raid chat. The popups that draw this are in popups.lua.
--
-- Rolling works as RollFor's demos show: /roll, /roll 99 and /roll 98 for main spec, off spec and transmog, all at once, with a
-- countdown that ends early once every reserver has rolled. Its code has no licence, so none was read.
--
-- Nothing hands out an item without two clicks, and chat is only ever spoken from a click, since the client flags both. That's why
-- the countdown and a timer running out stay in the popup rather than in chat.

local Core = NorgannonCore
local C = Council
if C.disabled then return end
local Ladder = C.Ladder

local LM = { drops = {}, remote = nil, rollsSecret = false, lootOpen = false }
C.LootMaster = LM

local BROADCAST_GAP = 1
local KEEP_HOURS = 8
local MAX_CANDIDATES = 40
local ECHO_WAIT = 3
local CLICK_HOLD = 3     -- seconds a roll button stays away after a click, while the roll comes back
local MAX_CHAT = 250

local function changed()
  if C.Popups then C.Popups:Refresh() end
  if C.Window then C.Window:Changed() end
end
LM.Changed = changed

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
-- The drops
-------------------------------------------------------------------------------------------

---The drops to show: ours if we're running it, otherwise the last the loot master told us.
function LM:View()
  if not self:IsMaster() and self.remote then return self.remote.drops or {} end
  return self.drops
end

function LM:Find(key)
  for _, d in ipairs(self:View()) do
    if d.key == key then return d end
  end
end

---How many of this drop still need a home.
function LM.Remaining(drop)
  return (drop.copies or 1) - #(drop.given or {})
end

function LM:Left()
  local n = 0
  for _, d in ipairs(self.drops) do n = n + self.Remaining(d) end
  return n
end

local function saved()
  C.db.live = C.db.live or { drops = {} }
  return C.db.live
end

function LM:Save()
  local live = saved()
  live.drops, live.at = self.drops, C.Now()
end

function LM:Restore()
  local live = saved()
  if live.at and C.Now() - live.at < KEEP_HOURS * 3600 then
    self.drops = live.drops or {}
    for _, d in ipairs(self.drops) do
      d.slots = {}
      if d.state == "rolling" or d.state == "raid" then d.state = "done" end
    end
  end
end

local function newDrop(key, id, link, name)
  return { key = key, id = id, link = link, name = name, boss = C.Capture.bossName, copies = 0, given = {}, slots = {}, rolls = {} }
end

-- Identical items from one corpse are one drop with copies, so two top rolls can win them.
local function readWindow()
  local count = C.Global("GetNumLootItems") or 0
  local rec = C:RecordForGroup()
  local minQuality = rec:State().rules.minQuality
  local fresh = false
  for _, d in ipairs(LM.drops) do d.slots = {} end
  local seen = {}
  for slot = 1, count do
    local _, name, _, _, quality = C.Global("GetLootSlotInfo", slot)
    local link = C.Global("GetLootSlotLink", slot)
    local id = type(link) == "string" and tonumber(link:match("item:(%d+)"))
    if id and type(quality) == "number" and quality >= minQuality then
      local key = (C.Global("GetLootSourceInfo", slot) or "?") .. "|" .. id
      local drop
      for _, d in ipairs(LM.drops) do
        if d.key == key then drop = d end
      end
      if not drop then
        drop = newDrop(key, id, link, name)
        table.insert(LM.drops, drop)
        fresh = true
      end
      seen[key] = (seen[key] or 0) + 1
      -- what's on the corpse plus what's been given is how many there were
      drop.copies = math.max(drop.copies, seen[key] + #drop.given)
      table.insert(drop.slots, slot)
    end
  end
  return fresh
end

Core:On("LOOT_OPENED", "council.lootmaster", function()
  if not C.db or not LM:IsMaster() then return end
  LM.lootOpen = true
  local fresh = readWindow()
  LM:Save()
  LM:Broadcast()
  if fresh and C.db.autoOpen and C.Popups then C.Popups:ShowList() end
  changed()
end)
Core:On("LOOT_CLOSED", "council.lootmaster", function()
  LM.lootOpen = false
  for _, d in ipairs(LM.drops) do d.slots = {} end
  changed()
end)

---An item from your bags, to roll for and hand over by trade: /council roll.
function LM:AddManual(id, link, copies)
  local drop = newDrop("bag|" .. id .. "|" .. C.Now(), id, link)
  drop.copies, drop.manual = math.max(1, copies or 1), true
  table.insert(self.drops, drop)
  self:Save()
  self:Broadcast()
  changed()
  return drop
end

---Clears the list, for when the night's done.
function LM:Clear()
  self.drops, self.activeKey = {}, nil
  self:Save()
  self:Broadcast()
  changed()
end

-------------------------------------------------------------------------------------------
-- Speaking. Only ever from a click: chat from add-ons is flagged as restricted
-------------------------------------------------------------------------------------------

local function chatKind(warn)
  if C.Global("IsInRaid") then
    if warn and (C.Global("UnitIsGroupLeader", "player") or C.Global("UnitIsGroupAssistant", "player")) then return "RAID_WARNING" end
    return "RAID"
  end
  if C.Global("IsInGroup") then return "PARTY" end
end

local SLASH = { RAID_WARNING = "/rw ", RAID = "/raid ", PARTY = "/party " }

local function openChatBox(text)
  local util = rawget(_G, "ChatFrameUtil")
  local open = (util and util.OpenChat) or rawget(_G, "ChatFrame_OpenChat")
  if open then pcall(open, text) end
end

local echoWanted

local function heard(text)
  if echoWanted and not Core.IsSecret(text) and text == echoWanted then
    echoWanted = nil
    C.db.chatWorks = true
  end
end
for _, event in ipairs({ "CHAT_MSG_RAID", "CHAT_MSG_RAID_LEADER", "CHAT_MSG_RAID_WARNING", "CHAT_MSG_PARTY", "CHAT_MSG_PARTY_LEADER" }) do
  Core:On(event, "council.lootmaster", function(_, text) heard(text) end)
end

---Says a line in group chat. If the game has been swallowing them, it opens the chat box with the line ready, so a press of Enter
---sends it, which any client allows.
function LM:Say(text, warn)
  local kind = chatKind(warn)
  if not kind or not C.db.announce then return false end
  text = text:sub(1, MAX_CHAT)
  if C.db.chatWorks == false then
    openChatBox(SLASH[kind] .. text)
    return true
  end
  local api = rawget(_G, "C_ChatInfo")
  local fn = (api and api.SendChatMessage) or rawget(_G, "SendChatMessage")
  if not fn then return false end
  -- /cprobe found AreOutgoingAddonChatMessagesRestricted true here, so whether this reaches chat is for the game to show
  local watching = C.db.chatWorks == nil and not C.In("C_ChatInfo", "InChatMessagingLockdown")
  if watching then echoWanted = text end
  if not pcall(fn, text, kind) then
    echoWanted = nil
    return false
  end
  if watching then
    C.Later(ECHO_WAIT, function()
      if echoWanted == text then
        echoWanted = nil
        C.db.chatWorks = false
        C:Print("Your announcement didn't appear in chat, so from now on the chat box opens with it ready. Press Enter to send.")
        openChatBox(SLASH[kind] .. text)
      end
    end)
  end
  return true
end

local function linkOrName(d) return d.link or C.ItemName(d.id) end
local function record() return C:RecordForGroup() end
local function listOf(rec) return rec:State().reserves end

---Lists what dropped and who reserved it. Sends each line, or if chat isn't reaching anyone, shows them in your own chat instead.
function LM:SayDropped()
  local rec = record()
  local state, list = rec:State(), listOf(rec)
  local lines = {}
  for i, d in ipairs(self.drops) do
    local names = {}
    for _, r in ipairs(Ladder.Reservers(list, state, d.id)) do names[#names + 1] = r.p end
    lines[#lines + 1] = string.format("%d. %s%s%s", i, (d.copies or 1) > 1 and (d.copies .. "x ") or "", linkOrName(d), #names > 0 and (" (SR by " .. table.concat(names, ", ") .. ")") or "")
  end
  if C.db.chatWorks == false then
    for _, line in ipairs(lines) do C:Print(line) end
    return
  end
  local boss = self.drops[1] and self.drops[1].boss
  self:Say(string.format("%s dropped %d %s:", boss or "This", #lines, #lines == 1 and "item" or "items"))
  for _, line in ipairs(lines) do self:Say(line) end
end

-------------------------------------------------------------------------------------------
-- Rolling
-------------------------------------------------------------------------------------------

local function isReserved(drop, rec)
  return Ladder.IsReserved(listOf(rec), rec:State(), drop.id, drop.everyone)
end

---How many winners are still to be found: what's left, less those already through a tie.
local function openCopies(drop)
  return math.max(1, LM.Remaining(drop) - #(drop.locked or {}))
end

---Standing: rows, winners, tied, waiting. Winners include anyone already through a tie.
function LM:Rank(drop)
  local rec = record()
  local rows, winners, tied, waiting = Ladder.Rank(listOf(rec), rec:State(), drop.id, drop.rolls or {}, {
    copies = openCopies(drop), tie = rec:State().rules.tie, only = drop.only, everyone = drop.everyone or drop.state == "raid" or drop.raided,
  })
  if winners and drop.locked then
    local all = {}
    for _, row in ipairs(drop.locked) do all[#all + 1] = row end
    for _, row in ipairs(winners) do all[#all + 1] = row end
    winners = all
  end
  return rows, winners, tied, waiting
end

---Starts the roll on a drop, and says so.
function LM:Start(drop, everyone)
  local rec = record()
  local state, list = rec:State(), listOf(rec)
  drop.state, drop.rolls, drop.ignored, drop.only, drop.onlyKind, drop.locked, drop.raided = "rolling", {}, nil, nil, nil, nil, nil
  drop.everyone = everyone or nil
  drop.endsAt = C.Clock() + C.db.rollSeconds
  self.activeKey = drop.key
  self.rollsSecret = false
  local copies = self.Remaining(drop)
  local what = (copies > 1 and (copies .. "x ") or "") .. linkOrName(drop)
  if isReserved(drop, rec) then
    local names = {}
    for _, r in ipairs(Ladder.Reservers(list, state, drop.id)) do
      names[#names + 1] = r.p .. (r.bonus > 0 and string.format(" (+%d)", r.bonus) or "")
    end
    self:Say(string.format("Roll for %s: reserved by %s.", what, table.concat(names, ", ")), true)
  else
    self:Say(string.format("Roll for %s: /roll (MS), /roll 99 (OS), /roll 98 (Tmog).%s", what, copies > 1 and string.format(" %d top rolls win.", copies) or ""), true)
  end
  self:Save()
  self:Broadcast()
  changed()
end

---Which rolls this player can make right now, as buttons: { { text, max } }. Empty once they've rolled, or if it isn't for them.
function LM:MyRolls(drop)
  local me = C.Me()
  if drop.state ~= "rolling" or not me or (drop.rolls or {})[me] then return {} end
  local clicked = self.clicked and self.clicked[drop.key]
  if clicked and C.Clock() - clicked < CLICK_HOLD then return {} end
  if drop.only then
    return drop.only[me] and { { text = "Roll", max = 100 } } or {}
  end
  local rec = record()
  if isReserved(drop, rec) then
    for _, r in ipairs(Ladder.Reservers(listOf(rec), rec:State(), drop.id)) do
      if r.p == me then return { { text = "Roll", max = 100 } } end
    end
    return {}
  end
  return { { text = "Main spec", max = 100 }, { text = "Off spec", max = 99 }, { text = "Transmog", max = 98 } }
end

---Makes the roll, a real one that everyone sees, the same as typing it.
function LM:RollFor(drop, max)
  self.clicked = self.clicked or {}
  self.clicked[drop.key] = C.Clock()
  pcall(RandomRoll, 1, max)
end

---Ends the roll. From a click it says who's on top; a timer running out stays in the popup.
function LM:Finish(drop, fromClick)
  drop.state, drop.endsAt = "done", nil
  if self.activeKey == drop.key then self.activeKey = nil end
  local rows, winners, tied = self:Rank(drop)
  if fromClick then
    if tied then
      self:Say(string.format("Tie at %d for %s: %s.", rows[1] and rows[1].total or 0, linkOrName(drop), table.concat(tied, " and ")))
    elseif winners and winners[1] then
      for _, w in ipairs(winners) do
        self:Say(string.format("%s rolled %d for %s.", w.p, w.total, linkOrName(drop)))
      end
    end
  end
  self:Save()
  self:Broadcast()
  changed()
end

function LM:Cancel(drop)
  drop.state, drop.rolls, drop.only, drop.onlyKind, drop.locked, drop.endsAt, drop.ignored, drop.raided, drop.everyone = nil, {}, nil, nil, nil, nil, nil, nil, nil
  if self.activeKey == drop.key then self.activeKey = nil end
  self:Say(string.format("Rolling for %s is off.", linkOrName(drop)))
  self:Save()
  self:Broadcast()
  changed()
end

---Those tied roll again, and only they count. Anyone clear of the tie has their place.
function LM:Reroll(drop, tied)
  local rows = self:Rank(drop)
  local isTied = {}
  drop.only = {}
  -- a tie at off spec stays off spec, whatever range the re-roll uses
  drop.onlyKind = {}
  for _, name in ipairs(tied) do
    isTied[name] = true
    drop.only[name] = true
    drop.onlyKind[name] = drop.rolls[name] and drop.rolls[name].kind
    drop.rolls[name] = nil
  end
  drop.locked = drop.locked or {}
  local places = openCopies(drop)
  for _, row in ipairs(rows) do
    if isTied[row.p] then break end
    if #drop.locked < places then drop.locked[#drop.locked + 1] = row end
  end
  drop.state, drop.endsAt = "rolling", C.Clock() + C.db.rollSeconds
  self.activeKey = drop.key
  self:Say(string.format("%s, /roll for %s now.", table.concat(tied, " and "), linkOrName(drop)))
  self:Save()
  self:Broadcast()
  changed()
end

---A numbered list in chat, and one roll by the loot master to pick from it.
function LM:RaidRoll(drop)
  local names = C.GroupNames()
  if #names == 0 then return false end
  local parts = {}
  for i, name in ipairs(names) do parts[i] = string.format("[%d]%s", i, name) end
  drop.state, drop.rolls, drop.only, drop.onlyKind, drop.locked, drop.ignored, drop.endsAt, drop.everyone = "raid", {}, nil, nil, nil, nil, nil, nil
  drop.raidNames = names
  self.activeKey = drop.key
  self:Say(string.format("Raid rolling %s: %s", linkOrName(drop), table.concat(parts, ", ")))
  pcall(RandomRoll, 1, #names)
  self:Save()
  self:Broadcast()
  changed()
  return true
end

local rollPattern, rollOrder

local function onSystem(text)
  if Core.IsSecret(text) then
    if LM.activeKey and not LM.rollsSecret then
      LM.rollsSecret = true
      changed()
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
  if not (name and roll) or low ~= 1 then return end
  LM.rollsSecret = false
  local drop
  for _, d in ipairs(LM.drops) do
    if d.key == LM.activeKey then drop = d end
  end
  if not drop then return end

  if drop.state == "raid" then
    local names = drop.raidNames or {}
    if name == C.Me() and high == #names and names[roll] then
      drop.rolls = { [names[roll]] = { v = roll, kind = "raid" } }
      drop.raided = true
      drop.state = "done"
      LM.activeKey = nil
      LM:Say(string.format("%s wins %s.", names[roll], linkOrName(drop)))
      LM:Save()
      LM:Broadcast()
      changed()
    end
    return
  end

  if drop.state ~= "rolling" then return end
  local kind = Ladder.KIND_BY_MAX[high]
  if not kind or (drop.rolls or {})[name] then return end   -- only the first roll counts
  local rec = record()
  local reserved = isReserved(drop, rec)
  local counts = true
  if drop.only and not drop.only[name] then counts = false end
  if reserved then
    -- a reserved item is one plain roll, and only from those who reserved it
    local isReserver = false
    for _, r in ipairs(Ladder.Reservers(listOf(rec), rec:State(), drop.id)) do
      if r.p == name then isReserver = true end
    end
    if not isReserver or high ~= 100 then counts = false end
  end
  if counts then
    drop.rolls[name] = { v = roll, kind = (drop.onlyKind and drop.onlyKind[name]) or kind }
  else
    drop.ignored = drop.ignored or {}
    drop.ignored[name] = roll
  end
  local _, _, _, waiting = LM:Rank(drop)
  if #waiting == 0 and (reserved or drop.only) and counts then
    LM:Finish(drop)   -- everyone who can roll has
  else
    LM:Save()
    LM:Broadcast()
    changed()
  end
end
LM.OnSystem = onSystem
Core:On("CHAT_MSG_SYSTEM", "council.lootmaster", function(_, text) onSystem(text) end)

---Time left on a roll, in whole seconds.
function LM.SecondsLeft(drop)
  if not drop.endsAt then return drop.left or 0 end
  return math.max(0, math.ceil(drop.endsAt - C.Clock()))
end

---The countdown. When it runs out the roll ends, unless a reserver still hasn't rolled.
function LM:Tick()
  local drop
  for _, d in ipairs(self.drops) do
    if d.key == self.activeKey then drop = d end
  end
  if not drop or drop.state ~= "rolling" then return end
  if drop.endsAt and C.Clock() >= drop.endsAt then
    local _, _, _, waiting = self:Rank(drop)
    if #waiting == 0 then
      self:Finish(drop)
      return
    end
    drop.endsAt = nil   -- out of time, but those in line can still roll: "Waiting for the rest"
    self:Broadcast()
  end
  if C.Popups then C.Popups:Refresh() end
end

---The game's own roll window, for everyone with or without the add-on: the fallback when /roll can't be read.
function LM:RequestRoll(drop)
  local slot = drop.slots and drop.slots[1]
  if not slot then return false end
  return (pcall(DoMasterLootRoll, slot))
end

-------------------------------------------------------------------------------------------
-- Giving
-------------------------------------------------------------------------------------------

local function candidateIndex(slot, name)
  for i = 1, MAX_CANDIDATES do
    local candidate = C.Global("GetMasterLootCandidate", slot, i)
    if candidate and C.Short(candidate) == name then return i end
  end
end

---Who the game will let this go to: names by class, for the player list. Falls back on the group if the game doesn't say.
function LM:Candidates(drop)
  local out, seen = {}, {}
  local slot = drop.slots and drop.slots[1]
  if slot and self:IsMasterLoot() then
    for i = 1, MAX_CANDIDATES do
      local candidate = C.Global("GetMasterLootCandidate", slot, i)
      local name = candidate and C.Short(candidate)
      if name and not seen[name] then
        seen[name] = true
        out[#out + 1] = name
      end
    end
  end
  if #out == 0 then out = C.GroupNames() end
  return out
end

-- which copy of this item this is for this player, so a loot line finds its award
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

---Whether Give only writes it down: group loot hands it out itself, and an item from your bags goes by trade.
function LM:OnlyRecords(drop)
  return drop.manual or not self:IsMasterLoot()
end

---What's in the way of giving: a reason, or nil.
function LM:GiveProblem(drop, player)
  if self:OnlyRecords(drop) then return nil end
  local slot = drop.slots and drop.slots[1]
  if not self.lootOpen or not slot then return "Open the loot window on this corpse first." end
  if not candidateIndex(slot, player) then return player .. " can't receive this: the game doesn't list them." end
end

---Gives the item, and either way records who it went to and why. Must come from a click. Returns true, or false and why.
function LM:Give(drop, player)
  local why = self:GiveProblem(drop, player)
  if why then return false, why end
  local rec, sid = C.Capture:Ensure()
  if not rec then return false, "There's no session to record it in: you need to be in a group." end
  if not self:OnlyRecords(drop) then
    local slot = table.remove(drop.slots, 1)
    if not pcall(GiveMasterLoot, slot, candidateIndex(slot, player)) then
      table.insert(drop.slots, 1, slot)
      return false, "The game refused to hand it over."
    end
  end
  local state, list = rec:State(), listOf(rec)
  local got = drop.rolls and drop.rolls[player]
  local reserved = Ladder.IsReserved(list, state, drop.id, drop.everyone or drop.raided)
  local kind = (got and got.kind == "raid" and "raid") or (reserved and "sr") or (got and got.kind) or "hand"
  local only = reserved and not got and Ladder.OnlyReserver(list, state, drop.id) == player
  local bonus = kind == "sr" and (C.State.Plus(state, player, drop.id) * state.rules.bonus) or 0
  local text = Ladder.Why(kind, got and got.v, bonus, only)
  rec:Append("award", { s = sid, p = player, i = drop.id, n = nextCopy(rec, sid, player, drop.id), rung = kind == "sr" and "sr" or kind, roll = got and got.v, bonus = bonus > 0 and bonus or nil, why = text, b = drop.boss })
  table.insert(drop.given, player)
  if drop.rolls then drop.rolls[player] = nil end
  if drop.locked then
    for i, row in ipairs(drop.locked) do
      if row.p == player then table.remove(drop.locked, i) break end
    end
  end
  drop.why = text
  self:Say(string.format("%s goes to %s: %s.", linkOrName(drop), player, text))
  if self.Remaining(drop) <= 0 then
    drop.state = "given"
    if self.activeKey == drop.key then self.activeKey = nil end
  end
  self:Save()
  self:Broadcast()
  changed()
  return true
end

-- Loot left behind when the loot window closes is the mistake that costs most, so it says so, once a corpse.
function LM:WarnIfLeft()
  local left = self:Left()
  if left > 0 then
    C:Print(string.format("%d %s still to hand out. Open the corpse again to finish.", left, left == 1 and "item" or "items"))
  end
end

-------------------------------------------------------------------------------------------
-- Everyone else's copy
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
      out[#out + 1] = { key = d.key, id = d.id, link = d.link, boss = d.boss, copies = d.copies, given = d.given, state = d.state, rolls = d.rolls, only = d.only, everyone = d.everyone, raided = d.raided, why = d.why, left = LM.SecondsLeft(d) }
    end
    C.Transport:Send({ m = "L", drops = out, active = self.activeKey }, kind, nil, "NORMAL", true)
  end)
end

function LM:ReceiveLive(sender, msg)
  if sender ~= self:MasterName() or type(msg.drops) ~= "table" then return end
  local clean = {}
  for _, d in ipairs(msg.drops) do
    if type(d) == "table" and type(d.id) == "number" and type(d.key) == "string" then
      d.rolls = type(d.rolls) == "table" and d.rolls or {}
      d.given = type(d.given) == "table" and d.given or {}
      -- a peer's table is only trusted to the shape drawing needs
      for name, got in pairs(d.rolls) do
        if type(name) ~= "string" or type(got) ~= "table" or type(got.v) ~= "number" or not Ladder.KIND_RANK[got.kind] then d.rolls[name] = nil end
      end
      if type(d.only) ~= "table" then d.only = nil end
      d.copies = type(d.copies) == "number" and d.copies or 1
      d.left = type(d.left) == "number" and d.left or 0
      clean[#clean + 1] = d
    end
  end
  self.remote = { drops = clean, from = sender, at = C.Now() }
  if C.Popups and type(msg.active) == "string" then C.Popups:Watch(msg.active) end
  changed()
end

Core:OnLogin(function() if C.db then LM:Restore() end end)
