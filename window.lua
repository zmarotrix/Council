-- Council's window (design/suite/council.html): tabs, the row list every pane shares, a box for pasting and copying
-- long text, and the footer that says whether the record is in step. Each pane is in its own file.

local Core = NorgannonCore
local C = Council
if C.disabled then return end
local UI = Core.UI
local Colors = UI.C

local Window = { panes = {} }
C.Window = Window

local W, H = 880, 600


local TABS = {
  { key = "tonight", label = "Tonight" }, { key = "reserves", label = "Reserves" }, { key = "history", label = "History" },
  { key = "players", label = "Players" }, { key = "records", label = "Records" },
}

local win

---The row list every pane shares (Core's UI.ActionList): { group } or { id, link, title, sub, right, onClick,
---actions = { { text, run, off, tip, width } } }. A row with an item shows its icon and, hovered, its tooltip.
function Window.RowList(parent, rowHeight)
  return UI.ActionList(parent, { rowHeight = rowHeight or 36 })
end

---A line of plain text across the top of something, anchored by the caller.
function Window.Line(parent, size, color)
  local text = UI.Text(parent, "body", size or 13, color or Colors.muted)
  text:SetJustifyH("LEFT")
  text:SetWordWrap(true)
  return text
end

---Time as "6 Nov" and "6 Nov 21:14".
function Window.Day(t) return date("%d %b", t):gsub("^0", "") .. "" end
function Window.Stamp(t) return date("%d %b %H:%M", t):gsub("^0", "") .. "" end

-------------------------------------------------------------------------------------------
-- Pasting and copying long text
-------------------------------------------------------------------------------------------

local box

---Opens the box. onAccept(text) makes it a paste; without it, it's a copy, with the text selected ready.
function Window:TextBox(title, lead, text, onAccept)
  if not box then
    box = UI.Window({ name = "CouncilTextBox", addon = "council", title = "Council", width = 640, height = 420, strata = "DIALOG" })
    box:SetAccent("council")
    box:Hide()
    box.lead = Window.Line(box.body)
    box.lead:SetPoint("TOPLEFT", 14, -10)
    box.lead:SetPoint("TOPRIGHT", -14, -10)
    box.pane = UI.Pane(box.body)
    box.pane:SetPoint("TOPLEFT", box.lead, "BOTTOMLEFT", 0, -8)
    box.pane:SetPoint("BOTTOMRIGHT", -14, 44)
    box.scroll = UI.ScrollArea(box.pane)
    box.scroll:SetPoint("TOPLEFT", 4, -4)
    box.scroll:SetPoint("BOTTOMRIGHT", -4, 4)
    box.edit = CreateFrame("EditBox", nil, box.scroll.content)
    box.edit:SetMultiLine(true)
    box.edit:SetAutoFocus(false)
    box.edit:SetFontObject(UI.Font("body", 12))
    box.edit:SetWidth(590)
    box.edit:SetPoint("TOPLEFT")
    box.edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    box.ok = UI.Button(box.body, "Read it", "primary", function()
      if box.onAccept then
        local accept = box.onAccept
        accept(box.edit:GetText())
      end
    end)
    box.ok:SetSize(110, 24)
    box.ok:SetPoint("BOTTOMRIGHT", -14, 12)
    box.note = Window.Line(box.body)
    box.note:SetPoint("LEFT", box.body, "BOTTOMLEFT", 14, 24)
    box.note:SetPoint("RIGHT", box.ok, "LEFT", -10, 0)
  end
  box:SetSub(title)
  box.lead:SetText(lead or "")
  box.note:SetText("")
  box.onAccept = onAccept
  box.ok:SetShown(onAccept ~= nil)
  box.edit:SetText(text or "")
  box:Show()
  box.edit:SetFocus()
  if not onAccept then box.edit:HighlightText() end
  return box
end

function Window:TextBoxNote(text)
  if box then box.note:SetText(text or "") end
end

function Window:TextBoxClose()
  if box then box:Hide() end
end

-------------------------------------------------------------------------------------------
-- The window
-------------------------------------------------------------------------------------------

---A pane: { build(frame), fill(frame), footer }.
function Window:AddPane(key, pane)
  self.panes[key] = pane
end

local function footerText()
  local rec = C:ShownRecord()
  if rec.personal then return "|cff8fe08f*|r Your own record: groups that aren't your guild's stay on this account." end
  local blocked = C.SendBlocked()
  if blocked == "refused" then return "|cffe7b04f*|r The game is refusing add-on messages. Records has the paste-in way of staying in step." end
  local waiting = C.Transport:QueueSize()
  if blocked == "lockdown" then
    return string.format("|cffe7b04f*|r Sending paused until the game lifts its restriction. %d waiting, none lost.", waiting)
  end
  local unverified = #rec:State().waiting
  if unverified > 0 then
    return string.format("|cffe7b04f*|r %d officer decisions wait for an officer online to confirm them.", unverified)
  end
  return "|cff8fe08f*|r Your record is saved, and shared with guild members as they come online."
end

local function fillPane()
  if not win then return end
  local key = C.db.tab or "tonight"
  if not Window.panes[key] then key = "tonight" end
  for k, p in pairs(Window.panes) do
    if p.frame then p.frame:SetShown(k == key) end
  end
  local p = Window.panes[key]
  if not p then return end
  if not p.frame then
    p.frame = CreateFrame("Frame", nil, win.paneArea)
    p.frame:SetAllPoints()
    p.build(p.frame)
  end
  p.frame:Show()
  p.fill(p.frame)
  win.footerText:SetText(footerText())
  local rec = C:ShownRecord()
  win:SetSub(rec.personal and "Your own groups" or (C.Global("GetGuildInfo", "player") or "Your guild"))
  if win.switch then
    win.switch:SetLabel(rec.personal and "Show the guild's" or "Show my own")
    win.switch:SetShown(C.guildRecord ~= nil)
  end
end

local function build()
  win = UI.Window({ name = "CouncilWindow", addon = "council", title = "Council", width = W, height = H, footer = true })
  win:SetAccent("council")
  win:Hide()
  win.tabs = UI.Tabs(win.body, TABS, function(key)
    C.db.tab = key
    fillPane()
  end)
  win.tabs:SetPoint("TOPLEFT")
  win.tabs:SetPoint("TOPRIGHT")
  win.tabs:ApplyAccent(UI.Accent("council"))
  win.paneArea = CreateFrame("Frame", nil, win.body)
  win.paneArea:SetPoint("TOPLEFT", win.tabs, "BOTTOMLEFT", 14, -10)
  win.paneArea:SetPoint("BOTTOMRIGHT", -14, 10)
  win.gear = UI.Button(win.footer, "Settings", "quiet", function() C:OpenSettings() end)
  win.gear:SetSize(76, 20)
  win.gear:SetPoint("RIGHT", -12, 0)
  win.switch = UI.Button(win.footer, "Show my own", "quiet", function()
    C.db.showPersonal = not C.db.showPersonal
    fillPane()
  end)
  win.switch:SetSize(120, 20)
  win.switch:SetPoint("RIGHT", win.gear, "LEFT", -6, 0)
end

function Window:Get()
  if not win and C.db then build() end
  return win
end

---Opens on a tab, or where it was.
function Window:Open(tab)
  if not self:Get() then return end
  if tab then C.db.tab = tab end
  C.db.tab = (C.db.tab and Window.panes[C.db.tab]) and C.db.tab or "tonight"
  win.tabs:Select(C.db.tab, true)
  win:Show()
  fillPane()
end

function Window:Refresh()
  if win and win:IsShown() then fillPane() end
end

---Something the window shows changed. Bursts become one redraw.
function Window:Changed()
  Core:NextFrame(function() Window:Refresh() end, "council.changed")
end
