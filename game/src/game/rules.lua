-- Race rules as the engine asks for them (docs/data-driven/02-entities.md): which buildings each race can construct,
-- what every building produces, what a unit or building needs, the per-race overrides and the typed Army.cfg /
-- Building.cfg columns. The data lives in the content registry (`content.race`, `content.unit`, `content.building`,
-- filled by src/import/wbc3/ from Building.cfg and Army.cfg); this module keeps the functions the engine calls,
-- race numbers (0..15 for the original races) in and plain tables out.
local content = require("src.content")

local M = {}

-- The race record of a race number; an unknown number (and nil) is the first race, as the original's lookups fall back.
local function raceOf(n)
    return content.race:bySlot(n) or content.race:bySlot(0)
end

-- race number -> letter used in the config files
M.RACE_LETTER = setmetatable({}, { __index = function(_, n) local r = content.race:bySlot(n) return r and r.letter end })

-- Kept for callers that force the data to be there; the registry is built at start-up.
function M.load() end

-- The Building.cfg [BUILDINGS] row of a building code, in the shape of the original file's columns (the race sets
-- keyed by race number), or nil.
---@param code string
---@return table?
function M.building(code)
    local b = content.building[code]
    return b and b._info
end

-- The [RULES] override of a unit / building / power-up code for a race, or nil.
---@param race integer?
---@param code string
---@return table?
function M.override(race, code)
    local t = content.thing(code)
    return t and t.byRace and t.byRace[raceOf(race).id]
end

-- Requirements (list of codes) for producing/constructing `code` as race.
---@param race integer?
---@param code string
---@return string[]
function M.requirements(race, code)
    local t = content.thing(code)
    return t and t.requires and t.requires[raceOf(race).id] or {}
end

-- The computer players' wish for `code` as race (Building.cfg [DEPENDENCIES] last column), or nil.
---@param race integer?
---@param code string
---@return number?
function M.priority(race, code)
    local t = content.thing(code)
    return t and t.priority and t.priority[raceOf(race).id]
end

-- Army.cfg row of a unit code: { index, status, size, missile, missileType, name, hero, general, maxMana, startMana }.
-- STATUS: size (S/M/L/H), alignment (G/N/E), race letter, X/T extra-planar/titan, L/A/F land/air/float, I/C
-- infantry/cavalry, A advanced, M missile (the string is rebuilt from the typed fields of the unit record).
---@param code string
---@return table?
function M.armyInfo(code)
    local u = content.unit[code] or content.unit[code:upper()]
    return u and u._info
end

local function byName(a, b)
    if a.name:lower() ~= b.name:lower() then return a.name:lower() < b.name:lower() end
    return a.code < b.code
end

-- All unit codes of Army.cfg ({ code, name, hero } sorted by name), for the editor.
---@return {code: string, name: string, hero: any}[]
function M.armyList()
    local cache = content.unit.cache
    if not cache.list then
        local list = {}
        for _, u in ipairs(content.unit:all()) do list[#list + 1] = { code = u.id, name = u._info.name, hero = u._info.hero } end
        table.sort(list, byName)
        cache.list = list
    end
    return cache.list
end

-- All building codes of Building.cfg ({ code, name } sorted by name), for the editor.
---@return {code: string, name: string}[]
function M.buildingList()
    local cache = content.building.cache
    if not cache.list then
        local list = {}
        for _, b in ipairs(content.building:all()) do list[#list + 1] = { code = b.id, name = b._info.name } end
        table.sort(list, byName)
        cache.list = list
    end
    return cache.list
end

-- The building and army codes a race has (the CACHE columns of Building.cfg / Army.cfg, what the original's
-- availability lists (FUN_00519480) walk through for its "new armies / buildings available" lines), in file order.
---@param race integer
---@return {buildings: string[], armies: string[]}
function M.raceSets(race)
    local cache = content.race.cache
    cache.sets = cache.sets or {}
    local set = cache.sets[race]
    if set then return set end
    local rrec = content.race:bySlot(race)
    local id = rrec and rrec.id
    set = { buildings = {}, armies = {} }
    for _, b in ipairs(content.building:all()) do
        if id and b.races[id] then set.buildings[#set.buildings + 1] = b.id end
    end
    for _, u in ipairs(content.unit:all()) do
        if id and not u.hero and u.races[id] then set.armies[#set.armies + 1] = u.id end
    end
    cache.sets[race] = set
    return set
end

---@param code string
---@param armyType table? the type record
---@return string
function M.unitName(code, armyType)
    local info = M.armyInfo(code)
    if info and info.name ~= "" then return info.name end
    if armyType and armyType.name ~= "" then return armyType.name end
    return code
end

-- What the race can construct: { { id, level, row } ... }.
---@param race integer?
---@return RaceBuildEntry[]
function M.buildList(race)
    return raceOf(race).build or {}
end

-- What a building produces for a race: { { id, level } ... } (the race's own list, else the building's default).
---@param race integer?
---@param building string
---@return ProductionEntry[]
function M.produces(race, building)
    local b = content.building[building]
    local p = b and b.produces
    if not p then return {} end
    return p[raceOf(race).id] or p["*"] or {}
end

local function unitsOf(list)
    local out = {}
    for _, it in ipairs(list) do
        if it.id:sub(1, 1) == "A" then out[#out + 1] = it.id end
    end
    return out
end

-- A skirmish starting force: the race's keep, its workers and a few troops
-- from its first barracks-type building.
---@param race integer
---@return {keep: string?, units: string[]}
function M.startingForce(race)
    local list = M.buildList(race)
    local keep = list[1] and list[1].id
    local force = { keep = keep, units = {} }
    if keep then
        local workers = unitsOf(M.produces(race, keep))
        if workers[1] then
            for _ = 1, 3 do force.units[#force.units + 1] = workers[1] end
        end
    end
    for i = 2, #list do
        local troops = unitsOf(M.produces(race, list[i].id))
        if #troops > 0 then
            for k = 1, math.min(2, #troops) do
                for _ = 1, 3 do force.units[#force.units + 1] = troops[k] end
            end
            break
        end
    end
    return force
end

return M
