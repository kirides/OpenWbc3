-- The computer player's levels (docs/data-driven/04-heroes-abilities-rules.md 4.3) and its group size defaults. The numbers are the original's
-- (aiplan.lua: binary FUN_004ffab0 / FUN_004ffee0 / FUN_004fc9a0 for the rates; aigroups.lua, aibase.lua for the rest); fields of a level not
-- listed (Passive, Barbarian) take the defaults of the code that reads them.
local NAMES = { [0] = "passive", "knave", "knight", "lord", "prince", "warlord", "emperor", "barbarian" }

-- by level 1..6
local RATES = {
    army = { 10, 30, 50, 90, 150, 210 },
    powerup = { 10, 20, 40, 60, 100, 150 },
    armyResearch = { 15, 35, 70, 140, 280, 560 },
    powerupResearch = { 10, 35, 70, 140, 280, 560 },
    production = { 10, 30, 60, 120, 240, 480 },
    defence = { 0, 35, 70, 140, 280, 560 },
    builder = { 10, 30, 60, 85, 120, 150 },
}
local INCOME_CAP = { 20, 30, 40, 70, 100, -1 }
local BUILDINGS_FACTOR = { 40, 60, 100, 140, 180, 250 }
local SIZE_FACTOR = { 40, 60, 80, 100, 130, 160 }
local SIDE_CHANGE = { 0, 25, 50, 80, 90, 100 }
local DAMAGE_SHIFT = { 4, 8, 16, 32, 64, 256 }
local TOWER_LIMIT = { 3, 7, 13, 20, 30, 45 }
-- by level 0..7
local HUMAN_BIAS = { [0] = 0, -5, -5, 20, 40, 75, 250, 50 }
local AI_BIAS = { [0] = 0, 25, 15, -15, -30, -60, -125, -5 }

return {
    ---@param content Content
    define = function(content)
        for level = 0, 7 do
            local rec = { id = NAMES[level], slot = level, humanBias = HUMAN_BIAS[level], aiBias = AI_BIAS[level] }
            if level >= 1 and level <= 6 then
                rec.rates = {}
                for key, row in pairs(RATES) do rec.rates[key] = row[level] end
                rec.incomeCap, rec.buildingsFactor, rec.sizeFactor = INCOME_CAP[level], BUILDINGS_FACTOR[level], SIZE_FACTOR[level]
                rec.sideChange, rec.damageShift, rec.towerLimit = SIDE_CHANGE[level], DAMAGE_SHIFT[level], TOWER_LIMIT[level]
            end
            content.aiprofile:add(rec)
        end
        -- the group sizes of a script without its own, by group type 0..5 (normal, long range, mine killer, kick-ass, large, generals)
        content.setting:add({ id = "ai.groupMin", value = { [0] = 10, 4, 6, 7, 15, 6 }, doc = "smallest group size by group type" })
        content.setting:add({ id = "ai.groupMax", value = { [0] = 12, 5, 8, 10, 17, 9 }, doc = "largest group size by group type" })
    end,
}
