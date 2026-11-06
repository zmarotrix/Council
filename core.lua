-- Council: your guild's loot and records. Built on NorgannonDB and NorgannonDB_Core.
-- Plan and client findings: docs/council-v1.md; the look: design/suite/council.html.
--
-- serial, hash, ledger, state, ladder and sync (loaded before this) know nothing of the game. This file ties them to it:
-- saved data, one record for the guild and one personal, and a one-second tick.

local ADDON = ...
local Core = NorgannonCore
local DB = NorgannonDB

local C = Council
C.addonName = ADDON or "Council"

if not (Core and Core:Require(1, 16)) or not (DB and DB:RequireSchema(1, 4)) then
  C.disabled = true
  C_Timer.After(5, function()
    print("|cffc3e05aCouncil|r needs NorgannonDB 1.4 and NorgannonDB Core 1.16 or newer; it is turned off.")
  end)
  return
end

C.PREFIX = "|cffc3e05aCouncil|r"
function C:Print(msg) Core:Print(msg, self.PREFIX) end

-------------------------------------------------------------------------------------------
-- Calling the client. Any call may be missing, refuse, or answer in secret values, which count as no answer.
-------------------------------------------------------------------------------------------

local function clean(ok, ...)
  if not ok then return nil end
  local n = select("#", ...)
  if n == 0 then return nil end
  local out = { ... }
  for i = 1, n do
    if Core.IsSecret(out[i]) then out[i] = nil end
  end
  return unpack(out, 1, n)
end

---The global function name(...), with errors and secret values turned into nil.
function C.Global(name, ...)
  local fn = rawget(_G, name)
  if not fn then return nil end
  return clean(pcall(fn, ...))
end

---The namespaced client function ns.name(...).
function C.In(ns, name, ...)
  local t = rawget(_G, ns)
  local fn = t and t[name]
  if not fn then return nil end
  return clean(pcall(fn, ...))
end

function C.Now() return C.Global("GetServerTime") or time() end
function C.Clock() return GetTime() end

---A player's name as records hold it: bare on our own realm, with the realm otherwise. nil for a secret name.
function C.Short(name)
  if type(name) ~= "string" or Core.IsSecret(name) or name == "" then return nil end
  local short = C.Global("Ambiguate", name, "none")
  return short or name
end

function C.Me() return C.Short((C.Global("UnitName", "player"))) end

---Why add-on messages can't go out right now, or nil: "realm" means never here, "lockdown" means for now.
function C.SendBlocked()
  if C.In("C_ChatInfo", "AreOutgoingAddonChatMessagesRestricted") then return "realm" end
  if C.In("C_ChatInfo", "InChatMessagingLockdown") then return "lockdown" end
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

function C.ItemColor(id)
  local quality = C.In("C_Item", "GetItemQualityByID", id)
  local colors = rawget(_G, "ITEM_QUALITY_COLORS")
  local color = quality and colors and colors[quality]
  return color and color.hex or "|cffa335ee"
end

function C.ItemText(id, link)
  return C.ItemColor(id) .. C.ItemName(id, link) .. "|r"
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
  if C.Roster then C.Roster:Tick() end
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

local DEFAULTS = {
  autoOpen = true,    -- the window opens when the loot master opens loot worth rolling on
  announce = true,    -- starting a roll says so in raid chat
}

Core:On("ADDON_LOADED", C, function(_, name)
  if name ~= C.addonName then return end
  Core:Off("ADDON_LOADED", C)
  local saved = rawget(_G, "CouncilDB")
  CouncilDB = type(saved) == "table" and saved or {}
  C.db = CouncilDB
  for k, v in pairs(DEFAULTS) do
    if C.db[k] == nil then C.db[k] = v end
  end
  C.db.guilds = C.db.guilds or {}
  C.db.personal = C.db.personal or {}
end)

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

Core:RegisterAddon("council", {
  version = C_AddOns and C_AddOns.GetAddOnMetadata(C.addonName, "Version") or "0.1.0",
  open = function() C:Toggle() end,
})

SLASH_COUNCIL1 = "/council"
SlashCmdList["COUNCIL"] = function(msg)
  local lower = string.lower(strtrim(msg or ""))
  if lower == "" then
    C:Toggle()
  elseif lower == "settings" or lower == "options" then
    C:OpenSettings()
  elseif lower == "loot" or lower == "reserves" or lower == "history" or lower == "players" or lower == "records" then
    C.Window:Open(lower)
  elseif lower == "status" then
    C:PrintStatus()
  else
    C:Print("/council opens the window. Also: /council loot, reserves, history, players, records, settings, status")
  end
end

---A short account of where things stand, for checking in game.
function C:PrintStatus()
  local rec = self:GuildRecord()
  self:Print(rec and ("Guild record: " .. #rec.ledger:Authors() .. " authors, digest " .. rec.ledger:Digest()) or "No guild record.")
  self:Print("You " .. (self.Roster:IsOfficer(self.Me()) and "count as an officer." or "don't count as an officer."))
  self:Print("Sending: " .. tostring(self.SendBlocked() or "allowed") .. ". Waiting to send: " .. self.Transport:QueueSize())
  self:Print("Loot lines this session: " .. tostring(self.Capture:SessionLineCount()) .. ". Lines the game kept secret: " .. tostring(self.Capture.secretLines))
  self:Print("Loot master: " .. tostring(self.LootMaster:MasterName()) .. ". Method: " .. tostring(self.LootMaster:MethodName()))
end

local function onClick(button)
  if button == "RightButton" then C:OpenSettings() else C:Toggle() end
end
local function tooltip(tt)
  tt:AddLine("Council", .765, .878, .353)
  tt:AddLine("Your guild's loot and records", 1, 1, 1)
  tt:AddLine("Click: open or close  ·  Right-click: settings  ·  Drag: move", .43, .4, .32)
end
Core:OnLogin(function() Core.MinimapButton:Add("council", { onClick = onClick, tooltip = tooltip }) end)
function Council_OnAddonCompartmentClick(_, button) onClick(button) end
function Council_OnAddonCompartmentEnter(_, frame)
  GameTooltip:SetOwner(frame, "ANCHOR_LEFT")
  tooltip(GameTooltip)
  GameTooltip:Show()
end
function Council_OnAddonCompartmentLeave() GameTooltip:Hide() end
