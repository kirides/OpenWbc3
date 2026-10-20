-- Importer: the race rules of Building.cfg (docs/data-driven/02-entities.md 2.4) onto the records:
--   race.build            [CONSTRUCTION]: { { id, level, row } ... } what a race can construct, in file order
--   building.produces     [PRODUCTION]: { ["*"] = list, [raceId] = list } what the building makes ("*" is the first
--                         line of the code, used for every race without a line of its own); entries { id, level }
--   <thing>.requires      { [raceId] = { ids } } the buildings / runes needed ([PRODUCTION] right part, else
--                         [DEPENDENCIES]); <thing> is the unit, building or power-up the line is about
--   <thing>.priority      { [raceId] = n } the computer players' wish for it ([DEPENDENCIES] last column)
--   <thing>.byRace        { [raceId] = { gold, metal, stone, crystal, time, combat, hits, speed, resistance, damage,
--                         range } } the [RULES] per-race overrides (absent column = unchanged)
-- A line about a code without a record is dropped with a warning.
local cfg = require("src.import.wbc3.cfg")

local function list(items)
    local out = {}
    for i, it in ipairs(items) do
        out[i] = { id = it.code, level = it.level, row = it.row }
    end
    return out
end

---@param content Content
return function(content)
    local data = cfg.building()
    local function race(letter) return content.race:byLetter(letter) end
    local missing = {}
    local function thing(code)
        local rec = content.thing(code)
        if not rec and not missing[code] then
            missing[code] = true
            content.warn("Building.cfg mentions %s, which has no record", code)
        end
        return rec
    end

    for _, row in ipairs(data.construction) do
        local r = race(row.letter)
        if r then
            r.build = r.build or {}
            for _, it in ipairs(list(row.items)) do r.build[#r.build + 1] = it end
        end
    end

    for _, row in ipairs(data.production) do
        local r, b = race(row.letter), content.building[row.code]
        if r and b then
            b.produces = b.produces or {}
            local items = {}
            for i, it in ipairs(row.items) do items[i] = { id = it.code, level = it.level } end
            b.produces[r.id] = items
            if b.produces["*"] == nil then b.produces["*"] = items end
            if #row.requires > 0 then
                b.requires = b.requires or {}
                b.requires[r.id] = row.requires
            end
        elseif r and not missing[row.code] then
            missing[row.code] = true
            content.warn("Building.cfg [PRODUCTION] mentions %s, which is no building", row.code)
        end
    end

    for _, row in ipairs(data.dependencies) do
        local r, t = race(row.letter), nil
        if r then t = thing(row.code) end
        if r and t then
            t.requires = t.requires or {}
            if not t.requires[r.id] then t.requires[r.id] = row.requires end
            t.priority = t.priority or {}
            t.priority[r.id] = row.priority
        end
    end

    for _, row in ipairs(data.rules) do
        local r = race(row.letter)
        local t = r and thing(row.code)
        if t then
            t.byRace = t.byRace or {}
            t.byRace[r.id] = row.values
        end
    end
end
