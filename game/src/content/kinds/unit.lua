-- Content kind `unit` (stage 2, docs/data-driven/02-entities.md 2.2): army and hero types. Key: the 4-letter code.
-- The record is the .ARM stat block (field names of formats/types.lua) plus the typed columns of Army.cfg:
--   index, label, hero, general, maxMana, startMana, missile, missileType
--   size "small|medium|large|huge"   alignment "good|neutral|evil"   moveClass "land|air|float"
--   raceClass (letter of the race column: H D U E W K B M O R X N C V A F L ...)
--   planar, titan, infantry, cavalry, advanced, ranged (booleans)
--   races = { [raceId] = true }       the races that have the unit (the cache columns)
--   fileId                            the id the .ARM file carries when it differs from the code
--   missingStats                      the code is in Army.cfg but has no .ARM file
--   tags = { ids }                    traits (kinds/tag.lua); `behaviour` holds the named per-type behaviours:
--     mineSkill (a builder's value in a mine), regenMultiplier, conversion = { rate = {num, den}, powerup = id },
--     psychWith = { powerup, type, strength }, nameSet (retinue naming set), hunts = { prey = codes, wounded, mana, heroRace }
--     (the animals a unit goes after), critterRest (the animals' resting roll), ...
-- Derived at finalise (not hashed): legacyStatus (the Army.cfg status string rebuilt from the typed fields), statusFlags
-- (the original's army type flag bits), tagSet (id -> true) and _info (the old `rules.armyInfo` table shape).
local tagKind = require("src.content.kinds.tag")

---@class ContentCost
---@field gold integer
---@field metal integer
---@field crystal integer
---@field stone integer

-- A [RULES] line of Building.cfg: the race's values of a type (absent = unchanged).
---@class RaceOverride
---@field gold integer?
---@field metal integer?
---@field stone integer?
---@field crystal integer?
---@field time integer?
---@field combat integer?
---@field hits integer?
---@field speed integer?
---@field resistance integer?
---@field damage integer?
---@field range integer?

-- What units, buildings and power-ups share: the tech tree of Building.cfg (import/wbc3/rules.lua), keyed by race id.
---@class TechRecord
---@field id string                     the 4-letter code, or "modid:name"
---@field cost ContentCost
---@field requires table<string, string[]>?      race id -> the buildings / runes it needs
---@field priority table<string, integer>?       race id -> the computer players' wish for it
---@field byRace table<string, RaceOverride>?    race id -> the [RULES] overrides

-- The config columns units and buildings share; their stat blocks are the .ARM / .BUI records of formats/types.lua (`ArmRecord`,
-- `BuiRecord`), whose fields are nil only for a stub flagged `missingStats`.
---@class TypeRecord: TechRecord
---@field fileId string?                the id the file carries when it differs from the code
---@field missingStats boolean?         in the config but without a .ARM / .BUI file
---@field index integer                 the index in the config table (scenario files store it)
---@field label string                  the name column of the config
---@field missile string?               missile code
---@field missileType string            its first character ("-" for none)
---@field races table<string, boolean>  the races that have it (the cache columns)
---@field tags string[]?                traits (kinds/tag.lua)
---@field sprite (string|table)?        the art: an install sprite code or an asset reference of a mod (docs/modding/assets.md)
---@field tagSet table<string, true>    derived: own tags plus the implied ones
---@field _info table                   derived: the old rules table shape

---@class UnitHunts
---@field prey string[]
---@field wounded boolean?
---@field mana integer?
---@field heroRace string?

-- Named per-type behaviours (content/base/tags.lua).
---@class UnitBehaviour
---@field mineSkill integer?
---@field regenMultiplier integer?
---@field conversion { num: integer, den: integer, powerup: string? }?
---@field psychWith { powerup: string, type: integer, strength: integer }?
---@field nameSet integer?
---@field hunts UnitHunts?
---@field critterRest integer?

---@class UnitRecord: ArmRecord, TypeRecord
---@field hero boolean
---@field general boolean
---@field maxMana integer?
---@field startMana integer?
---@field size "small"|"medium"|"large"|"huge"
---@field alignment "good"|"neutral"|"evil"
---@field moveClass "land"|"air"|"float"
---@field raceClass string?             the race letter of the status column
---@field planar boolean
---@field titan boolean
---@field infantry boolean
---@field cavalry boolean
---@field advanced boolean
---@field ranged boolean
---@field rawStatus string?             the Army.cfg status when the typed fields cannot express it
---@field behaviour UnitBehaviour?
---@field legacyStatus string           derived: the Army.cfg status string
---@field statusFlags integer           derived: the original's army type flags

local M = {
    name = "unit",
    doc = "army and hero types",
    derived = { "legacyStatus", "statusFlags", "tagSet" },
    refs = { { field = "tags", target = "tag", mode = "list" } },
    STATUS = {
        size = { S = "small", M = "medium", L = "large", H = "huge" },
        alignment = { G = "good", N = "neutral", E = "evil" },
        moveClass = { L = "land", A = "air", F = "float" },
    },
}

local function char(map, value)
    for c, name in pairs(map) do
        if name == value then return c end
    end
    return "-"
end

-- The Army.cfg status string of a record: size, alignment, race letter, X/T, land/air/float, I/C, advanced, missile.
---@param rec UnitRecord
---@return string
function M.composeStatus(rec)
    local S = M.STATUS
    return char(S.size, rec.size) .. char(S.alignment, rec.alignment) .. (rec.raceClass or "-")
        .. (rec.planar and "X" or rec.titan and "T" or "-") .. char(S.moveClass, rec.moveClass)
        .. (rec.infantry and "I" or rec.cavalry and "C" or "-") .. (rec.advanced and "A" or "-") .. (rec.ranged and "M" or "-")
end

-- The original's army type flags (ArmyConfig status flags), by Army.cfg status column.
M.FLAG = {
    race = { H = 0x1, D = 0x2, U = 0x4, E = 0x8, W = 0x10, K = 0x20, B = 0x40, M = 0x80, O = 0x100, R = 0x400, X = 0x800,
             N = 0x1000, C = 0x4000, V = 0x800000, A = 0x2, F = 0x80000, L = 0x1000000 },
    align = { G = 0x2000000, N = 0x4000000, E = 0x8000000 },
    size = { M = 0x10000000, S = 0x20000000, H = 0x40000000, L = 0x80000000 },
    move = { L = 0x400000, A = 0x200000, F = 0x100000 },
}

local function flagsOf(s)
    local bit = require("bit")
    local f = 0
    local F = M.FLAG
    local function add(tbl, ch) if tbl[ch] then f = bit.bor(f, tbl[ch]) end end
    add(F.size, s:sub(1, 1))
    add(F.align, s:sub(2, 2))
    add(F.race, s:sub(3, 3))
    local ex = s:sub(4, 4)
    if ex == "X" then f = bit.bor(f, 0x2000) elseif ex == "T" then f = bit.bor(f, 0x200) end
    add(F.move, s:sub(5, 5))
    local ic = s:sub(6, 6)
    if ic == "I" then f = bit.bor(f, 0x10000) elseif ic == "C" then f = bit.bor(f, 0x20000) end
    if s:sub(7, 7) == "A" then f = bit.bor(f, 0x8000) end
    if s:sub(8, 8) == "M" then f = bit.bor(f, 0x40000) end
    return f
end

---@param rec UnitRecord
---@param kind ContentKind<UnitRecord>
M.derive = function(rec, kind)
    rec.legacyStatus = rec.rawStatus or M.composeStatus(rec)
    rec.statusFlags = flagsOf(rec.legacyStatus)
    rec.tagSet = tagKind.tagSet(rec, kind, kind._R.tag)
    rec._info = {
        index = rec.index, status = rec.legacyStatus, size = char(M.STATUS.size, rec.size), missile = rec.missile,
        missileType = rec.missileType, name = rec.label or "", hero = rec.hero or false, general = rec.general or false,
        maxMana = rec.maxMana, startMana = rec.startMana,
    }
end

return M
