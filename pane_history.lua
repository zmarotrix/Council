-- History: who got what, by raid, by boss or by player. Every line says how many clients saw it, so a line nobody saw
-- shows up as one. Corrections never erase: the line says what it was.

local Core = NorgannonCore
local C = Council
if C.disabled then return end
local UI = Core.UI
local Colors = UI.C
local Window = C.Window

local VIEWS = { { key = "raid", label = "By raid" }, { key = "boss", label = "By boss" }, { key = "player", label = "By player" } }
local TRASH = "Trash"

local function witnessText(line)
  if line.void then return "|cffff9478voided|r" end
  if line.fixes then return string.format("|cffe7b04fcorrected, %d saw|r", line.seen) end
  if line.official == false then
    return line.officialWhy == "unverified" and "|cffe7b04funverified|r" or "|cffe7b04fnot from an officer|r"
  end
  if line.seen == 0 then return "|cffff9478no witnesses|r" end
  return string.format("|cff8fe08f%d saw it|r", line.seen)
end

local function reason(line)
  if line.fixes then
    local fix = line.fixes[#line.fixes]
    local text = line.void and "Voided" or ("Was " .. tostring(fix.was))
    return string.format("%s by %s%s", text, fix.by, fix.why and (": " .. fix.why) or "")
  end
  if line.why then return line.why end
  if line.groupRoll then return string.format("Group loot, rolled %d", line.groupRoll) end
  return "Seen in the loot messages"
end

local correct

StaticPopupDialogs["COUNCIL_CORRECT"] = {
  text = "Correct %s.\nType who it went to, or leave it empty to void the line. Anything after a comma is the reason.",
  button1 = OKAY or "OK", button2 = CANCEL or "Cancel", hasEditBox = true, timeout = 0, whileDead = true, hideOnEscape = true,
  OnAccept = function(self, data)
    local box = self.editBox or self.EditBox
    correct(data, box and box:GetText() or "")
  end,
}

correct = function(line, text)
  local rec = C:ShownRecord()
  local who, why = (text or ""):match("^%s*([^,]*),?%s*(.-)%s*$")
  who = who ~= nil and who:match("^(.-)%s*$") or ""
  local data = { s = line.session.id, key = line.key, why = why ~= "" and why or nil }
  if who == "" then data.void = true else data.to = who end
  rec:Append("fix", data)
  Window:Refresh()
end

local function lineRow(line, view, can)
  local sub
  if view == "player" then
    sub = string.format("%s, %s, %s", line.session.name, line.boss or TRASH, Window.Day(line.at))
  elseif view == "boss" then
    sub = string.format("%s, %s", line.session.name, Window.Day(line.at))
  else
    sub = line.boss or TRASH
  end
  local text = C.Who(line.player)
  return {
    id = line.item, link = line.link,
    title = C.ItemText(line.item, line.link) .. "  " .. text,
    sub = sub .. "  ·  " .. reason(line),
    right = witnessText(line),
    actions = can and { { text = "Correct", width = 62, tip = "Nothing is erased. A correction is a new entry, and the line shows both.", run = function()
      StaticPopup_Show("COUNCIL_CORRECT", C.ItemName(line.item, line.link), nil, line)
    end } } or nil,
  }
end

local function build(f)
  f.views = UI.Segmented(f, VIEWS, function(key)
    C.db.historyView = key
    f.player = nil
    Window:Refresh()
  end, 24)
  f.views:SetPoint("TOPLEFT")
  f.search = UI.Search(f, "Filter by player, item or boss", function() Window:Refresh() end)
  f.search:SetPoint("LEFT", f.views, "RIGHT", 12, 0)
  f.search:SetPoint("RIGHT", f, "RIGHT", -86, 0)
  f.search:SetHeight(24)
  f.export = UI.Button(f, "Export", "quiet", function() C.Records:ExportLoot() end)
  f.export:SetSize(76, 24)
  f.export:SetPoint("TOPRIGHT")
  f.pane = UI.Pane(f)
  f.pane:SetPoint("TOPLEFT", f.views, "BOTTOMLEFT", 0, -8)
  f.pane:SetPoint("BOTTOMRIGHT")
  f.list = Window.RowList(f.pane)
  f.list:SetPoint("TOPLEFT", 2, -2)
  f.list:SetPoint("BOTTOMRIGHT", -2, 2)
end

local function matches(line, filter)
  if not filter or filter == "" then return true end
  local hay = string.lower(line.player .. " " .. C.ItemName(line.item, line.link) .. " " .. (line.boss or TRASH) .. " " .. line.session.name)
  return string.find(hay, filter, 1, true) ~= nil
end

local function fill(f)
  local view = C.db.historyView or "raid"
  f.views:Select(view, true)
  local rec = C:ShownRecord()
  local state = rec:State()
  local can = rec:CanDecide()
  local filter = string.lower(f.search:GetText() or "")

  local lines = {}
  for _, line in ipairs(state.lines) do
    if matches(line, filter) then lines[#lines + 1] = line end
  end
  table.sort(lines, function(a, b)
    if a.at ~= b.at then return a.at > b.at end
    return a.key > b.key
  end)

  local groups, order = {}, {}
  for _, line in ipairs(lines) do
    local key
    if view == "player" then
      key = line.player
    elseif view == "boss" then
      key = line.boss or TRASH
    else
      key = line.session.name .. ", " .. Window.Day(line.session.start)
    end
    if not groups[key] then
      groups[key] = {}
      order[#order + 1] = key
    end
    table.insert(groups[key], line)
  end
  if view ~= "raid" then table.sort(order) end

  local items = {}
  for _, key in ipairs(order) do
    items[#items + 1] = { group = string.format("%s  (%d)", key, #groups[key]) }
    for _, line in ipairs(groups[key]) do items[#items + 1] = lineRow(line, view, can) end
  end
  if #items == 0 then
    items[1] = { title = filter ~= "" and "|cff6e6552Nothing matches that.|r" or "|cff6e6552Nothing recorded yet. Every rare or better drop in a group lands here, in raids and dungeons, whoever has the add-on.|r" }
  end
  f.list:SetData(items, true)
end

Window:AddPane("history", { build = build, fill = fill })
