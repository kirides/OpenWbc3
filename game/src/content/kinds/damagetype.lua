-- Content kind `damagetype` (stage 3, docs/data-driven/03-spells-effects.md 3.5): the damage types of the type records. Key: "piercing",
-- "ice", "electricity", "fire", "magic", "crushing", "slashing".
--   slot        the number the .ARM / .BUI records and the strong / weak columns use (0 .. 6)
--   spellSlot   the number spells and status effects use for it (fire 1, ice 2, electricity 3)
--   element     "ice" | "electricity" | "fire" | "magic": the element hero resistances apply to
--   classes     set of armour classes the type belongs to besides its own number: 7 physical, 8 pierce + slash, 9 elements, 10 all

---@class DamageTypeRecord
---@field id string
---@field slot integer
---@field spellSlot integer
---@field element string?
---@field classes table<integer, boolean>

return {
    name = "damagetype",
    doc = "damage types",
    slotted = true,
}
