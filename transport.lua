-- Add-on messages, on Core.Net under our own prefix: compression, the lockdown queue, the refusal test and whisper
-- addresses are Core's. What's Council's: turning messages into text and back (serial.lua), and where each one goes.
-- The wire is unchanged: "T" + text, or "Z" + compressed base64.

local C = Council
if C.disabled then return end
local Core = NorgannonCore
local Serial = C.Serial
local Net = Core.Net

local Transport = {}
C.Transport = Transport

local PREFIX = "Council"
local MAX_INCOMING = 120000      -- bytes of text we'll even try to read
local COMPRESS_FROM = 120

function Transport.Encode(msg)
  return Net.Pack(Serial.Write(msg), COMPRESS_FROM)
end

function Transport.Decode(text)
  local plain = Net.Unpack(text, MAX_INCOMING)
  return plain and Serial.Read(plain) or nil
end

local function onMessage(text, name)
  local msg = Serial.Read(text)
  if type(msg) ~= "table" then return end
  if msg.m == "L" then
    if C.LootMaster then Core.SafeCall(function() C.LootMaster:ReceiveLive(name, msg) end) end
    return
  end
  local rec = C.guildRecord
  -- whatever a peer sends must not raise an error here
  if rec and rec.sync then pcall(rec.sync.Receive, rec.sync, name, msg) end
end

local channel = Net:Channel(PREFIX, {
  onMessage = onMessage, maxIncoming = MAX_INCOMING, compressFrom = COMPRESS_FROM,
  onDrain = function() if C.Window then C.Window:Changed() end end,
})
Transport.channel = channel

-- the channel's test result, read as Transport.refused and Transport.lastResult
setmetatable(Transport, { __index = function(_, key)
  if key == "refused" or key == "lastResult" then return channel[key] end
end })

---Sends a table. It waits if the game forbids sending for now. A volatile message is dropped instead: it'd be stale.
function Transport:Send(msg, distribution, target, priority, volatile)
  return channel:Send(Serial.Write(msg), distribution, target, priority, volatile)
end

function Transport:Test() channel:Test() end
function Transport:QueueSize() return channel:QueueSize() end
function Transport:Tick() channel:Tick() end

---An incoming message, as AceComm hands it over (the harness calls this directly).
function Transport:OnComm(prefix, text, distribution, sender)
  channel:Receive(prefix, text, distribution, sender)
end

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
    send = function(msg, channelName, target, priority) Transport:Send(msg, channelName, target, priority) end,
    canSend = function() return C.SendBlocked() ~= "refused" end,
  }
end
