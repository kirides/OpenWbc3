-- Content kind `powerup` (stage 2, docs/data-driven/02-entities.md 2.3): permanent upgrades a side researches in its
-- buildings (codes starting with P, and the elven runes R...). Key: the 4-letter code.
--   cost = { gold, metal, crystal, stone }, time (research seconds)
--   bonus = { { stat = "combat"|"armor"|"speed"|"damage"|"range"|"resistance", amount = n,
--               units = { ids } | flags = mask [, without = true] } ... }   statistic bonuses for the army types
--   requires, priority, byRace   from Building.cfg, like units (see import/wbc3/rules.lua)
-- The behaviour of a power-up is coded in game/powerups.lua until the effect records of stage 2.3 replace it.
---@class PowerupBonus
---@field stat string
---@field amount integer
---@field units string[]?
---@field flags integer?
---@field without boolean?

---@class PowerupRecord: TechRecord
---@field time integer                  research seconds
---@field bonus PowerupBonus[]?
---@field view integer?                 cells of view it adds
---@field oneShot boolean?
---@field research integer?             casting levels for a random sphere
---@field mercenaries string[]?
---@field runeSkill integer?
---@field questFoes string[][]?         { unit, race id? }

return {
    name = "powerup",
    doc = "power-ups",
    ---@param rec PowerupRecord
    validate = function(rec)
        if type(rec.cost) ~= "table" or type(rec.time) ~= "number" then return "needs cost and time" end
    end,
}
