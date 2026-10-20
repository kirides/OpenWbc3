-- Content kind `building` (stage 2, docs/data-driven/02-entities.md 2.2): building types. Key: the 4-letter code.
-- The record is the .BUI stat block (formats/types.lua field names) plus the typed [BUILDINGS] columns of Building.cfg:
--   index, label, level, dataLevel, resource (letter of the mine's resource or nil), missile, missileType,
--   armyLimit, garrison (places), searchable, lair, shop (booleans)
--   races, stopDefeat, armies, build   sets { [raceId] = true } (the CACHE / stop-defeat / armies / build columns)
--   fileId, missingStats               as for units
--   tags = { ids }   traits (kinds/tag.lua)
-- Derived (not hashed): tagSet and _info, the old `rules.building` table shape with the sets keyed by race number.
local tagKind = require("src.content.kinds.tag")

-- An entry of a production list: what a building makes and the level it needs.
---@class ProductionEntry
---@field id string
---@field level string

---@class BuildingRecord: BuiRecord, TypeRecord
---@field level integer
---@field dataLevel integer
---@field resource string?              the resource letter of a mine
---@field armyLimit integer
---@field garrison integer
---@field searchable boolean
---@field lair boolean
---@field shop boolean
---@field stopDefeat table<string, boolean>
---@field armies table<string, boolean>
---@field build table<string, boolean>
---@field produces table<string, ProductionEntry[]>?   race id (or "*" for every race without a line) -> what it makes

return {
    name = "building",
    doc = "building types",
    derived = { "tagSet" },
    refs = { { field = "tags", target = "tag", mode = "list" } },
    ---@param rec BuildingRecord
    ---@param kind ContentKind<BuildingRecord>
    derive = function(rec, kind)
        local R = kind._R
        rec.tagSet = tagKind.tagSet(rec, kind, R.tag)
        local function bySlot(set)
            local m = {}
            for r = 0, 15 do m[r] = false end
            for id in pairs(set or {}) do
                local race = R.race[id]
                if race then m[race.slot] = true end
            end
            return m
        end
        rec._info = {
            code = rec.id, index = rec.index, level = rec.level or 0, dataLevel = rec.dataLevel or 0, resource = rec.resource,
            missile = rec.missile, missileType = rec.missileType, cache = bySlot(rec.races), stopDefeat = bySlot(rec.stopDefeat),
            armies = bySlot(rec.armies), build = bySlot(rec.build), armyLimit = rec.armyLimit or 0, garrison = rec.garrison or 0,
            searchable = rec.searchable or false, lair = rec.lair or false, shop = rec.shop or false, name = rec.label or "",
        }
    end,
}
