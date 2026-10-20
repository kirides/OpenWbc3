-- The 28 hero classes of the original (docs/data-driven/04-heroes-abilities-rules.md 4.1), in the original's class number order, and
-- the four broad groups of the class picker (openwbc3's own). Record:
--   id        the class name (the English name the profile files store)
--   slot      the class number (0..27)
--   broad     the broad group 1..4 (Warrior, Thief, Priest, Wizard)
--   attrMod   attribute modifiers { str, dex, int, cha } (starting attributes = 5 + race modifier + class modifier; the original's
--             hero creation as seen in the game, not yet cross-checked against the binary)
--   life, lifePerLevel, armor, mana   base life, life per level, base armour and base mana of the class (read from the binary's tables)
--   skills    the five class skills of a hero: { skill id, available at level, start level } (the skill list builder FUN_0054c620 in the binary); skill 0 = none
return {
    ---@param content Content
    define = function(content)
        content.setting:add({ id = "hero.broad", own = true, doc = "the four broad groups of the class picker (openwbc3's own)",
            value = {
                { name = "Warrior", blurb = "Strong fighters" },
                { name = "Thief", blurb = "Quick and cunning" },
                { name = "Priest", blurb = "Healers and leaders" },
                { name = "Wizard", blurb = "Masters of magic" },
            } })
        local list = {
            { id = "Warrior", slot = 0, broad = 1, attrMod = { 2, 0, -2, 0 }, life = 240, lifePerLevel = 4, armor = 10, mana = 5,
              skills = { { 1, 1, 3 }, { 2, 1, 0 }, { 3, 5, 0 }, { 33, 15, 0 }, { 42, 25, 0 } } },
            { id = "Chieftain", slot = 1, broad = 1, attrMod = { 2, 1, -3, 0 }, life = 240, lifePerLevel = 3, armor = 5, mana = 5,
              skills = { { 1, 1, 1 }, { 83, 1, 1 }, { 8, 5, 0 }, { 48, 15, 0 }, { 34, 25, 0 } } },
            { id = "Ranger", slot = 2, broad = 1, attrMod = { 2, 1, -1, -2 }, life = 220, lifePerLevel = 3, armor = 5, mana = 10,
              skills = { { 41, 1, 1 }, { 4, 1, 1 }, { 12, 5, 0 }, { 100, 15, 0 }, { 84, 25, 0 } } },
            { id = "Deathknight", slot = 3, broad = 1, attrMod = { 2, -1, 1, -2 }, life = 220, lifePerLevel = 3, armor = 10, mana = 10,
              skills = { { 1, 1, 1 }, { 35, 1, 1 }, { 19, 5, 0 }, { 14, 15, 0 }, { 43, 25, 0 } } },
            { id = "Dragonslayer", slot = 4, broad = 1, attrMod = { 2, -2, 0, 0 }, life = 240, lifePerLevel = 3, armor = 10, mana = 5,
              skills = { { 37, 1, 1 }, { 1, 1, 1 }, { 27, 5, 0 }, { 28, 15, 0 }, { 55, 25, 0 } } },
            { id = "Daemonslayer", slot = 5, broad = 1, attrMod = { 2, -2, 1, -1 }, life = 240, lifePerLevel = 3, armor = 10, mana = 5,
              skills = { { 38, 1, 1 }, { 1, 1, 1 }, { 24, 5, 0 }, { 57, 15, 0 }, { 11, 25, 0 } } },
            { id = "Thief", slot = 6, broad = 2, attrMod = { -1, 2, 0, -1 }, life = 200, lifePerLevel = 3, armor = 5, mana = 5,
              skills = { { 4, 1, 3 }, { 0, 1, 0 }, { 24, 5, 0 }, { 25, 15, 0 }, { 13, 25, 0 } } },
            { id = "Assassin", slot = 7, broad = 2, attrMod = { 1, 2, 0, -3 }, life = 200, lifePerLevel = 3, armor = 5, mana = 5,
              skills = { { 51, 1, 3 }, { 0, 1, 0 }, { 54, 5, 0 }, { 55, 15, 0 }, { 42, 25, 0 } } },
            { id = "Bard", slot = 8, broad = 2, attrMod = { -2, 2, -1, 1 }, life = 200, lifePerLevel = 3, armor = 5, mana = 10,
              skills = { { 8, 1, 3 }, { 0, 1, 0 }, { 55, 5, 0 }, { 21, 15, 0 }, { 26, 25, 0 } } },
            { id = "Merchant", slot = 9, broad = 2, attrMod = { -2, 2, 0, 0 }, life = 200, lifePerLevel = 3, armor = 0, mana = 5,
              skills = { { 9, 1, 3 }, { 0, 1, 0 }, { 55, 5, 0 }, { 59, 15, 0 }, { 58, 25, 0 } } },
            { id = "Priest", slot = 10, broad = 3, attrMod = { -1, -1, 1, 1 }, life = 180, lifePerLevel = 2, armor = 0, mana = 20,
              skills = { { 10, 1, 1 }, { 7, 1, 1 }, { 21, 5, 0 }, { 5, 15, 0 }, { 25, 25, 0 } } },
            { id = "Tinker", slot = 11, broad = 3, attrMod = { 0, 0, 0, 0 }, life = 180, lifePerLevel = 2, armor = 0, mana = 10,
              skills = { { 66, 1, 3 }, { 0, 1, 0 }, { 16, 5, 0 }, { 57, 15, 0 }, { 56, 25, 0 } } },
            { id = "Paladin", slot = 12, broad = 3, attrMod = { 1, -2, -1, 2 }, life = 200, lifePerLevel = 3, armor = 10, mana = 10,
              skills = { { 36, 1, 1 }, { 1, 1, 1 }, { 10, 5, 0 }, { 88, 15, 0 }, { 44, 25, 0 } } },
            { id = "Healer", slot = 13, broad = 3, attrMod = { -2, -1, 1, 2 }, life = 160, lifePerLevel = 2, armor = 0, mana = 20,
              skills = { { 10, 1, 3 }, { 7, 1, 0 }, { 60, 5, 0 }, { 24, 15, 0 }, { 3, 25, 0 } } },
            { id = "Druid", slot = 14, broad = 3, attrMod = { -2, 1, -1, 2 }, life = 160, lifePerLevel = 1, armor = 5, mana = 20,
              skills = { { 12, 1, 3 }, { 7, 1, 0 }, { 89, 5, 0 }, { 91, 15, 0 }, { 22, 25, 0 } } },
            { id = "Runemaster", slot = 15, broad = 3, attrMod = { 1, -3, 0, 2 }, life = 160, lifePerLevel = 2, armor = 5, mana = 20,
              skills = { { 17, 1, 3 }, { 7, 1, 0 }, { 90, 5, 0 }, { 56, 15, 0 }, { 22, 25, 0 } } },
            { id = "Shaman", slot = 16, broad = 3, attrMod = { -1, -1, 0, 2 }, life = 160, lifePerLevel = 2, armor = 0, mana = 20,
              skills = { { 19, 1, 3 }, { 7, 1, 0 }, { 24, 5, 0 }, { 25, 15, 0 }, { 22, 25, 0 } } },
            { id = "Elementalist", slot = 17, broad = 4, attrMod = { 0, -2, 0, 2 }, life = 160, lifePerLevel = 2, armor = 0, mana = 20,
              skills = { { 15, 1, 1 }, { 18, 1, 1 }, { 17, 5, 0 }, { 5, 15, 0 }, { 26, 25, 0 } } },
            { id = "Defiler", slot = 18, broad = 4, attrMod = { -1, 1, 2, -2 }, life = 160, lifePerLevel = 1, armor = 0, mana = 20,
              skills = { { 20, 1, 3 }, { 7, 1, 0 }, { 98, 5, 0 }, { 97, 15, 0 }, { 22, 25, 0 } } },
            { id = "Archmage", slot = 19, broad = 4, attrMod = { -2, 0, 2, 0 }, life = 150, lifePerLevel = 1, armor = 0, mana = 20,
              skills = { { 11, 1, 1 }, { 16, 1, 1 }, { 21, 5, 0 }, { 13, 15, 0 }, { 25, 25, 0 } } },
            { id = "Necromancer", slot = 20, broad = 4, attrMod = { 0, 0, 2, -2 }, life = 160, lifePerLevel = 1, armor = 0, mana = 20,
              skills = { { 14, 1, 3 }, { 7, 1, 0 }, { 93, 5, 0 }, { 85, 15, 0 }, { 22, 25, 0 } } },
            { id = "Pyromancer", slot = 21, broad = 4, attrMod = { 1, -2, 2, -1 }, life = 160, lifePerLevel = 1, armor = 0, mana = 20,
              skills = { { 15, 1, 3 }, { 7, 1, 0 }, { 27, 5, 0 }, { 46, 15, 0 }, { 22, 25, 0 } } },
            { id = "Summoner", slot = 22, broad = 4, attrMod = { -1, 0, 2, -1 }, life = 160, lifePerLevel = 1, armor = 0, mana = 20,
              skills = { { 11, 1, 3 }, { 7, 1, 0 }, { 40, 5, 0 }, { 94, 15, 0 }, { 22, 25, 0 } } },
            { id = "Alchemist", slot = 23, broad = 4, attrMod = { 0, -1, 2, -1 }, life = 160, lifePerLevel = 1, armor = 0, mana = 20,
              skills = { { 16, 1, 3 }, { 7, 1, 0 }, { 6, 5, 0 }, { 95, 15, 0 }, { 22, 25, 0 } } },
            { id = "Illusionist", slot = 24, broad = 4, attrMod = { -2, 1, 2, -1 }, life = 160, lifePerLevel = 1, armor = 0, mana = 20,
              skills = { { 13, 1, 3 }, { 7, 1, 0 }, { 8, 5, 0 }, { 25, 15, 0 }, { 22, 25, 0 } } },
            { id = "IceMage", slot = 25, broad = 4, attrMod = { -1, -1, 2, 0 }, life = 160, lifePerLevel = 1, armor = 0, mana = 20,
              skills = { { 18, 1, 3 }, { 7, 1, 0 }, { 28, 5, 0 }, { 58, 15, 0 }, { 22, 25, 0 } } },
            { id = "Lichelord", slot = 26, broad = 4, attrMod = { 1, 0, 2, -3 }, life = 160, lifePerLevel = 2, armor = 0, mana = 20,
              skills = { { 14, 1, 1 }, { 20, 1, 1 }, { 35, 5, 0 }, { 54, 15, 0 }, { 40, 25, 0 } } },
            { id = "Sage", slot = 27, broad = 4, attrMod = { -2, -1, 2, 1 }, life = 160, lifePerLevel = 1, armor = 0, mana = 20,
              skills = { { 21, 1, 3 }, { 7, 1, 0 }, { 92, 5, 0 }, { 6, 15, 0 }, { 22, 25, 0 } } },
        }
        for _, class in ipairs(list) do content.class:add(class) end
    end,
}
