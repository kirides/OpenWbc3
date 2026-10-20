-- Game rule data: unit and building type records (the content registry, docs/data-driven) and the helpers around them.
local content = require("src.content")

---@class GameData
---@field STEP_TIME table<integer, number> ms per walk step by speed value (the setting `unit.stepTime`)
local M = {}

-- The races' plural names by race number (the engine's own English list, for messages).
M.RACES = content.race:view("plural")
M.COLORS = { [0] = { 0.85, 0.15, 0.1 }, { 0.2, 0.35, 0.95 }, { 0.15, 0.75, 0.15 }, { 0.7, 0.2, 0.75 },
             { 0.2, 0.2, 0.2 }, { 0.95, 0.85, 0.3 }, { 0.6, 0.6, 0.6 }, { 0.95, 0.95, 0.2 } }

-- The type record of an army / hero code (the .ARM stat block plus the typed Army.cfg columns), or nil.
local units, buildings = content.unit, content.building
---@param code string
---@return UnitRecord? rec the content `unit` record
function M.army(code)
    return units._recs[code] or (type(code) == "string" and units._recs[code:upper()]) or nil
end

-- The type record of a building code (the .BUI stat block plus the typed Building.cfg columns), or nil.
---@param code string
---@return BuildingRecord? rec the content `building` record
function M.building(code)
    return buildings._recs[code] or (type(code) == "string" and buildings._recs[code:upper()]) or nil
end

local NO_TAGS = {}

-- The set of tags (id -> true) of a unit or building code; empty for an unknown code. Tags are the data form of the
-- engine's code sets ("is this a dragon / critter / temple?"); see content/base/tags.lua.
---@param code string
---@return table<string, boolean>
function M.tags(code)
    local t = units._recs[code] or buildings._recs[code]
    return t and t.tagSet or NO_TAGS
end

-- Whether the unit or building `code` has the tag.
---@param code string
---@param tag string
---@return boolean
function M.hasTag(code, tag)
    return M.tags(code)[tag] == true
end

-- The race towers: every race has one BWT<letter> type (`towerLetter` of the race record). The original re-picks the code
-- of every tower and wall it is handed a side for (the building placement FUN_004a50f0), so the ones a scenario or
-- the editor places are only placeholders for the owning side's race. Walls come in a good / neutral / evil set (BWG, BWN,
-- BWE) that the race decides (`wallSet`); the orc totem BWTP is not a race tower and the Guardian buildings BWGC / BWGS /
-- BWGI are not walls, so both keep their code.
local WALL_SET = { good = "G", neutral = "N", evil = "E" }

-- Whether `code` is one of the race towers.
---@param code string
---@return boolean
function M.isRaceTower(code)
    if code:sub(1, 3) ~= "BWT" then return false end
    return content.race:byTowerLetter(code:sub(4, 4)) ~= nil
end

-- The code a side of race `race` really gets for a placed tower / wall code; anything else is unchanged.
---@param code string
---@param race integer?
---@return string
function M.raceVariant(code, race)
    local rec = race and content.race:bySlot(race)
    if not rec then return code end
    if M.isRaceTower(code) then
        return "BWT" .. rec.towerLetter
    elseif code:sub(1, 2) == "BW" and code:sub(3, 3):match("[GNE]") and code:sub(4, 4):match("[012]") then
        return "BW" .. WALL_SET[rec.wallSet] .. code:sub(4, 4)
    end
    return code
end

-- The "Tough Towers" game mod changes the 16 tower type records (FUN_0041a8c0 of the 1.04 binary, on the building type
-- table at 0x00697778): damage x3, range +4, combat x3/2, hits x3/2, speed +1. Returns a modified copy (cached) for a tower
-- code and the record itself for anything else.
---@type table<BuildingRecord, BuildingRecord>
local tough = setmetatable({}, { __mode = "k" })     -- by type record
---@param code string
---@return BuildingRecord? rec
function M.toughBuilding(code)
    local t = M.building(code)
    if not t or not M.isRaceTower(code) then return t end
    if not tough[t] then
        local c = {}
        for k, v in pairs(t) do c[k] = v end
        c.damage = (t.damage or 0) * 3
        c.range = (t.range or 0) + 4
        c.combat = math.floor((t.combat or 0) * 3 / 2)
        c.hits = math.floor((t.hits or 0) * 3 / 2)
        c.speed = (t.speed or 0) + 1
        tough[t] = c
    end
    return tough[t]
end

-- Time for one walk step (one cell) by speed value 0..30, in ms (the setting `unit.stepTime`).
content.onReady(function() M.STEP_TIME = content.setting:value("unit.stepTime") end)

return M
