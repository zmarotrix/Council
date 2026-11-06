-- The loot popups (design/suite/council-loot.html): a loot list, a roll popup, a list of players and a confirmation. They sit beside the
-- game's own loot window rather than replacing it: hiding that window closes the loot (its OnHide calls CloseLoot), and the loot master
-- still needs it for gold and anything below the rolling threshold.
--
-- The flow follows what RollFor's README and demo GIFs show. Its code has no licence and wasn't read; the look is the suite's.

local Core = NorgannonCore
local C = Council
if C.disabled then return end
local UI = Core.UI
local Colors = UI.C
local Window, LM, Ladder = C.Window, C.LootMaster, C.Ladder

local Popups = { selected = nil }
C.Popups = Popups

local HEADER_H = 44
local LIST_W, LIST_ROW, LIST_MAX_ROWS, LIST_BAR = 330, 30, 12, 34
local ROLL_W, ROLL_ROW, ROLL_MAX_ROWS, ROLL_TOP, ROLL_MID, ROLL_BAR = 410, 26, 9, 46, 40, 36
local PICK_W, PICK_H, PICK_ROW = 240, 440, 22
local CONFIRM_W, CONFIRM_H = 360, 150
local ICON_SIZE, ICON_GAP, HEAD_MARGIN = 34, 9, 12
local MAX_BUTTONS = 5
local MAX_ROLL_BUTTONS, ROLL_PICK = 3, 30
local NO_BAR = 6

local list, roll, pick, confirm

local function place(frame, x, y)
  frame:ClearAllPoints()
  frame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", x, y)
  UI.RestorePosition(frame, frame.saveKey)
end

local function reservedTag(n, plus)
  if n == 0 then return "" end
  return "|cffc3e05aSR" .. (n > 1 and (" " .. n) or "") .. "|r"
end

local function kindTag(kind)
  local color = ({ sr = "c3e05a", ms = "e7c66c", os = "8fc7ff", tm = "e0a0e0", raid = "e7c66c" })[kind] or "a8a08a"
  return "|cff" .. color .. (Ladder.KIND_TAG[kind] or "") .. "|r"
end

-------------------------------------------------------------------------------------------
-- The loot list
-------------------------------------------------------------------------------------------

local function buildList()
  list = UI.Window({ name = "CouncilLootList", addon = "council", title = "Loot", width = LIST_W, height = 300 })
  list:SetAccent("council")
  list:Hide()
  if list.powered then list.powered:Hide() end
  list.rows = Window.RowList(list.body, LIST_ROW)
  list.rows:SetPoint("TOPLEFT", 6, -4)
  list.rows:SetPoint("BOTTOMRIGHT", -6, LIST_BAR)
  list.dropped = UI.Button(list.body, "Say what dropped", "quiet", function() LM:SayDropped() end)
  list.dropped:SetHeight(24)
  list.dropped:SetPoint("BOTTOMLEFT", 8, 6)
  list.clear = UI.Button(list.body, "Clear", "quiet", function() LM:Clear() end)
  list.clear:SetHeight(24)
  list.clear:SetPoint("LEFT", list.dropped, "RIGHT", 4, 0)
  list.left = UI.Text(list.body, "body", 12, Colors.muted)
  list.left:SetPoint("BOTTOMRIGHT", -10, 12)
  place(list, 40, -150)
  list:SetScript("OnHide", function() if LM:IsMaster() then LM:WarnIfLeft() end end)
end

local function fillList()
  if not list or not list:IsShown() then return end
  local rec = C:RecordForGroup()
  local state, reserves = rec:State(), rec:State().reserves
  local view = LM:View()
  local items = {}
  for i, d in ipairs(view) do
    local left = LM.Remaining(d)
    local nameText = C.ItemText(d.id, d.link)
    local right
    if left <= 0 then
      nameText = "|cff6e6552" .. C.ItemName(d.id, d.link) .. "|r"
      right = "|cff8fe08f" .. table.concat(d.given or {}, ", ") .. "|r"
    else
      local n = #Ladder.Reservers(reserves, state, d.id)
      right = reservedTag(n)
      if left > 1 then right = left .. "x  " .. right end
      if d.state == "rolling" then right = "|cffe7c66cRolling|r" end
    end
    items[#items + 1] = { id = d.id, link = d.link, title = string.format("|cff6e6552%d|r  %s", i, nameText), right = right, onClick = function()
      if left > 0 then Popups:Roll(d) end
    end }
  end
  if #items == 0 then items[1] = { title = "|cff6e6552Nothing to hand out.|r" } end
  list.rows:SetData(items, true)
  local boss = view[1] and view[1].boss
  list:SetSub(boss or "")
  local master = LM:IsMaster()
  list.dropped:SetShown(master and #view > 0)
  list.clear:SetShown(master and #view > 0)
  local total = 0
  for _, d in ipairs(view) do total = total + math.max(0, LM.Remaining(d)) end
  list.left:SetText(total > 0 and (total .. " left") or "")
  list:SetHeight(HEADER_H + 8 + math.min(math.max(#items, 1), LIST_MAX_ROWS) * LIST_ROW + LIST_BAR + 4)
end

function Popups:ShowList()
  if not list then buildList() end
  list:Show()
  fillList()
end

-------------------------------------------------------------------------------------------
-- The roll popup
-------------------------------------------------------------------------------------------

local function buildRoll()
  roll = UI.Window({ name = "CouncilRoll", addon = "council", title = "Roll", width = ROLL_W, height = 300 })
  roll:SetAccent("council")
  roll:Hide()
  if roll.powered then roll.powered:Hide() end
  roll.icon = roll.body:CreateTexture(nil, "ARTWORK")
  roll.icon:SetSize(ICON_SIZE, ICON_SIZE)
  roll.icon:SetPoint("TOPLEFT", 12, -8)
  roll.icon:SetTexCoord(.07, .93, .07, .93)
  roll.item = UI.Text(roll.body, "body", 15)
  roll.item:SetPoint("TOPLEFT", roll.icon, "TOPRIGHT", ICON_GAP, -1)
  roll.item:SetJustifyH("CENTER")
  roll.item:SetWordWrap(false)
  roll.note = UI.Text(roll.body, "body", 12, Colors.muted)
  roll.note:SetPoint("TOP", roll.item, "BOTTOM", 0, -2)
  roll.note:SetJustifyH("CENTER")
  roll.note:SetWordWrap(false)
  roll.rows = Window.RowList(roll.body, ROLL_ROW)
  roll.bar = roll.body:CreateTexture(nil, "ARTWORK")
  roll.bar:SetColorTexture(UI.Accent("council")[1], UI.Accent("council")[2], UI.Accent("council")[3], 1)
  roll.bar:SetHeight(3)
  roll.mid = UI.Text(roll.body, "body", 13, Colors.muted)
  roll.mid:SetHeight(ROLL_MID - 6)
  roll.mid:SetJustifyH("CENTER")
  roll.mid:SetWordWrap(true)
  roll.buttons = {}
  for i = 1, MAX_BUTTONS do
    local b = UI.Button(roll.body, "", i == 1 and "primary" or "quiet", function(self)
      if self.run then self.run() end
    end)
    b:SetHeight(24)
    roll.buttons[i] = b
  end
  roll.picks = {}
  for i = 1, MAX_ROLL_BUTTONS do
    local b = UI.Button(roll.body, "", "accent", function(self)
      if self.run then self.run() end
    end)
    b:SetHeight(24)
    roll.picks[i] = b
  end
  place(roll, 400, -170)
end

local function textWidth(text)
  return (text.GetUnboundedStringWidth and text:GetUnboundedStringWidth()) or text:GetStringWidth() or 0
end

-- The icon and the two lines of text sit in the middle as one group, however long the item's name is.
local function centreHeading()
  local room = ROLL_W - 2 * HEAD_MARGIN - ICON_SIZE - ICON_GAP
  local width = math.min(room, math.ceil(math.max(textWidth(roll.item), textWidth(roll.note))))
  roll.item:SetWidth(width)
  roll.note:SetWidth(width)
  roll.icon:ClearAllPoints()
  roll.icon:SetPoint("TOPLEFT", roll.body, "TOPLEFT", math.floor((ROLL_W - ICON_SIZE - ICON_GAP - width) / 2), -8)
end

-- A row of buttons, centred, this far from the bottom.
local function setButtons(pool, specs, y)
  local total, previous = 0, nil
  for i, b in ipairs(pool) do
    local spec = specs[i]
    b:SetShown(spec ~= nil)
    if spec then
      b.run = spec.run
      b:SetLabel(spec.text)
      total = total + b:GetWidth() + (i > 1 and 4 or 0)
    end
  end
  local x = math.floor(math.max(8, (ROLL_W - total) / 2))
  for i, b in ipairs(pool) do
    if specs[i] then
      b:ClearAllPoints()
      if previous then b:SetPoint("LEFT", previous, "RIGHT", 4, 0) else b:SetPoint("BOTTOMLEFT", roll.body, "BOTTOMLEFT", x, y) end
      previous = b
    end
  end
end

-- From the bottom up: the loot master's buttons, the line of text, the buttons to pick a roll, then the rows.
local function layoutRoll(bottom, picking)
  roll.mid:ClearAllPoints()
  roll.mid:SetPoint("BOTTOMLEFT", 12, bottom + 2)
  roll.mid:SetPoint("BOTTOMRIGHT", -12, bottom + 2)
  local above = bottom + ROLL_MID + (picking and ROLL_PICK or 0)
  roll.bar:ClearAllPoints()
  roll.bar:SetPoint("BOTTOMLEFT", roll.body, "BOTTOMLEFT", 14, above - 3)
  roll.rows:ClearAllPoints()
  roll.rows:SetPoint("TOPLEFT", 8, -ROLL_TOP - 4)
  roll.rows:SetPoint("BOTTOMRIGHT", -8, above)
  return above
end

local function currentDrop()
  return Popups.selected and LM:Find(Popups.selected)
end

local function askToGive(drop, player)
  Popups:Confirm(drop, player)
end

local function rowFor(row, winner, canGive, drop)
  local value = "|cffffffff" .. row.total .. "|r"
  if row.bonus > 0 then value = value .. string.format(" |cff6e6552(%d+%d)|r", row.v, row.bonus) end
  local actions
  if winner and canGive then
    actions = { { text = LM:OnlyRecords(drop) and "Record" or "Give", width = 62, run = function() askToGive(drop, row.p) end } }
  end
  return { title = (winner and "|cffc3e05a>|r " or "") .. C.Who(row.p), right = value .. "   " .. kindTag(row.kind), actions = actions }
end

local function buttonsFor(drop, master, winners, tied, waiting, reservers)
  local out = {}
  if not master then return out end
  local state = drop.state
  if not state then
    local only = #reservers == 1 and reservers[1].p
    if only then
      out[#out + 1] = { text = (LM:OnlyRecords(drop) and "Record for " or "Give to ") .. only, run = function() askToGive(drop, only) end }
    else
      out[#out + 1] = { text = "Roll", run = function() LM:Start(drop) end }
      if #reservers > 1 then out[#out + 1] = { text = "Everyone may roll", run = function() LM:Start(drop, true) end } end
    end
    out[#out + 1] = { text = "Raid roll", run = function() LM:RaidRoll(drop) end }
    out[#out + 1] = { text = "Give to...", run = function() Popups:Pick(drop) end }
    if LM.rollsSecret and drop.slots and drop.slots[1] then
      out[#out + 1] = { text = "The game's roll", run = function() LM:RequestRoll(drop) end }
    end
  elseif state == "rolling" then
    out[#out + 1] = { text = "Finish early", run = function() LM:Finish(drop, true) end }
    out[#out + 1] = { text = "Cancel", run = function() LM:Cancel(drop) end }
    if LM.rollsSecret and drop.slots and drop.slots[1] then
      out[#out + 1] = { text = "The game's roll", run = function() LM:RequestRoll(drop) end }
    end
  elseif state == "raid" then
    out[#out + 1] = { text = "Cancel", run = function() LM:Cancel(drop) end }
  elseif state == "done" then
    if tied then
      out[#out + 1] = { text = "Re-roll them", run = function() LM:Reroll(drop, tied) end }
    elseif not (winners and winners[1]) then
      out[#out + 1] = { text = "Roll again", run = function() LM:Start(drop, drop.everyone) end }
    end
    out[#out + 1] = { text = "Raid roll", run = function() LM:RaidRoll(drop) end }
    out[#out + 1] = { text = "Give to...", run = function() Popups:Pick(drop) end }
    out[#out + 1] = { text = "Close", run = function() roll:Hide() end }
  end
  return out
end

local function midText(drop, master, rows, winners, tied, waiting, reservers)
  local state = drop.state
  if state == "rolling" then
    if LM.rollsSecret then return "|cffe7b04fThe game is hiding /roll from add-ons right now.|r" end
    if drop.only then
      local names = {}
      for name in pairs(drop.only) do names[#names + 1] = name end
      table.sort(names)
      return "|cffe7c66cThere was a tie. Only " .. table.concat(names, " and ") .. " count now.|r"
    end
    local left = LM.SecondsLeft(drop)
    if left > 0 then return string.format("Rolling ends in |cffffffff%d|r seconds", left) end
    return "Waiting for the rest"
  elseif state == "raid" then
    return "Waiting for the raid roll"
  elseif state == "done" then
    if tied then return "|cffe7c66cTie: " .. table.concat(tied, " and ") .. "|r" end
    if not (winners and winners[1]) then return "Nobody rolled." end
    return nil
  elseif #reservers == 1 then
    return "Only one reserve, so no roll is needed."
  elseif not master then
    return C.Who(LM:MasterName() or "The loot master") .. " is looking at this."
  end
  return nil
end

local function fillRoll()
  if not roll or not roll:IsShown() then return end
  local drop = currentDrop()
  if not drop or LM.Remaining(drop) <= 0 then
    roll:Hide()
    return
  end
  local master = LM:IsMaster()
  local rec = C:RecordForGroup()
  local state, reserves = rec:State(), rec:State().reserves
  local reserved = Ladder.IsReserved(reserves, state, drop.id, drop.everyone or drop.raided)
  local reservers = reserved and Ladder.Reservers(reserves, state, drop.id) or {}
  local left = LM.Remaining(drop)

  roll.icon:SetTexture(C.In("C_Item", "GetItemIconByID", drop.id) or 134400)
  roll.item:SetText((left > 1 and (left .. "x ") or "") .. C.ItemText(drop.id, drop.link))
  if reserved then
    roll.note:SetText(#reservers == 1 and "Reserved by one player" or "Reserved: only these can win")
  elseif left > 1 then
    roll.note:SetText(string.format("Top %d rolls win. /roll, /roll 99 (off spec), /roll 98 (transmog)", left))
  else
    roll.note:SetText("/roll for main spec, /roll 99 for off spec, /roll 98 for transmog")
  end
  centreHeading()

  local rows, winners, tied, waiting = LM:Rank(drop)
  local items = {}
  if not drop.state then
    for _, r in ipairs(reservers) do
      items[#items + 1] = { title = C.Who(r.p), right = (r.plus > 0 and string.format("|cffc3e05aSR+%d, +%d|r   ", r.plus, r.bonus) or "") .. kindTag("sr") }
    end
  else
    local isWinner = {}
    if drop.state == "done" and winners then
      for _, w in ipairs(winners) do isWinner[w.p] = true end
    end
    for _, row in ipairs(rows) do items[#items + 1] = rowFor(row, isWinner[row.p], master, drop) end
    if drop.state == "rolling" then
      for _, r in ipairs(waiting) do
        items[#items + 1] = { title = C.Who(r.p), right = (r.bonus > 0 and string.format("|cffc3e05a+%d|r  ", r.bonus) or "") .. "|cff6e6552...|r   " .. kindTag(reserved and "sr" or "ms") }
      end
      for name, value in pairs(drop.ignored or {}) do
        items[#items + 1] = { title = "|cff6e6552" .. name .. "|r", right = "|cff6e6552" .. value .. ", doesn't count|r" }
      end
    end
  end
  roll.rows:SetData(items, true)

  local text = midText(drop, master, rows, winners, tied, waiting, reservers)
  roll.mid:SetText(text or "")
  local rolling = drop.state == "rolling" and drop.endsAt ~= nil
  roll.bar:SetShown(rolling)
  if rolling then
    roll.bar:SetWidth(math.max(1, (ROLL_W - 28) * LM.SecondsLeft(drop) / math.max(1, C.db.rollSeconds)))
  end
  local bottom = master and ROLL_BAR or NO_BAR
  local mine = {}
  for i, choice in ipairs(LM:MyRolls(drop)) do
    mine[i] = { text = choice.text, run = function()
      LM:RollFor(drop, choice.max)
      Popups:Refresh()
    end }
  end
  local above = layoutRoll(bottom, #mine > 0)
  setButtons(roll.buttons, buttonsFor(drop, master, winners, tied, waiting, reservers), 8)
  setButtons(roll.picks, mine, bottom + ROLL_MID)
  roll:SetHeight(HEADER_H + ROLL_TOP + 8 + math.min(math.max(#items, 1), ROLL_MAX_ROWS) * ROLL_ROW + above)
end

---Opens the roll popup on a drop.
function Popups:Roll(drop)
  if not roll then buildRoll() end
  self.selected = drop.key
  roll:Show()
  fillRoll()
  fillList()
end

---Someone else started a roll: show it, unless the player has turned that off or closed it.
function Popups:Watch(key)
  if not C.db.watchRolls or LM:IsMaster() then return end
  local drop = LM:Find(key)
  if not drop or drop.state ~= "rolling" then return end
  local tag = key .. (drop.only and "|tie" or "")   -- a tie is a new roll, so a popup closed earlier comes back for it
  if self.watched == tag then return end
  self.watched = tag
  self:Roll(drop)
end

-------------------------------------------------------------------------------------------
-- Who to give it to, by class, and the confirmation
-------------------------------------------------------------------------------------------

local function buildPick()
  pick = UI.Window({ name = "CouncilPick", addon = "council", title = "Give to", width = PICK_W, height = PICK_H })
  pick:SetAccent("council")
  pick:Hide()
  if pick.powered then pick.powered:Hide() end
  pick.rows = Window.RowList(pick.body, PICK_ROW)
  pick.rows:SetPoint("TOPLEFT", 6, -4)
  pick.rows:SetPoint("BOTTOMRIGHT", -6, 6)
  place(pick, 830, -170)
end

---Opens the list of players the game will let this go to, sorted by class.
function Popups:Pick(drop)
  if not pick then buildPick() end
  local byClass, classes = {}, {}
  for _, name in ipairs(LM:Candidates(drop)) do
    local class = C.Roster:ClassOf(name) or "?"
    if not byClass[class] then
      byClass[class] = {}
      classes[#classes + 1] = class
    end
    table.insert(byClass[class], name)
  end
  table.sort(classes)
  local items = {}
  local labels = rawget(_G, "LOCALIZED_CLASS_NAMES_MALE") or {}
  for _, class in ipairs(classes) do
    items[#items + 1] = { group = labels[class] or (class:sub(1, 1) .. class:sub(2):lower()) }
    table.sort(byClass[class])
    for _, name in ipairs(byClass[class]) do
      items[#items + 1] = { title = C.Who(name), onClick = function() Popups:Confirm(drop, name) end }
    end
  end
  pick.rows:SetData(items)
  pick:SetSub(C.ItemName(drop.id, drop.link))
  pick:Show()
end

local function buildConfirm()
  confirm = UI.Window({ name = "CouncilConfirm", addon = "council", title = "Council", width = CONFIRM_W, height = CONFIRM_H, strata = "DIALOG" })
  confirm:SetAccent("council")
  confirm:Hide()
  if confirm.powered then confirm.powered:Hide() end
  confirm.text = UI.Text(confirm.body, "body", 14)
  confirm.text:SetPoint("TOPLEFT", 14, -12)
  confirm.text:SetPoint("TOPRIGHT", -14, -12)
  confirm.text:SetJustifyH("CENTER")
  confirm.text:SetWordWrap(true)
  confirm.yes = UI.Button(confirm.body, "Yes", "primary", function()
    local drop, player = confirm.drop, confirm.player
    confirm:Hide()
    if not (drop and player) then return end
    local ok, why = LM:Give(drop, player)
    if not ok then C:Print(why) end
    if pick then pick:Hide() end
    Popups:Refresh()
  end)
  confirm.yes:SetSize(90, 24)
  confirm.yes:SetPoint("BOTTOMRIGHT", confirm.body, "BOTTOM", -4, 12)
  confirm.no = UI.Button(confirm.body, "No", "quiet", function() confirm:Hide() end)
  confirm.no:SetSize(90, 24)
  confirm.no:SetPoint("BOTTOMLEFT", confirm.body, "BOTTOM", 4, 12)
end

---The last check before something that can't be undone. It also says what's in the way, if something is.
function Popups:Confirm(drop, player)
  local problem = LM:GiveProblem(drop, player)
  if problem then
    C:Print(problem)
    return
  end
  if not confirm then buildConfirm() end
  confirm.drop, confirm.player = drop, player
  confirm.text:SetText(string.format(LM:OnlyRecords(drop) and "Record %s as going to %s?" or "Give %s to %s?", C.ItemText(drop.id, drop.link), C.Who(player)))
  confirm:Show()
end

function Popups:Refresh()
  fillList()
  fillRoll()
end

-------------------------------------------------------------------------------------------
-- Targeting a boss: a small question about master loot. SetLootMethod is flagged as restricted, so a person clicks Yes:
-- nothing here changes the loot rules by itself. A raid always gets asked; a party only when a reserve list is loaded, or every
-- dungeon boss would ask for no reason.
-------------------------------------------------------------------------------------------

local SWITCH_W, SWITCH_H = 340, 130
local SWITCH_CHECK = 2

local swap
local asked = {}
local bossIds

-- Every boss NorgannonDB knows, built once, the first time it's needed.
local function knownBoss(npcId)
  if not bossIds then
    bossIds = {}
    for _, key in ipairs(Core.DB:InstanceKeys()) do
      local record = Core.DB:Instance(key)
      for _, boss in ipairs(record and record.bosses or {}) do
        if boss.id then bossIds[boss.id] = true end
      end
    end
  end
  return bossIds[npcId] == true
end

---The target's NPC id if it's a boss, or nil. A secret answer counts as no.
local function targetBoss()
  local guid = C.Global("UnitGUID", "target")
  local npcId = type(guid) == "string" and tonumber(guid:match("^Creature%-%d+%-%d+%-%d+%-%d+%-(%d+)"))
  if not npcId or C.Global("UnitIsDead", "target") then return nil end
  if C.Global("UnitClassification", "target") == "worldboss" or knownBoss(npcId) then return npcId end
end

local function worthAsking()
  if not C.db or not C.db.askMasterLoot then return false end
  if not C.Global("IsInGroup") or not C.Global("UnitIsGroupLeader", "player") then return false end
  if C.Global("InCombatLockdown") or LM:IsMasterLoot() then return false end
  if C.Global("IsInRaid") then return true end
  return C:RecordForGroup():State().reserves ~= nil
end

local function buildSwap()
  swap = UI.Window({ name = "CouncilSwitchLoot", addon = "council", title = "Master loot", width = SWITCH_W, height = SWITCH_H })
  swap:SetAccent("council")
  swap:Hide()
  if swap.powered then swap.powered:Hide() end
  swap.text = UI.Text(swap.body, "body", 14)
  swap.text:SetPoint("TOPLEFT", 12, -8)
  swap.text:SetPoint("TOPRIGHT", -12, -8)
  swap.text:SetJustifyH("CENTER")
  swap.text:SetWordWrap(true)
  swap.yes = UI.Button(swap.body, "Switch", "primary", function()
    swap:Hide()
    if swap.onYes then swap.onYes() end
  end)
  swap.yes:SetSize(90, 24)
  swap.yes:SetPoint("BOTTOMRIGHT", swap.body, "BOTTOM", -4, 10)
  swap.no = UI.Button(swap.body, "Not now", "quiet", function() swap:Hide() end)
  swap.no:SetSize(90, 24)
  swap.no:SetPoint("BOTTOMLEFT", swap.body, "BOTTOM", 4, 10)
  place(swap, 560, -90)
end

local function ask(text, onYes)
  if not swap then buildSwap() end
  swap.text:SetText(text)
  swap.onYes = onYes
  swap:Show()
end

---The click: makes you the master looter, remembers what it was, and says if the game didn't take it.
function Popups:SwitchToMaster()
  local enum = rawget(_G, "Enum") and Enum.LootMethod
  local me = C.Me()
  if not (enum and me) then return end
  local before = C.In("C_PartyInfo", "GetLootMethod")
  C.In("C_PartyInfo", "SetLootMethod", enum.Masterlooter, me)
  C.db.lootBefore = { method = before, at = C.Clock(), asked = false }
  C.Later(SWITCH_CHECK, function()
    if not LM:IsMasterLoot() then
      C.db.lootBefore = nil
      C:Print("The game didn't switch to master loot. You can change it from your portrait's menu.")
    end
  end)
end

local METHOD_NAMES = { Freeforall = "free for all", Roundrobin = "round robin", Group = "group loot", Needbeforegreed = "need before greed", Personal = "personal loot" }

local function methodName(method)
  for name, value in pairs(rawget(_G, "Enum") and Enum.LootMethod or {}) do
    if value == method then return METHOD_NAMES[name] or name end
  end
  return "the old loot method"
end

---The click: back to what it was before Council switched it.
function Popups:SwitchBack()
  local before = C.db.lootBefore
  C.db.lootBefore = nil
  if not before then return end
  C.In("C_PartyInfo", "SetLootMethod", before.method)
  C.Later(SWITCH_CHECK, function()
    if LM:IsMasterLoot() then C:Print("The game didn't switch back. You can change it from your portrait's menu.") end
  end)
end

---Once Council has switched to master loot, a boss has died since, and nothing's left to hand out, it offers to switch back. Once.
function Popups:CheckSwitchBack()
  local before = C.db and C.db.lootBefore
  if not before or before.asked or not LM:IsMasterLoot() or not LM:IsMaster() then return false end
  if not C.Global("UnitIsGroupLeader", "player") or C.Global("InCombatLockdown") then return false end
  if LM:Left() > 0 or C.Capture.bossAt <= before.at then return false end
  before.asked = true
  ask(string.format("Everything's handed out. Switch back to %s?", methodName(before.method)), function() Popups:SwitchBack() end)
  return true
end

---Asks about this target, if there's reason to and it hasn't asked about this boss here already.
function Popups:CheckTarget()
  if not worthAsking() then return false end
  local npcId = targetBoss()
  if not npcId or asked[npcId] then return false end
  asked[npcId] = true
  ask(string.format("%s: switch to master loot, with you as looter?", C.Global("UnitName", "target") or "This boss"), function() Popups:SwitchToMaster() end)
  return true
end

Core:On("PLAYER_TARGET_CHANGED", "council.popups", function() Popups:CheckTarget() end)
-- answering "not now" holds until the next instance; the question also goes if the method changes some other way, or a fight starts
Core:On("PLAYER_ENTERING_WORLD", "council.popups", function() asked = {} end)
Core:On("PARTY_LOOT_METHOD_CHANGED", "council.popups", function()
  if LM:IsMasterLoot() then
    if swap and not (C.db.lootBefore and C.db.lootBefore.asked) then swap:Hide() end
  else
    -- it's off master loot, whoever did that, so there's nothing to go back from
    C.db.lootBefore = nil
    if swap then swap:Hide() end
  end
end)
Core:On("LOOT_CLOSED", "council.popups", function() Popups:CheckSwitchBack() end)
Core:On("GROUP_LEFT", "council.popups", function()
  if C.db then C.db.lootBefore = nil end
end)
Core:On("PLAYER_REGEN_DISABLED", "council.popups", function()
  if swap then swap:Hide() end
end)
