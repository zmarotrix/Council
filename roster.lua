-- Who's who: the guild roster and the current group. Rank is the trust boundary (docs/council-v1.md section 4), and the
-- game vouches for it. GetGuildRosterInfo is undocumented, so its fields are from memory until /cprobe confirms the
-- shape. Rows with a secret name are skipped, and a roster read in lockdown just waits for the next one.

local Core = NorgannonCore
local C = Council
if C.disabled then return end

local Roster = { revision = 0, byName = {}, count = 0, classOf = {} }
C.Roster = Roster

local REFRESH_EVERY = 60
local EDIT_OFFICER_NOTE = 12     -- position in the rank's permissions: from memory, /cprobe lists them to check
local FALLBACK_MAX_RANK = 1      -- if no rank says it can edit officer notes: guild master and the next one down

local nextAsk = 0
local lastRank

local function officerRanks()
  local out, any = {}, false
  local count = C.Global("GuildControlGetNumRanks") or 0
  for i = 1, count do
    local flags = C.In("C_GuildInfo", "GuildControlGetRankFlags", i)
    if type(flags) == "table" and flags[EDIT_OFFICER_NOTE] == true then
      out[i - 1] = true       -- the roster counts ranks from 0, this call from 1
      any = true
    end
  end
  return any and out or nil
end

local function read()
  local total = C.Global("GetNumGuildMembers")
  if type(total) ~= "number" or total == 0 then return false end
  local byName = {}
  local fingerprint = {}
  for i = 1, total do
    local name, _, rankIndex, _, _, _, _, _, online, _, classFile, _, _, _, _, _, guid = C.Global("GetGuildRosterInfo", i)
    local short = C.Short(name)
    if short then
      byName[short] = { rank = rankIndex, online = online, class = classFile, guid = guid, index = i }
      if classFile then Roster.classOf[short] = classFile end
      fingerprint[#fingerprint + 1] = short .. tostring(rankIndex)
    end
  end
  if next(byName) == nil then return false end
  table.sort(fingerprint)
  local stamp = table.concat(fingerprint, ";")
  Roster.byName, Roster.count = byName, total
  Roster.ranks = officerRanks()
  if stamp ~= lastRank then
    lastRank = stamp
    Roster.revision = Roster.revision + 1
    if C.Window then C.Window:Changed() end
    Roster:WatchRanks()
  end
  return true
end

function Roster:Known() return self.count > 0 end
function Roster:Rank(name)
  local row = self.byName[name]
  return row and row.rank
end
function Roster:IsMember(name) return self.byName[name] ~= nil end
function Roster:IsOnline(name)
  local row = self.byName[name]
  return row and row.online or false
end
function Roster:ClassOf(name) return self.classOf[name] end
function Roster:OnlineCount()
  local n = 0
  for _, row in pairs(self.byName) do
    if row.online then n = n + 1 end
  end
  return n
end

---Is this person an officer today? The guild master's setting first, then the game's own rank permissions.
function Roster:IsOfficer(name)
  local rank = self:Rank(name)
  if rank == nil then return false end
  if rank == 0 then return true end
  local rec = C.guildRecord
  local maxRank = rec and rec.state and rec.state.maxOfficerRank
  if maxRank then return rank <= maxRank end
  if self.ranks then return self.ranks[rank] == true end
  return rank <= FALLBACK_MAX_RANK
end

-- An officer's client writes down when someone who has made decisions gains or loses the rank, so their old decisions
-- stand and new ones don't. Everyone agrees because it's an entry, not a view of today's roster.
function Roster:WatchRanks()
  local rec = C.guildRecord
  if not rec or not self:Known() or not self:IsOfficer(C.Me()) then return end
  local state = rec:State()
  for _, author in ipairs(rec.ledger:Authors()) do
    local decided = false
    for _, e in ipairs(rec.ledger.store.logs[author]) do
      if C.Ledger.DECISIONS[e.k] then decided = true break end
    end
    if decided then
      local ranges = state.officerRanges[author]
      local last = ranges and ranges[#ranges] and ranges[#ranges].kind
      local isOfficer = self:IsOfficer(author)
      if not isOfficer and last ~= "revoke" then
        rec:Append("revoke", { who = author, at = C.Now() })
      elseif isOfficer and last == "revoke" then
        rec:Append("grant", { who = author, at = C.Now() })
      end
    end
  end
end

function Roster:Ask()
  if C.In("C_ChatInfo", "InChatMessagingLockdown") then return end
  if not C.Global("IsInGuild") then return end
  C.In("C_GuildInfo", "GuildRoster")
end

function Roster:Tick()
  local now = C.Clock()
  if now >= nextAsk then
    nextAsk = now + REFRESH_EVERY
    self:Ask()
  end
end

Core:On("GUILD_ROSTER_UPDATE", "council.roster", function() read() end)
Core:On("GUILD_RANKS_UPDATE", "council.roster", function() read() end)
Core:OnLogin(function() Roster:Ask() end)

-------------------------------------------------------------------------------------------
-- The group
-------------------------------------------------------------------------------------------

---Everyone in the group whose name the game will tell us, as { name, ... }, and their classes noted.
function C.GroupNames()
  local out = {}
  if C.Global("IsInRaid") then
    for i = 1, C.Global("GetNumGroupMembers") or 0 do
      local name, _, _, _, _, classFile = C.Global("GetRaidRosterInfo", i)
      local short = C.Short(name)
      if short then
        out[#out + 1] = short
        if classFile then Roster.classOf[short] = classFile end
      end
    end
  elseif C.Global("IsInGroup") then
    local me = C.Me()
    if me then out[1] = me end
    for i = 1, 4 do
      local short = C.Short((C.Global("UnitName", "party" .. i)))
      if short then
        out[#out + 1] = short
        local _, classFile = C.Global("UnitClass", "party" .. i)
        if classFile then Roster.classOf[short] = classFile end
      end
    end
  end
  table.sort(out)
  return out
end

---Half or more of the group in the guild makes it the guild's group; the rest stays personal.
function C:RecordForGroup()
  local guild = self:GuildRecord()
  if guild and Roster:Known() then
    local names = C.GroupNames()
    local inGuild = 0
    for _, name in ipairs(names) do
      if Roster:IsMember(name) then inGuild = inGuild + 1 end
    end
    if #names > 0 and inGuild * 2 >= #names then return guild end
  end
  return self:PersonalRecord()
end
