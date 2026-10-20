-- Content kind `skill` (stage 4, docs/data-driven/04-heroes-abilities-rules.md 4.1): the hero skills. Key: the skill's name; `slot` is the
-- number heroes, profiles and saves store. `mul` (default 1) and `base` give the effect at a level (mul * level + base), `help` is the
-- Game.txt template of the help line. The rules that read a skill ask `heroskills.value(world, side, heroskills.ids.<Name>)`.
---@class SkillRecord
---@field id string
---@field slot integer
---@field mul number?
---@field base number?
---@field help integer?

return {
    name = "skill",
    doc = "hero skills",
    slotted = true,
}
