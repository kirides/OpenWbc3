-- The 130 hero spells of the original game (13 spheres of 10) and the troops' own spells as `spell` records (docs/data-driven/
-- 03-spells-effects.md). The mana costs and the effect functions are the engine's own, modelled on the original game (see
-- docs/spells.md for what was verified and where; entries marked "own" are openwbc3's approximations). Names and descriptions are
-- the install's (<Lang>/Spells.txt by number), never stored here.
--
-- Record: { id = "<sphere>.<index>" (troop spells "troop.<n>"), slot (sphere * 10 + index; the troops' spells -1 ..), sphere, index,
--   cost (mana), ai ("heal" | "attack" | "summon" | "buff": how computer heroes use it), target ("ground" | "choice" | "none"),
--   choices (the four pictures and texts of a "choice" spell's dialog), portal
--   (the building whose presence adds a casting level), name (Game.txt key, troop spells), effect = function(c) }.
-- `c` is the cast context of fx.ctx: c.lvl is the success level (the original's "result", 1 = marginal), c.r / c.rm the radii,
-- c.empPct / c.ext the side's Empower / Extend; the effect calls the helpers of src/game/fx.lua.

-- Mana cost of every spell, by slot: the cost table of the 1.04 binary at 0x61b3b0 (130 words; read by the cost routine FUN_00529fa0 and
-- the spell dispatcher FUN_005777a0; docs/spells.md "Mana cost").
local COST = {
    [0] = 8, 8, 8, 6, 15, 16, 20, 40, 40, 60,
    10, 4, 5, 3, 14, 12, 20, 35, 30, 55,
    10, 12, 8, 8, 20, 8, 35, 40, 25, 50,
    8, 6, 5, 8, 14, 20, 30, 30, 50, 70,
    8, 8, 8, 15, 30, 16, 35, 30, 35, 65,
    10, 6, 8, 7, 30, 30, 15, 40, 40, 75,
    12, 15, 6, 14, 24, 22, 24, 40, 60, 70,
    12, 4, 8, 12, 25, 16, 24, 35, 40, 50,
    10, 8, 14, 10, 30, 25, 8, 30, 40, 65,
    6, 8, 5, 7, 12, 24, 30, 55, 32, 70,
    6, 6, 5, 10, 15, 24, 30, 45, 45, 50,
    6, 6, 5, 10, 30, 35, 60, 50, 60, 70,
    8, 12, 20, 22, 24, 28, 32, 40, 60, 100,
}

-- The effect pictures a cast shows (docs/spells.md "Effect pictures"): `cast` plays on the caster, `target` on every army or building the
-- spell changes, `persistent` loops on them for as long as the spell's status lasts (a `base` one stands at the feet, behind the army).
-- Read from the spell functions behind the spell dispatcher (FUN_005777a0, the 1.04 binary: one function per spell index, which fill the
-- spell message's fields +0x8d casting effect, +0x91 target effect, +0x85 persistent effect and +0x95 special effect type, 100 = at
-- the base); the codes are the effect codes of the effect-id conversion (FUN_0040ebd0): EZnn pictures, or an emitter code (gfx/emitters.lua).
-- `sound` is the message's sound number (+7): STEZ<nn>.wav, played at the caster by the receiver (docs/spells.md "Spell sounds").
-- The spell index of the binary is the slot (the order of <Lang>/Spells.txt); Ring of Ice (84) and Drain Mana (95) call the functions
-- of spell 48 and of the extra spell 150, Banish (114) is the function of 18. Shield is the troops' -1.
local PICTURES = {
    [-1] = { cast = "EZ00", persistent = "EZ54", base = true, sound = 2 },   -- Shield
    [-2] = { sound = 5 },   -- Multi-Target (the binary's spell 151, FUN_00578c90: a missile message, sound 5)
    [0] = { cast = "EZ11", sound = 11 },   -- Heal Self
    [1] = { cast = "EZ20", target = "EZ20", sound = 15 },   -- Cure
    [2] = { cast = "EZ20", persistent = "EBLS", sound = 8 },   -- Blessing
    [3] = { cast = "EZ20", persistent = "EZ22", sound = 7 },   -- White Ward
    [4] = { cast = "EZ11", target = "EZ11", sound = 11 },   -- Heal Group
    [5] = { cast = "EZ20", persistent = "EZ23", sound = 12 },   -- Invigorate
    [6] = { cast = "EZ19", sound = 10 },   -- Purify
    [7] = { cast = "EZ11", target = "EZ11", sound = 11 },   -- Major Healing
    [8] = { cast = "EZ20", persistent = "EZ24", sound = 13 },   -- Life Ward
    [9] = { cast = "EZ20", target = "EZ13", sound = 14 },   -- Resurrection
    [10] = { target = "EZ34", sound = 5 },   -- Summon Quasit
    [11] = { target = "EZ36", sound = 42 },   -- Circle of Power
    [12] = { cast = "EZ37", sound = 34 },   -- Phantom Steed
    [13] = { target = "EZ34", sound = 39 },   -- Blink
    [14] = { target = "EZ34", sound = 38 },   -- Summon Imp
    [15] = { target = "EZ34", sound = 37 },   -- Eye of Oros
    [16] = { target = "EZ34", sound = 38 },   -- Home Portal
    [17] = { target = "EZ34", sound = 32 },   -- Soulharvest
    [18] = { cast = "EZ37", target = "EZ37", sound = 30 },   -- Banish
    [19] = { target = "EZ35", sound = 21 },   -- Daemongate
    [20] = { target = "EZ14", sound = 5 },   -- Summon Sprite
    [21] = { cast = "EZ15", target = "EZ15", sound = 15 },   -- Gemberry
    [22] = { cast = "EZ19", persistent = "EZ16", sound = 40 },   -- Entangle
    [23] = { persistent = "EZ17", sound = 29 },   -- Shillelagh
    [24] = { target = "EZ18", sound = 34 },   -- Summon Unicorn
    [25] = { target = "EZ18", sound = 28 },   -- Wall of Thorns
    [26] = { target = "EZ09", sound = 9 },   -- Call Lightning
    [27] = { target = "EZ18", sound = 33 },   -- Summon Treant
    [28] = { cast = "EZ19", sound = 17 },   -- Change Weather
    [29] = { target = "EZ14", sound = 32 },   -- Elementalism
    [30] = { cast = "EILU", sound = 22 },   -- Shadowform
    [31] = { cast = "EILU", target = "EILE", sound = 31 },   -- Scare
    [32] = { cast = "EZ19", sound = 17 },   -- Light/Darkness
    [33] = { cast = "EILU", target = "EILE", sound = 43 },   -- Awe
    [34] = { target = "EZ34", sound = 42 },   -- Spectral Horde
    [35] = { target = "EZ34", sound = 44 },   -- Dragonfear
    [36] = { cast = "EILU", sound = 40 },   -- Invisibility
    [37] = { target = "EZ08", sound = 16 },   -- Call Shadow
    [38] = { cast = "EILU", target = "EZ12", sound = 29 },   -- Mutate
    [39] = { cast = "EILU", target = "EILE", sound = 42 },   -- Transform
    [40] = { target = "EZ08", sound = 16 },   -- Raise Skeleton
    [41] = { target = "EZ08", sound = 16 },   -- Raise Zombie
    [42] = { target = "EZ05", sound = 19 },   -- Black Portal
    [43] = { target = "EZ08", sound = 16 },   -- Raise Wight
    [44] = { cast = "EZ27", persistent = "EZ26", sound = 20 },   -- Vampirism
    [45] = { cast = "EZ27", sound = 21 },   -- Darkstorm
    [46] = { cast = "EZ27", target = "EZ41", sound = 29 },   -- Strip Flesh
    [47] = { cast = "EZ78", target = "EZ08", sound = 9 },   -- Call the Dead
    [48] = { cast = "EZ07", sound = 23 },   -- Ring of Ice
    [49] = { target = "EZ08", sound = 17 },   -- Raise Champion
    [50] = { sound = 27 },   -- Hand of Flame: a missile message without pictures
    [51] = { cast = "EZ30", target = "EF01", sound = 15 },   -- Soul Flame
    [52] = { cast = "EF04", target = "EF04", sound = 11 },   -- Cauterize
    [53] = { cast = "EZ29", persistent = "EZ28", sound = 25 },   -- Resist Fire
    [54] = { cast = "EZ06", sound = 47 },   -- Ring of Fire
    [55] = { cast = "EZ31", persistent = "EZ33", sound = 26 },   -- Firebreath
    [56] = { cast = "EZ30", sound = 28 },   -- Berserker
    [57] = { cast = "EZ32", sound = 35 },   -- Pillar of Fire
    [58] = { target = "EZ14", sound = 32 },   -- Fire Elemental
    [59] = { target = "EZ32", sound = 9 },   -- Armageddon
    -- [60] Create Item: no spell message (a dialog)
    -- [61] Transmute: no spell message (a dialog)
    [62] = { cast = "EZ20", persistent = "EZ39", sound = 43 },   -- Charm
    [63] = { target = "EZ34", sound = 5 },   -- Stone Golem
    [64] = { target = "EZ20", sound = 46 },   -- Brew Potion
    [65] = { target = "EZ20", sound = 46 },   -- Acquire
    [66] = { target = "EZ35", sound = 24 },   -- Summon Guardian
    [67] = { cast = "EZ26", persistent = "EZ69", base = true, sound = 26 },   -- Disjunction
    [68] = { target = "EZ34", sound = 5 },   -- Bronze Golem
    [69] = { cast = "EZ26", persistent = "EZ80", base = true, sound = 26 },   -- Spellforge
    [70] = { cast = "ERUC", sound = 33 },   -- Stoneskin
    [71] = { cast = "ERUC", sound = 13 },   -- Gem of Wisdom
    [72] = { cast = "ERUC", persistent = "EZ39", sound = 42 },   -- Dig
    [73] = { cast = "ERUC", target = "EZ00", sound = 24 },   -- Earthpower
    [74] = { cast = "ERUC", sound = 36 },   -- Resist Magic
    [75] = { cast = "ERUC", sound = 27 },   -- Doomstones
    [76] = { cast = "ERUC", target = "EZ35", sound = 24 },   -- Summon Guardian
    [77] = { cast = "ERUC", persistent = "EZ40", sound = 39 },   -- Resist Missile
    -- [78] Rune Item: no spell message (a dialog)
    [79] = { cast = "ERUC", target = "EZ34", sound = 32 },   -- Stonecall
    [80] = { cast = "EISP", sound = 27 },   -- Hand Of Ice
    [81] = { cast = "EZ27", sound = 21 },   -- Storm
    [82] = { cast = "EISP", persistent = "EIAR", sound = 2 },   -- Ice Armor
    [83] = { cast = "EISP", target = "EISP", sound = 40 },   -- Calm
    [84] = { cast = "EZ07", sound = 23 },   -- Ring Of Ice
    [85] = { cast = "EISP", sound = 40 },   -- Freeze
    [86] = { target = "EISP", sound = 28 },   -- Wall Of Ice
    [87] = { cast = "EISP", persistent = "EMIF", sound = 3 },   -- Ice Floe
    [88] = { cast = "EISP", persistent = "EIFM", sound = 36 },   -- Freeze Magic
    [89] = { cast = "EIST", target = "EIST", sound = 9 },   -- Ice Storm
    [90] = { cast = "ECHC", target = "ECHC", sound = 20 },   -- Morph Combat
    [91] = { cast = "ECHC", target = "ECHC", sound = 20 },   -- Morph Speed
    [92] = { cast = "ECHC", target = "ECHC", sound = 20 },   -- Morph Health
    [93] = { cast = "ECHC", target = "ECHC", sound = 20 },   -- Morph Damage
    [94] = { cast = "ECHC", target = "ECHC", sound = 20 },   -- Morph Tower
    [95] = { cast = "EZ15", target = "EZ15", sound = 4 },   -- Drain Mana
    -- [96] Morph Resources: no spell message (a dialog)
    [97] = { cast = "ECHC", sound = 36 },   -- Increase Casting
    [98] = { cast = "ECHW", target = "ECHW", sound = 9 },   -- Wildfire
    [99] = { cast = "EZ19", target = "EZ25", sound = 18 },   -- Chaos Plague
    [100] = { cast = "EZ20", persistent = "EIMM", sound = 8 },   -- Immunity
    [101] = { cast = "EZ19", target = "EZ25", sound = 18 },   -- Poison Cloud
    [102] = { target = "EZ18", sound = 34 },   -- Summon Wasp
    [103] = { cast = "EZ20", target = "EZ20", sound = 15 },   -- Antidote
    [104] = { cast = "EPOC", persistent = "ESVT", sound = 26 },   -- Venom Touch
    [105] = { cast = "EZ19", persistent = "EPGA", sound = 26 },   -- Poison Gate
    [106] = { cast = "EPOC", sound = 27 },   -- Spray Poison
    [107] = { target = "EZ18", sound = 34 },   -- Guardian Naga
    [108] = { cast = "EPOC", target = "EPOC", sound = 15 },   -- Rot
    [109] = { target = "EZ18", sound = 34 },   -- Call of Kargoth
    [110] = { cast = "EARC", persistent = "EZ65", base = true, sound = 33 },   -- Elemental Lore
    [111] = { cast = "EDVC", persistent = "EZ66", base = true, sound = 33 },   -- Defense Lore
    [112] = { cast = "EDVC", persistent = "ESIV", sound = 42 },   -- See Invisible
    [113] = { cast = "EDVC", persistent = "EZ67", sound = 42 },   -- Telepathy
    [114] = { cast = "EZ37", target = "EZ37", sound = 30 },   -- Banish
    [115] = { cast = "EDVC", persistent = "ECOM", sound = 42 },   -- Comprehension
    [116] = { target = "EZ34", sound = 32 },   -- Call Sage
    [117] = { cast = "EDVC", persistent = "EZ68", sound = 20 },   -- Mind Leech
    [118] = { cast = "EDVC", sound = 13 },   -- True Sight
    [119] = { cast = "EDVC", target = "EDVC", sound = 30 },   -- Psychic Blast
    [120] = { cast = "EDVC", persistent = "EZ70", base = true, sound = 33 },   -- Concentration
    [121] = { cast = "EDVC", persistent = "EZ71", base = true, sound = 34 },   -- Command
    [122] = { cast = "EDVC", persistent = "EZ72", base = true, sound = 33 },   -- Enervate
    [123] = { cast = "EDVC", persistent = "EZ73", base = true, sound = 33 },   -- Extend
    [124] = { cast = "EDVC", persistent = "EZ74", base = true, sound = 33 },   -- Mana Flow
    [125] = { cast = "EDVC", persistent = "EZ75", base = true, sound = 33 },   -- Corruption
    [126] = { cast = "EARC", target = "EARC", sound = 40 },   -- Dispel
    [127] = { cast = "EDVC", persistent = "EZ76", base = true, sound = 33 },   -- Mana Leech
    [128] = { cast = "EDVC", persistent = "EZ77", base = true, sound = 33 },   -- Empower
    [129] = { cast = "EARC", target = "EX01", sound = 9 },   -- Destruction
}

local SPHERES = { [0] = "healing", "summoning", "nature", "illusion", "necromancy", "pyromancy", "alchemy", "runes", "ice", "chaos",
                  "poison", "divination", "arcane" }

return {
    ---@param content Content
    define = function(content)
        -- the engine modules are loaded here, not at the top of the file: they read settings of the registry when they load
        local bit = require("bit")
        local fx = require("src.game.fx")
        local weather = require("src.game.weather")
        local psychs = require("src.game.psych")
        local status = require("src.game.status")
        local powerups = require("src.game.powerups")
        local gamedata = require("src.game.gamedata")
        local D = {}
        -- the effect library under the names the effect bodies use
        local dist, each, nearestEnemies, ring, bolt, COL, aura, emp = fx.dist, fx.each, fx.nearestEnemies, fx.ring, fx.bolt, fx.COL, fx.aura, fx.emp
        local dur, hurt, heal, buff, buffGroup, debuffEnemies, summon, summonXp = fx.dur, fx.hurt, fx.heal, fx.buff, fx.buffGroup, fx.debuffEnemies, fx.summon, fx.summonXp
        local corpses, giveItem, isEvil, isPlanar, isCavalry, isInfantry, isUndead, isMech = fx.corpses, fx.giveItem, fx.isEvil, fx.isPlanar, fx.isCavalry, fx.isInfantry, fx.isUndead, fx.isMech
        local sideTimer, ARMOUR_TYPE, fire, hitMany, areaHurt, revive, levelOf, isFlyer = fx.sideTimer, fx.ARMOUR_TYPE, fx.fire, fx.hitMany, fx.areaHurt, fx.revive, fx.levelOf, fx.isFlyer
        local replace, place = fx.replace, fx.place
        local CW, CH = fx.CW, fx.CH

        -- An entry of the old table layout `D[slot] = { ai =, target =, portal =, name =, fn = }` becomes a record.
        local registered = {}
        setmetatable(D, {
            __newindex = function(_, slot, def)
                if registered[slot] ~= nil then error("spell slot " .. slot .. " is defined twice") end
                local rec = { slot = slot, ai = def.ai, target = def.target, portal = def.portal, name = def.name, effect = def.effect or def.fn,
                              pictures = PICTURES[slot], choices = def.choices }
                if slot >= 0 then
                    rec.sphere, rec.index, rec.cost = SPHERES[math.floor(slot / 10)], slot % 10, COST[slot]
                    rec.id = rec.sphere .. "." .. rec.index
                else
                    rec.id = "troop." .. -slot
                end
                registered[slot] = def
                content.spell:add(rec)
            end,
            __index = function(_, slot) return registered[slot] end,
        })

    -- Healing
    D[0] = { ai = "heal", effect = {
        { heal = { target = "self", amount = { perLevel = 50 }, empower = true, aura = "heal", auraRadius = 2 } },
    } }
    D[1] = { ai = "heal", effect = {
        { heal = { target = "allies", radius = "r", cure = true, amount = { perLevel = 10 }, empower = true, aura = "heal" } },
    } }
    D[2] = { ai = "buff", effect = {
        { status = { id = "morale", who = "self", seconds = { duration = "normal" }, value = { base = 1, perLevel = 1 } } },
        { aura = { key = "light", radius = 2 } },
    } }
    D[3] = { ai = "buff", effect = {
        { status = { id = "resistance", who = "allies", seconds = { duration = "normal" }, value = { perLevel = 5 }, filter = { without = "evil" } } },
    } }
    D[4] = { ai = "heal", effect = {
        { heal = { target = "allies", radius = "r", amount = { perLevel = 50 }, empower = true, aura = "heal" } },
    } }
    D[5] = { ai = "buff", fn = function(c)
        buffGroup(c, "speed", dur(c, "normal"), math.min(5, 1 + c.lvl), function(o) return not isUndead(o) end) end }
    D[6] = { ai = "attack", fn = function(c)
        each(c, "enemy", c.r, function(o)
            if isEvil(o) then
                fire(c, o, 30 + 20 * c.lvl, 4, "EMM2")           -- the damage part of Purify is a missile (FUN_0057b6a0)
            end
        end)
        weather.spell(c.w, 0)                 -- Purify sends weather 0 (day, fine): the rain stops (FUN_0057b6a0)
        aura(c, "light") end }
    D[7] = { ai = "heal", fn = function(c)
        each(c, "ally", 255, function(o) status.cure(o) heal(c, o, emp(c, 100 * c.lvl)) end) aura(c, "heal") end }
    D[8] = { ai = "buff", fn = function(c)
        if c.u.fx and c.u.fx.lifeward then return end
        buff(c, c.u, "lifeward", dur(c, "long")) aura(c, "light", 2) end }
    -- Resurrection: dead units of the caster's side (every side from level 3) rise as new units of the caster's side with
    -- full hit points; undead and timed summons do not
    D[9] = { target = "none", fn = function(c)
        corpses(c, c.rm, function(o)
            if (o.side == c.side or c.lvl >= 3) and not isUndead(o) and not o.summonUntil and not o.illusion then
                o.side = c.side
                revive(c, o, 1)
            end
        end) end }
    -- Summoning
    -- Summoned armies stay for good: the summon message's lifetime (+0x89, which the army creation FUN_004a49e0 turns into the
    -- army's end time only when it is not 0) is 0 in every summon routine of the 1.04 binary except the Eye of Oros
    -- (FUN_00581a30: duration class 6), Spectral Horde and Dragonfear (FUN_0057cab0 / FUN_0057ccd0: class 7). The number of
    -- armies (+0x99) grows with the result only for Quasit, Succubus, Wasp, Zombie (r), Skeleton, Eye (r + 1) and Spectral Horde
    -- (2r + 4); every other summon routine makes one (or a fixed number), the result only adds experience
    D[10] = { ai = "summon", portal = "BMCP", effect = {
        { summon = { unit = "AVBX", count = { perLevel = 1 }, xp = 0 } },
    } }
    D[11] = { target = "ground", fn = function(c) place(c, "BMCP", dur(c, "building")) end } -- Circle of Power
    D[12] = { ai = "buff", fn = function(c)
        local s = dur(c, "normal")
        local function f(o) return o ~= c.u and isCavalry(o) end
        buffGroup(c, "speed", s, 1 + c.lvl, f) buffGroup(c, "armor", s, 5 * c.lvl, f)
        buffGroup(c, "resistance", s, 5 * c.lvl, f) end }
    D[13] = { fn = function(c) -- Blink: a random cell within the command radius
        local w = c.w
        local gx = math.max(1, math.min(w.w - 2, c.u.gx + math.random(-c.r, c.r)))
        local gy = math.max(1, math.min(w.h - 2, c.u.gy + math.random(-c.r, c.r)))
        local x, y = w:nearestFree(gx, gy, c.u.move, 3)
        if x then
            ring(c, c.u.x, c.u.y, 2, 0.8, 0.5, 1)
            w:teleport(c.u, x, y)
            ring(c, c.u.x, c.u.y, 2, 0.8, 0.5, 1)
        end end }
    D[14] = { ai = "summon", portal = "BMCP", effect = {                -- one Imp whatever the result (FUN_005818f0)
        { summon = { unit = "AAIM", count = 1, xp = 20 } },
    } }
    D[15] = { fn = function(c)
        summonXp(c, 0, "AAEY", c.lvl + 1, dur(c, "short"), 20 * powerups.level(c.w.sides[c.side], "PGAX")) end }
    D[16] = { fn = function(c)
        local s = c.w.sides[c.side]
        if s.startX and s.startX >= 0 then
            local x, y = c.w:nearestFree(s.startX, s.startY, c.u.move, 6)
            if x then ring(c, c.u.x, c.u.y, 2, 0.8, 0.5, 1) c.w:teleport(c.u, x, y) ring(c, c.u.x, c.u.y, 2, 0.8, 0.5, 1) end
        end end }
    D[17] = { ai = "summon", portal = "BMCP", effect = {
        { summon = { unit = "AVIX", count = { perLevel = 1 }, xp = 0 } },
    } }
    -- Banish: extraplanar enemies of a level below 2 x result die, unless their owner has the Binding power-up (FUN_00581e70); the others
    -- show "Spell Resisted" (the "resisted" event: the host's spell resolution FUN_004aa840 case 0x17 sends the line, Game.txt 1112, for every target of
    -- the list - the planar flag 0x2000 of the message - that it does not kill)
    local function banish(c)
        each(c, "enemy", c.r, function(o)
            if levelOf(o) < 2 * c.lvl and not powerups.has(c.w.sides[o.side], "PBIN") then
                o:takeDamage(o.hp + 1, c.u)
            else
                c.w:event("resisted", o)
            end
        end, nil, isPlanar)
        aura(c, "light")
    end
    D[18] = { ai = "attack", fn = banish }
    D[19] = { ai = "summon", portal = "BMCP", fn = function(c) summonXp(c, 50, "AADE", 1, nil) end }   -- one Demon (FUN_00581f70)
    -- Nature
    D[20] = { ai = "summon", effect = {
        { summon = { unit = "AASP", count = 1, xp = 20 } },
    } }
    D[21] = { ai = "heal", fn = function(c)
        each(c, "ally", c.r, function(o)
            if not (isPlanar(o) or isUndead(o)) then
                heal(c, o, emp(c, 25 * c.lvl))
                if c.lvl >= 2 then status.cure(o) end
            end
        end)
        aura(c, "heal") end }
    D[22] = { ai = "attack", fn = function(c)
        each(c, "enemy", c.r, function(o) if (o.move or 0) == 0 then buff(c, o, "slow", dur(c, "short"), 2 + 2 * c.lvl) end end)
        aura(c, "earth") end }
    D[23] = { ai = "buff", effect = {
        { status = { id = "combat", who = "self", seconds = { duration = "normal" }, value = { perLevel = 5 } } },
    } }
    D[24] = { ai = "summon", effect = {
        { summon = { unit = "AEDX", count = 1, xp = 20 } },
    } }
    D[25] = { ai = "attack", target = "ground", fn = function(c) place(c, "BWBR", dur(c, "wall")) end } -- Wall of Thorns
    D[26] = { ai = "attack", fn = function(c) -- Call Lightning: every enemy unit and building in range, at most 24
        local dmg = emp(c, 40 + 20 * c.lvl)
        local n = hitMany(c, 24, dmg, 3, "elec")
        for _, b in ipairs(c.w.buildings) do
            if n >= 24 then break end
            if b.hp > 0 and c.w:enemies(c.side, b.side) and dist(b, c.u) <= c.r then hurt(c, b, dmg, 3) n = n + 1 end
        end end }
    D[27] = { ai = "summon", effect = {
        { summon = { unit = "AWJX", count = 1, xp = 20 } },
    } }
    -- The four-choice spells (1.04 binary): the cast routine FUN_005717e0 opens the four-picture dialog FUN_0055bc90 for
    -- Change Weather, Elementalism and Raise Champion (target kinds 9 / 10 / 11 of FUN_00570f80) with the spell's name as
    -- title and the picture table at 0x61b4b8 / 0x61b4f8 / 0x61b538 (codes, picture frames, the texts [SPELL_DLG_TEXT_00..11]
    -- of Spells.txt, read by FUN_0056f490); a pick sends the cast message with the choice (+0x18 of the message, the cast
    -- record's +0xc), Cancel sends nothing. The computer never casts them: they are not in its spell lists (FUN_00502ed0).
    -- `choices` is what the dialog shows (screens/spellchoice.lua); the effect reads the pick as c.target.choice (0..3).
    -- A cast without a choice (an item's spell power) takes the first: openwbc3's own (the binary reads the hero's last
    -- cast record).
    local function choiceOf(c)
        local i = c.target and c.target.choice
        return (type(i) == "number" and i >= 0 and i <= 3) and math.floor(i) or 0
    end
    local function choices(codes, text0, unit)
        local t = {}
        for i, code in ipairs(codes) do
            t[i] = { picture = code, frame = (not unit) and (i - 1) or nil, unit = unit or nil,
                     text = ("SPELL_DLG_TEXT_%02d"):format(text0 + i - 1) }
        end
        return t
    end
    -- Change Weather: the chosen number is the weather spell kind (0 day / fine .. 3 night / rain); pictures EWTH 0..3
    D[28] = { target = "choice", choices = choices({ "EWTH", "EWTH", "EWTH", "EWTH" }, 0), fn = function(c)
        weather.spell(c.w, choiceOf(c))
        aura(c, "ice", 3) end }
    -- Elementalism: one elemental of the choice, Air / Earth / Fire / Water (FUN_0057dd20)
    local ELEMENTALS = { "AAEA", "AAEE", "AAEF", "AAEW" }
    D[29] = { target = "choice", choices = choices(ELEMENTALS, 4, true), fn = function(c)
        summonXp(c, 50, ELEMENTALS[choiceOf(c) + 1], 1, nil) end }
    -- Illusion
    D[30] = { ai = "buff", effect = {
        { status = { id = "armor", who = "self", seconds = { duration = "normal" }, value = { perLevel = 5 } } },
        { status = { id = "speed", who = "self", seconds = { duration = "normal" }, value = { perLevel = 1 } } },
        { status = { id = "resistance", who = "self", seconds = { duration = "normal" }, value = { perLevel = 5 } } },
    } }
    -- Scare / Awe (FUN_0057c7c0 / FUN_0057c9b0: the psych-effect message to every enemy army in the radius that is not undead, at most
    -- 24). Checked in the 1.04 binary: the effect (FUN_004ac0e0 case 0xd) skips heroes and puts the psych effect (FUN_00528a40) on each
    -- of the rest, and that fails only for the immunities of the psych bonus routine (FUN_005286c0; drunk, mechanical, titan, critter,
    -- race rules: psych.lua); there is no resistance roll (the host's spell resolution FUN_004aa840 has no case for the effect and
    -- nothing reads the targets' resistance) and the army's other psych flags do not matter. The
    -- time is the aura's: 45 s fear, 30 s awe, 3x / 2x for the slow races, and Extend does not stretch it.
    local function psych(kind)
        return function(c)
            each(c, "enemy", c.rm, function(o)
                if not o.h and not isUndead(o) then psychs.apply(o, kind) end
            end)
            aura(c, kind == "fear" and "dark" or "light")
        end
    end
    D[31] = { ai = "attack", fn = psych("fear") }
    D[32] = { fn = function(c)      -- Light / Darkness flips the day and keeps the rain (FUN_0057c8c0)
        weather.spell(c.w, weather.lightDarkKind(c.w))
        aura(c, "dark", 3) end }
    D[33] = { ai = "attack", fn = psych("awe") }
    local SPECTRAL = content.race:view("units.spectral")
    local DRAGON = content.race:view("units.dragon")
    D[34] = { ai = "summon", fn = function(c)
        summon(c, SPECTRAL[c.w.sides[c.side].race] or "AUBX", 4 + 2 * c.lvl, dur(c, "long"), nil, true) end }
    D[35] = { ai = "summon", fn = function(c)
        summon(c, DRAGON[c.w.sides[c.side].race] or "AADR", 1, dur(c, "long"), nil, true) end }
    D[36] = { ai = "buff", fn = function(c) buff(c, c.u, "invis", dur(c, "normal")) end }
    D[37] = { ai = "summon", fn = function(c) summonXp(c, 20, "AUXX", 1, nil) end }   -- one Shadow (FUN_0057cf90)
    -- The type flags of an army (the Army.cfg status column as bits, the data item's `+0x1c0` of the binary) the spell messages test:
    -- a target needs one of `any` (when given) and none of `none` (the host's spell resolution FUN_004aa840: the message's flags at
    -- +0x135 and +0x131)
    local function flagTest(any, none)
        return function(o)
            local f = powerups.flags(o.code)
            if any ~= 0 and bit.band(f, any) == 0 then return false end
            return bit.band(f, none) == 0
        end
    end
    -- Mutate: enemies below level 1 + result become neutral animals for good (FUN_0057d0d0); the targets are every army that is not a
    -- titan (0x200) or mechanical (0x4000); a hero, an army of a level of 1 + result or more and an animal (the critters, FUN_00528280)
    -- resist ("Spell Resisted", the "resisted" event; case 0x19 of FUN_004aa840)
    local MUTATE_TARGET = flagTest(0, 0x4200)
    D[38] = { ai = "attack", fn = function(c)
        local n = 0
        each(c, "enemy", c.r, function(o)
            if o.h or levelOf(o) >= 1 + c.lvl or fx.hasTag(o, "critter") then
                c.w:event("resisted", o)
                return
            end
            n = n + 1
            local code = isFlyer(o) and "ACGO" or (n % 2 == 0 and "ACSH" or "ACPE")
            replace(c, o, code, 6)
        end, nil, MUTATE_TARGET)
        aura(c, "magic") end }
    -- Transform: friendly ordinary troops become one random type for good (FUN_0057d1d0)
    local TRANSFORM = { [0] = "AOSX", "AKIX", "AHIX", "AEIX", "AOIX", "ABIX", "AUJX", "AHMX", "AMIX", "AULX", "ADJX", "AUMX",
                        "AHGW", "AKNX", "ABGX", "AMMX", "AHGR", "AEGX", "AWGX", "ADGX", "AGGX" }
    D[39] = { fn = function(c)
        local keep = c.w.eco:keepLevel(c.side) or 0
        local n = 2 * c.lvl + keep
        local idx = math.max(0, math.min(20, math.random(n) + math.random(n) - 2))
        local left = math.min(15, 3 * c.lvl)
        each(c, "ally", c.r, function(o)
            if left > 0 and not o.h and o ~= c.u and not isFlyer(o) and not o.illusion and not o.summonUntil
                and o.side == c.side then
                left = left - 1
                status.morph(o, TRANSFORM[idx])
            end
        end)
        aura(c, "magic") end }
    -- Necromancy
    D[40] = { ai = "summon", portal = "BMBP", effect = {
        { summon = { unit = "AUIX", count = { base = 1, perLevel = 1 }, xp = 5 } },
    } }
    D[41] = { ai = "summon", portal = "BMBP", effect = {
        { summon = { unit = "AUBX", count = { perLevel = 1 }, xp = 5 } },
    } }
    D[42] = { target = "ground", fn = function(c) place(c, "BMBP", dur(c, "building")) end } -- Black Portal
    D[43] = { ai = "summon", portal = "BMBP", fn = function(c) summonXp(c, 20, "AUJX", 1, nil) end }   -- one (FUN_0057e350)
    D[44] = { ai = "buff", fn = function(c) -- Vampirism: every hit heals the attacker by 1 + result points
        local s = dur(c, "normal")      -- duration class 0 (FUN_0057e490)
        each(c, "ally", c.rm, function(o) if o:attackRange() <= 1 then buff(c, o, "vampirism", s, 1 + c.lvl) end end)
        aura(c, "dark") end }
    D[45] = { fn = function(c) weather.spell(c.w, 3) aura(c, "dark", 4) end }      -- Darkstorm: night and rain (kind 3)
    -- Strip Flesh: enemy infantry (or small or medium) armies below level 1 + result become skeletons of their own side for good
    -- (FUN_0057e160): the message's flags are infantry | small | average and not titan | undead | mechanical | flyer | monster
    -- (0x30010000 / 0x204a04); heroes, armies of that level or more and animals resist as in Mutate (case 0x25)
    local STRIP_TARGET = flagTest(0x30010000, 0x204a04)
    D[46] = { ai = "attack", fn = function(c)
        each(c, "enemy", c.r, function(o)
            if o.h or levelOf(o) >= 1 + c.lvl or fx.hasTag(o, "critter") then
                c.w:event("resisted", o)
                return
            end
            replace(c, o, "AUIX", o.side)
        end, nil, STRIP_TARGET)
        aura(c, "dark") end }
    D[47] = { ai = "summon", fn = function(c) -- Call the Dead: every corpse in range (at most 24) becomes a skeleton for good
        local n = 0
        local xp = c.w.eco:initialXp(c.side, "AUIX", { training = false, gate = true }) + 20 * (c.lvl - 1) -- FUN_0057e670
        -- FUN_0057e670 collects the corpses (at most 24) first and, when there is one, checks the army limit for a unit value of 1
        local found = 0
        corpses(c, c.r, function() found = found + 1 end)
        if found > 0 and not fx.roomFor(c, nil) then return end
        corpses(c, c.r, function(o)
            if n < 24 then
                n = n + 1
                local u = replace(c, o, "AUIX", c.side)
                if u and xp > 0 then u:addXp(xp) end
            end
        end) end }
    D[48] = { ai = "attack", effect = {
        { damage = { amount = { base = 25, perLevel = 25 }, empower = true, damageType = 2, key = "ice", radius = 7, buildings = true } },
    } }
    -- Raise Champion: one army of the choice whatever the result (FUN_0057ea70: AUXX / AUMX / AUGX / AUAX; the dialog's
    -- texts 08..11), see the four-choice spells at Change Weather
    local CHAMPIONS = { "AUXX", "AUMX", "AUGX", "AUAX" }
    D[49] = { target = "choice", choices = choices(CHAMPIONS, 8, true), portal = "BMBP", fn = function(c)
        summonXp(c, 20, CHAMPIONS[choiceOf(c) + 1], 1, nil) end }
    -- Pyromancy
    D[50] = { ai = "attack", effect = {
        { damage = { amount = { base = 10, perLevel = 10 }, empower = true, damageType = 1, key = "fire", missile = "EMF0" } },
    } }
    -- Soul Flame: the friendly troops in the command radius gain experience (FUN_0057f9e0, an add-experience message):
    -- 5 + 5 x result points (empowered), each army's total raised to at most 10 x result (the message's handler caps the
    -- army's experience at that maximum and adds min(maximum - XP, points)); heroes and titans gain none (Unit:addXp)
    D[51] = { ai = "buff", fn = function(c)
        local xp = emp(c, 5 + 5 * c.lvl)
        local cap = c.lvl * 10
        each(c, "ally", c.r, function(o)
            if o ~= c.u and not o.h and (o.xp or 0) < cap then
                o:addXp(math.min(cap - (o.xp or 0), xp))
            end
        end)
        aura(c, "fire") end }
    D[52] = { ai = "heal", effect = {
        { heal = { target = "allies", radius = "r", amount = { perLevel = 25 }, empower = true, aura = "fire" } },
    } }
    D[53] = { ai = "buff", effect = {
        { status = { id = "resfire", who = "allies", seconds = { duration = "normal" }, value = { perLevel = 25 } } },
    } }
    D[54] = { ai = "attack", effect = {
        { damage = { amount = { base = 25, perLevel = 25 }, empower = true, damageType = 1, key = "fire", radius = 6, buildings = true } },
    } }
    D[55] = { ai = "buff", fn = function(c) buffGroup(c, "firebreath", dur(c, "normal"), 5 + 5 * c.lvl, function(o) return o ~= c.u end) end }
    D[56] = { ai = "buff", fn = function(c)
        local s = dur(c, "long")
        local function f(o) return o ~= c.u and not isMech(o) end
        -- the Berserker spell also immolates its units (the original's immolation type 2 from a spell, FUN_0057ffe0):
        -- they burn for 1 hit point a second and go rampant for the spell's duration, on top of the combat / speed bonus
        each(c, "ally", c.r, function(o)
            if f(o) then
                buff(c, o, "combat", s, 4 + c.lvl)
                buff(c, o, "speed", s, 3 + 2 * c.lvl)
                status.berserk(o, s * 1000 * c.ext)
            end
        end)
        aura(c, "light") end }
    D[57] = { ai = "attack", fn = function(c) -- Pillar of Fire: around the caster
        bolt(c, c.u.x, c.u.y - 140, c.u.x, c.u.y, 1, 0.5, 0.1)
        areaHurt(c, emp(c, 60 + 40 * c.lvl), 1, "fire", 3, true) end }
    D[58] = { ai = "summon", effect = { { summon = { unit = "AAEF", count = 1, xp = 50 } } } }
    D[59] = { ai = "attack", effect = {
        { damage = { amount = { base = 50, perLevel = 50 }, empower = true, damageType = 1, key = "fire", buildings = true } },
    } }
    -- Alchemy
    local CREATE_TIERS = { { [1] = true, [2] = true }, { [1] = true, [2] = true, [3] = true },
                           { [2] = true, [3] = true, [4] = true }, { [3] = true, [4] = true, [5] = true } }
    D[60] = { fn = function(c) -- Create Item: a random item by result (minor/lesser/major/artifact/set), dropped at the hero's feet
        local it = require("src.game.items").randomOf(CREATE_TIERS[math.min(4, c.lvl)])
        if it then c.w:dropItem(c.u.gx, c.u.gy, it) c.w:event("itemfound", c.u, it, "ground") end end }
    -- Transmute / Morph Resources: the original opens the trade dialog at this rate; openwbc3's choice of what to trade is
    -- its own (half of the richest resource, at most 150, into the poorest)
    local function transmute(c, rate)
        local s = c.w.sides[c.side]
        local hi, lo = "gold", "gold"
        for _, r in ipairs({ "gold", "metal", "crystal", "stone" }) do
            if s[r] > s[hi] then hi = r end
            if s[r] < s[lo] then lo = r end
        end
        local amount = math.min(150, math.floor(s[hi] / 2))
        s[hi], s[lo] = s[hi] - amount, s[lo] + math.floor(amount * math.min(100, rate) / 100)
    end
    D[61] = { fn = function(c) transmute(c, 40 + 10 * c.lvl) end }
    D[62] = { fn = function(c) sideTimer(c, "charm", dur(c, "normal")) c.w.sides[c.side].charmValue = 2 * c.lvl aura(c, "light", 2) end }
    D[63] = { ai = "summon", effect = { { summon = { unit = "AAIX", count = 1, xp = 20 } } } } -- Golem (FUN_005756b0)
    D[64] = { fn = function(c) c.h.potions.health = c.h.potions.health + c.lvl aura(c, "heal", 2) end } -- Brew Potion
    D[65] = { fn = function(c)
        local eco = c.w.eco
        -- FUN_005758b0 calls the conversion routine FUN_00532640(side, x, y, result / 2, mines only)
        for _, b in ipairs(eco:conversionTargets(c.u, math.floor(c.rm / 2), true)) do eco:setOwner(b, c.side) end
        aura(c, "light") end }
    D[66] = { target = "ground", fn = function(c) -- Guardian: a building for (8 + 2 x result) minutes
        place(c, c.lvl <= 1 and "BWGC" or c.lvl == 2 and "BWGS" or "BWGI", (c.lvl + 4) * 120) end }
    D[67] = { ai = "attack", fn = function(c) -- Disjunction: the items of every other side stop working
        local s = dur(c, "short")
        each(c, "enemy", 255, function(o) if o.h then o.h.itemsOff = c.w.time + s * 1000 * c.ext o.h:recalc() end end)
        aura(c, "magic") end }
    D[68] = { ai = "summon", effect = { { summon = { unit = "AAGX", count = 1, xp = 20 } } } }
    D[69] = { fn = function(c) c.h.itemMult = { t1 = c.w.time + dur(c, "normal") * 1000 * c.ext, value = 2 } c.h:recalc() aura(c, "magic", 2) end }
    -- Runes
    D[70] = { ai = "buff", effect = {
        { status = { id = "armor", who = "self", seconds = { duration = "normal" }, value = 10 } },
    } }
    D[71] = { fn = function(c) c.h.nextBonus = emp(c, 10 + 10 * c.lvl) aura(c, "light", 2) end }
    D[72] = { fn = function(c) -- Dig: buildings go up (10 + 10 x result) percent faster, at most 75
        sideTimer(c, "dig", dur(c, "long")) c.w.sides[c.side].digPct = math.min(75, 10 + 10 * c.lvl) aura(c, "earth", 3) end }
    D[73] = { ai = "heal", fn = function(c) -- Earthpower: damaged buildings of the caster's side and its allies
        for _, b in ipairs(c.w.buildings) do
            if b.hp > 0 and b.hp < b.maxHp and b.complete and (b.side == c.side or (b.side ~= 6 and not c.w:enemies(c.side, b.side)))
                and dist(b, c.u) <= c.rm then
                b.hp = math.min(b.maxHp, b.hp + emp(c, 200 * c.lvl))
            end
        end
        aura(c, "earth") end }
    D[74] = { ai = "buff", effect = {
        { status = { id = "resmagic", who = "self", seconds = { duration = "normal" }, value = { perLevel = 25 } } },
    } }
    D[75] = { ai = "attack", effect = {
        { damage = { amount = { base = 10, perLevel = 20 }, empower = true, damageType = 0, key = "earth", buildings = true, missile = "EMC0" } },
    } }
    D[76] = { target = "ground", fn = function(c) -- Guardian (runes): the same buildings for the tower duration
        place(c, c.lvl <= 1 and "BWGC" or c.lvl == 2 and "BWGS" or "BWGI", dur(c, "tower")) end }
    D[77] = { ai = "buff", effect = {
        { status = { id = "resmissile", who = "self", seconds = { duration = "normal" } } },
    } }
    D[78] = { fn = function(c) giveItem(c, math.min(3, 1 + math.floor(c.h.level / 6))) end } -- own: the original offers four fixed items
    D[79] = { ai = "summon", effect = { { summon = { unit = "AAEE", count = 1, xp = 50 } } } }
    -- Ice
    D[80] = { ai = "attack", effect = {
        { damage = { amount = { base = 15, perLevel = 10 }, empower = true, damageType = 2, key = "ice", missile = "EMIS" } },
    } }
    -- Storm: rain; a success level of 2 or more makes it a storm (binary FUN_0057be40: kinds 1 / 4 by day, 3 / 5 at night)
    D[81] = { fn = function(c) weather.spell(c.w, weather.stormKind(c.w, c.lvl)) aura(c, "ice", 3) end }
    D[82] = { ai = "buff", effect = {
        { status = { id = "armor", who = "self", seconds = { duration = "normal" }, value = { perLevel = 5 } } },
    } }
    D[83] = { fn = function(c) -- Calm: every spell effect goes, poison and disease stay
        each(c, "all", c.rm, function(o) status.clear(o, false, { poison = true, disease = true }) end) aura(c, "light") end }
    D[84] = D[48]
    D[85] = { ai = "attack", effect = {
        { status = { id = "slow", who = "enemies", seconds = { duration = "short" }, value = { base = 1, perLevel = 1 } } },
        { aura = { key = "ice" } },
    } }
    D[86] = { ai = "attack", target = "ground", fn = function(c) place(c, "BWIC", dur(c, "wall")) end } -- Wall of Ice
    D[87] = { ai = "buff", fn = function(c) buff(c, c.u, "icefloe", dur(c, "short"), emp(c, 5 + 15 * c.lvl)) end }
    D[88] = { fn = function(c) c.w.manaFreeze = { t1 = c.w.time + dur(c, "normal") * 1000 * c.ext, side = c.side } aura(c, "ice", 6) end }
    D[89] = { ai = "attack", effect = {
        { damage = { amount = { base = 50, perLevel = 50 }, empower = true, damageType = 2, key = "ice", buildings = true, missile = "EMM2" } },
    } }
    -- Chaos: one roll per cast, uniform in -3r..3r without 0, changes the base stats of every army in range for good
    local function morphRoll(c)
        local k
        repeat k = math.random(1 + 6 * c.lvl) - (3 * c.lvl + 1) until k ~= 0
        return k
    end
    local function morph(c, field)
        local k = morphRoll(c)
        each(c, "all", c.r, function(o)
            if o == c.u then return end
            if field == "hits" then
                o.maxHp = math.max(1, math.min(999, o.maxHp + 10 * k))
                o.hp = math.max(1, math.min(o.maxHp, o.hp + 10 * k))
            elseif field ~= "damage" or (o.type and (o.type.damage or 0) > 0) then
                o.morphMod = o.morphMod or {}
                o.morphMod[field] = (o.morphMod[field] or 0) + k
            end
        end)
    end
    D[90] = { fn = function(c) morph(c, "combat") end }
    D[91] = { fn = function(c) morph(c, "speed") end }
    D[92] = { fn = function(c) morph(c, "hits") end }
    D[93] = { fn = function(c) morph(c, "damage") end }
    D[94] = { fn = function(c) -- Morph Tower: towers of every side, one random statistic
        local k = morphRoll(c)
        local field = ({ "combat", "speed", "hits", "damage" })[math.random(4)]
        for _, b in ipairs(c.w.buildings) do
            if b.hp > 0 and b.complete and (b.type.damage or 0) > 0 and dist(b, c.u) <= c.r then
                if field == "hits" then
                    b.maxHp = math.max(1, math.min(999, b.maxHp + 10 * k))
                    b.hp = math.max(1, math.min(b.maxHp, b.hp + 10 * k))
                else
                    b.morphMod = b.morphMod or {}
                    b.morphMod[field] = (b.morphMod[field] or 0) + k
                end
            end
        end
    end }
    D[95] = { ai = "attack", fn = function(c) -- Drain Mana: the victims lose it, the caster gains nothing
        local amount = emp(c, 25 + 25 * c.lvl)
        each(c, "enemy", c.rm, function(o)
            if o.h and (o.h.mana or 0) > 0 then o.h.mana = o.h.mana - math.min(amount, o.h.mana) end
        end)
        aura(c, "dark") end }
    D[96] = { fn = function(c) transmute(c, 40 + 10 * c.lvl + math.random(21) - 11) end }
    D[97] = { fn = function(c) -- Learn Spell: +1 casting skill in a random sphere, once (binary: FUN_00577100 sends
        -- effect 0x20, which FUN_004ac0e0 turns into the Spell Research power-up PSPR: one research call FUN_00438180(side, 1))
        require("src.game.powerups").research(c.w, c.u.side, 1) end }
    D[98] = { ai = "attack", effect = {
        { damage = { amount = { perLevel = 50 }, empower = true, damageType = 1, key = "fire", buildings = true, missile = "EMM4" } },
    } }
    D[99] = { ai = "attack", fn = function(c) -- Chaos Plague: (53 - 3 x result) percent of the hit points stay, and disease
        local pct = math.max(5, 53 - 3 * c.lvl)
        each(c, "enemy", c.base, function(o)
            o.hp = math.max(1, math.floor(o.hp * pct / 100))
            status.disease(o)
        end)
        aura(c, "poison") end }
    -- Poison
    D[100] = { ai = "buff", effect = { { status = { id = "immunity", who = "self", seconds = { duration = "long" } } } } } -- Immunity: no poison or disease
    D[101] = { ai = "attack", fn = function(c) -- Poison Cloud
        each(c, "enemy", c.rm, function(o) if not o.h and not isUndead(o) and not isMech(o) then status.poison(o) end end)
        aura(c, "poison", c.rm) end }
    D[102] = { ai = "summon", effect = { { summon = { unit = "AAWA", count = { perLevel = 1 }, xp = 0 } } } }
    D[103] = { ai = "heal", fn = function(c) each(c, "ally", c.rm, function(o) status.cure(o) end) aura(c, "heal") end }
    D[104] = { ai = "buff", fn = function(c) buffGroup(c, "venom", dur(c, "normal"), nil, function(o) return o ~= c.u end) end }
    D[105] = { fn = function(c) sideTimer(c, "poisonGate", dur(c, "normal")) aura(c, "poison", 2) end } -- Poison Gate
    D[106] = { ai = "attack", fn = function(c) -- Spray Poison: a poisoned arrow at every enemy in range
        local dmg = emp(c, 30 + 10 * c.lvl)
        hitMany(c, 24, dmg, 0, "poison", nil, "EMAP") end }
    D[107] = { ai = "summon", effect = { { summon = { unit = "ALGX", count = 1, xp = 20 } } } }
    D[108] = { ai = "attack", fn = function(c) -- Rot: poisoned enemies of a level below 1 + result drop to 1/8 of their hit points
        each(c, "enemy", c.rm, function(o)
            if levelOf(o) >= 1 + c.lvl then
                -- only a poisoned or diseased army shows "Spell Resisted" (case 0x26 of FUN_004aa840)
                if o.fx and (o.fx.poison or o.fx.disease) then c.w:event("resisted", o) end
                return
            end
            if not o.fx then return end
            if o.fx.poison and o.hp > math.floor(o.maxHp / 8) then
                o.hp = math.max(1, math.floor(o.maxHp / 8))
            elseif o.fx.disease then
                local st = o:stats()
                o.fx.disease.forced = math.max(st.combat, st.speed)
            end
        end)
        aura(c, "poison") end }
    D[109] = { ai = "summon", fn = function(c) summonXp(c, 20, "AKLX", 8, nil) summonXp(c, 20, "AKKX", 8, nil) end }
    -- Divination. Elemental Lore and Defense Lore (FUN_0057a6b0 / FUN_0057a7b0) send the persistent effect EZ65 / EZ66 with
    -- the special effect type 100 (at the base), so the caster keeps a looping aura sprite at its base for as
    -- long as the buff lasts.
    D[110] = { ai = "buff", effect = {
        { status = { id = "resistance", who = "self", seconds = { duration = "normal" }, value = 10, effect = "EZ65" } },
    } }
    D[111] = { ai = "buff", effect = {
        { status = { id = "armor", who = "self", seconds = { duration = "normal" }, value = 10, effect = "EZ66" } },
    } }
    D[112] = { fn = function(c) sideTimer(c, "seeInvisible", dur(c, "long")) aura(c, "light", 2) end }
    -- Telepathy (FUN_0057a9a0, the training power on the hero): armies the side produces while the hero lives
    -- start with this much more experience (the initial experience routine FUN_00557d90); the value is the empowered result x 10 points
    D[113] = { fn = function(c)
        sideTimer(c, "training", dur(c, "normal"))
        c.w.sides[c.side].trainingXp = emp(c, c.lvl * 10)
        aura(c, "light", 2) end }
    D[114] = D[18]
    D[115] = { fn = function(c) -- Comprehension: cheaper power-ups and runes
        sideTimer(c, "cheapSkills", dur(c, "normal")) c.w.sides[c.side].cheapPct = math.min(50, 20 + 5 * c.lvl) aura(c, "light", 2) end }
    D[116] = { ai = "summon", fn = function(c)
        local codes = { "AHGR", "AHGW", "AHGB" }
        summonXp(c, 20, codes[math.random(#codes)], 1, nil) end }
    -- Mind Leech (FUN_0057ad20, the energy-drain power on the friendly troops in the command radius): a troop with it
    -- gains the experience of the army it kills (army death FUN_005210b0, energy-drain test FUN_00526fe0); heroes are immune (the message
    -- skips the power for heroes), as are missle / mechanical / ship units (the radius flags, not modelled here)
    D[117] = { ai = "buff", fn = function(c)
        each(c, "ally", c.r, function(o)
            if o ~= c.u and not o.h then buff(c, o, "drain", dur(c, "normal")) end
        end)
        aura(c, "dark", 2) end }
    D[118] = { fn = function(c)
        local sd = c.w.sides[c.side]
        sd.trueSight = true
        sd.visionBonus = (sd.visionBonus or 0) + c.lvl
        aura(c, "light", 4) end }
    D[119] = { ai = "attack", effect = {
        { status = { id = "stun", who = "enemies", seconds = { duration = "veryShort" } } },
        { aura = { key = "magic" } },
    } }
    -- Arcane
    D[120] = { fn = function(c) sideTimer(c, "concentration", dur(c, "arcane")) c.w.sides[c.side].concentrationPct = 15 + 5 * c.lvl
        aura(c, "magic", 2) end }
    D[121] = { fn = function(c) sideTimer(c, "command", dur(c, "arcane")) c.w.sides[c.side].commandPct = 25 * c.lvl aura(c, "magic", 2) end }
    D[122] = { fn = function(c) sideTimer(c, "enervate", dur(c, "arcane")) c.w.sides[c.side].enervatePct = 75 + 25 * c.lvl
        aura(c, "magic", 2) end }
    D[123] = { fn = function(c) sideTimer(c, "extend", dur(c, "arcane")) aura(c, "magic", 2) end }
    D[124] = { fn = function(c) sideTimer(c, "manaflow", dur(c, "arcane")) aura(c, "magic", 2) end }
    D[125] = { fn = function(c) -- Corruption: armies other sides summon may join the caster's side
        sideTimer(c, "corruption", dur(c, "arcane")) c.w.sides[c.side].corruptionPct = 20 + 10 * c.lvl aura(c, "dark") end }
    D[126] = { ai = "attack", fn = function(c) -- Dispel: every spell effect of every unit around, poison and disease stay
        local rad = math.floor(c.base + 50 * c.lvl * c.base / 100)
        each(c, "all", rad, function(o)
            status.clear(o, false, { poison = true, disease = true })
            if o.h then o.h.itemsOff = nil end
        end)
        aura(c, "light") end }
    D[127] = { fn = function(c) c.h.manaLeech = c.w.time + dur(c, "arcane") * 1000 * c.ext c.h.manaLeechAmount = 4 + c.lvl
        aura(c, "dark", 2) end }
    D[128] = { fn = function(c) sideTimer(c, "empower", dur(c, "arcane")) c.w.sides[c.side].empowerPct = 25 + 25 * c.lvl
        aura(c, "magic", 2) end }
    D[129] = { ai = "attack", fn = function(c) -- Destruction: every army and building around takes the caster's hit points - 1
        local dmg = math.max(1, emp(c, c.u.hp - 1))
        each(c, "all", c.rm, function(o) o:takeDamage(dmg, c.u) end)
        for _, b in ipairs(c.w.buildings) do
            if b.hp > 0 and dist(b, c.u) <= c.rm then c.w:damageBuilding(b, dmg, c.u) end
        end
        aura(c, "dark") end }

    -- Unit-only spells: troops get spells of their own that no hero can learn; in the 1.04 binary each has its own
    -- routine, called from the button handler FUN_00426350 (Shield FUN_00578930, Multi-Target FUN_00578c90 ...).
    -- openwbc3 keeps them in the same table with negative indices.
    D[-1] = { name = "0886", fn = function(c) -- Shield: +10 armour to the allies in the command radius (FUN_00578930)
        each(c, "ally", c.r, function(o) buff(c, o, "armor", dur(c, "short"), 10) end)
        aura(c, "light") end }
    D[-2] = { name = "0222", fn = function(c) -- Multi-Target: a missile at every enemy within the unit's own range
        -- (FUN_00578c90: 30 piercing points, the unit's level used to add 2 each; openwbc3's troops have none)
        local rad = math.max(6, c.u.type and c.u.type.range or 0)
        hitMany(c, 24, emp(c, 30), 0, "light", rad, "EMA1") end }
    D[-3] = { name = "0720", fn = function(c) summonXp(c, 20, "AABA", 4, nil) end } -- Summon Bats: four permanent Giant Bats
    D[-4] = { name = "0890", fn = function(c) summonXp(c, 20, "AKLX", 1, nil) end } -- Summon Spiders: one permanent Queen Spider
    D[-7] = { name = "0879", fn = function(c) summonXp(c, 0, "AASX", c.lvl, nil) end } -- Create Firebomb: one per result
    D[-5] = { name = "0902", fn = function(c) summonXp(c, 0, "AOSX", 4 + c.lvl, nil) end } -- Goblin Horde: four plus one per result
    D[-6] = { name = "1104", fn = function(c) summonXp(c, 0, "AHLX", 2 + c.lvl, nil) end } -- Summon Blades: two plus one per result

    -- n dice of `faces`, the original's dice roll without the bonus (callers add it)
    local function dice(n, faces)
        local s = 0
        for _ = 1, n do s = s + math.random(faces) end
        return s
    end

    local function give(c, got)
        local s = c.w.sides[c.side]
        for _, r in ipairs({ "gold", "metal", "stone", "crystal" }) do
            if got[r] > 0 then
                s[r] = s[r] + got[r]
                c.w:battleStats():resource(c.side, r, got[r], "obtained")
            end
        end
    end

    D[-9] = { name = "0234", fn = function(c) -- Feast: the Undead eat the fallen armies around them (FUN_00578e10:
        -- bones give 1d20 gold and dying armies one resource by a d6; openwbc3 has no bone heaps)
        local got = { gold = 0, metal = 0, stone = 0, crystal = 0 }
        corpses(c, 6, function(o)
            local roll, amount = math.random(6), dice(c.lvl, 20)
            if roll <= 2 then got.gold = got.gold + amount
            elseif roll <= 4 then got.metal = got.metal + amount
            elseif roll == 5 then got.stone = got.stone + amount
            else got.crystal = got.crystal + amount end
        end)
        give(c, got)
        aura(c, "dark") end }
    D[-8] = { name = "0872", fn = function(c) -- Plague Cloud: the enemies around the caster fall sick (FUN_00579f80;
        -- the original's flag mask picks the humanoid races, openwbc3 only leaves out the undead and heroes)
        each(c, "enemy", c.rm, function(o) if not o.h and not isUndead(o) then status.disease(o) end end)
        c.w:event("emit", c.u, "ECHC")          -- its casting effect (FUN_00579f80)
        aura(c, "poison", c.rm) end }
    D[-10] = { name = "0526", fn = function(c) -- Scavenge: the Bronze Golem takes the rubble of wrecked buildings
        -- (FUN_00579410, checked in the 1.04 binary: one roll of d8 per heap of rubble (EDB0..2 effect) within a radius
        -- of 6, i.e. dx^2 + dy^2 <= 36, then the heaps are removed. openwbc3's rubble is the wrecked
        -- building itself, one heap each, taken away when scavenged. The button has a 1 s throttle shared by all casters
        -- in the original (FUN_004cfce0); the roll table, the dice with the caster's casting level + 1 and the
        -- all-four-resources roll 8 are the original's.)
        local got = { gold = 0, metal = 0, stone = 0, crystal = 0 }
        for _, b in ipairs(c.w.buildings) do
            local dx, dy = b.gx - c.u.gx, b.gy - c.u.gy
            if b.rubbleSince and dx * dx + dy * dy <= 36 then
                b.wreck = nil                      -- cleaned out: the building is dropped by World:update
                local roll = math.random(8)
                if roll <= 2 then
                    got.metal, got.stone = got.metal + dice(c.lvl + 1, 20) + 20, got.stone + dice(c.lvl + 1, 20) + 20
                elseif roll <= 4 then
                    got.metal = got.metal + dice(c.lvl + 1, 40) + 20
                elseif roll <= 6 then
                    got.stone = got.stone + dice(c.lvl + 1, 40) + 20
                elseif roll == 7 then
                    got.gold, got.metal = got.gold + dice(c.lvl + 1, 20) + 20, got.metal + dice(c.lvl + 1, 20) + 20
                else
                    for _, r in ipairs({ "gold", "metal", "stone", "crystal" }) do
                        got[r] = got[r] + dice(c.lvl + 1, 20) + 20
                    end
                end
            end
        end
        give(c, got)
        aura(c, "earth") end }

    end,
}