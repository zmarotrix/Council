-- The loot rules, with no game in them: who's in line for a drop and in what order, how rolls rank, and reading a
-- reserve list from a paste. The real softres.it and raidres formats haven't been seen yet (docs/council-v1.md
-- section 7), so the reader goes by column names and says plainly when it can't make sense of something.

Council = Council or {}
local Ladder = {}
Council.Ladder = Ladder

-- What a roll is for, from the range rolled: everyone rolls once, and main spec beats off spec beats transmog whatever the number.
Ladder.KIND_BY_MAX = { [100] = "ms", [99] = "os", [98] = "tm" }
Ladder.KIND_RANK = { sr = 0, ms = 0, raid = 0, os = 1, tm = 2 }
Ladder.KIND_LABEL = { sr = "Reserved", ms = "Main spec", os = "Off spec", tm = "Transmog", raid = "Raid roll", hand = "Given by hand" }
Ladder.KIND_TAG = { sr = "SR", ms = "MS", os = "OS", tm = "Tmog", raid = "Raid" }

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

---Is this drop reserved, for these purposes? Not if the loot master has opened it to everyone.
function Ladder.IsReserved(list, state, item, everyone)
  return not everyone and #Ladder.Reservers(list, state, item) > 0
end

---Everyone in line for a drop. rolls = { [player] = { v = roll, kind = "ms" } }. opts = { copies, tie, only = set, everyone }.
---Returns rows (best first: { p, v, kind, plus, bonus, total }), winners (the top rows, nil while a tie stands in the way),
---tied (the names tied across the last winning place, or nil), and waiting (reservers who haven't rolled).
function Ladder.Rank(list, state, item, rolls, opts)
  opts = opts or {}
  local copies = opts.copies or 1
  local reserved = Ladder.IsReserved(list, state, item, opts.everyone)
  local rows, waiting = {}, {}
  if reserved then
    for _, r in ipairs(Ladder.Reservers(list, state, item)) do
      if not opts.only or opts.only[r.p] then
        local got = rolls[r.p]
        if got then
          rows[#rows + 1] = { p = r.p, v = got.v, kind = "sr", plus = r.plus, bonus = r.bonus, total = got.v + r.bonus }
        else
          waiting[#waiting + 1] = r
        end
      end
    end
  else
    for p, got in pairs(rolls) do
      if not opts.only or opts.only[p] then
        rows[#rows + 1] = { p = p, v = got.v, kind = got.kind or "ms", plus = 0, bonus = 0, total = got.v }
      end
    end
    if opts.only then
      for p in pairs(opts.only) do
        if not rolls[p] then waiting[#waiting + 1] = { p = p, plus = 0, bonus = 0 } end
      end
    end
  end
  local rank = Ladder.KIND_RANK
  table.sort(rows, function(a, b)
    if rank[a.kind] ~= rank[b.kind] then return rank[a.kind] < rank[b.kind] end
    if a.total ~= b.total then return a.total > b.total end
    if a.plus ~= b.plus then return a.plus > b.plus end
    return a.p < b.p
  end)
  table.sort(waiting, function(a, b)
    if a.plus ~= b.plus then return a.plus > b.plus end
    return a.p < b.p
  end)

  -- a tie only matters if it crosses the last winning place
  local last, nextUp = rows[copies], rows[copies + 1]
  local tied
  if last and nextUp and rank[last.kind] == rank[nextUp.kind] and last.total == nextUp.total then
    if not (opts.tie == "oldest" and last.plus ~= nextUp.plus) then
      tied = {}
      for _, row in ipairs(rows) do
        if rank[row.kind] == rank[last.kind] and row.total == last.total and (opts.tie ~= "oldest" or row.plus == last.plus) then tied[#tied + 1] = row.p end
      end
    end
  end
  local winners
  if not tied then
    winners = {}
    for i = 1, math.min(copies, #rows) do winners[i] = rows[i] end
  end
  return rows, winners, tied, waiting
end

---The one player a drop goes to without a roll: the only reserver. Otherwise nil.
function Ladder.OnlyReserver(list, state, item)
  local r = Ladder.Reservers(list, state, item)
  return #r == 1 and r[1].p or nil
end

---What gets written down about an award.
function Ladder.Why(kind, roll, bonus, only)
  if only then return "The only reserve" end
  local title = Ladder.KIND_LABEL[kind] or "Given"
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
