-- Timed effects on units (spells, poison, slows ...). u.fx[kind] = { t1, value, ... }.
--
-- stat kinds   : combat, speed, armor, resistance, damage (value is added)
-- state kinds  : stun, slow (value = speed points lost), poison, disease, fear, awe, invis, lifeward, ward,
--                venom, vampirism (value = hit points per hit), firebreath, icefloe, morale (value = bonus),
--                resfire, resmagic, resmissile, poly (value = original type record), drain (Mind Leech: the troop
--                gains the experience of the army it kills: army death FUN_005210b0, energy-drain test FUN_00526fe0)
--
-- Drunkenness (+4 combat and speed, immune to psych effects, 2 minutes) and Fanaticism (the original's type 2 immolation:
-- +6 combat, +4 speed, 1 hit point lost per second, 3 minutes, rampant attitude meanwhile) are army abilities, see
-- armyabilities.lua; kinds drunk and fanatic. Immolation of type 0 / 1 (kind immol) is what a critical fire or hot-and-
-- pointy hit does to its victim: 2 hit points a second for 15 s, or 5 for 60 s, and a rampant attitude meanwhile
-- (immolation routine FUN_00527720). The Berserker spell's immolation (the original's type 2 from a spell, FUN_0057ffe0)
-- is kind berserk: the same 1 hit point a second and rampant attitude, but for the spell's own duration and without the
-- +6 / +4 bonus (that belongs to the Fanaticism ability); the original keeps one immolation flag with a type, openwbc3
-- models the type 2 ability and the type 2 spell as the two kinds fanatic and berserk.
-- The other critical-hit special attacks (melee FUN_0042ace0, the fight activation FUN_00523150 for missiles) are in
-- unit.lua's strike: the ice freeze is an 8 s slow of 6 speed points (kind slow; the original's slow-all effect 6 also slows fight
-- speed, which openwbc3 does not model), electricity drains 40 mana, magic dispels, crushing stuns for 5 s and
-- slashing cleaves splash every enemy troop within 2 cells of the attacker; the basilisk and the Titan Orc's petrify
-- missile (EMM5) kills its victims and gives the inflictor's side 50 stone, a victim that survives the hit is frozen
-- instead. All of these come from the original (melee FUN_0042ace0, fight activation FUN_00523150, the army routines
-- freeze FUN_00527b30, stun FUN_00527d10, petrify FUN_005280c0, cleave FUN_005278a0, the host's spell resolution
-- FUN_004aa840, the stone added by the petrify message handler FUN_004a9c90).
-- Poison and disease follow the original (regeneration tick FUN_0051b820, poisoning FUN_0051bfb0, the can-be-poisoned
-- test FUN_0051c130): poison is a flag that costs 1 hit point per second (not below 1/8 of the maximum), lasts
-- 600 s, the first tick comes 500 + 128 x resistance ms after the infection, and a poisoned or diseased unit does not
-- regenerate. Disease lowers combat and speed by a modifier that grows by 1 every 5 + 2 x (resistance - virulence)
-- seconds (at least every second) up to 10 + virulence (at most 100); the virulence is the plague piles plus the
-- Contamination skills of the living heroes (heroskills.virulence, binary FUN_0040d9b0 / FUN_00532a20 / FUN_0051c060).
-- Poison and disease exclude each other. Fear / Awe (45 s / 30 s) are the original psych effects, not stuns; terror
-- (15 s), chaos (30 s) and `psychimmune` (30 s after resisting an aura) are the other psych flags, all four are put on
-- armies by the auras of psych.lua (which has the rules), a clear of the spell effects leaves `psychimmune` alone.
local content = require("src.content")

local M = {}

-- One timed effect: u.fx[kind]. The kind's record may keep more fields on it (tick state, orig of poly ...).
---@class StatusEffect
---@field t1 number            world time (ms) it ends
---@field value number?        strength (stat kinds: added to the stat)
---@field nextTick number?     world time of the next tick (kinds with a tick)
---@field t0 number?           disease: when it started
---@field res number?          disease: the victim's resistance at the infection
---@field forced number?       disease: a fixed modifier a spell set (Plague, content/base/spells.lua)
---@field oldAttitude string?  immol / berserk: the attitude to go back to
---@field effect string?       the aura picture a status recipe shows with it (content/recipes.lua)
---@field orig {code: string, type: UnitRecord?, set: table, maxHp: number, move: integer, name: string}? poly: the original

-- What each kind does is the `status` record of its name (content/base/statuses.lua); a kind without a record only exists.
local function def(kind) return content.status._recs[kind] end

M.POISON_TIME = 600000        -- poison and disease duration (ms, FUN_0051bfb0)

---@param u Unit
---@param kind string
---@return boolean
function M.has(u, kind)
    local f = u.fx and u.fx[kind]
    return f ~= nil
end

---@param u Unit
---@param kind string
---@return StatusEffect?
function M.get(u, kind) return u.fx and u.fx[kind] end

-- duration in ms; value optional. Re-casting refreshes and keeps the stronger value.
---@param u Unit
---@param kind string
---@param ms number
---@param value number?
---@param extra table? more fields to set on the effect
---@return StatusEffect
function M.add(u, kind, ms, value, extra)
    local world = u.world
    u.fx = u.fx or {}
    local cur = u.fx[kind]
    local f = cur or {}
    f.t1 = math.max(cur and cur.t1 or 0, world.time + ms)
    if value then f.value = math.max(math.abs(cur and cur.value or 0), math.abs(value)) * (value < 0 and -1 or 1) end
    if extra then for k, v in pairs(extra) do f[k] = v end end
    local d = def(kind)
    if d and d.tick and not f.nextTick then f.nextTick = world.time + (d.tick.first or d.tick.every or 1000) end
    u.fx[kind] = f
    return f
end

---@param u Unit
---@param kind string
function M.remove(u, kind)
    if not (u.fx and u.fx[kind]) then return end
    local d = def(kind)
    if d and d.onRemove then d.onRemove(u) end
    u.fx[kind] = nil
end

-- Removes the effects of a unit (all, or only the negative ones); `except` lists kinds that stay.
---@param u Unit
---@param negativeOnly boolean?
---@param except table<string, boolean>?
function M.clear(u, negativeOnly, except)
    if not u.fx then return end
    for k in pairs(u.fx) do
        local d = def(k)
        if (not negativeOnly or (d and d.negative)) and not (except and except[k]) and k ~= "psychimmune" then M.remove(u, k) end
    end
end

-- Cure: removes poison and disease only (Antidote).
function M.cure(u)
    M.remove(u, "poison")
    M.remove(u, "disease")
end

local function resistanceOf(u) return u:resistance() end

-- The can-be-poisoned test (FUN_0051c130): not already poisoned or diseased, not protected by Immunity.
---@param u Unit
---@return boolean
function M.canInfect(u)
    for kind in pairs(u.fx or {}) do
        local d = def(kind)
        if d and (d.infection or d.blocksInfection) then return false end
    end
    return true
end

---@param u Unit
---@return boolean infected
function M.poison(u)
    if not M.canInfect(u) then return false end
    local f = M.add(u, "poison", M.POISON_TIME)
    f.nextTick = u.world.time + 500 + resistanceOf(u) * 128
    return true
end

---@param u Unit
---@return boolean infected
function M.disease(u)
    if not M.canInfect(u) then return false end
    -- the disease lasts longer with the Contamination skill of every hero (FUN_0051c060: 15 s per point of virulence)
    local f = M.add(u, "disease", M.POISON_TIME + 15000 * require("src.game.heroskills").virulence(u.world))
    f.t0, f.res = u.world.time, resistanceOf(u)
    return true
end

-- Immolation of a victim (FUN_00527720): type 0 is what a critical fire or hot-and-pointy hit does to it
-- (2 hit points a second for 15 s), type 1 the nastier version (5 a second for 60 s). The original keeps one flag with
-- a type and lets a higher type replace a lower one; Fanaticism (type 2, the army ability) lives in `fanatic` and
-- beats both, so it is not applied over it.
---@param u Unit
---@param kind integer 0 or 1
---@return boolean
function M.immolate(u, kind)
    local amount, ms = kind == 1 and 5 or 2, kind == 1 and 60000 or 15000
    local cur = u.fx and u.fx.immol
    if cur and (cur.value or 0) >= amount then return false end
    if u.fx and u.fx.fanatic then return false end
    u.fx = u.fx or {}
    u.fx.immol = { t1 = u.world.time + ms, value = amount, nextTick = u.world.time + 1000,
                   oldAttitude = cur and cur.oldAttitude or u.attitude }
    if not cur then u.attitude = "rampant" end
    return true
end

-- The Berserker spell's immolation (the original's immolation type 2 from a spell, FUN_0057ffe0): the unit burns
-- for 1 hit point a second and goes rampant for `ms`, but keeps no combat / speed bonus of its own (the spell adds those
-- itself). Like Fanaticism it is a type 2 immolation, so it is not applied over an existing Fanaticism.
---@param u Unit
---@param ms number
function M.berserk(u, ms)
    if u.fx and u.fx.fanatic then return end
    local cur = u.fx and u.fx.immol
    u.fx = u.fx or {}
    u.fx.berserk = { t1 = u.world.time + ms, value = 1, nextTick = u.world.time + 1000,
                     oldAttitude = cur and cur.oldAttitude or u.attitude }
    if not cur then u.attitude = "rampant" end
end

-- The critical-hit ice freeze: the original (the freeze routine FUN_00527b30) adds an 8 s slow-all spell effect of 6
-- that the speed getters (FUN_0051c460, fight speed FUN_0051c6a0) subtract from movement speed and fight speed, never
-- below 1; openwbc3 has no fight-speed model, so it is the "slow" kind of 6 speed points for 8 s. The crushing stun's
-- 5 s is applied by unit.lua with the "stun" kind; the petrify missile kills in unit.lua and leaves no effect here.
function M.freeze(u) M.add(u, "slow", 8000, 6) end

-- Electricity drains the victim's mana (40 points, melee FUN_0042ace0 / the drain routine FUN_00527a00): heroes keep it
-- on their hero record, spellcasting troops on the unit.
---@param u Unit
---@param n number
function M.drainMana(u, n)
    if u.h then u.h.mana = math.max(0, (u.h.mana or 0) - n)
    else u.mana = math.max(0, (u.mana or 0) - n) end
end

-- Magic dispels: every spell effect of the victim goes, poison and disease stay (as the Dispel spell does).
function M.dispel(u) M.clear(u, false, { poison = true, disease = true }) end

-- The damage spell effects that replace the unit's attack: Fire Breathing gives fire damage of the spell's strength at
-- range 5 (a Pyromancy spell), Ice Floe ice damage at range 12 (an Ice spell), type numbering of the type record (1 ice,
-- 3 fire). The army's damage getter (0x00526310, slot 20 of the army vtable 0x005eabfc, not a Ghidra function)
-- takes the best of the effects and, for an absolute one, lets it replace the base attack when its damage is at least the
-- unit's or when it gives a range to a unit that has none: damage, type and range all become the effect's (the range
-- unconditionally in the binary). A weaker effect leaves the unit's own attack alone. Applied to the base values, before the
-- power-ups, like the damage getter does. The original skips this entirely under its Chaos status (psych.lua,
-- Unit:stats), the Chaos spells' morph is a permanent base change of its own.
---@param u Unit
---@param st UnitStats
function M.powerDamage(u, st)
    local best, bestValue
    for kind, f in pairs(u.fx) do
        local d = def(kind)
        local e = d and d.damage
        if e and (not best or (f.value or 0) > bestValue) then best, bestValue = e, f.value or 0 end
    end
    if not best then return end
    if bestValue >= st.damage or (best.range > 0 and st.range == 0) then
        st.damage, st.damageType, st.range = bestValue, best.type, best.range
    end
end

-- Applies stat modifiers to the table built by Unit:stats().
---@param u Unit
---@param st UnitStats
---@return UnitStats
function M.stats(u, st)
    for kind, f in pairs(u.fx) do
        local d = def(kind)
        if d then
            if d.stat then st[d.stat] = (st[d.stat] or 0) + f.value end
            if d.bonus then
                for stat, n in pairs(d.bonus) do st[stat] = st[stat] + n end
            end
            if d.stats then d.stats(u, st, f) end
        end
    end
    if st.speed < 0 then st.speed = 0 end
    return st
end

-- Damage multiplier from resist spells; type 1 fire, 4 magic.
---@param target Unit|Building only units carry effects
---@param dmgType integer? nil: only Resist Missiles counts
---@param ranged boolean?
---@param dmg number
---@return number
function M.reduce(target, dmgType, ranged, dmg)
    local fx = target.fx
    if not fx then return dmg end
    -- Resist Fire / Resist Magic: 25 percent per success level (value = percent resisted); Resist Missiles stops ranged damage
    for kind, f in pairs(fx) do
        local d = def(kind)
        if d then
            if d.resist and dmgType == d.resist.type then dmg = dmg * (100 - math.min(100, f.value or d.resist.pct)) / 100 end
            if d.immuneRanged and ranged then dmg = 0 end
        end
    end
    return math.max(dmg > 0 and 1 or 0, math.floor(dmg))
end

-- Permanently turns a unit into another type (Transform, Mutate); keeps the fraction of hit points.
---@param u Unit
---@param code string
---@param full boolean? full hit points instead of keeping the fraction
---@return boolean
function M.morph(u, code, full)
    local gamedata = require("src.game.gamedata")
    local anims = require("src.gfx.anims")
    local t = gamedata.army(code)
    local set = anims.get(code)
    if not t or not set then return false end
    local ratio = full and 1 or u.hp / u.maxHp
    u.code, u.type, u.set = code, t, set
    u.maxHp = t.hits > 0 and t.hits or 20
    u.hp = math.max(1, u.maxHp * ratio)
    u.target, u.task, u.path, u.goalX = nil, nil, nil, nil
    if u.state ~= "step" then u.state = "idle" end
    return true
end

---@param u Unit
---@param code string
---@param ms number
---@return boolean
function M.polymorph(u, code, ms)
    local gamedata = require("src.game.gamedata")
    local anims = require("src.gfx.anims")
    local t = gamedata.army(code)
    local set = anims.get(code)
    if not t or not set or u.fx and u.fx.poly then return false end
    local ratio = u.hp / u.maxHp
    local orig = { code = u.code, type = u.type, set = u.set, maxHp = u.maxHp, move = u.move, name = u.name }
    u.code, u.type, u.set = code, t, set
    u.maxHp = t.hits > 0 and t.hits or 20
    u.hp = math.max(1, u.maxHp * ratio)
    u.target, u.task, u.path, u.goalX = nil, nil, nil, nil
    if u.state ~= "step" then u.state = "idle" end
    M.add(u, "poly", ms, nil, { orig = orig })
    return true
end

---@param u Unit
function M.unpoly(u)
    local f = u.fx and u.fx.poly
    if not f then return end
    local o = f.orig
    ---@cast o -nil                 M.poly always keeps the original
    local ratio = u.hp / u.maxHp
    u.code, u.type, u.set, u.name = o.code, o.type, o.set, o.name
    u.maxHp = o.maxHp
    u.hp = math.max(1, u.maxHp * ratio)
end

-- Per-unit update; returns true while the unit is stunned.
local function sortedKinds(fx)
    local kinds = {}
    for kind in pairs(fx) do kinds[#kinds + 1] = kind end
    table.sort(kinds)
    return kinds
end

---@param u Unit
---@param t number world time (ms)
---@return boolean stunned
function M.update(u, t)
    local fx = u.fx
    -- only called for a unit with effects
    ---@cast fx -nil
    local stunned = false
    for _, kind in ipairs(sortedKinds(fx)) do
        local f = fx[kind]
        if f then
            local d = def(kind)
            if t >= f.t1 then
                fx[kind] = nil
                if d and d.expire then d.expire(u, f) end
            elseif d then
                if d.stuns then
                    stunned = true                              -- a stunned unit cannot act
                elseif d.tick and t >= f.nextTick then
                    f.nextTick = t + (d.tick.every or 1000)
                    d.tick.fn(u, f, t)
                    if u.state == "dead" then return false end
                end
            end
        end
    end
    if next(fx) == nil then u.fx = nil end
    return stunned
end

return M
