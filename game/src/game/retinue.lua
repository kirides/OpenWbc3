-- The retinue: veterans that follow the hero from battle to battle in every game type (the original's army setup code,
-- 0x0043f3e0 .. 0x00445ad0 of the 1.04 binary; the rules are noted where they come from).
--
-- The retinue belongs to the hero record (profile): `rec.retinue[1..8]` = { code, name, level, xp, battles } (a slot is
-- nil when empty) and `rec.graveyard[1..10]` = { code, name, level, xp, battles, scenario, since, killer }. After a battle
-- the survivors that qualify are offered as recruits (M.recruits) and the player puts them into free slots or in
-- place of members (screens/armysetup.lua, recruit mode). Before a battle the retinue members that come along and
-- regular troops are bought with the army setup points (select mode).
--
-- Verified in the 1.04 binary:
--   - the number of slots is min(Charisma / 4, 7) + 1 (FUN_0040b130 -> FUN_0054a720 case 0xe), not a constant 8;
--     the army setup screen's opener (FUN_00440b40) adds the province bonus, caps the points at 100 and does NOT add the
--     Charisma bonus or the Diplomacy skill to them, nothing else reads skill 106 for the retinue
--   - the setup points of a retinue member = the type's points + a level table (0x006095b0: 0 0 0 0 1 1 1 2 2 3 4 5 6
--     7 8 9 10 11 12 15 by level 0..19) (FUN_00444940)
--   - recruits (FUN_0043f3e0), the computer's army purchase (FUN_00445200) and the tables below are read from it:
--     the general table at 0x00609330 (16 races x 10) and the AI army table at 0x006095d8 (16 races x 8 point values
--     x 4 rolls x 4 ids); handicap points at 0x00603c9c
-- Not in the original data: the placement of units is the original's (the start location +- 5 cells), the rest is
-- the original's rules; names for new recruits come from the naming sets (FUN_00434e90).
local content = require("src.content")
local gamedata = require("src.game.gamedata")
local rules = require("src.game.rules")
local armylevel = require("src.game.armylevel")

local M = { SLOTS = 8, RECRUITS = 8, GRAVEYARD = 10, MAX_POINTS = 100 }

-- A retinue member (rec.retinue[slot]) or a recruit on offer.
---@class RetinueEntry
---@field code string
---@field name string?
---@field level integer          counts from 0
---@field xp number
---@field battles integer?
---@field general boolean?       recruits: a general of the race
---@field combat number?         recruits: the type's combat at its level

-- A fallen member (rec.graveyard[1..10]).
---@class RetinueGrave: RetinueEntry
---@field scenario string?       the battle it fell in
---@field since integer          battles since
---@field killer string?         the unit type that killed it ("" a building or nothing)

-- A unit of the battle that may become a recruit (M.collect).
---@class RetinueCandidate
---@field code string
---@field level integer
---@field xp number
---@field combat number
---@field general boolean
---@field mechanical boolean
---@field defaultData boolean
---@field name string?

---@class RecruitOptions
---@field race integer?
---@field short boolean?         a game under five minutes
---@field pitched boolean?
---@field roll integer?          0..9: the general
---@field nameOf (fun(code: string): string?)?

-- What M.settle learns about a battle.
---@class RetinueBattle
---@field brought table<integer, boolean> the slots that fought
---@field alive table<integer, {level: integer, xp: number}> slot -> the survivor's level and experience
---@field fallen table<integer, string>? slot -> the killer's unit type ("" none)
---@field scenario string?

-- Charisma -> number of enabled retinue slots.
---@param cha integer?
---@return integer
function M.slots(cha)
    return math.min(math.floor((cha or 0) / 4), 7) + 1
end

-- Setup points added to a retinue member's type points by its level (0 .. 19).
M.LEVEL_POINTS = { [0] = 0, 0, 0, 0, 1, 1, 1, 2, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 15 }

-- What a computer side buys and which general a retinue gets live on the race records (`retinue.ai`, `retinue.generals`, content/base/races.lua).
local function codesOf(s)
    local out = {}
    for c in s:gmatch("%S+") do out[#out + 1] = c end
    return out
end

-- The general of a race's retinue recruits: the race's list of ten, one is rolled (0..9).
---@param race integer?
---@param roll integer? 0..9
---@return string
function M.generalFor(race, roll)
    local rec = content.race:bySlot(race or 0) or content.race:bySlot(0)
    -- race slot 0 always exists
    ---@cast rec -nil
    local list = rec.retinue.generals
    return list[(roll or 0) % #list + 1]
end

-- AI army points: the race's `retinue.ai[points]` = "<roll 0 ids>/<roll 1 ids>/<roll 2 ids>/<roll 3 ids>" (points 1..8).
local aiParsed = setmetatable({}, { __mode = "k" })       -- by race record
local function aiRolls(race, points)
    local rec = content.race:bySlot(race) or content.race:bySlot(0)
    -- race slot 0 always exists
    ---@cast rec -nil
    local byPoints = aiParsed[rec]
    if not byPoints then
        byPoints = {}
        aiParsed[rec] = byPoints
    end
    local p = byPoints[points]
    if not p then
        p = {}
        local row = rec.retinue.ai[points] or ""
        for part in (row .. "/"):gmatch("(.-)/") do p[#p + 1] = codesOf(part) end
        byPoints[points] = p
    end
    return p
end

-- What a computer side buys with its army setup points (1.04 binary FUN_00445200): the race's builder
-- first (it costs a point), a Knave only gets half of the rest, then the table row for min(points, 8) points is rolled
-- (one of four entries) until the points are gone, at most 50 units. `rng(n)` returns 1..n.
---@param race integer
---@param points integer
---@param aiLevel integer
---@param rng fun(n: integer): integer
---@return string[]
function M.aiArmy(race, points, aiLevel, rng)
    if points <= 0 then return {} end
    local out = { aiRolls(race, 1)[1][1] }
    points = points - 1
    if aiLevel == 1 then points = math.floor((points + 1) / 2) end
    while points > 0 do
        local these = math.min(points, 8)
        for _, code in ipairs(aiRolls(race, these)[rng(4)] or {}) do
            out[#out + 1] = code
            if #out >= 50 then points = 0 break end
        end
        points = points - these
    end
    return out
end

-- The extra points a campaign computer side may get (FUN_00445200): with a campaign difficulty above 0 (not for a
-- Passive or Rampant side) a d100 roll below 30 x difficulty gives 10, below 75 x difficulty gives 4.
---@param difficulty integer
---@param roll integer
---@return integer
function M.aiExtraPoints(difficulty, roll)
    if difficulty <= 0 then return 0 end
    if roll < difficulty * 30 then return 10 end
    if roll < difficulty * 75 then return 4 end
    return 0
end

-- Whether a campaign computer side hires a mercenary company, and a major one: the multiplier is 25 for a hero of level
-- 10 or more, 12 for level 5..9, none below; a d100 roll below difficulty x multiplier is a major company, below twice
-- that a minor / average one.
---@param difficulty integer
---@param heroLevel integer
---@param roll integer
---@return boolean hire
---@return boolean? major
function M.aiMercenaryRoll(difficulty, heroLevel, roll)
    if difficulty <= 0 then return false end
    local mult = 25
    if heroLevel < 5 then mult = 0 elseif heroLevel < 10 then mult = 12 end
    if roll < difficulty * mult then return true, true end
    if roll < difficulty * mult * 2 then return true, false end
    return false
end

-- The mercenary pick (FUN_00405680): companies of the race (-1: any) with a rarity, quality 0 and 1, quality 2 only when `major`,
-- weighted by rarity, in the order of their ids. `mercs` is campaigndata's id -> company table; `taken` a set of ids.
---@param mercs table<integer, table>
---@param race integer -1: any
---@param major boolean?
---@param rng fun(n: integer): integer
---@param taken table<integer, boolean>?
---@return table? company
function M.pickMercenary(mercs, race, major, rng, taken)
    local ids = {}
    for id in pairs(mercs) do ids[#ids + 1] = id end
    table.sort(ids)
    local pool, total = {}, 0
    for _, id in ipairs(ids) do
        local c = mercs[id]
        if id > 0 and c.rarity > 0 and (race < 0 or c.race == race) and (c.quality <= 1 or (c.quality == 2 and major))
            and not (taken and taken[id]) then
            total = total + c.rarity
            pool[#pool + 1] = { c = c, upto = total }
        end
    end
    if total == 0 then return nil end
    local roll = rng(total)
    for _, p in ipairs(pool) do
        if p.upto >= roll then return p.c end
    end
end

-- Handicapping (table at 0x00603c9c, read by FUN_00417280): the player whose hero is below the highest level in the game gets extra
-- army setup points, indexed by the difference - 1; beyond 30 levels +3 per level.
M.HANDICAP = { 1, 2, 3, 4, 5, 7, 9, 10, 12, 14, 15, 17, 19, 20, 22, 24, 26, 28, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39,
               40, 41 }
---@param highest integer
---@param mine integer
---@return integer
function M.handicap(highest, mine)
    if mine >= highest then return 0 end
    local diff = highest - mine
    if diff > 30 then return M.HANDICAP[30] + (diff - 30) * 3 end
    return M.HANDICAP[diff]
end

-- Entries -----------------------------------------------------------------------------------------------------------
-- A retinue entry: { code, name, level (counts from 0), xp, battles }.

-- The army setup points of a unit of this level (binary FUN_00444940): the type's setup points plus a
-- table of the level.
---@param code string
---@param level integer?
---@return integer
function M.cost(code, level)
    local t = gamedata.army(code)
    if not t then return 0 end
    return (t.setupPoints or 0) + (M.LEVEL_POINTS[math.max(0, math.min(19, level or 0))] or 0)
end

-- The statistics a unit of this type has at a level (the type's plus the level gains of FUN_0040daa0).
---@param code string
---@param level integer?
---@return {combat: number, hits: number, speed: number, damage: number, range: number}
function M.stats(code, level)
    local t = gamedata.army(code) or {}
    local g = armylevel.gain({ combat = t.combat or 0, speed = t.speed or 0, hits = t.hits or 0, damage = t.damage or 0 },
                             level or 0)
    return { combat = (t.combat or 0) + g.combat, hits = (t.hits or 0) + g.hits, speed = (t.speed or 0) + g.speed,
             damage = (t.damage or 0) + g.damage, range = t.range or 0 }
end

-- The experience a troop of a level has at least (the XP table of FUN_0040da20).
---@param level integer?
---@return number
function M.xpFor(level)
    return require("src.game.unit").XP_FOR_LEVEL[math.max(0, math.min(19, level or 0)) + 1] or 0
end

-- The name a new recruit gets (the recruit list, binary FUN_0043f3e0): a naming set by the unit's type or race
-- flags, a mechanical unit keeps its type name. `fromSet(n)` returns a name of the naming set n.
-- (the single types with a naming set of their own carry `behaviour.nameSet`, content/base/tags.lua)
---@param code string
---@param flags integer
---@return integer?
function M.nameSetOf(code, flags)
    local band = require("bit").band
    local rec = gamedata.army(code)
    local own = rec and rec.behaviour and rec.behaviour.nameSet
    if own then return own end
    if band(flags, 0x100) ~= 0 then return 1 end              -- orc
    if band(flags, 0x38) ~= 0 then return 6 end               -- elves
    if band(flags, 0x4) ~= 0 then return 1 end                -- undead
    if band(flags, 0x2) ~= 0 then return 8 end                -- dwarf
    if band(flags, 0xc0) ~= 0 then return 12 end              -- horse lord, minotaur
    if band(flags, 0x1) ~= 0 then return 4 end                -- human
    if band(flags, 0x4000) ~= 0 then return nil end           -- mechanical: its type name
    return 0
end

---@param code string
---@return string
function M.nameFor(code)
    local flags = require("src.game.powerups").flags(code)
    local set = M.nameSetOf(code, flags)
    local name = set and require("src.game.quests").nameFromSet(set)
    return name or rules.unitName(code, gamedata.army(code))
end

-- Recruits -----------------------------------------------------------------------------------------------------------

-- The units of a side that may become recruits (the candidates of FUN_0043f3e0): alive, not a hero, not
-- in the retinue, produced in the battle (a flag of the army). Plain descriptors, so the rules can be tested.
---@param world World
---@param side integer
---@return RetinueCandidate[]
function M.collect(world, side)
    local band = require("bit").band
    local flagsOf = require("src.game.powerups").flags
    local out = {}
    for _, u in ipairs(world.units) do
        if u.side == side and u.canRetinue and not u.hero and not u.retinueIndex and not u.illusion and u.type and u:alive() then
            local info = rules.armyInfo(u.code) or {}
            out[#out + 1] = { code = u.code, level = u.level or 0, xp = u.xp or 0, combat = u:baseStats().combat,
                              general = info.general == true, mechanical = band(flagsOf(u.code), 0x4000) ~= 0,
                              defaultData = u.type.useDefault ~= false,
                              name = u.name ~= rules.unitName(u.code, u.type) and u.name or nil }
        end
    end
    return out
end

-- The recruits (at most 8): candidates of level 2 or more with combat 8 or more that are not mechanical, not the Eye of
-- Oros and use the default data; a full list gives way to a newcomer by replacing the weakest copy of a type that is in
-- it more than once (strength = combat + 5 x level) or else the weakest entry if the newcomer's combat + 3 x level is
-- higher; when no general qualified and the game was not a short one (under five minutes, unless a pitched battle) a
-- general of the race is added, replacing the entry of least combat when the list is full. Recruits are reset to the
-- type's values plus their levels, and get a name if they have none. opts: race, short, pitched, roll (0..9),
-- nameOf(code).
---@param cands RetinueCandidate[]
---@param opts RecruitOptions
---@return RetinueEntry[]
function M.recruits(cands, opts)
    local list, gotGeneral = {}, false
    local function strength(e, per) return e.combat + e.level * per end
    for _, c in ipairs(cands) do
        local ok = c.code ~= "AAEY" and (c.level or 0) >= 2 and (c.combat or 0) >= 8 and not c.mechanical
        if ok and c.general then gotGeneral = true end
        if c.defaultData == false then ok = false end
        if ok then
            local e = { code = c.code, name = c.name, level = c.level, xp = c.xp, general = c.general,
                        combat = M.stats(c.code, c.level).combat }
            if #list < M.RECRUITS then
                list[#list + 1] = e
            else
                local counts = {}
                for i, a in ipairs(list) do
                    counts[i] = 0
                    for _, b in ipairs(list) do if a.code == b.code then counts[i] = counts[i] + 1 end end
                end
                local dup, most = nil, -1
                for i = 1, #list do
                    if counts[i] > most and counts[i] > 1 then dup, most = i, counts[i] end
                end
                if dup then
                    local at, best = nil, 1000
                    for i, a in ipairs(list) do
                        if a.code == list[dup].code and strength(a, 5) < best then at, best = i, strength(a, 5) end
                    end
                    if at then list[at] = e end
                else
                    local at, best = nil, 1000
                    for i, a in ipairs(list) do
                        if strength(a, 5) < best then at, best = i, strength(a, 5) end
                    end
                    if at and strength(e, 3) > best then list[at] = e end
                end
            end
        end
    end
    if (not opts.short or opts.pitched) and not gotGeneral then
        ---@type integer?
        local at = #list + 1
        if #list >= M.RECRUITS then
            at = nil
            local best = 1000
            for i, a in ipairs(list) do
                if a.combat < best then at, best = i, a.combat end
            end
        end
        if at then
            local code = M.generalFor(opts.race, opts.roll)
            list[at] = { code = code, level = 0, xp = 1, general = true, combat = M.stats(code, 0).combat }
        end
    end
    for _, e in ipairs(list) do
        if not e.name or e.name == "" then e.name = opts.nameOf and opts.nameOf(e.code) or nil end
    end
    return list
end

-- The hero record's retinue ---------------------------------------------------------------------------------------

---@param rec HeroProfile
---@return table<integer, RetinueEntry>
function M.get(rec)
    rec.retinue = rec.retinue or {}
    return rec.retinue
end

-- The retinue slots a hero record has enabled (by its Charisma).
---@param rec HeroProfile
---@return integer
function M.slotsOf(rec)
    local attr = rec.hero and rec.hero.attr
    return M.slots(attr and attr.cha or 0)
end

---@param rec HeroProfile
---@return table<integer, RetinueGrave>
function M.graveyard(rec)
    rec.graveyard = rec.graveyard or {}
    return rec.graveyard
end

-- Puts an entry into the retinue (a campaign reward or hire; not traced in the 1.04 binary yet): the first free slot of the enabled
-- ones, else the slot of least combat is replaced. Returns the slot.
---@param rec HeroProfile
---@param entry {code: string, name: string?, level: integer?, xp: number?, battles: integer?}
---@param enabled integer
---@return integer slot
function M.give(rec, entry, enabled)
    local ret = M.get(rec)
    local at
    for i = 1, enabled do
        if not ret[i] then at = i break end
    end
    if not at then
        local best = 1000
        for i = 1, enabled do
            local c = M.stats(ret[i].code, ret[i].level).combat
            if c < best then at, best = i, c end
        end
    end
    ret[at] = { code = entry.code, name = entry.name, level = entry.level or 0,
                xp = entry.xp or M.xpFor(entry.level or 0), battles = entry.battles or 0 }
    return at
end

-- The experience an entry has when it is created at a level.
---@param code string
---@param level integer?
---@param name string?
---@return RetinueEntry
function M.fresh(code, level, name)
    return { code = code, name = name, level = level or 0, xp = M.xpFor(level or 0), battles = 0 }
end

-- After a battle: the members that fell go to the graveyard, the others count the battle and keep what they learned
-- (the loop at the end of FUN_0043f3e0). info: brought (set of slots that fought), alive (slot ->
-- { level, xp } of the survivors), fallen (slot -> unit type that killed it, "" for a building or nothing: the killer the army records,
-- copied into the grave as `killer`), scenario (name of the battle). The graveyard has ten places; a new grave takes the
-- first free one or else the one that has been there longest, and the most valuable grave (level x 10 + experience +
-- combat x 5) is kept in the first place.
---@param rec HeroProfile
---@param info RetinueBattle
function M.settle(rec, info)
    local ret, gy = M.get(rec), M.graveyard(rec)
    local function value(g) return g.level * 10 + (g.xp or 0) + M.stats(g.code, g.level).combat * 5 end
    for slot = 1, M.SLOTS do
        local e = ret[slot]
        if e and info.brought[slot] and not info.alive[slot] then
            local grave = { code = e.code, name = e.name, level = e.level or 0, xp = e.xp or 0, battles = (e.battles or 0) + 1,
                            scenario = info.scenario, since = 0, killer = (info.fallen or {})[slot] }
            local at
            for i = 1, M.GRAVEYARD do
                if not gy[i] then at = i break end
            end
            if not at then
                local oldest = -1
                for i = 1, M.GRAVEYARD do
                    if (gy[i].since or 0) > oldest then at, oldest = i, gy[i].since or 0 end
                end
            end
            gy[at] = grave
            ret[slot] = nil
        elseif e then
            local a = info.alive[slot]
            if a then e.level, e.xp = a.level, a.xp end
            e.battles = (e.battles or 0) + 1
        end
        local best, bestAt = -1, nil
        for i = 1, M.GRAVEYARD do
            if gy[i] then
                local v = value(gy[i])
                if v > best then best, bestAt = v, i end
            end
        end
        if bestAt and bestAt > 1 then
            if gy[1] then
                gy[1], gy[bestAt] = gy[bestAt], gy[1]
            else
                gy[1], gy[bestAt] = gy[bestAt], nil
            end
        end
    end
    for i = 1, M.GRAVEYARD do
        if gy[i] then gy[i].since = (gy[i].since or 0) + 1 end
    end
end

-- A name typed into the retinue screen: at most 19 characters; the names of the original's own characters get a 2
-- appended (the rename box's handler at 0x00442e30).
local RESERVED = { "robert", "minos", "paridian", "kheldon", "kaari", "elnaria", "gront", "setroth", "baragon", "aelfwine",
                   "elana" }
---@param s string?
---@return string
function M.cleanName(s)
    s = (s or ""):sub(1, 19)
    for _, r in ipairs(RESERVED) do
        if s:lower() == r then return s .. "2" end
    end
    return s
end

return M
