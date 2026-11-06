-- Tonight: what's dropped in the current session and where it went, read-only. Running the loot happens in the popups (popups.lua);
-- this is for looking back an hour without going through History.

local Core = NorgannonCore
local C = Council
if C.disabled then return end
local UI = Core.UI
local Window, LM = C.Window, C.LootMaster

local TRASH = "Trash"

local function build(f)
  f.lead = Window.Line(f)
  f.lead:SetPoint("TOPLEFT")
  f.lead:SetPoint("TOPRIGHT", -150, 0)
  f.open = UI.Button(f, "Show the loot list", "quiet", function() C.Popups:ShowList() end)
  f.open:SetSize(140, 24)
  f.open:SetPoint("TOPRIGHT")
  f.pane = UI.Pane(f)
  f.pane:SetPoint("TOPLEFT", f.lead, "BOTTOMLEFT", 0, -10)
  f.pane:SetPoint("BOTTOMRIGHT")
  f.list = Window.RowList(f.pane)
  f.list:SetPoint("TOPLEFT", 2, -2)
  f.list:SetPoint("BOTTOMRIGHT", -2, 2)
end

local function fill(f)
  local rec = C:ShownRecord()
  local state = rec:State()
  local s = state.sessions[#state.sessions]
  if not s then
    f.lead:SetText("No raid or dungeon on record yet.")
    f.list:SetData({})
    return
  end
  local master = LM:IsMaster() and "You're running the loot." or (C.Global("IsInGroup") and (C.Who(LM:MasterName() or "?") .. " is running the loot.") or "")
  f.lead:SetText(string.format("%s, %s. %d here, %d %s killed. %s", s.name, Window.Stamp(s.start), (function()
    local n = 0
    for _ in pairs(s.people) do n = n + 1 end
    return n
  end)(), #s.kills, #s.kills == 1 and "boss" or "bosses", master))

  local groups, order = {}, {}
  for i = #s.lines, 1, -1 do
    local line = s.lines[i]
    local key = line.boss or TRASH
    if not groups[key] then
      groups[key] = {}
      order[#order + 1] = key
    end
    table.insert(groups[key], line)
  end
  local items = {}
  for _, key in ipairs(order) do
    items[#items + 1] = { group = key }
    for _, line in ipairs(groups[key]) do
      items[#items + 1] = { id = line.item, link = line.link, title = C.ItemText(line.item, line.link) .. "  " .. C.Who(line.player), sub = line.why or (line.groupRoll and string.format("Group loot, rolled %d", line.groupRoll)) or "Seen in the loot messages",
        right = line.seen > 0 and string.format("|cff8fe08f%d saw it|r", line.seen) or "" }
    end
  end
  if #items == 0 then items[1] = { title = "|cff6e6552Nothing has dropped yet.|r" } end
  f.list:SetData(items, true)
end

Window:AddPane("tonight", { build = build, fill = fill })
