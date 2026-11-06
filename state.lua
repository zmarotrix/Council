-- Replays the record into what the window shows: sessions, loot lines, attendance, reserves, SR+, rules. It's a
-- plain function of the entries, sorted one agreed way, so every client that holds the same entries gets the same
-- answer, and no part of this state is ever saved or sent.
--
-- env = { me, personal = bool, isOfficer = function(name) ... }. Personal records (groups that aren't the guild's)
-- have one author, who decides everything.

Council = Council or {}
local State = {}
Council.State = State

local Ledger = Council.Ledger

State.RULES = {
  bonus = 10,          -- SR+: points per step
  cap = 0,             -- most steps, 0 for no cap
  resetOnWin = true,
  resetOnChange = true,
  missLimit = 3,       -- raids missed in a row before SR+ resets, 0 for never
  tie = "reroll",      -- or "oldest": whoever has held the most SR+ steps wins
  minQuality = 3,      -- the loot record's floor: rare
}
local RULE_TYPES = { bonus = "number", cap = "number", resetOnWin = "boolean", resetOnChange = "boolean", missLimit = "number", tie = "string", minQuality = "number" }

local MERGE_RAID = 8 * 3600     -- same instance, overlapping people, this close: one raid
local MERGE_PARTY = 3 * 3600
local CLASH_WINDOW = 300        -- two officers setting one rule this close together, to different values

---The short key a client's "seen" entry uses for one loot line. It only needs to be short: replay computes one per
---line, so it's a plain string hash rather than SHA-256, and nothing's trust rests on it.
function State.SeenKey(player, item, n)
  local key = player .. "|" .. item .. "|" .. n
  local h = 5381
  for i = 1, #key do h = (h * 33 + string.byte(key, i)) % 16777216 end
  return string.format("%06x", h)
end

local function plusOf(state, player)
  local t = state.plus[player]
  if not t then
    t = {}
    state.plus[player] = t
  end
  return t
end

-- Was this author allowed to decide, at the time of the entry?
local function makeAuthority(env, state)
  local ranges = state.officerRanges
  return function(entry)
    if env.personal then return true end
    local author, t = entry.a, entry.t
    local last
    for _, r in ipairs(ranges[author] or {}) do
      if r.at <= t then last = r.kind end
    end
    if last == "revoke" then return false, "rank removed" end
    if last == "grant" then return true end
    if env.isOfficer(author) then return true end
    -- not an officer today: fine if they were at the time, which only a later revoke can say
    for _, r in ipairs(ranges[author] or {}) do
      if r.kind == "revoke" and r.at > t then return true end
    end
    return false, "not an officer"
  end
end

local function findSession(state, map, size, t, names)
  local window = (size or 40) > 5 and MERGE_RAID or MERGE_PARTY
  for i = #state.sessions, 1, -1 do
    local s = state.sessions[i]
    if t - s.start > window then break end
    if s.map == map then
      if next(s.people) == nil or next(names) == nil then return s end
      for name in pairs(names) do
        if s.people[name] then return s end
      end
    end
  end
end

local function asSet(list)
  local set = {}
  if type(list) == "table" then
    for _, name in ipairs(list) do
      if type(name) == "string" then set[name] = true end
    end
  end
  return set
end

local handlers = {}

function handlers.sess(state, e)
  local d = e.d
  if type(d.id) ~= "string" or type(d.map) ~= "number" then return end
  local names = asSet(d.ros)
  local s = findSession(state, d.map, d.size, e.t, names)
  if not s then
    s = { id = d.id, map = d.map, name = type(d.name) == "string" and d.name or "?", size = d.size, kind = d.kind, start = e.t, last = e.t, people = {}, kills = {}, killSeen = {}, lines = {}, lineByKey = {} }
    state.sessions[#state.sessions + 1] = s
  end
  state.sessionById[d.id] = s
  for name in pairs(names) do s.people[name] = true end
  s.last = math.max(s.last, e.t)
end

local function sessionOf(state, id)
  return type(id) == "string" and state.sessionById[id] or nil
end

function handlers.att(state, e)
  local s = sessionOf(state, e.d.s)
  if not s then return end
  for name in pairs(asSet(e.d.add)) do s.people[name] = true end
end

function handlers.kill(state, e)
  local s = sessionOf(state, e.d.s)
  if not s or type(e.d.b) ~= "string" then return end
  if not s.killSeen[e.d.b] then
    s.killSeen[e.d.b] = true
    s.kills[#s.kills + 1] = { boss = e.d.b, at = e.t }
  end
  s.last = math.max(s.last, e.t)
end

local function lineFor(state, s, player, item, n, t)
  local key = player .. "|" .. item .. "|" .. n
  local line = s.lineByKey[key]
  if not line then
    line = { session = s, player = player, item = item, n = n, at = t, witnesses = {}, seen = 0, key = key, short = State.SeenKey(player, item, n) }
    s.lineByKey[key] = line
    s.lines[#s.lines + 1] = line
    state.lines[#state.lines + 1] = line
  end
  return line
end

function handlers.loot(state, e)
  local d, s = e.d, sessionOf(state, e.d.s)
  if not s or type(d.p) ~= "string" or type(d.i) ~= "number" then return end
  local line = lineFor(state, s, d.p, d.i, type(d.n) == "number" and d.n or 1, e.t)
  line.observed = true
  line.witnesses[e.a] = true
  line.link = line.link or (type(d.l) == "string" and d.l or nil)
  line.boss = line.boss or (type(d.b) == "string" and d.b or nil)
  line.count = line.count or d.c
  line.groupRoll = line.groupRoll or (type(d.r) == "number" and d.r or nil)
  s.last = math.max(s.last, e.t)
end

function handlers.seen(state, e)
  local s = sessionOf(state, e.d.s)
  if not s or type(e.d.keys) ~= "table" then return end
  state.rollups[#state.rollups + 1] = { session = s, author = e.a, keys = asSet(e.d.keys) }
end

-- A decision that needs an officer and came from someone who isn't still names who gave the item, but changes nothing else.
function handlers.award(state, e, allowed, why)
  local d, s = e.d, sessionOf(state, e.d.s)
  if not s or type(d.p) ~= "string" or type(d.i) ~= "number" then return end
  local n = type(d.n) == "number" and d.n or 1
  local line = lineFor(state, s, d.p, d.i, n, e.t)
  line.by = e.a
  line.rung = type(d.rung) == "string" and d.rung or nil
  line.roll = type(d.roll) == "number" and d.roll or nil
  line.bonus = type(d.bonus) == "number" and d.bonus or nil
  line.why = type(d.why) == "string" and d.why or nil
  line.boss = line.boss or (type(d.b) == "string" and d.b or nil)
  line.official = allowed
  line.officialWhy = why
  line.entry = e
  if allowed and line.rung == "sr" then
    local list = state.reserves
    if list then
      list.won[d.p] = list.won[d.p] or {}
      list.won[d.p][d.i] = true
    end
    if state.rules.resetOnWin then plusOf(state, d.p)[d.i] = nil end
  end
end

function handlers.fix(state, e, allowed)
  if not allowed then return end
  local d, s = e.d, sessionOf(state, e.d.s)
  if not s or type(d.key) ~= "string" then return end
  local line = s.lineByKey[d.key]
  if not line then return end
  line.fixes = line.fixes or {}
  line.fixes[#line.fixes + 1] = { by = e.a, at = e.t, why = d.why, was = line.player, void = d.void }
  if d.void then line.void = true end
  if type(d.to) == "string" then line.player = d.to end
end

local function wantsOf(rows, player)
  local want = {}
  for _, row in ipairs(rows) do
    if row.p == player then want[row.i] = true end
  end
  return want
end

function handlers.sr(state, e, allowed)
  if not allowed or type(e.d.rows) ~= "table" then return end
  local rows = {}
  for _, row in ipairs(e.d.rows) do
    if type(row) == "table" and type(row[1]) == "string" and type(row[2]) == "number" then
      rows[#rows + 1] = { p = row[1], i = row[2], plus = type(row[3]) == "number" and row[3] or nil, name = type(row[4]) == "string" and row[4] or nil }
    end
  end
  -- a corrected list mid-raid still remembers who's won tonight, or winning would earn them a step of SR+ at the close
  local carried = state.reserves and state.reserves.won or {}
  state.reserves = { key = e.d.key, at = e.t, by = e.a, rows = rows, source = e.d.src, won = carried }
  state.reserveLists[#state.reserveLists + 1] = state.reserves
  for _, row in ipairs(rows) do
    if state.rules.resetOnChange then
      local plus = plusOf(state, row.p)
      local want = wantsOf(rows, row.p)
      for item in pairs(plus) do
        if not want[item] then plus[item] = nil end
      end
    end
  end
  if e.d.usePlus then
    for _, row in ipairs(rows) do
      plusOf(state, row.p)[row.i] = (row.plus and row.plus > 0) and row.plus or nil
    end
  end
end

function handlers.plus(state, e, allowed)
  if not allowed then return end
  local d = e.d
  if type(d.p) ~= "string" or type(d.i) ~= "number" or type(d.n) ~= "number" then return end
  local plus = plusOf(state, d.p)
  local value = (plus[d.i] or 0) + d.n
  plus[d.i] = value > 0 and value or nil
end

-- A raid closing is when SR+ moves: everyone who came and reserved, and didn't win, gets a step.
function handlers.close(state, e, allowed)
  if not allowed then return end
  local list = state.reserves
  if not list or list.closed or (e.d.key and e.d.key ~= list.key) then return end
  list.closed = e.t
  local present = asSet(e.d.present)
  local rules = state.rules
  local done = {}
  for _, row in ipairs(list.rows) do
    local tag = row.p .. "|" .. row.i
    if not done[tag] then
      done[tag] = true
      local plus = plusOf(state, row.p)
      state.miss[row.p] = state.miss[row.p] or {}
      local won = list.won[row.p] and list.won[row.p][row.i]
      if present[row.p] then
        state.miss[row.p][row.i] = nil
        if not won then
          local value = (plus[row.i] or 0) + 1
          if rules.cap > 0 then value = math.min(value, rules.cap) end
          plus[row.i] = value
        end
      elseif plus[row.i] then
        local missed = (state.miss[row.p][row.i] or 0) + 1
        state.miss[row.p][row.i] = missed
        if rules.missLimit > 0 and missed >= rules.missLimit then
          plus[row.i] = nil
          state.miss[row.p][row.i] = nil
        end
      end
    end
  end
  state.reserves = nil
end

function handlers.rules(state, e, allowed)
  if not allowed then return end
  for key, value in pairs(type(e.d.set) == "table" and e.d.set or {}) do
    if RULE_TYPES[key] and type(value) == RULE_TYPES[key] then
      local previous = state.ruleWriters[key]
      if previous and previous.a ~= e.a and e.t - previous.t <= CLASH_WINDOW and previous.value ~= value then
        state.clashes[#state.clashes + 1] = { rule = key, a = previous.a, b = e.a, kept = value, at = e.t }
      end
      state.rules[key] = value
      state.ruleWriters[key] = { a = e.a, t = e.t, value = value }
    end
  end
end

-- These two gather first, because a decision made earlier depends on a rank change written later
local function gatherRanges(state, entries, env)
  for _, e in ipairs(entries) do
    if (e.k == "revoke" or e.k == "grant") and type(e.d.who) == "string" and type(e.d.at) == "number" then
      if env.personal or env.isOfficer(e.a) then
        state.officerRanges[e.d.who] = state.officerRanges[e.d.who] or {}
        table.insert(state.officerRanges[e.d.who], { kind = e.k, at = e.d.at })
      end
    end
  end
  for _, list in pairs(state.officerRanges) do
    table.sort(list, function(a, b) return a.at < b.at end)
  end
end

---Builds the state from a ledger.
function State.Build(ledger, env)
  local state = {
    sessions = {}, sessionById = {}, lines = {}, rollups = {}, plus = {}, miss = {}, rules = {}, ruleWriters = {}, clashes = {},
    officerRanges = {}, reserveLists = {}, waiting = {}, refused = {}, maxOfficerRank = nil,
  }
  for k, v in pairs(State.RULES) do state.rules[k] = v end
  local entries = ledger:All()
  gatherRanges(state, entries, env)
  local authority = makeAuthority(env, state)

  for _, e in ipairs(entries) do
    local handler = handlers[e.k]
    if Ledger.OBSERVATIONS[e.k] then
      if handler then handler(state, e) end
    elseif Ledger.DECISIONS[e.k] then
      if not ledger:IsVerified(e) then
        -- nobody we trust has vouched for this: an award still names itself on its line, but changes nothing
        state.waiting[#state.waiting + 1] = e
        if e.k == "award" then handler(state, e, false, "unverified") end
      else
        local allowed, why = authority(e)
        if not allowed then state.refused[#state.refused + 1] = { entry = e, why = why } end
        if handler then
          handler(state, e, allowed, why)
        elseif e.k == "council" and allowed and type(e.d.maxRank) == "number" and (not env.isGuildMaster or env.isGuildMaster(e.a)) then
          state.maxOfficerRank = e.d.maxRank
        end
      end
    end
  end

  for _, r in ipairs(state.rollups) do
    for _, line in ipairs(r.session.lines) do
      if r.keys[line.short] then line.witnesses[r.author] = true end
    end
  end
  for _, line in ipairs(state.lines) do
    local n = 0
    for _ in pairs(line.witnesses) do n = n + 1 end
    line.seen = n
  end
  return state
end

---Steps of SR+ a player holds on an item.
function State.Plus(state, player, item)
  local t = state.plus[player]
  return t and t[item] or 0
end

---The session a client should join for this instance and these people, or nil to start one.
function State.FindSession(state, map, size, now, names)
  return findSession(state, map, size, now, asSet(names))
end
