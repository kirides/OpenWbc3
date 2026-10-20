-- Item rules of the engine (docs/data-driven/02-entities.md 2.5): the item classes (the rows of Items.bmp), the tiers and what
-- the power types of Items.xml do. The numbers and mappings are the engine's own, modelled on the original game
-- (FUN_0042a0d0 for the worn slot of a class); the texts are keys into the install's Game.txt.
return {
    ---@param content Content
    define = function(content)
        content.setting:add({ id = "item.tiers", value = { minor = 1, lesser = 2, greater = 3, artifact = 4, set = 5 },
                              doc = "the tier names of Items.xml and their numbers" })
        -- name, row, count, worn slot
        for _, c in ipairs({ { "Sword", 0, 1, 3 }, { "Staff", 1, 1, 3 }, { "Armor", 2, 1, 2 }, { "Necklace", 3, 1, 2 },
                             { "Shield", 4, 1, 4 }, { "Ring", 5, 2, 5 }, { "Crown", 6, 1, 1 }, { "Helm", 7, 1, 1 },
                             { "Banner", 8, 1, 4 }, { "Boots", 9, 1, 7 }, { "Charm", 10, 1, 5 } }) do
            content.itemclass:add({ id = c[1], slot = c[2], count = c[3], worn = c[4] })
        end
        local function power(id, fields)
            fields.id = id
            content.itempower:add(fields)
        end
        for _, p in ipairs({ { "combat", "combat", 1, "0435" }, { "speed", "speed", 1, "0436" }, { "slow", "speed", -1, "0438" },
                             { "armor", "armor", 1, "0452" }, { "resistance", "resistance", 1, "0447" },
                             { "morale", "morale", 1, "0455" }, { "command", "command", 1 },
                             { "speed attack", "attackSpeed", 1, "0437" }, { "slow attack", "attackSpeed", -1, "0439" },
                             { "life regen", "regen", 1, "0463" }, { "mana discount", "manaDiscount", 1, "0458" }, { "vampirism", "vampirism", 1, "0460" },
                             { "critical hit", "critical", 1, "0461" }, { "assassin", "assassin", 1, "0459" } }) do
            power(p[1], { stat = p[2], sign = p[3], text = p[4] })
        end
        for _, p in ipairs({ { "slashing", "0440" }, { "crushing", "0441" }, { "piercing", "0442" }, { "fire", "0443" },
                             { "ice", "0444" }, { "electricity", "0445" }, { "magic", "0446" } }) do
            power(p[1], { damageType = p[1], text = p[2] })
        end
        for _, p in ipairs({ { "fire resistance", "fire", "0448" }, { "cold resistance", "ice", "0449" },
                             { "electricity resistance", "electricity", "0450" }, { "magic resistance", "magic", "0451" } }) do
            power(p[1], { resist = p[2], text = p[3] })
        end
        power("hero skill", { skill = true })
        -- described from templates only (the hero code reads them elsewhere)
        for _, p in ipairs({ { "spell casting", "0453" }, { "spell range", "0457" }, { "mana regen", "0462" } }) do
            power(p[1], { text = p[2] })
        end
    end,
}
