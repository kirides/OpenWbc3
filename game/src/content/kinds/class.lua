-- Content kind `class` (stage 4, docs/data-driven/04-heroes-abilities-rules.md 4.1): the hero classes. Key: the class name; `slot` is the class
-- number, `broad` the group of the class picker; `attrMod`, `life`, `lifePerLevel`, `armor`, `mana` and the five `skills` { id, availableAt,
-- startLevel } follow content/base/classes.lua.

---@class ClassRecord
---@field id string                     the class name the profile files store
---@field slot integer                  the class number
---@field broad integer                 the group of the class picker 1..4
---@field attrMod integer[]             { str, dex, int, cha }
---@field life integer
---@field lifePerLevel integer
---@field armor integer
---@field mana integer
---@field skills integer[][]            five { skill id, available at level, start level }

return {
    name = "class",
    doc = "hero classes",
    slotted = true,
}
