-- The loot rules, with no game in them: who's in line for a drop and in what order, how rolls rank, and reading a
-- reserve list from a paste. The real softres.it and raidres formats haven't been seen yet (docs/council-v1.md
-- section 7), so the reader goes by column names and says plainly when it can't make sense of something.

Council = Council or {}
local Ladder = {}
Council.Ladder = Ladder

Ladder.RUNGS = {
  { key = "sr", title = "Reserved", note = "Only these players can win it" },
  { key = "ms", title = "Main spec", note = "Anyone" },
  { key = "os", title = "Off spec", note = "After main spec" },
  { key = "de", title = "Disenchant or bank", note = "If nobody wants it" },
}

---The reservers of an item in a list, with their SR+: { { p, plus, bonus } }, most SR+ first.
function Ladder.Reservers(list, state, item)
  local out, seen = {}, {}
  if not list then return out end
  for _, row in ipairs(list.rows) do
    if row.i == item and not seen[row.p] then
      seen[row.p] = true
      local plus = Council.State.Plus(state, row.p, item)
      out[#out + 1] = { p = row.p, plus = plus, bonus = plus * state.rules.bonus }
    end
  end
  table.sort(out, function(a, b)
    if a.plus ~= b.plus then return a.plus > b.plus end
    return a.p < b.p
  end)
  return out
end

---The first rung that applies: Reserved if anyone reserved it, otherwise Main spec.
function Ladder.StartRung(list, state, item)
  return #Ladder.Reservers(list, state, item) > 0 and "sr" or "ms"
end

---Who can roll on a rung. Reserved: the reservers. Others: nil, meaning anyone.
function Ladder.Eligible(rung, list, state, item)
  if rung ~= "sr" then return nil end
  local set = {}
  for _, r in ipairs(Ladder.Reservers(list, state, item)) do set[r.p] = r end
  return set
end

---rolls = { [player] = roll }. Everyone in line, best total first; those yet to roll follow, by SR+.
---Returns rows { p, roll, plus, bonus, total }, and the players tied for first if there's a tie that matters.
function Ladder.Rank(rung, list, state, item, rolls, tieRule)
  local rows, seen = {}, {}
  if rung == "sr" then
    for _, r in ipairs(Ladder.Reservers(list, state, item)) do
      seen[r.p] = true
      local roll = rolls[r.p]
      rows[#rows + 1] = { p = r.p, plus = r.plus, bonus = r.bonus, roll = roll, total = roll and roll + r.bonus or nil }
    end
  else
    for p, roll in pairs(rolls) do
      if not seen[p] then rows[#rows + 1] = { p = p, plus = 0, bonus = 0, roll = roll, total = roll } end
    end
  end
  table.sort(rows, function(a, b)
    if a.total and b.total then
      if a.total ~= b.total then return a.total > b.total end
      if a.plus ~= b.plus then return a.plus > b.plus end
      return a.p < b.p
    end
    if a.total or b.total then return a.total ~= nil end
    if a.plus ~= b.plus then return a.plus > b.plus end
    return a.p < b.p
  end)
  local tied
  local top = rows[1]
  if top and top.total and rows[2] and rows[2].total == top.total then
    -- under "oldest", more SR+ settles it; the same SR+ still needs a re-roll
    if not (tieRule == "oldest" and top.plus ~= rows[2].plus) then
      tied = {}
      for _, row in ipairs(rows) do
        if row.total == top.total and (tieRule ~= "oldest" or row.plus == top.plus) then tied[#tied + 1] = row.p end
      end
    end
  end
  return rows, tied
end

---The one player a drop goes to without a roll: the only reserver. Otherwise nil.
function Ladder.OnlyReserver(list, state, item)
  local r = Ladder.Reservers(list, state, item)
  return #r == 1 and r[1].p or nil
end

---What gets written down about an award.
function Ladder.Why(rung, roll, bonus, only)
  if only then return "The only reserve" end
  local title = "Given"
  for _, r in ipairs(Ladder.RUNGS) do
    if r.key == rung then title = r.title end
  end
  if roll and bonus and bonus > 0 then return string.format("%s, rolled %d + %d SR+", title, roll, bonus) end
  if roll then return string.format("%s, rolled %d", title, roll) end
  return title
end

-------------------------------------------------------------------------------------------
-- Reading a pasted list
-------------------------------------------------------------------------------------------

local COLUMNS = {
  player = { "attendee", "player", "name", "character", "charactername", "raider" },
  id = { "id", "itemid", "item id", "item_id" },
  item = { "item", "itemname", "item name" },
  plus = { "sr+", "srplus", "plus", "sr plus", "bonus" },
}

local function splitCsv(line)
  local out, field, quoted = {}, {}, false
  local i, n = 1, #line
  while i <= n do
    local c = line:sub(i, i)
    if quoted then
      if c == '"' then
        if line:sub(i + 1, i + 1) == '"' then
          field[#field + 1] = '"'
          i = i + 1
        else
          quoted = false
        end
      else
        field[#field + 1] = c
      end
    elseif c == '"' then
      quoted = true
    elseif c == "," or c == "\t" or c == ";" then
      out[#out + 1] = table.concat(field)
      field = {}
    else
      field[#field + 1] = c
    end
    i = i + 1
  end
  out[#out + 1] = table.concat(field)
  for k, v in ipairs(out) do out[k] = v:match("^%s*(.-)%s*$") end
  return out
end

local function findColumns(header)
  local at = {}
  for i, cell in ipairs(header) do
    local name = cell:lower()
    for key, names in pairs(COLUMNS) do
      if not at[key] then
        for _, candidate in ipairs(names) do
          if name == candidate then at[key] = i end
        end
      end
    end
  end
  return at
end

---Reads a paste. Returns { rows = { {player, itemId, plus, itemName} }, problems = { text }, hasPlus = bool }, or nil
---and a sentence saying what's wrong with it. findItem(name) turns an item name into an id, for lists without ids.
function Ladder.ParseReserves(text, findItem)
  if type(text) ~= "string" or not text:find("%S") then return nil, "There's nothing to read." end
  local lines = {}
  for line in (text .. "\n"):gmatch("(.-)\r?\n") do
    if line:find("%S") then lines[#lines + 1] = line end
  end
  if #lines > 2000 then return nil, "That's too long to be a reserve list." end
  local at = findColumns(splitCsv(lines[1]))
  if not at.player or not (at.id or at.item) then
    return nil, "I can't find a player column and an item column in the first line. Send Maro this export and it can be taught to read it."
  end
  local rows, problems, hasPlus = {}, {}, false
  local seen = {}
  for i = 2, #lines do
    local cells = splitCsv(lines[i])
    local player = cells[at.player]
    if player and player ~= "" then
      player = player:gsub("^%l", string.upper)
      local id = at.id and tonumber(cells[at.id])
      local name = at.item and cells[at.item] or nil
      if name then name = name:gsub('^%[', ""):gsub('%]$', "") end
      if not id and name and findItem then id = findItem(name) end
      local plus = at.plus and tonumber(cells[at.plus]) or nil
      if plus then hasPlus = true end
      if id then
        local tag = player .. "|" .. id
        if not seen[tag] then
          seen[tag] = true
          rows[#rows + 1] = { player, id, plus or 0, name }
        end
      else
        problems[#problems + 1] = string.format("Line %d: couldn't work out which item %q is.", i, name or "?")
      end
    else
      problems[#problems + 1] = string.format("Line %d has no player.", i)
    end
  end
  if #rows == 0 then return nil, "No line could be read. " .. (problems[1] or "") end
  return { rows = rows, problems = problems, hasPlus = hasPlus }
end

---What's wrong with a list before the pull. raiders = { name, ... }; dropsHere = set of item ids, or nil if unknown.
---Returns { missing = names with no reserve, absent = {p, i}, wrongPlace = {p, i} }.
function Ladder.Check(list, raiders, dropsHere)
  local out = { missing = {}, absent = {}, wrongPlace = {} }
  if not list then return out end
  local reserved, here = {}, {}
  for _, name in ipairs(raiders or {}) do here[name] = true end
  for _, row in ipairs(list.rows) do
    reserved[row.p] = true
    if raiders and #raiders > 0 and not here[row.p] then out.absent[#out.absent + 1] = row end
    if dropsHere and not dropsHere[row.i] then out.wrongPlace[#out.wrongPlace + 1] = row end
  end
  for _, name in ipairs(raiders or {}) do
    if not reserved[name] then out.missing[#out.missing + 1] = name end
  end
  table.sort(out.missing)
  return out
end
