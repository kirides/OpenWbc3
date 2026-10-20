-- Importer: army and hero types of the install -> `unit` records (docs/data-driven/02-entities.md 2.2).
-- The stat block comes from the .ARM file (PatchData.xcr overrides the side archives), the typed flags from the
-- Army.cfg row of the same code. Field names of the .ARM record are unchanged (formats/types.lua); the cfg columns
-- become typed fields:
--   index        the type's index in the global table (scenario files store it)
--   label        the name column of Army.cfg (the .ARM record's own `name` stays as it is)
--   hero, general, maxMana, startMana
--   size "small|medium|large|huge", alignment "good|neutral|evil", raceClass (the race-letter column: H D U E W K B ...
--   V daemon, A dark dwarf, N dragon, X monster, C mechanical ...), planar, titan, moveClass "land|air|float",
--   infantry, cavalry, advanced, ranged
--   missile (missile code of the shoot column), missileType (its first character)
--   races  set of race ids that have the unit (the cache columns)
-- Codes of Army.cfg without a .ARM file get a stub flagged `missingStats`.
local types = require("src.formats.types")
local cfg = require("src.import.wbc3.cfg")

local M = {}

---@param content Content
function M.run(content)
    local unit = content.unit
    local STATUS = unit.def.STATUS
    local function add(row)
        local code = row.code
        local data = cfg.lookup(code, ".arm")
        local rec = (data and types.parseArmy(data) or { missingStats = true }) --[[@as UnitRecord]]
        if rec.id and rec.id ~= code then rec.fileId = rec.id end
        rec.id = code
        local s = row.status
        rec.index, rec.label, rec.hero, rec.general = row.index, row.label, row.hero, row.general
        rec.size, rec.alignment = STATUS.size[s:sub(1, 1)], STATUS.alignment[s:sub(2, 2)]
        rec.raceClass = s:sub(3, 3) ~= "-" and s:sub(3, 3) or nil
        rec.planar, rec.titan = s:sub(4, 4) == "X", s:sub(4, 4) == "T"
        rec.moveClass = STATUS.moveClass[s:sub(5, 5)]
        rec.infantry, rec.cavalry = s:sub(6, 6) == "I", s:sub(6, 6) == "C"
        rec.advanced, rec.ranged = s:sub(7, 7) == "A", s:sub(8, 8) == "M"
        rec.missile = row.shoot:match("^%a:(%w%w%w%w)$")
        rec.missileType = row.shoot:sub(1, 1)
        -- MANA column "max:start" ("---:---" when the unit has none); the Army.cfg reader FUN_00584810 scans it with "%3d:%3d"
        local maxMana, startMana = row.mana:match("^(%d+):(%d+)$")
        rec.maxMana, rec.startMana = maxMana and tonumber(maxMana) or nil, startMana and tonumber(startMana) or nil
        rec.races = {}
        for _, race in ipairs(content.race:all()) do
            if race.slot <= 15 and row.cache:sub(race.slot + 1, race.slot + 1) ~= "-" then rec.races[race.id] = true end
        end
        -- the status string is rebuilt from the typed fields (kinds/unit.lua); anything it cannot express is kept
        if content.unit.def.composeStatus(rec) ~= s then rec.rawStatus = s end
        unit:add(rec)
    end
    -- a code listed twice keeps the later row's columns, at the position of the first (the original's table does the same)
    local last, order = {}, {}
    for _, row in ipairs(cfg.army().rows) do
        if not last[row.code] then order[#order + 1] = row.code end
        last[row.code] = row
    end
    for _, code in ipairs(order) do add(last[code]) end
end

return M.run
