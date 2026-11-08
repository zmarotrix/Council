-- Council's settings page, under NorgannonDB in the game's Settings window (/council settings). The guild's loot rules
-- live in the window, because they're shared; this holds this client's choices, and the guild master's say on who
-- counts as an officer.

local Core = NorgannonCore
local C = Council
if C.disabled then return end
local UI = Core.UI

Core:OnLogin(function()
  if not C.db then return end
  local page = CreateFrame("Frame")
  page:Hide()
  local list = UI.SettingsList(page)

  list:Header("Loot night")
  list:Toggle("Open the window when loot is ready", "When you're the loot master and open a corpse with something worth rolling on.",
    function() return C.db.autoOpen end, function(on) C.db.autoOpen = on end)
  list:Toggle("Announce in group chat", "Starting a roll, re-rolls and who got what. Each is a button you press: Council never speaks by itself.",
    function() return C.db.announce end, function(on) C.db.announce = on end)

  list:Toggle("Ask about master loot when you target a boss", "When you lead a raid, or a party with a reserve list loaded, and it's not on already. It only asks: you click to switch.",
    function() return C.db.askMasterLoot end, function(on) C.db.askMasterLoot = on end)
  list:Toggle("Show someone else's rolls", "The roll popup, with buttons to pick a roll, when another player is running the loot.",
    function() return C.db.watchRolls end, function(on) C.db.watchRolls = on end)
  list:Slider("Seconds to roll", nil, 5, 60, 1, function() return C.db.rollSeconds end, function(v) C.db.rollSeconds = v end, "%.0f", 1)

  list:Header("Who counts as an officer")
  list:Slider("Ranks that count", "Set by the guild master, for everyone. 1 means the rank below guild master. Left alone, Council goes by who can edit officer notes.", 0, 9, 1,
    function()
      local rec = C.guildRecord
      local state = rec and rec:State()
      return state and state.maxOfficerRank or 1
    end,
    function(v)
      local rec = C:GuildRecord()
      if rec and C.Roster:Rank(C.Me()) == 0 then
        rec:Append("council", { maxRank = v })
      else
        C:Print("Only the guild master can change this.")
      end
    end, "%.0f", 1)


  page:SetScript("OnShow", function() list:Refresh() end)
  C.settingsPage, C.settingsList = page, list
  C:AddSettingsPage(page)

  local function perf(label, tbl, method) Core:RegisterPerf("Council: " .. label, tbl, method, "council") end
  perf("replay", C.State, "Build")
  perf("window refresh", C.Window, "Refresh")
  perf("loot line", C.Capture, "OnLootText")
end)
