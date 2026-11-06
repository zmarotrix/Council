-- Players: attendance and items, for free from the record. Stage 3 grows this into the guild tools (docs/council-v1.md).

local Core = NorgannonCore
local C = Council
if C.disabled then return end
local UI = Core.UI
local Window = C.Window

local RECENT_RAIDS = 10
local RAID_SIZE = 10    -- sessions this big or bigger count as raids for attendance

---Players with attendance over the last raids and their item count: { name, came, raids, items }, raids most first.
function C.PlayerStats(state)
  local raids = {}
  for i = #state.sessions, 1, -1 do
    local s = state.sessions[i]
    if (s.size or 0) >= RAID_SIZE then
      raids[#raids + 1] = s
      if #raids >= RECENT_RAIDS then break end
    end
  end
  local stats = {}
  local function of(name)
    stats[name] = stats[name] or { name = name, came = 0, items = 0, plus = 0 }
    return stats[name]
  end
  for _, s in ipairs(raids) do
    for name in pairs(s.people) do
      local row = of(name)
      row.came = row.came + 1
    end
  end
  for _, line in ipairs(state.lines) do
    if not line.void then
      local row = of(line.player)
      row.items = row.items + 1
    end
  end
  for player, items in pairs(state.plus) do
    for _, steps in pairs(items) do of(player).plus = of(player).plus + steps end
  end
  local out = {}
  for _, row in pairs(stats) do out[#out + 1] = row end
  table.sort(out, function(a, b)
    if a.came ~= b.came then return a.came > b.came end
    if a.items ~= b.items then return a.items > b.items end
    return a.name < b.name
  end)
  return out, #raids
end

local function build(f)
  f.lead = Window.Line(f)
  f.lead:SetPoint("TOPLEFT")
  f.lead:SetPoint("TOPRIGHT")
  f.pane = UI.Pane(f)
  f.pane:SetPoint("TOPLEFT", f.lead, "BOTTOMLEFT", 0, -8)
  f.pane:SetPoint("BOTTOMRIGHT")
  f.list = Window.RowList(f.pane, 28)
  f.list:SetPoint("TOPLEFT", 2, -2)
  f.list:SetPoint("BOTTOMRIGHT", -2, 2)
end

local function fill(f)
  local rec = C:ShownRecord()
  local stats, raids = C.PlayerStats(rec:State())
  f.lead:SetText(string.format("Attendance over the last %d raids on record, and items across all of them. Alts, notes and the guild tools come in a later stage.", raids))
  local items = {}
  for _, row in ipairs(stats) do
    local rank = C.Roster:Rank(row.name)
    local tag = rank and "" or "  |cff6e6552not in the guild|r"
    items[#items + 1] = {
      title = C.Who(row.name) .. tag,
      right = string.format("%d of %d raids   %d items%s", row.came, raids, row.items, row.plus > 0 and string.format("   |cffc3e05aSR+%d|r", row.plus) or ""),
    }
  end
  if #items == 0 then items[1] = { title = "|cff6e6552Nobody on record yet.|r" } end
  f.list:SetData(items, true)
end

Window:AddPane("players", { build = build, fill = fill })
