-- Spell recipes (docs/data-driven/03-spells-effects.md 3.3): a spell's `effect` may be a table of steps instead of a function. The
-- steps call the effect library (src/game/fx.lua) with amounts, durations and radii computed from the cast context, so a modder
-- composes a spell from data. `compile(recipe)` returns the `function(c)` the engine runs.
--
--   amount      n | { base = n, perLevel = n, perLevelSq = n }      (c.lvl is the success level)
--   seconds     n | { duration = "normal" [, mastery = n] }         (a class of the `spell.duration` setting)
--   radius      "r" | "rm" | n                                      (the command radius, the mastery radius, cells)
--   filter      { tag = "cavalry", without = "evil", notSelf = true }   which units a group effect takes
--
-- Steps (one key per step, run in order):
--   { heal = { target = "self" | "allies", amount, empower = true, cure = true, radius, aura = "heal", auraRadius = 2 } }
--   { status = { id, who = "self" | "allies" | "enemies", seconds, value = amount, radius, filter, effect = "EZ65" } }
--       "allies" is the group buff: every ally in the radius and a light ring; "enemies" skips units under Ward
--   { damage = { amount, empower = true, damageType = 0..4, key = "fire", radius, buildings = true, friends = true, missile = "EMF0" } }
--       damage to everything hostile in the radius (area damage with the caster's ring)
--   { summon = { unit, count = amount, seconds, xp = n } }          troops that fight for the caster, with the Gate experience
--   { aura = "heal" | "light" | "dark" | ..., radius }              a ring around the caster
local M = {}

local function amount(a, c)
    if type(a) == "number" then return a end
    if a == nil then return nil end
    return (a.base or 0) + (a.perLevel or 0) * c.lvl + (a.perLevelSq or 0) * c.lvl * c.lvl
end

local function radiusOf(r, c, default)
    if r == nil then return default or c.r end
    if r == "r" then return c.r elseif r == "rm" then return c.rm end
    return r
end

local function secondsOf(s, c, fx)
    if type(s) == "number" then return s end
    if s == nil then return nil end
    return fx.dur(c, s.duration, s.mastery)
end

local function filterOf(f, c, fx)
    if not f then return nil end
    return function(o)
        if f.notSelf and o == c.u then return false end
        if f.tag and not fx.hasTag(o, f.tag) then return false end
        if f.without and fx.hasTag(o, f.without) then return false end
        return true
    end
end

local STEPS = {}

function STEPS.aura(spec, c, fx)
    if type(spec) == "table" then fx.aura(c, spec.key or spec[1], spec.radius) else fx.aura(c, spec) end
end

function STEPS.heal(spec, c, fx)
    local n = amount(spec.amount, c)
    if spec.empower then n = fx.emp(c, n) end
    local function one(o)
        if spec.cure then require("src.game.status").cure(o) end
        fx.heal(c, o, n)
    end
    if spec.target == "allies" then
        fx.each(c, "ally", radiusOf(spec.radius, c), one)
    else
        fx.heal(c, c.u, n)
    end
    if spec.aura then fx.aura(c, spec.aura, spec.auraRadius) end
end

function STEPS.status(spec, c, fx)
    local secs, value = secondsOf(spec.seconds, c, fx), amount(spec.value, c)
    local extra = spec.effect and { effect = spec.effect } or nil
    if spec.who == "allies" then
        fx.buffGroup(c, spec.id, secs, value, filterOf(spec.filter, c, fx))
    elseif spec.who == "enemies" then
        fx.debuffEnemies(c, spec.id, secs, value, radiusOf(spec.radius, c))
    else
        fx.buff(c, c.u, spec.id, secs, value, extra)
    end
end

function STEPS.damage(spec, c, fx)
    local n = amount(spec.amount, c)
    if spec.empower then n = fx.emp(c, n) end
    fx.areaHurt(c, n, spec.damageType or 0, spec.key, radiusOf(spec.radius, c), spec.buildings, spec.friends, spec.missile)
end

function STEPS.summon(spec, c, fx)
    fx.summonXp(c, spec.xp or 0, spec.unit, amount(spec.count or 1, c), secondsOf(spec.seconds, c, fx))
end

-- Turns a recipe into the function the engine calls as `effect(c)`. Errors (an unknown step) are raised at compile time.
---@param recipe table[]
---@return fun(c: SpellCast)
function M.compile(recipe)
    local steps = {}
    for i, step in ipairs(recipe) do
        local name
        for k in pairs(step) do
            if STEPS[k] then
                if name then error(("recipe step %d names two actions (%s, %s)"):format(i, name, k), 0) end
                name = k
            end
        end
        if not name then
            local keys = {}
            for k in pairs(step) do keys[#keys + 1] = tostring(k) end
            error(("recipe step %d has no known action (%s)"):format(i, table.concat(keys, ", ")), 0)
        end
        steps[#steps + 1] = { STEPS[name], step[name] }
    end
    return function(c)
        local fx = require("src.game.fx")
        for _, s in ipairs(steps) do s[1](s[2], c, fx) end
    end
end

return M
