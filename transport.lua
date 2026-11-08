-- Add-on messages: AceComm from Core's libraries, under our own prefix. Messages are compressed when the client can,
-- and they wait while the game forbids sending. ChatThrottleLib doesn't look at why a send was refused, so a message
-- sent during lockdown would be lost: this is the gate that stops that.

local C = Council
if C.disabled then return end
local Core = NorgannonCore
local Serial = C.Serial

local Transport = { queue = {} }
C.Transport = Transport

local PREFIX = "Council"
local MAX_QUEUE = 200
local MAX_INCOMING = 120000      -- bytes of text we'll even try to read
local COMPRESS_FROM = 120
local CHANNELS = { GUILD = true, OFFICER = true, RAID = true, PARTY = true, WHISPER = true, INSTANCE_CHAT = true }

-- Records call people by first name (see C.Short), but the game can't deliver a whisper to one: Forever's players have
-- surnames too, and whispering "Tyrant" gets "No player named 'Tyrant'" in chat. So a reply goes to the sender's name
-- exactly as the game gave it to us.
local addresses = {}             -- first name -> their name as the game wrote it

local AceComm = LibStub("AceComm-3.0")
AceComm:Embed(Transport)

local function encodingApi()
  local api = rawget(_G, "C_EncodingUtil")
  if api and api.CompressString and api.DecompressString and api.EncodeBase64 and api.DecodeBase64 then return api end
end

function Transport.Encode(msg)
  local text = Serial.Write(msg)
  local api = encodingApi()
  if api and #text >= COMPRESS_FROM then
    local ok, zipped = pcall(function() return api.EncodeBase64(api.CompressString(text)) end)
    if ok and type(zipped) == "string" and #zipped < #text then return "Z" .. zipped end
  end
  return "T" .. text
end

function Transport.Decode(text)
  if type(text) ~= "string" or #text > MAX_INCOMING then return nil end
  local kind, body = text:sub(1, 1), text:sub(2)
  if kind == "T" then return Serial.Read(body) end
  if kind == "Z" then
    local api = encodingApi()
    if not api then return nil end
    local ok, plain = pcall(function() return api.DecompressString(api.DecodeBase64(body)) end)
    if ok and type(plain) == "string" and #plain <= MAX_INCOMING * 4 then return Serial.Read(plain) end
  end
  return nil
end

local function deliver(item)
  Transport:SendCommMessage(PREFIX, item.text, item.channel, item.target, item.priority)
end

local TEST_EVERY_REFUSED = 300    -- seconds, while the game is turning us down
local nextTest = 0

local function resultName(code)
  local names = rawget(_G, "Enum") and Enum.SendAddonMessageResult
  for name, value in pairs(names or {}) do
    if value == code then return name end
  end
  return tostring(code)
end

---ChatThrottleLib hides what the game answers, so a small real message finds out whether sending works. Peers ignore it.
function Transport:Test()
  if not C.Global("IsInGuild") or C.In("C_ChatInfo", "InChatMessagingLockdown") then return end
  local code = C.In("C_ChatInfo", "SendAddonMessage", PREFIX, "Ttest", "GUILD")
  self.lastResult = code == nil and "no answer" or resultName(code)
  local ok = code == nil or code == 0 or self.lastResult == "AddonMessageThrottle" or self.lastResult == "ChannelThrottle"
  self.refused = not ok or nil
  if self.refused then nextTest = C.Clock() + TEST_EVERY_REFUSED end
end

---Sends a table. It waits if the game forbids sending for now. A volatile message is dropped instead: it'd be stale.
function Transport:Send(msg, channel, target, priority, volatile)
  local blocked = C.SendBlocked()
  if blocked == "refused" then return false end
  if channel == "WHISPER" then target = addresses[target] or Core.Names:Address(target) or target end
  local item ={ text = self.Encode(msg), channel = channel, target = target, priority = priority or "NORMAL" }
  if blocked then
    if volatile then return false end
    if #self.queue >= MAX_QUEUE then table.remove(self.queue, 1) end
    self.queue[#self.queue + 1] = item
    return false
  end
  deliver(item)
  return true
end

function Transport:QueueSize() return #self.queue end

function Transport:Tick()
  if self.refused and C.Clock() >= nextTest then self:Test() end
  if #self.queue > 0 and not C.SendBlocked() then
    local queue = self.queue
    self.queue = {}
    for _, item in ipairs(queue) do deliver(item) end
    if C.Window then C.Window:Changed() end
  end
end

function Transport:OnComm(prefix, text, channel, sender)
  if prefix ~= PREFIX or Core.IsSecret(text) or Core.IsSecret(sender) then return end
  if not CHANNELS[channel] then return end
  local name = C.Short(sender)
  if not name or name == C.Me() then return end
  addresses[name] = sender
  local msg = self.Decode(text)
  if type(msg) ~= "table" then return end
  if msg.m == "L" then
    if C.LootMaster then Core.SafeCall(function() C.LootMaster:ReceiveLive(name, msg) end) end
    return
  end
  local rec = C.guildRecord
  -- whatever a peer sends must not raise an error here
  if rec and rec.sync then pcall(rec.sync.Receive, rec.sync, name, msg) end
end

Transport:RegisterComm(PREFIX, "OnComm")
Core:OnLogin(function() C.Later(8, function() Transport:Test() end) end)

---What sync.lua needs from the game.
function Transport:SyncIO()
  local Roster = C.Roster
  return {
    me = C.Me(),
    now = C.Now,
    random = function(a, b) return math.random(a, b) end,
    isOfficer = function(name) return Roster:IsOfficer(name) end,
    -- until the roster has loaded, nobody can be checked, and a message can wait for the next summary
    isMember = function(name) return Roster:IsMember(name) end,
    isOnline = function(name) return Roster:IsOnline(name) end,
    onlineCount = function() return Roster:OnlineCount() end,
    send = function(msg, channel, target, priority) Transport:Send(msg, channel, target, priority) end,
    canSend = function() return C.SendBlocked() ~= "refused" end,
  }
end
