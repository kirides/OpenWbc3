-- The damage types of the original's type records (docs/data-driven/03-spells-effects.md 3.5): 0 piercing, 1 ice, 2 electricity, 3 fire,
-- 4 magic, 5 crushing, 6 slashing (checked against the data: Frost Dragon 1, Storm Dragon 2, Fire Elemental 3). 1..4 are the elemental
-- ones (resistances from items apply to them). The spells and status effects number them differently (fire 1, ice 2, electricity 3):
-- `spellSlot` is that number. `classes` are the armour classes ("strong" / "weak" of a type record) a damage type belongs to besides its
-- own number: 7 all physical (pierce, crush, slash), 8 pierce + slash, 9 the first three elements, 10 everything.
-- A critical hit applies the type's special attack (unit.lua `strike`): piercing ignores armour, ice freezes for 8 s, electricity drains
-- mana, fire immolates, magic dispels, crushing stuns, slashing cleaves.
return {
    ---@param content Content
    define = function(content)
        for _, t in ipairs({
            { "piercing", 0, nil, 0, { 7, 8, 10 } }, { "ice", 1, "ice", 2, { 9, 10 } }, { "electricity", 2, "electricity", 3, { 9, 10 } },
            { "fire", 3, "fire", 1, { 9, 10 } }, { "magic", 4, "magic", 4, { 10 } }, { "crushing", 5, nil, 5, { 7, 10 } },
            { "slashing", 6, nil, 6, { 7, 8, 10 } },
        }) do
            local classes = {}
            for _, c in ipairs(t[5]) do classes[c] = true end
            content.damagetype:add({ id = t[1], slot = t[2], element = t[3], spellSlot = t[4], classes = classes })
        end
    end,
}
