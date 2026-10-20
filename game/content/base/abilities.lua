-- The army abilities of the original (docs/data-driven/04-heroes-abilities-rules.md 4.2): the special buttons of selected units (the
-- 1.04 binary's special-button builder FUN_004d3200 and button handler FUN_00426350) as `ability` records. Records:
--   kind = "spell": the mana-cost buttons a single spellcasting troop gets (the spellcaster part of FUN_004d3200). `units` names the
--     troops that have it, `mana` the cost (the mana FUN_004d3200 asks for), `icon` the button icon (a Panel_Icons index), `name`
--     the Game.txt string, `spell` the slot of the spell whose effect it reuses (spells, content/base/
--     spells.lua; the troops' own spells have negative slots). The cast is the unit's casting level (spells.lua unitCast: (level + 1) / 5 + 1),
--     so the effect is the hero's at that result. A press casts with one unit (FUN_00426350, also the button's handler, picks the first selected caster with the
--     mana in the order of `units`, else one on the screen: see the key fields below); `all` (Invisibility) casts with every selected caster that has the mana. `cost` (optional) is the mana the press needs and
--     takes when it differs from the button's `mana` (Freeze). `power` (optional) maps a caster code to a power-up the side must own for that troop's button to be enabled
--     (Earthpower, Blending for the Chameleon, Zombie Feast; without it the button is shown disabled), `race` (optional) a caster code to
--     the race id the side must be for the button to appear at all (Earthpower, Feast); `mana` 0 means no mana (Scavenge). `limit` (optional) is the army type whose unit value must fit under the side's army limit before the button
--     spends any mana (the binary's button handler FUN_00426350 checks it for the Zombie, Imp, Daemon, Giant Bat, Queen Spider, Earth Elemental
--     and Fire Elemental buttons; the Fire Elemental one checks its own caster type, Scorpion Priest, a quirk of the original); the other summons check
--     inside the spell, after the mana is gone (spells.lua / fx.lua). `order` is the button order of the
--     original's block.
--   The KeyMap.txt ability keys (game/abilitykeys.lua): `key` is the record's case of FUN_00426350 (0-based, the line in the
--     file's ability block). A spell record's key tries its `units` in order: the first selected one with the mana, else (FUN_00427cf0)
--     the player's first one of that type on the screen with the mana; `keyUnits` replaces that list, `keyFirst` codes are looked for
--     in the selection only before it (Entangle, case 0xc), `keyLoop` lets every selected caster of those codes cast first
--     (Invisibility, case 0xd, which also takes the ASWM code no button offers), `keyNoPower` skips `power` (the key casts
--     Earthpower without the power-up and for any race, case 0x18). A building record's key looks for `keyBuildings` in that
--     order (FUN_00427e30: the selection, then the whole map), asks the record's price and power-up but has no button timer or
--     target check; `keyUnpaid` casts without taking the price (cases 0x22 / 0x24 / 0x2e call the casts directly).
--   kind = "morph": the Undead morph chain: `from` / `to` unit, the fixed price `res` / `amount` (cost routine FUN_0040b6b0; the Merchant discount applies),
--     the buildings it `need`s, `icon` (Panel_Icons index), `name` / `req` the Game.txt strings (or a plain name), `order` the button order
--     per unit type it morphs from.
return {
    ---@param content Content
    define = function(content)
        local function add(rec) content.ability:add(rec) end

        -- Undead morphs: a Skeleton becomes a Wight / Wraith, a Wraith a Shadow, a Wight a Slayer Knight / Liche, a Slayer Knight a Doom Knight.
        -- Fixed price (FUN_0040b6b0: 80 / 70 / 120 / 250 / 150 / 350 metal or crystal), needs the matching building, the unit keeps its fraction
        -- of hit points. A group morphs as many units as the resources allow.
        add({ id = "morphWight", kind = "morph", from = "AUIX", to = "AUJX", res = "metal", amount = 80, need = { "BPDM" }, icon = 46, name = "0105", req = "0110",
             order = 1 })
        add({ id = "morphWraith", kind = "morph", from = "AUIX", to = "AUKX", res = "crystal", amount = 70, need = { "BPBA" }, icon = 44, name = "0106", req = "0111",
             order = 2 })
        add({ id = "morphShadow", kind = "morph", from = "AUKX", to = "AUXX", res = "crystal", amount = 120, need = { "BPAS" }, icon = 45, name = "0107", req = "0112",
             order = 1 })
        add({ id = "morphSlayerKnight", kind = "morph", from = "AUJX", to = "AULX", res = "metal", amount = 250, need = { "BPCG" }, icon = 47, name = "0108", req = "0113",
             order = 1 })
        add({ id = "morphLiche", kind = "morph", from = "AUJX", to = "AUMX", res = "crystal", amount = 150, need = { "BPBL" }, icon = 48, name = "0109", req = "0114",
             order = 2 })
        add({ id = "morphDoomKnight", kind = "morph", from = "AULX", to = "AUAX", res = "metal", amount = 350, need = { "BPBL", "BPCG", "BPAS", "BPBA" }, icon = 55, name = "Morph to Doom Knight",
             order = 1 })

        -- Unit special abilities (spell buttons), in the order the button builder FUN_004d3200 tests them
        -- Gate Imp: the Daemon summons an Imp (40 mana, icon 69, Game.txt 0409), reusing the Summoning spell 14
        -- (FUN_005818f0).
        add({ id = "gateImp", key = 21, kind = "spell", units = { "AADE" }, mana = 40, icon = 69, name = "0409", spell = 14, limit = "AAIM",
              order = 22 })
        -- Cure: White Mage, Unicorn and Archon cure and heal their allies (30 mana, icon 49, Game.txt 0159), reusing
        -- Healing spell 1 (FUN_0057b1a0).
        add({ id = "cure", key = 11, kind = "spell", units = { "AHGW", "AEDX", "AAAR" }, mana = 30, icon = 49, name = "0159", spell = 1,
              order = 1 })
        -- Group Healing: White Mage and Unicorn heal their allies (40 mana, icon 57, Game.txt 0161), reusing Healing
        -- spell 4 (FUN_0057b560).
        add({ id = "groupHealing", key = 0, kind = "spell", units = { "AHGW", "AEDX" }, mana = 40, icon = 57, name = "0161", spell = 4,
              order = 2 })
        -- Resist Fire: the Red Mage resists fire around its allies (30 mana, icon 58, Game.txt 0163), reusing Pyromancy
        -- spell 53 (FUN_0057fc10).
        add({ id = "resistFire", key = 18, kind = "spell", units = { "AHGR" }, mana = 30, icon = 58, name = "0163", spell = 53,
              order = 3 })
        -- Ring of Fire: Red Mage, Minotaur Shaman and Scorpion Priest burn the enemies around them (40 mana, icon 59,
        -- Game.txt 0165), reusing Pyromancy spell 54 (FUN_0057fd60, case 0x36 of the spell dispatcher FUN_005777a0;
        -- the 1.04 handler FUN_00426350 case 2).
        add({ id = "ringOfFire", key = 2, kind = "spell", units = { "AHGR", "AMMX", "ARGX" }, mana = 40, icon = 59, name = "0165", spell = 54,
              order = 4 })
        -- Fire Elemental: the Scorpion Priest summons a permanent Fire Elemental (100 mana, icon 94, Game.txt 0893),
        -- reusing Pyromancy spell 58 (FUN_00580260).
        add({ id = "fireElemental", key = 41, kind = "spell", units = { "ARGX" }, mana = 100, icon = 94, name = "0893", spell = 58, limit = "ARGX",
              order = 5 })
        -- Hand of Ice: Black Mage and Ice Maiden freeze the enemies around them (20 mana, icon 60, Game.txt 0167),
        -- reusing Ice spell 80 (FUN_0057bd20).
        add({ id = "handOfIce", key = 10, kind = "spell", units = { "AHGB", "AEOX" }, mana = 20, icon = 60, name = "0167", spell = 80,
              order = 6 })
        -- Call the Dead: the Liche turns every corpse around it into a skeleton (45 mana, icon 54, Game.txt 0134),
        -- reusing Necromancy spell 47 (FUN_0057e670).
        add({ id = "callTheDead", key = 47, kind = "spell", units = { "AUMX" }, mana = 45, icon = 54, name = "0134", spell = 47,
              order = 7 })
        -- Poison Cloud: the Snake Priest poisons the enemies around it (25 mana, icon 88, Game.txt 0884), reusing
        -- Poison spell 101 (FUN_0057ed00).
        add({ id = "poisonCloud", key = 37, kind = "spell", units = { "ALMX" }, mana = 25, icon = 88, name = "0884", spell = 101,
              order = 9 })
        -- Drain Mana: Black Mage and Harpy drain the mana of the enemy spellcasters around them (20 mana, icon 53,
        -- Game.txt 0220), reusing Chaos spell 95 (FUN_00578b60).
        add({ id = "drainMana", key = 4, kind = "spell", units = { "AHGB", "AAHA" }, mana = 20, icon = 53, name = "0220", spell = 95,
              order = 12 })
        -- Lightning: Goblin Shaman and Wood Elf Mage call lightning on every enemy around them (40 mana, icon 62,
        -- Game.txt 0171), reusing Nature spell 26 (FUN_0057da00).
        add({ id = "lightning", key = 1, kind = "spell", units = { "AONX", "AWNX" }, mana = 40, icon = 62, name = "0171", spell = 26,
              order = 15 })
        -- Entangle: Treant and Ancient Treant slow the ground enemies around them (20 mana, icon 12, Game.txt 0224),
        -- reusing Nature spell 22 (FUN_0057d5b0).
        add({ id = "entangle", key = 12, kind = "spell", units = { "AWJX", "AWKX" }, mana = 20, icon = 12, name = "0224", spell = 22,
              keyFirst = { "AWJX" }, keyUnits = { "AWKX", "AWJX" },
              order = 19 })
        -- Pillar of Fire: Dark Elf Mage and Minotaur Shaman burn the ground around them (35 mana: the 1.04 button
        -- FUN_004d3200 and handler FUN_00426350 case 5; icon 65, Game.txt 0228), reusing Pyromancy spell 57 (FUN_00580140).
        add({ id = "pillarOfFire", key = 5, kind = "spell", units = { "AKNX", "AMMX" }, mana = 35, icon = 65, name = "0228", spell = 57,
              order = 20 })
        -- Gate Daemon: the Summoner summons a Daemon (100 mana, icon 70, Game.txt 0412), reusing Summoning spell 19
        -- (FUN_00581f70).
        add({ id = "gateDaemon", key = 22, kind = "spell", units = { "AVGX" }, mana = 100, icon = 70, name = "0412", spell = 19, limit = "AADE",
              order = 23 })
        -- Banish: the Summoner destroys the summoned extraplanar enemies around it (30 mana, icon 72, Game.txt 0415),
        -- reusing Summoning spell 18 (FUN_00581e70).
        add({ id = "banish", key = 23, kind = "spell", units = { "AVGX" }, mana = 30, icon = 72, name = "0415", spell = 18,
              order = 27 })
        -- Scare: the Banshee frightens the enemies around it, making them flee (40 mana, icon 80, Game.txt 0726),
        -- reusing Illusion spell 31 (FUN_0057c7c0).
        add({ id = "scare", key = 30, kind = "spell", units = { "AFGX" }, mana = 40, icon = 80, name = "0726", spell = 31,
              order = 26 })
        -- Invisibility: the Black Guard turns invisible; the Chameleon only can with the Blending power-up PBLE (35 mana,
        -- icon 30, Game.txt 0139), reusing Illusion spell 36 (FUN_0057ce90). Every selected caster with the mana turns
        -- invisible and pays (FUN_00426350 case 0xd loops over the selection).
        add({ id = "invisibility", key = 13, kind = "spell", units = { "AKGX", "ALBX" }, mana = 35, icon = 30, name = "0139", spell = 36, power = { ALBX = "PBLE" },
              all = true, keyLoop = { "ASWM", "AKGX", "ALBX" }, keyUnits = { "AKGX", "ASWM" },
              order = 29 })
        -- Earthpower: the Dark Dwarves' Engineer repairs its damaged buildings (40 mana, icon 75, Game.txt 0429), needs
        -- the Earthpower power-up and the Dark Dwarf race (race 10 in FUN_004d3200), reusing Runes spell 73 (FUN_005807a0).
        add({ id = "earthpower", key = 24, kind = "spell", units = { "AABX" }, mana = 40, icon = 75, name = "0429", spell = 73, power = { AABX = "PEPO" },
              race = { AABX = "darkdwarf" }, keyNoPower = true,
              order = 32 })
        -- Stonecall: the Runelord summons an Earth Elemental (100 mana, icon 78, Game.txt 0677), reusing Runes spell 79
        -- (FUN_00581250).
        add({ id = "stonecall", key = 28, kind = "spell", units = { "ADOX" }, mana = 100, icon = 78, name = "0677", spell = 79, limit = "AAEE",
              order = 34 })
        -- Purify: the Inquisitor casts the hero's Purify (50 mana, icon 81, Game.txt 0867), Healing spell 6: the 1.04
        -- handler FUN_00426350 case 0x1f calls FUN_0057b6a0, case 6 of the spell dispatcher FUN_005777a0.
        add({ id = "purify", key = 31, kind = "spell", units = { "AHGX" }, mana = 50, icon = 81, name = "0867", spell = 6,
              order = 35 })
        -- Freeze: the Ice Maiden slows the enemies around it (icon 86, Game.txt 0906), reusing Ice spell 85
        -- (FUN_0057c150: two speed points less for half a minute). In 1.04 the button is enabled from 45 mana
        -- (FUN_004d3200: FUN_004d4840(AEOX, 45)) but the handler (FUN_00426350 case 0x2c) needs and takes only 20.
        add({ id = "freeze", key = 44, kind = "spell", units = { "AEOX" }, mana = 45, cost = 20, icon = 86, name = "0906", spell = 85,
              order = 8 })
        -- Shield: the Naga gives its allies +10 armour (40 mana, icon 93, Game.txt 0886). The original's unit-only
        -- routine FUN_00578930; openwbc3 keeps unit-only spells in D[] with negative ids.
        add({ id = "shield", key = 38, kind = "spell", units = { "ALGX" }, mana = 40, icon = 93, name = "0886", spell = -1,
              order = 10 })
        -- Cauterize: the Snake Priest heals its wounded allies (30 mana, icon 92, Game.txt 0888), reusing Pyromancy
        -- spell 52 (the hero's Cauterize, the same routine FUN_0057fb00).
        add({ id = "cauterize", key = 39, kind = "spell", units = { "ALMX" }, mana = 30, icon = 92, name = "0888", spell = 52,
              order = 11 })
        -- White Ward: the High Elf Mage wards its good and neutral allies (+5 resistance, Game.txt 0218, icon 52, 25
        -- mana), reusing Healing spell 3 (the hero's White Ward, the same routine FUN_0057b410).
        add({ id = "whiteWard", key = 8, kind = "spell", units = { "AENX" }, mana = 25, icon = 52, name = "0218", spell = 3,
              order = 13 })
        -- Ring of Ice: the High Elf Mage freezes the enemies around it (50 mana, icon 61, Game.txt 0169), reusing
        -- Necromancy spell 48 (FUN_0057e950, the hero's Ring of Ice).
        add({ id = "ringOfIce", key = 3, kind = "spell", units = { "AENX" }, mana = 50, icon = 61, name = "0169", spell = 48,
              order = 14 })
        -- Berserker: the Goblin Shaman and Minotaur Shaman send their allies into a berserker rage (+5 combat and
        -- speed, 25 mana, icon 63, Game.txt 0173), reusing Pyromancy spell 56 (FUN_0057ffe0).
        add({ id = "berserker", key = 14, kind = "spell", units = { "AONX", "AMMX" }, mana = 25, icon = 63, name = "0173", spell = 56,
              order = 16 })
        -- Light/Darkness: the Goblin Shaman and Wood Elf Mage turn day into night and back (50 mana, icon 64, Game.txt
        -- 0175), reusing Illusion spell 32 (FUN_0057c8c0).
        add({ id = "lightDarkness", key = 9, kind = "spell", units = { "AONX", "AWNX" }, mana = 50, icon = 64, name = "0175", spell = 32,
              order = 17 })
        -- Multi-Target: the Moonguard and Scorpion fire an extra missile at every enemy within their own range (25
        -- mana, icon 25, Game.txt 0222), the original's own routine FUN_00578c90.
        add({ id = "multiTarget", key = 17, kind = "spell", units = { "AEGX", "ASSC" }, mana = 25, icon = 25, name = "0222", spell = -2,
              order = 18 })
        -- Raise Zombie: the Dark Elf Mage raises a zombie beside it (45 mana, icon 66, Game.txt 0230), reusing
        -- Necromancy spell 41 (the hero's Raise Zombie, the same routine FUN_0057e010).
        add({ id = "raiseZombie", key = 6, kind = "spell", units = { "AKNX" }, mana = 45, icon = 66, name = "0230", spell = 41, limit = "AUBX",
              order = 21 })
        -- Summon Bats: the Vampire calls four permanent Giant Bats (40 mana, icon 79, Game.txt 0720), the original's
        -- own routine FUN_00579a10.
        add({ id = "summonBats", key = 29, kind = "spell", units = { "AUGX" }, mana = 40, icon = 79, name = "0720", spell = -3, limit = "AABA",
              order = 24 })
        -- Summon Spiders: the Spider Priestess calls a permanent Queen Spider (45 mana, icon 89, Game.txt 0890), the
        -- original's own routine FUN_00579b90.
        add({ id = "summonSpiders", key = 40, kind = "spell", units = { "AKOX" }, mana = 45, icon = 89, name = "0890", spell = -4, limit = "AKLX",
              order = 25 })
        -- Darkstorm: the Dark Elf Mage brings night and rain (40 mana, icon 67, Game.txt 0232), reusing Necromancy
        -- spell 45 (the hero's Darkstorm, the same routine FUN_0057e5b0).
        add({ id = "darkstorm", key = 7, kind = "spell", units = { "AKNX" }, mana = 40, icon = 67, name = "0232", spell = 45,
              order = 28 })
        -- Feast: the Zombies eat the fallen around them for resources (no mana, icon 10, Game.txt 0234, FUN_004cfc90);
        -- the button is only there for the Undead race and enabled with the Feast of Garok power-up (PZOM).
        -- Feast and Scavenge use the first selected unit and work once a second (FUN_004cfc90 / FUN_004cfce0 timers).
        add({ id = "feast", key = 25, kind = "spell", units = { "AUBX" }, mana = 0, icon = 10, name = "0234", spell = -9, power = { AUBX = "PZOM" },
              race = { AUBX = "undead" },
              order = 30 })
        -- Scavenge: the Bronze Golem takes the rubble around it apart for resources, always and for no mana (icon 76,
        -- Game.txt 0526), the original's own routine FUN_004cfce0.
        add({ id = "scavenge", key = 26, kind = "spell", units = { "AAGX" }, mana = 0, icon = 76, name = "0526", spell = -10,
              order = 31 })
        -- Doomstones: the Runelord hurls rocks at the enemies around it (40 mana, icon 77, Game.txt 0675), reusing
        -- Runes spell 75 (the hero's Doomstones, the same routine FUN_005809c0).
        add({ id = "doomstones", key = 27, kind = "spell", units = { "ADOX" }, mana = 40, icon = 77, name = "0675", spell = 75,
              order = 33 })
        -- Eye of Oros: the Plague Priest conjures floating eyes to scout with (30 mana, icon 83, Game.txt 0874),
        -- reusing Summoning spell 15 (the hero's Eye of Oros, the same routine FUN_00581a30).
        add({ id = "eyeOfOros", key = 32, kind = "spell", units = { "AGGX" }, mana = 30, icon = 83, name = "0874", spell = 15,
              order = 36 })
        -- Plague Cloud: the Plague Priest sickens the enemies around it (55 mana, icon 82, Game.txt 0872), the
        -- original's own routine FUN_00579f80.
        add({ id = "plagueCloud", key = 33, kind = "spell", units = { "AGGX" }, mana = 55, icon = 82, name = "0872", spell = -8,
              order = 37 })
        -- Create Firebomb: the Iron Golem builds a permanent Firebomb beside it (35 mana, icon 85, Game.txt 0879), the
        -- original's own routine FUN_0057a080.
        add({ id = "createFirebomb", key = 35, kind = "spell", units = { "AAJX" }, mana = 35, icon = 85, name = "0879", spell = -7,
              order = 38 })
        -- Goblin Horde: the Goblin Chief calls five permanent Goblins (75 mana, icon 90, Game.txt 0902), the original's
        -- own routine FUN_00579ce0.
        add({ id = "goblinHorde", key = 43, kind = "spell", units = { "AOKX" }, mana = 75, icon = 90, name = "0902", spell = -5,
              order = 39 })
        -- Summon Blades: the Inquisitor dances three permanent swords around it (45 mana, icon 97, Game.txt 1104), the
        -- original's own routine FUN_00579e30.
        add({ id = "summonBlades", key = 45, kind = "spell", units = { "AHGX" }, mana = 45, icon = 97, name = "1104", spell = -6,
              order = 40 })

        -- Building abilities (the building buttons of the 1.04 binary: layout FUN_004d2300, the button handlers 0x004d0c50..0x004d1e10):
        -- the extra buttons of a building. `slot` 1 / 2 is the button below the unload button, `icon` a Panel_Icons index, `power` the
        -- power-up that enables it (`family` its levels; `needsPower`: the button only appears with it, Famine FUN_004d06d0),
        -- `buildings` the building codes that offer it, `races` the race ids it is shown for (`orPower`: or anyone who bought the power-up),
        -- `buildingRace` a race per building (the Trade of a race's market, FUN_004d07e0); `crystal` / `gold` the cost of a one-shot (what
        -- the button handler asks for and takes), `resource` / `each` / `max` / `unit` the units a button hires, `delay` the ms between two
        -- presses (the handler's own timer, set before the price is checked), `room` the button is only enabled while the army limit has
        -- room, `weather` / `effect` / `morph` what it does, `free` no power-up needed.
        add({ id = "slaveHorde", icon = 20, name = "Slave Horde", slot = 1, power = "PSLH", resource = "gold", each = 25, max = 10, unit = "ABBX", delay = 3000, room = true, kind = "building", buildings = { "BAPR", "BPCG", "BPDU" } })
        add({ id = "brood", icon = 68, name = "Brood", slot = 1, power = "PBRD", resource = "gold", each = 30, max = 8, unit = "AVBX", delay = 3000, room = true, kind = "building", buildings = { "BAS0", "BAS1", "BAS2" } })
        add({ id = "gravestone", icon = 14, name = "Gravestone to Skeleton", slot = 1, free = true, morph = "AUIX", room = true, kind = "building", buildings = { "BAGR" }, races = { "undead", "darkelf" } })
        add({ id = "trade", icon = 29, name = "Trade", slot = 1, power = "PTRA", dialog = "trade", kind = "building", buildings = { "BPMA", "BPQM", "BPMI", "BPTP", "BPHS", "BPTR", "BPME" },
              buildingRace = { BPMA = "human", BPQM = "empire", BPMI = "barbarian", BPTP = "dwarf", BPHS = "woodelf", BPTR = "darkdwarf", BPME = "highelf" } })
        add({ id = "ritesOfDawn", icon = 9, name = "Rites of Dawn", slot = 1, power = "PROD", crystal = 40, weather = "day", kind = "building", buildings = { "BKL0", "BKL1", "BKL2", "BKL3", "BKL4", "BPCA", "BPMT" }, races = { "human", "ssrathi", "highelf" } })
        add({ id = "darkCitadel", icon = 23, name = "Dark Citadel", slot = 1, power = "PDKC", crystal = 100, weather = "night", kind = "building", buildings = { "BKU0", "BKU1", "BKU2", "BKU3", "BKU4" }, races = { "undead" } })
        add({ id = "stormCall", icon = 71, name = "Storm Call", slot = 1, power = "PSCL", crystal = 80, weather = "storm", kind = "building", buildings = { "BWL0", "BWL1" }, races = { "daemon" } })
        add({ id = "elcorsBalm", key = 20, keyBuildings = { "BPHE", "BPHO" }, icon = 24, name = "Elcor's Balm", slot = 1, power = "PELC", crystal = 400, effect = "balm", snd = 11, orPower = true, kind = "building", buildings = { "BPHE", "BPHO" }, races = { "highelf", "woodelf" } })
        add({ id = "summonWraith", icon = 73, name = "Summon Wraith", slot = 1, power = "PAS0", resource = "crystal", each = 125, max = 1, unit = "AUKX", delay = 1000, kind = "building", buildings = { "BPAH" }, races = { "darkdwarf" } })
        add({ id = "famine", key = 42, keyBuildings = { "BKR4", "BKR3", "BKR2", "BKR1", "BKR0" }, icon = 95, name = "Famine", slot = 1, power = "PFA0", needsPower = true, crystal = 500, effect = "famine", snd = 27, kind = "building", family = { "PFA0", "PFA1", "PFA2", "PFA3" }, buildings = { "BKR0", "BKR1", "BKR2", "BKR3", "BKR4" }, races = { "swarm" } })
        add({ id = "holyWord", key = 19, keyBuildings = { "BPCA" }, icon = 51, name = "Holy Word", slot = 2, power = "PHOL", crystal = 200, effect = "holy", snd = 9, orPower = true, kind = "building", buildings = { "BPCA", "BPMT" }, races = { "human", "highelf" } })
        add({ id = "chaosPlague", key = 34, keyBuildings = { "BKG4", "BKG3", "BKG2", "BKG1", "BKG0" }, keyUnpaid = true, icon = 84, name = "Chaos Plague", slot = 2, power = "PCN0", crystal = 1000, effect = "plague", snd = 18, orPower = true, kind = "building", family = { "PCN0", "PCN1", "PCN2", "PCN3", "PCN4" }, buildings = { "BKG0", "BKG1", "BKG2", "BKG3", "BKG4" }, races = { "plaguelord" } })
        add({ id = "swordOfSirian", key = 46, keyBuildings = { "BPSS" }, keyUnpaid = true, icon = 96, name = "Sword of Sirian", slot = 2, power = "PSWS", crystal = 200, effect = "sword", snd = 22, orPower = true, kind = "building", buildings = { "BPSS" }, races = { "human" } })
        add({ id = "wrath", key = 36, keyBuildings = { "BKL4", "BKL3", "BKL2", "BKL1", "BKL0" }, keyUnpaid = true, icon = 91, name = "Couatl's Wrath", slot = 2, power = "PCWR", gold = 750, effect = "wrath", snd = 18, kind = "building", buildings = { "BKL0", "BKL1", "BKL2", "BKL3", "BKL4" }, races = { "ssrathi" } })
        add({ id = "summonShadow", icon = 74, name = "Summon Shadow", slot = 2, power = "PAS1", resource = "crystal", each = 250, max = 1, unit = "AUXX", delay = 1000, kind = "building", buildings = { "BPAH" }, races = { "darkdwarf" } })
    end,
}
