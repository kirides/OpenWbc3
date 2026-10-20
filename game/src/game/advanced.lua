-- The advanced options of a game (the original's advanced options dialog): which of the eight switches a
-- battle runs with, how they are kept in openwbc3.ini and which rules the combinations force.
--
--   randomWeather  weather changes by chance (weather.lua)            resignKills  a resigning side is neutralised
--   aiResign       a crushed computer side gives up (ai.lua)          tournament   every hero starts at a fixed level
--   points         the tournament level, 4..50                        greatest     "I am the greatest" (single player)
--   toughTowers    stronger race towers (not the game mod)           noItems      items give a hero nothing
--
-- Verified in the 1.04 binary (Battlecry III.exe):
--   * the registry names "RandomWeather", "AICanResign", "IAmTheGreatest", "ResignationKillsSide", "ThoughTowers" (sic),
--     "TournamentMode", "TournamentModePoints" and "NoItems" are read by FUN_00450d00 into a
--     9 byte struct: random weather +0, resignation +1, AI resign +2, tournament +3, points (u16) +4, greatest +6,
--     tough towers +7, no items +8;
--   * a value missing from an existing key defaults to random weather TRUE, AI resign TRUE, greatest FALSE, resignation
--     kills TRUE, tough towers FALSE, tournament FALSE, points 15, no items FALSE (the arguments of those reads);
--   * with no key at all FUN_004531e0 stores random weather FALSE, resignation kills TRUE, AI resign TRUE, tournament
--     FALSE, points 10, greatest / tough towers / no items FALSE;
--   * the struct sits at 0x749c60; the computer player's think step FUN_004fa120 tests +2.
-- Forced combinations are those of the dialog's check box handler (0x004e9ab0, no Ghidra function; box 4): switching
-- "I am the greatest" sets random weather and resignation kills on, AI resign and tournament off and locks the other
-- boxes; it exists only in single player games.
-- Campaign battles run with AI resign on, random weather off, no items / greatest / tough towers / tournament off
-- (the campaign battle start FUN_005a1880 at 0x5a19a6); the tutorials switch everything but the resignation rule off
-- (the tutorial start FUN_004494e0).
local M = {}

M.KEYS = { "randomWeather", "resignKills", "aiResign", "tournament", "points", "greatest", "toughTowers", "noItems" }
M.POINTS_MIN, M.POINTS_MAX = 4, 50

-- openwbc3.ini [advanced] key of every field (the registry value names of the original).
M.INI = { randomWeather = "randomweather", resignKills = "resignationkillsside", aiResign = "aicanresign",
          tournament = "tournamentmode", points = "tournamentmodepoints", greatest = "iamthegreatest",
          toughTowers = "thoughtowers", noItems = "noitems" }

-- The advanced options of a game (world.advanced), as M.normalize makes them.
---@class AdvancedOptions
---@field randomWeather boolean
---@field resignKills boolean
---@field aiResign boolean
---@field tournament boolean
---@field points integer            tournament points 4..50
---@field greatest boolean          "I am the greatest"
---@field toughTowers boolean
---@field noItems boolean

local function clampPoints(v)
    v = math.floor(tonumber(v) or 10)
    return math.max(M.POINTS_MIN, math.min(M.POINTS_MAX, v))
end

-- A complete, clean copy: booleans for the switches, the points clamped.
---@param t table?
---@return AdvancedOptions
function M.normalize(t)
    t = t or {}
    return { randomWeather = t.randomWeather == true, resignKills = t.resignKills ~= false, aiResign = t.aiResign == true,
             tournament = t.tournament == true, points = clampPoints(t.points), greatest = t.greatest == true,
             toughTowers = t.toughTowers == true, noItems = t.noItems == true }
end

-- What a battle gets when nobody picked options (headless tests, the --scenario developer start): nothing that
-- changes the rules, resignation as it has always been.
---@return AdvancedOptions
function M.baseline() return M.normalize({ resignKills = true }) end

---@return AdvancedOptions
function M.campaign() return M.normalize({ resignKills = true, aiResign = true }) end

---@return AdvancedOptions
function M.tutorial() return M.normalize({ resignKills = true }) end

-- Applies the rules the combinations force. `multiplayer`: "I am the greatest" does not exist there.
---@param t table?
---@param multiplayer boolean?
---@return AdvancedOptions
function M.enforce(t, multiplayer)
    t = M.normalize(t)
    if multiplayer then t.greatest = false end
    if t.greatest then
        t.randomWeather, t.resignKills, t.aiResign, t.tournament = true, true, false, false
    end
    return t
end

-- Whether two option sets are the same.
---@param a table
---@param b table
---@return boolean
function M.equal(a, b)
    for _, k in ipairs(M.KEYS) do if a[k] ~= b[k] then return false end end
    return true
end

-- The lines of the lobby / rules text for the switches that are on.
---@param t table
---@return string[]
function M.active(t)
    local out = {}
    for _, k in ipairs({ "randomWeather", "resignKills", "aiResign", "tournament", "greatest", "toughTowers", "noItems" }) do
        if t[k] then out[#out + 1] = k end
    end
    return out
end

-- The settings "I am the greatest" forces on the setup (FUN_004de4f0 for the options, FUN_004e0590 for the sides):
-- hidden map, no quests, 5 army setup points, fog of war level 2, tech level 5, standard victory, every game mod off but No Walls.
M.GREATEST = { quests = false, points = 5, tech = 5, victory = 0, mods = { noWalls = true } }
M.GREATEST_HUMAN = { res = 0, team = 0 }            -- very low resources, team 0
M.GREATEST_AI = { res = 4, team = 1, level = 6 }    -- very high resources, team 1, Emperor

-- The tournament hero's points. Binary (the create-hero screen FUN_0054b040 / its OK FUN_0054bbd0 -> the attribute
-- screen FUN_00552d90(TRUE, level) -> the skill screen FUN_005522e0(TRUE, the attribute screen's original points)): with
-- the temporary flag set the attribute screen starts with the tournament LEVEL as its points (not one less) and the
-- skill screen with the same number; the hero is made at that level with the experience of the level. Points left over stay with the hero (Accept stores the rest).
---@param level integer
---@return integer
---@return integer
function M.tournamentPoints(level) return level, level end

-- Whether a game plays with the tournament hero creation: the option, not in a No Heroes game (the game start
-- message handler, binary FUN_004e2660: tournament flag +3 of the options received from the host and No Heroes
-- flag 0x70ae2d clear).
---@param adv table?
---@param mods table<string, boolean>?
---@return boolean
function M.tournamentGame(adv, mods)
    return adv ~= nil and adv.tournament == true and not (mods and mods.noHeroes)
end

-- Tough towers (the building placement of the 1.04 binary, FUN_004a50f0 at 0x4a52e9):
-- every race tower that is not a character gets 750 hits (current and maximum), speed 3, combat and damage doubled and
-- range + 1 (speed 3 for scenario placed and starting towers alike).
M.TOUGH_HITS, M.TOUGH_SPEED = 750, 3

---@type table<BuildingRecord, BuildingRecord>
local tough = setmetatable({}, { __mode = "k" })

-- A copy of a tower type record with the advanced Tough Towers changes; cached per record.
---@param t BuildingRecord the tower's type record
---@return BuildingRecord
function M.toughTower(t)
    local c = tough[t]
    if not c then
        ---@diagnostic disable-next-line: missing-fields -- a copy of t, the loop below fills every field
        c = {}
        for k, v in pairs(t) do c[k] = v end
        c.hits = M.TOUGH_HITS
        c.speed = M.TOUGH_SPEED
        c.combat = (t.combat or 0) * 2
        c.damage = (t.damage or 0) * 2
        c.range = (t.range or 0) + 1
        tough[t] = c
    end
    return c
end

-- Hero-level scaling of towers (skirmish / multiplayer only, game type 0 / 1). Verified in the binary: the building
-- placement (FUN_004a50f0, the tower block from 0x4a52e9 on) and the random map's starting towers (FUN_00418700).
-- A tower that is not a character gets, with L the highest hero level of the human sides (the larger of the side panel's
-- level and the hero's own level, tournament mode: the tournament level), integer divisions rounding down:
--   scenario towers (FUN_004a50f0)           hits + 10 L, speed + L / 20, combat + L / 10, damage + L / 4
--   starting towers (FUN_00418700, kind "start")  hits + 10 L, speed + L / 50, combat + L / 10, damage + L / 5
-- The tower is made a character afterwards, so nothing scales it a second time; Tough Towers comes first and both add
-- up. Only done when the building is created at the start (placed by the scenario or the random map), never for a tower a player builds.
---@type table<BuildingRecord, table<string, BuildingRecord>>
local scaled = setmetatable({}, { __mode = "k" })

---@param t BuildingRecord the tower's type record
---@param level integer
---@param kind "start"|"scenario"
---@return BuildingRecord
function M.scaledTower(t, level, kind)
    local key = kind .. level
    local cache = scaled[t]
    if not cache then cache = {}; scaled[t] = cache end
    local c = cache[key]
    if not c then
        ---@diagnostic disable-next-line: missing-fields -- a copy of t, the loop below fills every field
        c = {}
        for k, v in pairs(t) do c[k] = v end
        c.hits = (t.hits or 0) + 10 * level
        c.speed = (t.speed or 0) + math.floor(level / (kind == "start" and 50 or 20))
        c.combat = (t.combat or 0) + math.floor(level / 10)
        c.damage = (t.damage or 0) + math.floor(level / (kind == "start" and 5 or 4))
        cache[key] = c
    end
    return c
end

-- The resignation test of the computer player (binary FUN_004fc5a0, decompiled): a computer side with no hero, a current
-- army limit of at most 5 and a maximum of at most 15 gives up while the victory condition is standard and some other
-- side that is still in the game has more than ten times its current or more than twice its maximum army limit. Every
-- allied side that is not a computer side of this game or that has a hero or more than 5 / 15 keeps it in.
---@param world World
---@param i integer
---@param checkAllies boolean?
---@return boolean
function M.shouldResign(world, i, checkAllies)
    local eco = world.eco
    if eco:heroAlive(i) then return false end
    local cur, max = eco:armyLimit(i)
    if cur > 5 or max > 15 then return false end
    if (world.victoryRule or "standard") ~= "standard" then return false end
    for j = 0, 5 do
        local o = world.sides[j]
        if j ~= i and o.used and not o.defeated then
            local ally = checkAllies and not world:enemies(i, j)
            if ally then
                if not o.ai or eco:heroAlive(j) then return false end
                local c2, m2 = eco:armyLimit(j)
                if c2 > 5 or m2 > 15 then return false end
            else
                local c2, m2 = eco:armyLimit(j)
                if c2 > cur * 10 or m2 > max * 2 then return true end
            end
        end
    end
    return false
end

return M
