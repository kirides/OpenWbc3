-- Importer: building types of the install -> `building` records (docs/data-driven/02-entities.md 2.2): the .BUI stat
-- block plus the typed columns of Building.cfg [BUILDINGS] (see kinds/building.lua). A [BUILDINGS] row without a .BUI
-- file gets a stub flagged `missingStats`.
local types = require("src.formats.types")
local cfg = require("src.import.wbc3.cfg")

---@param content Content
return function(content)
    -- a 16-column race mask -> { [raceId] = true }
    local function mask(text)
        local set = {}
        for _, race in ipairs(content.race:all()) do
            if race.slot <= 15 then
                local c = text:sub(race.slot + 1, race.slot + 1)
                if c ~= "-" and c ~= "" then set[race.id] = true end
            end
        end
        return set
    end
    local last, order = {}, {}
    for _, row in ipairs(cfg.building().buildings) do
        if not last[row.code] then order[#order + 1] = row.code end
        last[row.code] = row
    end
    for _, code in ipairs(order) do
        local row = last[code]
        do
            local data = cfg.lookup(code, ".bui")
            local rec = (data and types.parseBuilding(data) or { missingStats = true }) --[[@as BuildingRecord]]
            if rec.id and rec.id ~= code then rec.fileId = rec.id end
            rec.id = code
            rec.index, rec.label, rec.level, rec.dataLevel = row.index, row.label, row.level, row.dataLevel
            rec.resource = row.resource ~= "-" and row.resource or nil
            rec.missile = row.missile ~= "----" and row.missile or nil
            rec.missileType = row.missileType
            rec.races, rec.stopDefeat, rec.armies, rec.build = mask(row.cache), mask(row.stopDefeat), mask(row.armies), mask(row.build)
            rec.armyLimit, rec.garrison = row.armyLimit, row.garrison
            rec.searchable, rec.lair, rec.shop = row.searchable ~= "-", row.lair ~= "-", row.shop ~= "-"
            content.building:add(rec)
        end
    end
end
