-- Content kind `itempower` (stage 2, docs/data-driven/02-entities.md 2.5): what the power types of Items.xml mean. Key: the type
-- name of the file (<Power type="...">). Item bonuses (items.bonuses) and descriptions (items.powerLines) are driven by these:
--   stat         the bonus field that `data` is added to (combat, speed, armor, resistance, morale, command, attackSpeed, regen,
--                vampirism, critical, assassin, manaDiscount); `sign` -1 subtracts ("slow", "slow attack")
--   damageType   a damage power: counts for the weapon slot's item only, its first three powers, and names the hero's damage type
--   resist       the element a resistance power adds to
--   skill        true: `data` is a hero skill, the power's level the levels it adds
--   text         the key of the description template in Game.txt (localised, "%+d" formats); none: no line from a template
-- Types without a record (and "cast spell", which spells.itemCast fires) add nothing to the bonus table.
---@class ItemPowerRecord
---@field id string
---@field stat string?
---@field sign integer?
---@field damageType string?
---@field resist string?
---@field skill boolean?
---@field text string?

return {
    name = "itempower",
    doc = "item power types",
}
