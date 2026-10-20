-- A sphere is a slot (the next free one, 13), the hero skill that is its casting skill (a mod picks a skill id of its own) and some looks.
content.sphere:add({ id = "new_spell:chronomancy", slot = 13, skill = 150, name = "Chronomancy", researchName = "Chronomancy Spell",
                     colour = { 0.9, 0.8, 1 }, icon = 12 })

-- A recipe: a list of steps (docs/modding/effects.md). Hasten speeds the hero up for a minute and draws a light ring.
content.spell:add({
    id = "new_spell:hasten", slot = 130, sphere = "new_spell:chronomancy", index = 0, cost = 6, ai = "buff", name = "Hasten",
    effect = {
        { status = { id = "speed", who = "self", seconds = { duration = "normal" }, value = { base = 2, perLevel = 1 } } },
        { aura = { key = "light", radius = 2 } },
    },
})

-- A function: anything the effect library `fx` offers. Mend Time heals the hero and its allies and cures them.
content.spell:add({
    id = "new_spell:mend", slot = 131, sphere = "new_spell:chronomancy", index = 1, cost = 12, ai = "heal", name = "Mend Time",
    effect = function(c)
        local amount = fx.emp(c, 40 * c.lvl)
        fx.each(c, "ally", c.r, function(o)
            fx.heal(c, o, amount)
        end)
        fx.aura(c, "heal")
    end,
})
