-- Content kind `sphere` (stage 3, docs/data-driven/03-spells-effects.md 3.2): the spell spheres. Key: a short name ("healing" ...).
--   slot    the sphere number (spells of the sphere are slot * 10 + index; a hero's casting skill of the sphere is its `skill`)
--   skill   the hero skill id that is the casting skill of the sphere (10 + slot for the original spheres)
--   name    the English name the engine falls back to (the displayed names come from <Lang>/Spells.txt)
--   colour  { r, g, b } of the sphere's spell bar slots;  icon  its cell in the spell book's icon sheet (default: the last one)
--   researchName   the name the research messages use ("Healing Spell")
-- Sphere slots must be contiguous from 0 (the spell book pages walk 0 .. count - 1).
---@class SphereRecord
---@field id string
---@field slot integer
---@field skill integer
---@field name string
---@field colour number[]
---@field icon integer?
---@field researchName string?

return {
    name = "sphere",
    doc = "spell spheres",
    slotted = true,
    sortBy = "slot",
    ---@param rec SphereRecord
    validate = function(rec)
        if type(rec.slot) ~= "number" or rec.slot < 0 then return "needs a slot >= 0" end
        if type(rec.skill) ~= "number" then return "needs the hero skill id of its casting skill" end
    end,
}
