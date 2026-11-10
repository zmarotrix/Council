-- Council: your guild's loot and records. Built on NorgannonDB and NorgannonDB_Core.
-- Plan and client findings: docs/council-v1.md; the look: design/suite/council.html.
--
-- serial, hash, ledger, state, ladder and sync (loaded before this) know nothing of the game. This file ties them to it:
-- saved data, one record for the guild and one personal, and a one-second tick.

local ADDON = ...
local Core = NorgannonCore

local C = Council

if not (Core and Core.NewAddon) then
  C.disabled = true
  print("Council needs NorgannonDB Core 1.25 or newer; it is turned off.")
  return
end

-------------------------------------------------------------------------------------------
-- Saved data
-------------------------------------------------------------------------------------------

C.DEFAULTS = {
  autoOpen = true,    -- the window opens when the loot master opens loot worth rolling on
  announce = true,    -- starting a roll says so in raid chat
  rollSeconds = 15,   -- how long a roll stays open
  watchRolls = true,  -- show the roll popup when someone else is running the loot
  askMasterLoot = true, -- targeting a boss as leader asks about switching to master loot
  guilds = {},        -- [realm/guild] = the guild's record
  personal = {},      -- [first name] = a character's own record, for groups that aren't the guild's
}

-- The suite's plumbing (Core:NewAddon): version checks, CouncilDB with its defaults, the slash command, the minimap row
-- and the add-on menu. Left-click and /council open the window; right-click opens settings.
Core:NewAddon("council", {
  folder = ADDON, api = { 1, 25 }, data = { 1, 4 },
  db = "CouncilDB", defaults = C.DEFAULTS,
  slash = { "/council" },
  commands = {
    loot = { function() C.Popups:ShowList() end, "the loot list" },
    roll = { function(rest)
      -- an item from your bags: /council roll [link], or 2x[link] for two winners
      local copies = tonumber((rest or ""):match("(%d+)x")) or 1
      local link = (rest or ""):match("(|c.-|h|r)")
      local id = link and tonumber(link:match("item:(%d+)"))
      if id then
        C.Popups:Roll(C.LootMaster:AddManual(id, link, copies))
      else
        C:Print("/council roll, then shift-click an item from your bags. 2x before it means two top rolls win.")
      end
    end, "[item]: roll an item from your bags (2x[item] for two winners)" },
    tonight = { function() C.Window:Open("tonight") end, "tonight's loot" },
    reserves = { function() C.Window:Open("reserves") end, "soft reserves" },
    history = { function() C.Window:Open("history") end, "who got what" },
    players = { function() C.Window:Open("players") end, "everyone's record" },
    records = { function() C.Window:Open("records") end, "the shared record" },
    status = { function() C:PrintStatus() end, "where things stand" },
  },
})
if C.disabled then return end

-------------------------------------------------------------------------------------------
-- Calling the client: Core's helpers. Any call may be missing, refuse, or answer in secret values.
-------------------------------------------------------------------------------------------

C.Global, C.In, C.Now = Core.Global, Core.In, Core.Now
function C.Clock() return GetTime() end

---A player's name as records hold it: the first name (Core.Names.First). Forever's loot lines and C_LootHistory say
---"Arhara Dawnstrider" where the roster and UnitName say "Arhara", so records go by the first name, or nobody's reserve
---would match their loot. This is who someone is, not an address: a whisper to it fails (Transport and Core.Names keep
---the full names).
C.Short = Core.Names.First

function C.Me() return C.Short((C.Global("UnitName", "player"))) end

---Why add-on messages can't go out right now, or nil: "lockdown" means for now, "refused" means the game turned down our
---last test message. C_ChatInfo.AreOutgoingAddonChatMessagesRestricted doesn't decide this: /cprobe found it true on
---Forever while add-on messages from others kept arriving, so only a real send can say.
function C.SendBlocked()
  if C.In("C_ChatInfo", "InChatMessagingLockdown") then return "lockdown" end
  if C.Transport and C.Transport.refused then return "refused" end
  return nil
end

---The class of one of our people, as far as anything knows.
function C.Who(name)
  local class = C.Roster and C.Roster:ClassOf(name)
  local colors = rawget(_G, "RAID_CLASS_COLORS")
  local color = class and colors and colors[class]
  if color and color.colorStr then return "|c" .. color.colorStr .. name .. "|r" end
  return name
end

---An item's name, from its link, then the client, then NorgannonDB.
function C.ItemName(id, link)
  if type(link) == "string" then
    local name = link:match("%[(.-)%]")
    if name then return name end
  end
  return C.In("C_Item", "GetItemNameByID", id) or Core.DB:Name("items", id) or ("Item " .. tostring(id))
end

---An item's quality from a link, as this client writes them: "|cnIQ3:|Hitem:..."; nil if it doesn't say.
function C.LinkQuality(link)
  return type(link) == "string" and tonumber(link:match("|cnIQ(%d+):")) or nil
end

function C.ItemColor(id, link)
  local quality = C.In("C_Item", "GetItemQualityByID", id) or C.LinkQuality(link)
  local colors = rawget(_G, "ITEM_QUALITY_COLORS")
  local color = quality and colors and colors[quality]
  return color and color.hex or "|cffa335ee"
end

function C.ItemText(id, link)
  return C.ItemColor(id, link) .. C.ItemName(id, link) .. "|r"
end

---A format string from the game ("%s receives loot: %s.") as a Lua pattern, and which capture holds which argument.
function C.Pattern(text)
  if type(text) ~= "string" then return nil end
  local order, position = {}, 0
  local pattern = text:gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1")
  pattern = pattern:gsub("%%(%d)%$([sd])", function(n, kind)
    order[#order + 1] = tonumber(n)
    return kind == "d" and "(%d+)" or "(.-)"
  end)
  pattern = pattern:gsub("%%([sd])", function(kind)
    position = position + 1
    order[#order + 1] = position
    return kind == "d" and "(%d+)" or "(.-)"
  end)
  return "^" .. pattern .. "$", order
end

---Matches text against C.Pattern's result. Returns the arguments in the format's own order.
function C.Match(text, pattern, order)
  local got = { text:match(pattern) }
  if #got == 0 then return nil end
  local out = {}
  for i, n in ipairs(order) do out[n] = got[i] end
  return out
end

-------------------------------------------------------------------------------------------
-- A small scheduler. Everything that waits goes through this, because it's one place to read and test.
-------------------------------------------------------------------------------------------

local later = {}

function C.Later(seconds, fn)
  later[#later + 1] = { at = C.Clock() + seconds, fn = fn }
end

function C.Tick()
  if C.disabled or not C.db then return end
  local now = C.Clock()
  local due
  for i = #later, 1, -1 do
    if later[i].at <= now then
      due = due or {}
      table.insert(due, 1, later[i].fn)
      table.remove(later, i)
    end
  end
  if due then
    for _, fn in ipairs(due) do Core.SafeCall(fn) end
  end
  if C.Transport then C.Transport:Tick() end
  local guild = C.guildRecord
  if guild and guild.sync then guild.sync:Tick() end
  if C.LootMaster then C.LootMaster:Tick() end
end

-------------------------------------------------------------------------------------------
-- Records: the guild's, and a personal one for groups that aren't the guild's
-------------------------------------------------------------------------------------------

local Record = {}
Record.__index = Record

function Record:Stateenv()
  if self.personal then return { me = C.Me(), personal = true } end
  local Roster = C.Roster
  return { me = C.Me(), isOfficer = function(name) return Roster:IsOfficer(name) end, isGuildMaster = function(name) return Roster:Rank(name) == 0 end }
end

---The replayed state. Built only when the record or the roster changed.
function Record:State()
  local rosterRev = C.Roster and C.Roster.revision or 0
  if not self.state or self.builtRev ~= self.ledger.revision or self.builtRoster ~= rosterRev then
    self.state = C.State.Build(self.ledger, self:Stateenv())
    self.builtRev, self.builtRoster = self.ledger.revision, rosterRev
  end
  return self.state
end

---Writes an entry and sends it on its way. Returns the entry.
function Record:Append(kind, data, at)
  local entry = self.ledger:Append(kind, data, at)
  if self.sync then self.sync:Broadcast(entry) end
  return entry
end

---Can I write decisions here?
function Record:CanDecide()
  return self.personal or (C.Roster and C.Roster:IsOfficer(C.Me()))
end

local function changed()
  if C.Window then C.Window:Changed() end
end

local function newRecord(store, personal)
  local rec = setmetatable({ personal = personal, store = store }, Record)
  rec.ledger = C.Ledger.New(store, { me = C.Me(), now = C.Now, onChange = changed, onAlarm = function(alarm)
    if alarm.kind == "impersonated" then
      C:Print("Someone sent an entry in your name that you didn't write. It's in Records.")
    end
  end })
  return rec
end

local function guildKey()
  local name = C.Global("GetGuildInfo", "player")
  if not name then return nil end
  return (C.Global("GetRealmName") or "?") .. "/" .. name
end

---The guild's record, or nil when not in one, or before the game has said which.
function C:GuildRecord()
  local key = guildKey()
  if not key then
    self.guildRecord = nil
    return nil
  end
  local rec = self.guildRecord
  if rec and rec.key == key then return rec end
  self.db.guilds[key] = self.db.guilds[key] or {}
  rec = newRecord(self.db.guilds[key], false)
  rec.key = key
  rec.sync = C.Sync.New(rec.ledger, C.Transport:SyncIO())
  rec.sync:Start()
  self.guildRecord = rec
  return rec
end

function C:PersonalRecord()
  local me = C.Me() or "?"
  local rec = self.personalRecord
  if rec and rec.owner == me then return rec end
  self.db.personal[me] = self.db.personal[me] or {}
  rec = newRecord(self.db.personal[me], true)
  rec.owner = me
  self.personalRecord = rec
  return rec
end

---The record the window is showing: the guild's, unless the player chose their own or isn't in a guild.
function C:ShownRecord()
  if self.db.showPersonal then return self:PersonalRecord() end
  return self:GuildRecord() or self:PersonalRecord()
end

-------------------------------------------------------------------------------------------
-- Saved data
-------------------------------------------------------------------------------------------

Core:OnLogin(function()
  if not C.db then return end
  C:GuildRecord()
  C:PersonalRecord()
  if C_Timer and C_Timer.NewTicker then C_Timer.NewTicker(1, C.Tick) end
end)
Core:On("PLAYER_GUILD_UPDATE", "council", function()
  if C.db then C:GuildRecord() end
end)

-------------------------------------------------------------------------------------------
-- Opening
-------------------------------------------------------------------------------------------

function C:Toggle()
  local win = self.Window and self.Window:Get()
  if not win then return end
  if win:IsShown() then win:Hide() else self.Window:Open() end
end

---A short account of where things stand, for checking in game.
function C:PrintStatus()
  local rec = self:GuildRecord()
  self:Print(rec and ("Guild record: " .. #rec.ledger:Authors() .. " authors, digest " .. rec.ledger:Digest()) or "No guild record.")
  self:Print("You " .. (self.Roster:IsOfficer(self.Me()) and "count as an officer." or "don't count as an officer."))
  self:Print("Sending: " .. tostring(self.SendBlocked() or "allowed") .. ". Last test: " .. tostring(self.Transport.lastResult) .. ". Waiting to send: " .. self.Transport:QueueSize())
  self:Print("Announcing in chat: " .. tostring(self.db.chatWorks == nil and "not tried yet" or (self.db.chatWorks and "works" or "doesn't reach chat, so it opens the chat box for you")))
  self:Print("Loot lines this session: " .. tostring(self.Capture:SessionLineCount()) .. ". Lines the game kept secret: " .. tostring(self.Capture.secretLines))
  self:Print("Loot master: " .. tostring(self.LootMaster:MasterName()) .. ". Method: " .. tostring(self.LootMaster:MethodName()))
end
