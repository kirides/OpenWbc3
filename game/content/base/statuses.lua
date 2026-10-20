-- The timed effects on units (docs/data-driven/03-spells-effects.md 3.4): `u.fx[kind] = { t1, value, ... }` and what each kind does.
-- The engine (src/game/status.lua) applies, refreshes, ticks and expires them; the behaviour of a kind is these records. Fields
-- (kinds/status.lua): stat, bonus, stats(u, st, f), negative, stuns, tick = { every, fn(u, f, t) }, expire(u, f), onRemove(u),
-- resist = { type, pct }, immuneRanged, damage = { type, range }, infection, blocksInfection. All rules are the original's (the
-- binary's regeneration tick FUN_0051b820, poisoning FUN_0051bfb0, immolation FUN_00527720, freeze FUN_00527b30, damage getter
-- 0x00526310 ...); the long comments live in status.lua next to the helpers that apply them.
return {
    ---@param content Content
    define = function(content)
        local S = content.status
        local function add(id, fields)
            fields.id = id
            S:add(fields)
        end

        -- plain statistic modifiers: the value is added
        for _, stat in ipairs({ "combat", "speed", "armor", "resistance", "damage" }) do
            add(stat, { stat = stat, doc = "adds its value to the " .. stat .. " statistic" })
        end

        -- disabling
        add("stun", { negative = true, stuns = true, doc = "the unit cannot act" })
        add("slow", { negative = true, doc = "value = speed points lost",
            stats = function(u, st, f) st.speed = math.max(0, st.speed - f.value) end })
        add("fear", { negative = true, doc = "psych effect: half the damage",
            stats = function(u, st) st.damage = math.floor(st.damage / 2) end })
        add("awe", { negative = true, doc = "psych effect: no ranged attack",
            stats = function(u, st) st.range = math.min(st.range, 1) end })
        add("terror", { negative = true, doc = "psych effect: the army runs; free again when it ends",
            expire = function(u) require("src.game.psych").dropOrders(u) end })
        add("chaos", { negative = true, doc = "psych effect" })
        add("psychimmune", { doc = "30 s after an army resisted an aura" })
        add("poly", { negative = true, doc = "polymorph: the original type record is kept in `orig`",
            expire = function(u, f)
                u.fx.poly = f
                require("src.game.status").unpoly(u)
                u.fx.poly = nil
            end,
            onRemove = function(u) require("src.game.status").unpoly(u) end })

        -- infections
        add("poison", { negative = true, infection = true,
            doc = "1 hit point per second, not below 1/8 of the maximum (Melkor's Curse doubles it); 600 s",
            tick = { every = 1000, fn = function(u)
                if u.hp > math.floor(u.maxHp / 8) then
                    local dmg = require("src.game.powerups").melkorCurse(u.world) and 2 or 1
                    -- the original takes the hit points off directly (the regeneration tick FUN_0051b820 subtracts 1, or 2 under Melkor's
                    -- Curse): no hit message, so no hit list entry, no been-hit flag and no drunkenness trigger
                    u.hp = u.hp - dmg
                end
            end } })
        add("disease", { negative = true, infection = true,
            doc = "lowers combat and speed by a modifier that grows with time up to 10 + virulence (at most 100)",
            stats = function(u, st, f)
                local mod = f.forced
                if not mod then
                    local v = require("src.game.heroskills").virulence(u.world)
                    mod = math.min(math.min(100, 10 + v), math.floor((u.world.time - f.t0) / (1000 * math.max(1, 5 + 2 * (f.res - v)))))
                end
                st.combat = math.max(0, st.combat - mod)
                st.speed = math.max(0, st.speed - mod)
            end })
        add("immunity", { blocksInfection = true, doc = "no poison or disease" })

        -- burning: immolation (type 0 / 1 from critical hits, `immol`), the Fanaticism ability, the Berserker spell
        local function burnTick(kind)
            return { every = 1000, fn = function(u, f) u:takeDamage(kind == "fanatic" and 1 or f.value, nil) end }
        end
        local function restoreAttitude(u, f) u.attitude = f.oldAttitude end
        add("immol", { doc = "burns for `value` hit points a second, rampant meanwhile", tick = burnTick("immol"), expire = restoreAttitude })
        add("berserk", { negative = true, doc = "the Berserker spell: 1 hit point a second, rampant", tick = burnTick("berserk"),
            expire = restoreAttitude })
        add("fanatic", { doc = "Fanaticism: +6 combat, +4 speed, 1 hit point a second, rampant", bonus = { combat = 6, speed = 4 },
            tick = burnTick("fanatic"), expire = restoreAttitude })
        add("drunk", { doc = "Drunkenness: +4 combat and speed, immune to psych effects", bonus = { combat = 4, speed = 4 } })

        -- protections and spell effects the unit rules read
        add("resfire", { doc = "Resist Fire: value percent of fire damage resisted (25 per level)", resist = { type = 1, pct = 25 } })
        add("resmagic", { doc = "Resist Magic: value percent of magic damage resisted", resist = { type = 4, pct = 25 } })
        add("resmissile", { doc = "Resist Missiles: ranged damage does nothing", immuneRanged = true })
        add("firebreath", { doc = "Fire Breathing: fire damage of the value's strength at range 5", damage = { type = 3, range = 5 } })
        add("icefloe", { doc = "Ice Floe: ice damage of the value's strength at range 12", damage = { type = 1, range = 12 } })
        for _, e in ipairs({ { "invis", "invisible" }, { "lifeward", "Life Ward" }, { "ward", "Ward: spell effects of others do not take" },
                             { "venom", "Venom: poisons what it hits" }, { "vampirism", "value hit points back per hit" },
                             { "morale", "value = morale bonus" },
                             { "drain", "Mind Leech: the troop gains the experience of the army it kills" } }) do
            add(e[1], { doc = e[2] })
        end
    end,
}
