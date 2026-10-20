-- The missile pictures of the original (docs/data-driven/03-spells-effects.md 3.5). `flags` is what FUN_0053f180 (the missile setup)
-- gives every picture (DIMN flags: speed, path, carry-through, splash ..., see game/missiles.lua `F`; the dragon breath's 0x21 comes from the
-- shared tail of that function), `sprite` the picture a ball is drawn with, `piercing` marks the plain piercing missiles that buildings and
-- missile-resistant units take a sixteenth of (the building's missile test FUN_0052e790: the flaming arrow EMA2 and the
-- black lightning EMM4 are not among them), `lightning` the colour ramp of a bolt's five lines (red R 250 G 250 - 40i B 250 - 50i, blue
-- R 250 - 50i G 250 - 10i B 250 - 5i, black 10i each: value = base + step * line). `trail` is the number of after-image frames drawn at the
-- steps behind the picture (sheet columns `frames` .. `frames + trail - 1`), `frames` the animation frames of the picture itself (default 1),
-- `dirs` the direction rows of its sheet (default 16), `spinner` the rocks that turn through their rows instead of facing along the
-- flight (all four read from FUN_0053f180, offsets +0x680 / +0x682 / +0x684 / +0x67e). The impact sounds are the
-- setting `missile.sounds`. `sprite` is the picture the missile-id conversion (FUN_0040f620 of the 1.04 binary) swaps a code for: the poison and fire
-- poison arrows are drawn as EMA0 / EMA2, the Minotaur's axe as EMM3, the titan's balls as EMF0 / EMM0, the ice shards and the ice floe as the
-- invisible dummy EDUM (only their particles show, gfx/emitters.lua). `burst` is the effect picture a Titan's ball bursts with, `getsUp` the chance (one in n) that a thrown
-- goblin gets up again.
return {
    ---@param content Content
    define = function(content)
        local list = {
            { "EMA0", 0x82, piercing = true, trail = 5 }, { "EMA1", 0x82, piercing = true, trail = 5 }, { "EMA2", 0x82, trail = 5, frames = 3 },
            { "EMAP", 0x82, sprite = "EMA0", piercing = true, trail = 5 },
            { "EMFP", 0x82, sprite = "EMA2", piercing = true, trail = 5, frames = 3 },                -- arrows: fast, arc
            { "EMA5", 0x42, piercing = true, trail = 5 },                                       -- crossbow bolt: fast, curved
            { "EMA3", 0x224, piercing = true },                                      -- spear: medium, linear, carry through
            { "EMA4", 0x222, piercing = true }, { "EMA6", 0x222, piercing = true }, { "EMS0", 0x222, sprite = "EMM3", piercing = true },   -- bolts, the Minotaur's axe
            { "EMM3", 0x22, piercing = true },                                       -- throwing axe
            { "EMC0", 0x44, trail = 5, dirs = 4, spinner = true },                                                        -- rock: medium, curved
            { "EMC1", 0x510, trail = 5, dirs = 4, spinner = true },                                                       -- catapult rock: very slow, high arc, splash
            { "EMF0", 0x24, trail = 5 }, { "EMM0", 0x24, trail = 5 }, { "EMM5", 0x24, piercing = true, trail = 5 },   -- fireball, magic sphere, petrify: medium, linear
            { "EMM1", 0x2021, lightning = { { 250, 0 }, { 250, -40 }, { 250, -50 } } },     -- red lightning: instant
            { "EMM2", 0x2021, lightning = { { 250, -50 }, { 250, -10 }, { 250, -5 } } },    -- blue lightning
            { "EMM4", 0x2021, lightning = { { 0, 10 }, { 0, 10 }, { 0, 10 } } },            -- black lightning
            { "EMTF", 0x110, sprite = "EMF0", trail = 5, burst = "EZ06" }, { "EMTM", 0x110, sprite = "EMM0", trail = 5, burst = "EZ07" },  -- the titan's balls: very slow, high arc
            { "EMIS", 0x22, sprite = "EDUM", frames = 8, dirs = 1 }, { "EMIF", 0x224, sprite = "EDUM", frames = 8, dirs = 1 },                                     -- ice shards, ice floe
            -- dragon breath: instant. `picture`: the first three letters of its effect pictures (E?B0 .. E?B7 by direction, FUN_00541a30);
            -- `special`: the special attack the picture always carries (FUN_0053f180 +0x67c: immolate, freeze, drain mana 40); `attack`: the acid, evil
            -- and good breath's own { kind, amount } (+0x67c 14 / 12 / 5, +0x67d 2 / 10: reduce armour 2, drain experience 10, crystallize, 100 crystal);
            -- `doubleVs`: the opposite alignment that takes double damage; `after`: the effect picture the breath strike puts on a victim (FUN_00542150)
            { "EMF1", 0x21, picture = "EFB", special = true, after = { sprite = "EF01" } }, { "EMF2", 0x21, picture = "EIB", special = true, after = { sprite = "EZ64" } },
            { "EMF3", 0x21, picture = "EAB", attack = { kind = "reduceArmour", amount = 2 }, after = { emit = "EPGA" } },
            { "EMF4", 0x21, picture = "EVB", attack = { kind = "drainXp", amount = 10 }, doubleVs = "good", after = { emit = "EILE" } },
            { "EMF5", 0x21, picture = "EGB", attack = { kind = "crystallize", amount = 100 }, doubleVs = "evil", after = { sprite = "EZ21", emit = "EBLS" } },
            { "EMF6", 0x21, picture = "ELB", special = true, after = { sprite = "EZ61" } },
            { "ACSH", 0x4484, frames = 8, dirs = 8 }, { "ACCO", 0x4510, frames = 8, dirs = 8 }, { "AOSX", 0x4508, frames = 8, dirs = 8, getsUp = 8 },              -- thrown sheep, cow, goblin: splash
        }
        for _, m in ipairs(list) do
            content.missile:add({ id = m[1], flags = m[2], sprite = m.sprite, piercing = m.piercing, lightning = m.lightning, trail = m.trail,
                                  frames = m.frames, dirs = m.dirs, spinner = m.spinner, picture = m.picture, special = m.special, attack = m.attack, doubleVs = m.doubleVs, after = m.after, burst = m.burst, getsUp = m.getsUp })
        end
        -- impact sound numbers by picture code: { on an army, on a building } (Missile<n>.wav; the table of FUN_005427e0's tail, read from the
        -- 1.04 binary: the poison and flaming-poison arrows, EMA6, the lightnings, the titan balls and the dragon breath make no sound)
        local sounds = { EMA0 = { 0, 18 }, EMA1 = { 0, 18 }, EMA2 = { 0, 18 }, EMA3 = { 0, 18 }, EMA4 = { 0, 18 }, EMA5 = { 0, 18 },
                         EMC0 = { 4, 22 }, EMC1 = { 4, 22 }, EMS0 = { 4, 22 }, EMM3 = { 4, 22 }, EMF0 = { 6, 24 }, EMM5 = { 6, 24 },
                         EMM0 = { 7, 25 }, EMIS = { 7, 25 }, EMIF = { 7, 25 }, ACSH = { 15, 33 }, ACCO = { 16, 34 }, AOSX = { 36, 35 } }
        -- the one-shot pictures at an impact (the effect display, vtable 0x005eb038, 50 ms a frame; frame counts from the .ani records): the puff where a missile
        -- ends against a building, the void or a lightning's end, the splash picture, and the frames of those and of the balls' bursts
        content.setting:add({ id = "missile.effects", doc = "impact pictures of the missiles: puff, splash and their frame counts",
                              value = { puff = "EMX0", splash = "EMX1", frames = { EMX0 = 8, EMX1 = 8, EZ06 = 20, EZ07 = 20 } } })
        content.setting:add({ id = "missile.sounds", doc = "impact sounds of the missile pictures (MissileN.wav): { army, building }", value = sounds })
    end,
}
