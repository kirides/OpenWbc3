-- The psych auras: armies whose type record carries a psych effect of type 1 fear, 2 terror, 3 awe or 4 chaos (the
-- Hydra's fear, the Dragons' and Titans' terror, the Unicorn's and Archon's awe, the Doom Knight's and Slayer Knight's
-- chaos; the type record's psych effect = strength, type, range, `type.psych`) put the effect on the enemy armies within
-- their range. Verified in the 1.04 binary (the once-a-second pass `FUN_00532a20`, which builds its list in
-- `FUN_005332e0` and applies the effects inline with the timers' constants; the bonus flags are `FUN_005286c0`):
--   * once a second (the counter reaches 40) every living army that is not a hero is checked against the auras of the
--     sides that are neither its own nor allied; the aura reaches an army when max(dx, dy) < 20 and
--     floor(sqrt(dx^2 + dy^2)) < range (the table of the direct distances), in cells
--   * an army that already carries any psych effect (fear, terror, awe, chaos or the immunity flag) is left alone, and an
--     army with the same capability itself or with terror (for terror: only terror) is not affected by the aura
--   * the bonus flags (`FUN_005286c0`, by capability) decide: a drunk army, a mechanical one, a titan or a critter is immune to all
--     four; then the race flags, first match wins (below)
--   * the roll: chance = max(1, (strength - resistance + 10) x 5) percent with the resistance +5 for "resistant", -5 for
--     "susceptible" and 0 for "very susceptible"; a d100 > chance means the army resists and is immune to
--     psych effects for 30 s (flag 0x10, the ECM0 cell 7), else it is under the effect for 45 s fear, 15 s terror,
--     30 s awe or chaos (+2x with the slow recovery flag 0x10, +1x with the very slow one 0x20); a hero's command radius
--     bonus ends at once
--   * terror also drops every order of the army when it starts (the army runs when told to attack) and when it
--     ends (`FUN_00532a20` / the spell's `FUN_00528a40`)
-- What the effects do is in unit.lua / status.lua: fear halves the damage, awe takes away the ranged attack, both and
-- terror slow the fight, and chaos (bit 8 of the psych bits at +0xBA: combat `FUN_0051bd10` / speed `FUN_0051c460` /
-- resistance `FUN_00526b70` never above the base value, armour `0x005260a0` 0, damage `0x00526310` the base damage) is in
-- `Unit:stats` / `Unit:resistance`.
-- openwbc3's own: the original lets only the host apply the effects and sends the army's state to the others, here every
-- peer runs this in the lockstep tick with the world's random numbers; armies that are `hidden` (garrisoned, in a
-- transport) do not radiate (the binary lists every army that is not dead, how it treats the garrisoned ones was not
-- looked at); the neutral side 6 is hostile to every side (the binary reads the alliance table at 0x00748915, whose neutral row was not
-- looked at).
local bit = require("bit")
local powerups = require("src.game.powerups")

local M = {}

M.KINDS = { "fear", "terror", "awe", "chaos" }          -- aura type 1..4
M.SECONDS = { fear = 45, terror = 15, awe = 30, chaos = 30 }   -- inline constants of FUN_00532a20
M.IMMUNE_SECONDS = 30                                    -- the same, after a resisted aura
M.MAX_REACH = 20

local IMMUNE, RESISTANT, SUSCEPTIBLE, VERY_SUSCEPTIBLE, SLOW, VERYSLOW = 0x1, 0x2, 0x4, 0x8, 0x10, 0x20
local UNDEAD, HIGHELF, WOODELF, DARKELF, MINOTAUR, ORC, INSECT, MECHANICAL, DAEMON =
    0x4, 0x8, 0x10, 0x20, 0x80, 0x100, 0x400, 0x4000, 0x800000

-- The race rules of the bonus flags (FUN_005286c0) by capability, first match wins (the order of the binary's bit tests).
local RACE_RULES = {
    fear = { { ORC, SLOW }, { HIGHELF, IMMUNE }, { WOODELF, RESISTANT }, { DARKELF, IMMUNE }, { UNDEAD, IMMUNE },
             { DAEMON, RESISTANT } },
    terror = { { ORC, SLOW }, { HIGHELF, IMMUNE }, { WOODELF, RESISTANT }, { UNDEAD, IMMUNE } },
    awe = { { ORC, SLOW }, { UNDEAD, IMMUNE }, { DARKELF, VERYSLOW }, { DAEMON, IMMUNE } },
    chaos = { { ORC, SLOW }, { UNDEAD, IMMUNE }, { MINOTAUR, bit.bor(VERYSLOW, RESISTANT) }, { DAEMON, IMMUNE },
              { INSECT, RESISTANT } },
}

local Unit

-- One aura of the pass (M.update): an army with a psych effect.
---@class PsychAura
---@field kind string            "fear" | "terror" | "awe" | "chaos"
---@field cap integer            aura type 1..4
---@field gx integer
---@field gy integer
---@field range number
---@field strength number
---@field side integer

-- Is the army under any psych effect, or immune after resisting one (the psych bits at +0xBA ~= 0)?
---@param u Unit
---@return boolean
function M.busy(u)
    local fx = u.fx
    return fx ~= nil and (fx.fear or fx.terror or fx.awe or fx.chaos or fx.psychimmune) ~= nil
end

-- FUN_005286c0: the bonus flags of the army against an effect kind.
---@param u Unit
---@param kind string
---@return integer flags (IMMUNE, RESISTANT ...)
function M.bonus(u, kind)
    Unit = Unit or require("src.game.unit")
    if u.fx and u.fx.drunk then return IMMUNE end
    local flags = powerups.flags(u.code)
    if bit.band(flags, MECHANICAL) ~= 0 then return IMMUNE end
    if Unit.isTitanUnit(u.code) or Unit.isCritter(u.code) then return IMMUNE end
    for _, r in ipairs(RACE_RULES[kind]) do
        if bit.band(flags, r[1]) ~= 0 then return r[2] end
    end
    return 0
end

-- How long the effect lasts on this army, in seconds, from the bonus flags.
local function seconds(kind, bonus)
    local d = M.SECONDS[kind]
    if bit.band(bonus, SLOW) ~= 0 then return d * 3 end
    if bit.band(bonus, VERYSLOW) ~= 0 then return d * 2 end
    return d
end

-- Puts the effect on the army (the part of FUN_00528a40 after the immunity test): the command radius bonus ends,
-- terror takes the orders away.
---@param u Unit
---@param kind string
---@param bonus integer
function M.start(u, kind, bonus)
    local world = u.world
    u.fx = u.fx or {}
    u.fx[kind] = { t1 = world.time + seconds(kind, bonus) * 1000 }
    u.cmdIn, u.cmdTimer = nil, nil
    if kind == "terror" then M.dropOrders(u) end
end

-- FUN_00528a40 as the Scare and Awe spells use it: an army that is not immune (FUN_005286c0)
-- gets the effect, whatever psych flags it carries and without a saving throw; false when it is immune.
---@param u Unit
---@param kind string
---@return boolean
function M.apply(u, kind)
    local bonus = M.bonus(u, kind)
    if bit.band(bonus, IMMUNE) ~= 0 then return false end
    M.start(u, kind, bonus)
    return true
end

-- Terror's extra effect when it starts and ends: no orders any more, the army is free again (and decides for itself).
---@param u Unit
function M.dropOrders(u)
    if u.state == "dead" then return end
    u:stop()
    u.running, u.att = nil, nil
end

-- Chaos (called by Unit:stats after everything else): combat and speed stay at or below the army's base
-- value (what the type record and the level give, Chaos morph spells included, nothing from power-ups, weather or the
-- hero's radius that would raise it; reductions such as disease stay), the armour is 0 and the damage getter returns the base
-- damage, type and range (no spell effects, power-ups, fear or awe). Heroes are never under chaos, so
-- `baseStats` is the stored record here.
---@param u Unit
---@param st UnitStats
function M.chaosStats(u, st)
    local base = u:baseStats()
    st.combat = math.min(st.combat, base.combat)
    st.speed = math.min(st.speed, base.speed)
    st.armor = 0
    st.damage, st.damageType, st.range, st.hot = base.damage, base.damageType, base.range, nil
end

local function hostile(world, a, b)
    if a == b then return false end
    local sa, sb = world.sides[a], world.sides[b]
    if a < 6 and b < 6 and sa and sb and sa.team ~= 0 and sa.team == sb.team then return false end
    return true
end

local function usable(world, side)
    local s = world.sides[side]
    return s and s.used and not s.defeated
end

-- One pass of the aura part of FUN_00532a20; called once a second by the world, before the command radius pass.
---@param world World
function M.update(world)
    local units = world.units
    local list = {}
    for i = #units, 1, -1 do                  -- the original's list nodes are put in front, so its order is the reverse
        local e = units[i]
        local p = e.type and e.type.psych
        if p and p.type >= 1 and p.type <= 4 and e.state ~= "dead" and not e.hidden and not e.hero
            and usable(world, e.side) then
            list[#list + 1] = { kind = M.KINDS[p.type], cap = p.type, gx = e.gx, gy = e.gy, range = p.range,
                                strength = p.strength, side = e.side }
        end
    end
    if #list == 0 then return end
    for _, u in ipairs(units) do
        if u.state ~= "dead" and not u.hidden and not u.hero and u.side and usable(world, u.side) then
            local own = u.type and u.type.psych and u.type.psych.type or 0
            for _, e in ipairs(list) do
                if M.busy(u) then break end                 -- psych bits at +0xBA ~= 0
                if hostile(world, u.side, e.side) then
                    local dx, dy = math.abs(u.gx - e.gx), math.abs(u.gy - e.gy)
                    if math.max(dx, dy) < M.MAX_REACH and math.floor(math.sqrt(dx * dx + dy * dy)) < e.range
                        and own ~= 2 and not (own == e.cap and e.cap ~= 2) then
                        M.roll(world, u, e)
                    end
                end
            end
        end
    end
end

-- The saving throw against one aura.
---@param world World
---@param u Unit
---@param e PsychAura
function M.roll(world, u, e)
    local bonus = M.bonus(u, e.kind)
    if bit.band(bonus, IMMUNE) ~= 0 then return end
    local res = u:resistance()
    if bit.band(bonus, RESISTANT) ~= 0 then res = res + 5
    elseif bit.band(bonus, SUSCEPTIBLE) ~= 0 then res = res - 5
    elseif bit.band(bonus, VERY_SUSCEPTIBLE) ~= 0 then res = 0 end
    local chance = math.max(1, (e.strength - res + 10) * 5)
    if math.random(100) > chance then
        u.fx = u.fx or {}
        u.fx.psychimmune = { t1 = world.time + M.IMMUNE_SECONDS * 1000 }
    else
        M.start(u, e.kind, bonus)
    end
end

return M
