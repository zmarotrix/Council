-- Reserves: importing a list, what's wrong with it before the pull, tonight's reserves with SR+, closing the raid, and
-- the guild's own SR+ rules. What only this suite can do is here: NorgannonDB knows what drops where, so a reserve that
-- can't drop in this instance is caught now and not at the boss.

local Core = NorgannonCore
local C = Council
if C.disabled then return end
local UI = Core.UI
local Colors = UI.C
local Window, Ladder, State = C.Window, C.Ladder, C.State

local TIE_LABEL = { reroll = "Re-roll", oldest = "Most SR+ wins" }

---Everything that drops in the instance we're in, or nil if the database doesn't know this place.
function C.DropsHere()
  local name = C.Global("GetInstanceInfo")
  if not name or not C.Global("IsInInstance") then return nil end
  for _, key in ipairs(Core.DB:InstanceKeys()) do
    if Core.DB:InstanceName(key) == name then
      local record = Core.DB:Instance(key)
      local set = {}
      for _, boss in ipairs(record and record.bosses or {}) do
        for _, item in ipairs(boss.loot or {}) do set[item] = true end
      end
      return next(set) and set or nil, name
    end
  end
end

local function findItem(name)
  local ids = Core.DB:IdsByName("items", name)
  return ids and ids[1]
end

local function importText(text)
  local rec = C:RecordForGroup()
  local parsed, why = Ladder.ParseReserves(text, findItem)
  if not parsed then
    Window:TextBoxNote("|cffff9478" .. why .. "|r")
    return
  end
  local rows = {}
  for _, row in ipairs(parsed.rows) do rows[#rows + 1] = row end
  rec:Append("sr", { key = tostring(C.Now()), rows = rows, src = "paste", usePlus = parsed.hasPlus or nil })
  local note = string.format("Read %d reserves.", #rows)
  if #parsed.problems > 0 then
    note = note .. string.format(" %d lines couldn't be read, first: %s", #parsed.problems, parsed.problems[1])
    C:Print(note)
  end
  C:Print(note)
  Window:TextBoxClose()
  Window:Refresh()
end

StaticPopupDialogs["COUNCIL_CLOSE_RAID"] = {
  text = "Close this raid? Everyone who came and reserved, and didn't win, gets a step of SR+. Those who missed it count a miss.",
  button1 = YES, button2 = NO, timeout = 0, whileDead = true, hideOnEscape = true,
  OnAccept = function(_, data)
    if data then data() end
    Window:Refresh()
  end,
}

local function closeRaid(rec)
  local list = rec:State().reserves
  if not list then return end
  local present, seen = {}, {}
  local function add(name)
    if not seen[name] then
      seen[name] = true
      present[#present + 1] = name
    end
  end
  for _, name in ipairs(C.GroupNames()) do add(name) end
  local s = rec:State().sessions[#rec:State().sessions]
  if s then
    for name in pairs(s.people) do add(name) end
  end
  table.sort(present)
  rec:Append("close", { key = list.key, present = present })
end

local function setRule(rec, key, value)
  rec:Append("rules", { set = { [key] = value } })
  Window:Refresh()
end

local function ruleRows(rec, can)
  local rules = rec:State().rules
  local items = { { group = "SR+ rules for this guild" } }
  local function step(key, label, sub, lo, hi, by, show)
    local value = rules[key]
    items[#items + 1] = { title = label, sub = sub, right = "|cffc3e05a" .. (show and show(value) or tostring(value)) .. "|r", actions = can and {
      { text = "+", width = 26, off = value >= hi, run = function() setRule(rec, key, math.min(hi, value + by)) end },
      { text = "-", width = 26, off = value <= lo, run = function() setRule(rec, key, math.max(lo, value - by)) end },
    } or nil }
  end
  local function flip(key, label, sub)
    items[#items + 1] = { title = label, sub = sub, right = rules[key] and "|cffc3e05aYes|r" or "No", actions = can and {
      { text = "Change", width = 64, run = function() setRule(rec, key, not rules[key]) end },
    } or nil }
  end
  step("bonus", "Bonus per step", "Added to the roll of someone holding SR+", 1, 100, 1, function(v) return "+" .. v end)
  step("cap", "Most steps", nil, 0, 20, 1, function(v) return v == 0 and "No cap" or tostring(v) end)
  flip("resetOnWin", "Winning the item resets it")
  flip("resetOnChange", "Changing your reserve resets it")
  step("missLimit", "Missed raids in a row before it resets", nil, 0, 10, 1, function(v) return v == 0 and "Never" or tostring(v) end)
  items[#items + 1] = { title = "Ties", right = "|cffc3e05a" .. (TIE_LABEL[rules.tie] or rules.tie) .. "|r", actions = can and {
    { text = "Change", width = 64, run = function() setRule(rec, "tie", rules.tie == "reroll" and "oldest" or "reroll") end },
  } or nil }
  return items
end

local function build(f)
  f.left = UI.Pane(f)
  f.left:SetPoint("TOPLEFT")
  f.left:SetPoint("BOTTOM")
  f.left:SetWidth(410)
  f.leftList = Window.RowList(f.left, 34)
  f.leftList:SetPoint("TOPLEFT", 2, -2)
  f.leftList:SetPoint("BOTTOMRIGHT", -2, 2)
  f.right = UI.Pane(f)
  f.right:SetPoint("TOPLEFT", f.left, "TOPRIGHT", 12, 0)
  f.right:SetPoint("BOTTOMRIGHT")
  f.rightList = Window.RowList(f.right, 32)
  f.rightList:SetPoint("TOPLEFT", 2, -2)
  f.rightList:SetPoint("BOTTOMRIGHT", -2, 2)
end

local function fill(f)
  local rec = C:ShownRecord()
  local state = rec:State()
  local list = state.reserves
  local can = rec:CanDecide()

  local left = {}
  local raiders = C.GroupNames()
  local drops, placeName = C.DropsHere()
  local check = Ladder.Check(list, #raiders > 0 and raiders or nil, drops)
  left[#left + 1] = { group = "Before the pull" }
  if can then
    left[#left + 1] = { title = list and "A list is loaded" or "No list loaded", sub = list and string.format("%d reserves, from %s", #list.rows, Window.Stamp(list.at)) or "Paste an export from your reserve site", actions = {
      { text = "Import", width = 64, run = function()
        Window:TextBox("Import reserves", "Paste a reserve list with a first line of column names. Council looks for a player column and an item or item ID column, and SR+ if there is one.", "", importText)
      end },
      list and { text = "Close raid", width = 80, tip = "SR+ moves here, once, at the end of the night", run = function()
        StaticPopup_Show("COUNCIL_CLOSE_RAID", nil, nil, function() closeRaid(rec) end)
      end } or nil,
    } }
  elseif not list then
    left[#left + 1] = { title = "No list loaded", sub = "An officer imports it" }
  end
  if list then
    for _, row in ipairs(check.absent) do
      left[#left + 1] = { id = row.i, title = "|cffff9478" .. row.p .. " isn't here|r", sub = "Reserved " .. C.ItemName(row.i, row.name) }
    end
    for _, row in ipairs(check.wrongPlace) do
      left[#left + 1] = { id = row.i, title = "|cffff9478" .. C.ItemName(row.i, row.name) .. " doesn't drop here|r", sub = string.format("%s reserved it. NorgannonDB has no boss in %s with it", row.p, tostring(placeName)) }
    end
    if #check.missing > 0 then
      left[#left + 1] = { title = "|cffe7b04f" .. #check.missing .. " haven't reserved anything|r", sub = table.concat(check.missing, ", "), actions = can and {
        { text = "Say so", width = 64, tip = "Says this in raid chat", run = function()
          C.LootMaster:Say("Not reserved yet: " .. table.concat(check.missing, ", "))
        end },
      } or nil }
    end
    if #check.absent + #check.wrongPlace + #check.missing == 0 then
      left[#left + 1] = { title = "|cff8fe08fNothing wrong|r", sub = #raiders == 0 and "Join the group to check who's missing" or nil }
    end
  end
  for _, item in ipairs(ruleRows(rec, can)) do left[#left + 1] = item end
  f.leftList:SetData(left, true)

  local right = {}
  if list then
    right[#right + 1] = { group = string.format("Tonight's reserves: %d", #list.rows) }
    local rows = {}
    for _, row in ipairs(list.rows) do rows[#rows + 1] = row end
    table.sort(rows, function(a, b)
      local an, bn = C.ItemName(a.i, a.name), C.ItemName(b.i, b.name)
      if an ~= bn then return an < bn end
      return State.Plus(state, a.p, a.i) > State.Plus(state, b.p, b.i)
    end)
    for _, row in ipairs(rows) do
      local plus = State.Plus(state, row.p, row.i)
      right[#right + 1] = { id = row.i, title = C.ItemText(row.i, row.name and ("[" .. row.name .. "]")), sub = C.Who(row.p), right = plus > 0 and string.format("|cffc3e05aSR+%d, +%d|r", plus, plus * state.rules.bonus) or "" }
    end
  else
    right[#right + 1] = { group = "SR+ held" }
    local any = false
    for player, items in pairs(state.plus) do
      for item, steps in pairs(items) do
        any = true
        right[#right + 1] = { id = item, title = C.ItemText(item), sub = C.Who(player), right = string.format("|cffc3e05aSR+%d, +%d|r", steps, steps * state.rules.bonus) }
      end
    end
    if not any then right[#right + 1] = { title = "|cff6e6552Nobody holds any yet|r" } end
  end
  f.rightList:SetData(right, true)
end

Window:AddPane("reserves", { build = build, fill = fill })
