-- Loot night: the drops on the left, and on the right who's in line for the one selected and what happens next.
-- The ladder rows are always shown, so a raider can see why, not just who.

local Core = NorgannonCore
local C = Council
if C.disabled then return end
local UI = Core.UI
local Colors = UI.C
local Window, LM, Ladder = C.Window, C.LootMaster, C.Ladder

local LEFT_W = 270
local BAR_H = 26
local MAX_BUTTONS = 3

local function dropState(d, state, list)
  if d.winner then return "|cff8fe08f" .. d.winner .. "|r" end
  local reservers = #Ladder.Reservers(list, state, d.id)
  if d.state == "rolling" then return "|cffc3e05aRolling|r" end
  if reservers > 0 then return string.format("|cffc3e05a%d reserved|r", reservers) end
  return "open"
end

local function build(f)
  f.left = UI.Pane(f)
  f.left:SetPoint("TOPLEFT")
  f.left:SetPoint("BOTTOMLEFT")
  f.left:SetWidth(LEFT_W)
  f.drops = Window.RowList(f.left)
  f.drops:SetPoint("TOPLEFT", 2, -2)
  f.drops:SetPoint("BOTTOMRIGHT", -2, 2)

  f.title = UI.Text(f, "title", 16, Colors.gold)
  f.title:SetPoint("TOPLEFT", f.left, "TOPRIGHT", 12, -2)
  f.title:SetPoint("RIGHT", f, "RIGHT", 0, 0)
  f.title:SetJustifyH("LEFT")
  f.title:SetWordWrap(false)
  f.lead = Window.Line(f)
  f.lead:SetPoint("TOPLEFT", f.title, "BOTTOMLEFT", 0, -3)
  f.lead:SetPoint("RIGHT", f, "RIGHT", 0, 0)

  f.bar = CreateFrame("Frame", nil, f)
  f.bar:SetPoint("BOTTOMLEFT", f.left, "BOTTOMRIGHT", 12, 0)
  f.bar:SetPoint("BOTTOMRIGHT")
  f.bar:SetHeight(BAR_H)
  f.buttons = {}
  for i = 1, MAX_BUTTONS do
    local b = UI.Button(f.bar, "", i == 1 and "primary" or "quiet", function(self)
      if self.run then self.run() end
    end)
    b:SetHeight(BAR_H - 2)
    f.buttons[i] = b
  end

  f.ladder = UI.Pane(f)
  f.ladder:SetPoint("TOPLEFT", f.lead, "BOTTOMLEFT", 0, -8)
  f.ladder:SetPoint("BOTTOMRIGHT", f.bar, "TOPRIGHT", 0, 8)
  f.list = Window.RowList(f.ladder, 28)
  f.list:SetPoint("TOPLEFT", 2, -2)
  f.list:SetPoint("BOTTOMRIGHT", -2, 2)

  f.empty = Window.Line(f, 14)
  f.empty:SetPoint("TOPLEFT", f.left, "TOPRIGHT", 12, -2)
  f.empty:SetPoint("RIGHT", f, "RIGHT", 0, 0)
end

local function setButtons(f, specs)
  local previous
  for i, b in ipairs(f.buttons) do
    local spec = specs[i]
    b:SetShown(spec ~= nil)
    if spec then
      b.run = spec.run
      b:SetLabel(spec.text)
      b:SetWidth(spec.width or 150)
      b:ClearAllPoints()
      if previous then b:SetPoint("LEFT", previous, "RIGHT", 6, 0) else b:SetPoint("LEFT", f.bar, "LEFT", 0, 0) end
      previous = b
    end
  end
end

local function give(drop, player)
  local ok, why = LM:Give(drop, player)
  if not ok then C:Print(why) end
  Window:Refresh()
end

local function rowsFor(drop, state, list)
  local items = {}
  local rung = drop.rung or Ladder.StartRung(list, state, drop.id)
  local ranked, tied = LM:Rank(drop)
  for _, r in ipairs(Ladder.RUNGS) do
    local reservers = r.key == "sr" and Ladder.Reservers(list, state, drop.id) or nil
    if r.key == rung then
      items[#items + 1] = { group = r.title .. ": " .. r.note }
      for _, row in ipairs(ranked) do
        local bits = {}
        if row.plus > 0 then bits[#bits + 1] = string.format("SR+%d", row.plus) end
        if row.roll then bits[#bits + 1] = string.format("rolled %d", row.roll) end
        if row.bonus > 0 then bits[#bits + 1] = string.format("+%d", row.bonus) end
        items[#items + 1] = { title = C.Who(row.p), right = (row.total and ("|cffffd100" .. row.total .. "|r  ") or "") .. table.concat(bits, "  ") }
      end
      if #ranked == 0 then items[#items + 1] = { title = "|cff6e6552Waiting for rolls|r" } end
      for name, roll in pairs(drop.ignored or {}) do
        items[#items + 1] = { title = "|cff6e6552" .. name .. " rolled " .. roll .. ", and doesn't count here|r" }
      end
    elseif not (r.key == "sr" and #reservers == 0) then
      items[#items + 1] = { group = r.title }
    end
  end
  return items, ranked, tied, rung
end

local function fill(f)
  local rec = C:RecordForGroup()
  local state, list = rec:State(), rec:State().reserves
  local view = LM:View()
  local master = LM:IsMaster()
  local selected = LM:Selected()

  local items, lastBoss = {}, nil
  for _, d in ipairs(view) do
    if d.boss ~= lastBoss or #items == 0 then
      items[#items + 1] = { group = d.boss or "Other loot" }
      lastBoss = d.boss
    end
    items[#items + 1] = { id = d.id, link = d.link, title = C.ItemText(d.id, d.link), sub = dropState(d, state, list), onClick = function()
      LM.selected = d.key
      Window:Refresh()
    end }
  end
  f.drops:SetData(items, true)

  local showing = selected ~= nil
  f.title:SetShown(showing)
  f.lead:SetShown(showing)
  f.ladder:SetShown(showing)
  f.bar:SetShown(showing and master)
  f.empty:SetShown(not showing)
  if not showing then
    f.empty:SetText(master and "Open a corpse with loot worth rolling on, and it's listed here." or (C.Global("IsInGroup") and "When the loot master opens loot, you'll see it here. Everything they do shows up, read-only." or "Join a group. History is under History whether you're in one or not."))
    return
  end

  local rows, ranked, tied, rung = rowsFor(selected, state, list)
  f.list:SetData(rows, true)
  f.title:SetText(C.ItemText(selected.id, selected.link))

  local lead
  if selected.winner then
    lead = string.format("Given to %s. %s.", C.Who(selected.winner), selected.why or "")
  elseif LM.rollsSecret and selected.state == "rolling" then
    lead = "|cffe7b04fThe game is hiding /roll results from add-ons right now.|r Wait until it lifts, or use the game's own roll window."
  elseif C.SendBlocked() == "lockdown" then
    lead = "|cffe7b04fThe game has add-ons restricted right now, usually while a boss is engaged.|r Rolls can't be read yet."
  elseif not master then
    lead = string.format("%s is running the loot. This is what they see.", C.Who(LM:MasterName() or "The loot master"))
  elseif rung == "sr" then
    lead = "Reserved, so only these players can win it while one of them wants it."
  else
    lead = "Nobody reserved this, so it goes down the rules."
  end
  if not LM:IsMasterLoot() and master and not selected.winner then lead = lead .. " Group loot: the game hands it out, and this only records." end
  f.lead:SetText(lead)

  if not master then return end
  local buttons = {}
  if selected.winner then
    buttons[1] = { text = "Clear the list", width = 110, run = function() LM:Clear() Window:Refresh() end }
  elseif selected.state ~= "rolling" then
    local only = Ladder.OnlyReserver(list, state, selected.id)
    if only then
      buttons[1] = { text = "Give to " .. only, run = function() give(selected, only) end }
      buttons[2] = { text = "Roll anyway", width = 100, run = function() LM:Start(selected) Window:Refresh() end }
    else
      buttons[1] = { text = "Announce and start the roll", width = 200, run = function() LM:Start(selected) Window:Refresh() end }
    end
    buttons[#buttons + 1] = { text = "Skip to next rule", width = 130, run = function() LM:NextRung(selected) Window:Refresh() end }
  else
    local top = ranked[1]
    if tied then
      buttons[1] = { text = "Tie: re-roll " .. table.concat(tied, ", "), width = 240, run = function() LM:Reroll(selected, tied) Window:Refresh() end }
    elseif top and top.total then
      buttons[1] = { text = (LM:IsMasterLoot() and "Give to " or "Record for ") .. top.p, width = 180, run = function() give(selected, top.p) end }
    end
    if LM.rollsSecret and selected.slot then
      buttons[#buttons + 1] = { text = "The game's roll window", width = 170, run = function() LM:RequestRoll(selected) end }
    end
    buttons[#buttons + 1] = { text = "Next rule", width = 90, run = function() LM:NextRung(selected) Window:Refresh() end }
  end
  setButtons(f, buttons)
end

Window:AddPane("loot", { build = build, fill = fill })
