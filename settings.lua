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

  list:Header("How it starts")
  list:Toggle("Show the minimap button", "Council is also in the game's addon menu and opens with /council.",
    function() return Core.MinimapButton:IsShown("council") end,
    function(on) Core.MinimapButton:SetShown("council", on) end)

  page:SetScript("OnShow", function() list:Refresh() end)
  C.settingsPage, C.settingsList = page, list
  C.settingsCategory = Core:AddSettingsPage(page, "Council")

  local function perf(label, tbl, method) Core:RegisterPerf("Council: " .. label, tbl, method, "council") end
  perf("replay", C.State, "Build")
  perf("window refresh", C.Window, "Refresh")
  perf("loot line", C.Capture, "OnLootText")
end)

function C:OpenSettings()
  if self.settingsCategory and Settings and Settings.OpenToCategory then
    Settings.OpenToCategory(self.settingsCategory:GetID())
  else
    Core:OpenSettings()
  end
end
