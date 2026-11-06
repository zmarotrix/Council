-- Records: who's in the record, what's verified, what looks wrong, and keeping a copy. Export and import also serve as
-- the way officers stay in step if this realm doesn't let add-ons send.

local Core = NorgannonCore
local C = Council
if C.disabled then return end
local UI = Core.UI
local Window = C.Window
local Serial = C.Serial

local Records = {}
C.Records = Records

local ALARMS = {
  conflict = "Two versions of %s's entry %d exist. The first one we held stands.",
  mismatch = "An officer's summary doesn't match what we hold for %s's entry %d.",
  replaced = "%s sent a different entry %d than the one we'd been told about. Theirs stands.",
  impersonated = "Someone sent an entry %2$d in your name that you didn't write. %1$s is you.",
}

local function encode(text)
  local api = rawget(_G, "C_EncodingUtil")
  if api and api.CompressString and api.EncodeBase64 then
    local ok, out = pcall(function() return api.EncodeBase64(api.CompressString(text)) end)
    if ok and type(out) == "string" then return "COUNCILZ1:" .. out end
  end
  return "COUNCILT1:" .. text
end

local function decode(text)
  text = (text or ""):match("^%s*(.-)%s*$")
  local kind, body = text:match("^COUNCIL([ZT])1:(.*)$")
  if not kind then return nil end
  if kind == "T" then return Serial.Read(body) end
  local api = rawget(_G, "C_EncodingUtil")
  if not api then return nil end
  local ok, plain = pcall(function() return api.DecompressString(api.DecodeBase64(body)) end)
  if ok and type(plain) == "string" then return Serial.Read(plain) end
end

---The whole record as one string.
function Records.Export(rec)
  return encode(Serial.Write({ v = 1, entries = rec.ledger:All() }))
end

---Merges a string into a record. Everything goes through the same checks as a message from a stranger, so nothing
---here is verified until an officer's summary or the author says so. Returns new, skipped, or nil and why.
function Records.Import(rec, text)
  local data = decode(text)
  if type(data) ~= "table" or type(data.entries) ~= "table" then return nil, "That isn't an export from Council." end
  -- each author's chain has to go in order
  local entries = {}
  for _, e in ipairs(data.entries) do
    if type(e) == "table" and type(e.a) == "string" and type(e.s) == "number" then entries[#entries + 1] = e end
  end
  table.sort(entries, function(a, b)
    if a.a ~= b.a then return a.a < b.a end
    return a.s < b.s
  end)
  local new, skipped = 0, 0
  for _, entry in ipairs(entries) do
    if rec.ledger:Ingest(entry, "import") == "new" then new = new + 1 else skipped = skipped + 1 end
  end
  return new, skipped
end

local function csvCell(text)
  text = tostring(text or "")
  if text:find('[,"\n]') then return '"' .. text:gsub('"', '""') .. '"' end
  return text
end

---Every loot line as CSV, for a sheet.
function Records.LootCsv(rec)
  local out = { "Date,Instance,Boss,Player,Item ID,Item,Reason,Rule,Roll,Bonus,Witnesses,Corrected" }
  for _, line in ipairs(rec:State().lines) do
    out[#out + 1] = table.concat({
      csvCell(date("%Y-%m-%d %H:%M", line.at)), csvCell(line.session.name), csvCell(line.boss or "Trash"), csvCell(line.player), line.item,
      csvCell(C.ItemName(line.item, line.link)), csvCell(line.why), csvCell(line.rung), csvCell(line.roll), csvCell(line.bonus), line.seen,
      line.void and "voided" or (line.fixes and "yes" or ""),
    }, ",")
  end
  return table.concat(out, "\n")
end

function Records:ExportAll()
  Window:TextBox("Export everything", "Keep this somewhere safe, or paste it to another officer. Importing it never overrides a verified entry.", Records.Export(C:ShownRecord()))
end

function Records:ExportLoot()
  Window:TextBox("Loot as CSV", "For a spreadsheet. Copy it with Ctrl+C.", Records.LootCsv(C:ShownRecord()))
end

function Records:ImportBox()
  Window:TextBox("Import a backup", "Paste an export. Everything in it stays unverified until an officer or its author confirms it.", "", function(text)
    local new, skipped = Records.Import(C:ShownRecord(), text)
    if not new then
      Window:TextBoxNote("|cffff9478" .. skipped .. "|r")
      return
    end
    C:Print(string.format("Imported %d new entries. %d were already here or didn't check out.", new, skipped))
    Window:TextBoxClose()
    Window:Refresh()
  end)
end

local function build(f)
  f.lead = Window.Line(f)
  f.lead:SetPoint("TOPLEFT")
  f.lead:SetPoint("TOPRIGHT", -280, 0)
  f.lead:SetText("The game vouches for who sent a message and what rank they hold, and hashes make a changed entry stand out. This makes tampering visible. It can't make it impossible: nothing in this client can sign, and an officer is trusted by rank.")
  f.export = UI.Button(f, "Export", "quiet", function() Records:ExportAll() end)
  f.export:SetSize(84, 24)
  f.export:SetPoint("TOPRIGHT")
  f.csv = UI.Button(f, "CSV of loot", "quiet", function() Records:ExportLoot() end)
  f.csv:SetSize(92, 24)
  f.csv:SetPoint("RIGHT", f.export, "LEFT", -4, 0)
  f.import = UI.Button(f, "Import", "quiet", function() Records:ImportBox() end)
  f.import:SetSize(84, 24)
  f.import:SetPoint("RIGHT", f.csv, "LEFT", -4, 0)
  f.pane = UI.Pane(f)
  f.pane:SetPoint("TOPLEFT", f.lead, "BOTTOMLEFT", 0, -8)
  f.pane:SetPoint("BOTTOMRIGHT")
  f.list = Window.RowList(f.pane, 30)
  f.list:SetPoint("TOPLEFT", 2, -2)
  f.list:SetPoint("BOTTOMRIGHT", -2, 2)
end

local function fill(f)
  local rec = C:ShownRecord()
  local ledger, state = rec.ledger, rec:State()
  local items = {}

  if #ledger.store.alarms > 0 or #state.clashes > 0 then
    items[#items + 1] = { group = "What looks wrong" }
    for i = #ledger.store.alarms, 1, -1 do
      local a = ledger.store.alarms[i]
      local text = string.format(ALARMS[a.kind] or "%s, entry %d", a.author, a.seq)
      items[#items + 1] = { title = "|cffff9478" .. text .. "|r", sub = string.format("From %s, %s", tostring(a.detail or "?"), Window.Stamp(a.at)) }
    end
    for _, clash in ipairs(state.clashes) do
      items[#items + 1] = { title = string.format("|cffe7b04f%s and %s set %s within minutes.|r", clash.a, clash.b, clash.rule), sub = string.format("Settled by time and name, the same on every client: %s", tostring(clash.kept)) }
    end
  end
  if #state.refused > 0 then
    items[#items + 1] = { group = string.format("Decisions that didn't count: %d", #state.refused) }
    for i = #state.refused, math.max(1, #state.refused - 5), -1 do
      local r = state.refused[i]
      items[#items + 1] = { title = string.format("%s, entry %d (%s)", r.entry.a, r.entry.s, r.entry.k), sub = r.why, right = Window.Stamp(r.entry.t) }
    end
  end

  items[#items + 1] = { group = "Who's in the record" }
  for _, author in ipairs(ledger:Authors()) do
    local head = ledger:Head(author)
    local v = ledger.store.verified[author]
    local verified = author == C.Me() or (v and v.s >= head)
    items[#items + 1] = {
      title = C.Who(author) .. (author == C.Me() and "  |cff6e6552you|r" or ""),
      sub = C.Roster:IsOfficer(author) and "Officer" or "Observations only",
      right = string.format("%d entries   %s", head, verified and "|cff8fe08fverified|r" or string.format("|cffe7b04f%d of them unverified|r", head - (v and v.s or 0))),
    }
  end
  if #ledger:Authors() == 0 then items[#items + 1] = { title = "|cff6e6552Nothing yet.|r" } end
  f.list:SetData(items, true)
end

Window:AddPane("records", { build = build, fill = fill })
