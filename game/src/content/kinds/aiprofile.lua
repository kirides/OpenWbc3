-- Content kind `aiprofile` (stage 4, docs/data-driven/04-heroes-abilities-rules.md 4.3): what differs between the computer player's levels
-- (the original's AI levels: 0 Passive, 1 Knave ... 6 Emperor, 7 Barbarian, the one the neutral side plays). Key: the level's name, `slot` is the level number
-- that a side stores in `aiLevel`. A field that a profile does not have takes the engine's default of the code that reads it (levels 0 and 7
-- have no economy). The numbers are the original's (the binary functions are named where the engine reads them: aiplan.lua, aigroups.lua,
-- aibase.lua).
--   rates            share of the income each kind of resource list entry may take, in percent, by `army`, `powerup`, `armyResearch`,
--                    `powerupResearch`, `production`, `defence`, `builder` (default 60)
--   incomeCap        most mine points the AI counts as income (-1: no cap; default 35)
--   buildingsFactor  scales how many buildings it wants (default 120)
--   sizeFactor       group sizes in percent of the script's (default 50), sideChange the chance in percent that a group picks another
--                    side than the main enemy (default 0)
--   humanBias, aiBias, damageShift   the choice of the main enemy: bias for a human / computer side, damage taken is divided by damageShift
--   towerLimit       most towers it builds (default 13)

---@class AiProfileRecord
---@field id string
---@field slot integer                  the AI level (Side.aiLevel)
---@field rates table<string, integer>? percent of the income by resource list entry kind
---@field incomeCap integer?
---@field buildingsFactor integer?
---@field sizeFactor integer?
---@field sideChange integer?
---@field humanBias integer?
---@field aiBias integer?
---@field damageShift integer?
---@field towerLimit integer?

return {
    name = "aiprofile",
    doc = "computer player levels",
    slotted = true,
    validate = function(rec)
        if type(rec.slot) ~= "number" then return "needs the level number as slot" end
    end,
}
