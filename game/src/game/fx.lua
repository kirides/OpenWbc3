-- The effect library of the spells (docs/data-driven/03-spells-effects.md 3.3): the helpers the spell effects are written against --
-- targeting (`each`, `nearestEnemies`, `corpses`), damage and healing, timed statuses, summoning, placing buildings, rings and bolts
-- for the eye. Every helper takes the cast context `c` first ({ u, w, h, id, target, side, lvl, r, rm, empPct, ext ... }, see `ctx`).
-- Their semantics (the 24-target cap, row-by-row order, "hero resistances apply to magic damage") are the original's and were moved
-- unchanged out of spells.lua; spell effects in content/base (and in mods) use them and nothing else of the engine's internals.
local content = require("src.content")
local status = require("src.game.status")
local gamedata = require("src.game.gamedata")
local powerups = require("src.game.powerups")
local missiles = require("src.game.missiles")

local M = {}

-- Spell durations in seconds: base + mastery * step (the `spell.duration` setting).
---@return table<string, {[1]: number, [2]: number}> duration class -> base, step
local function durations() return content.setting:value("spell.duration") end

---@param w World
---@param side integer
---@param key string a side timer field (Side)
---@return boolean? running
local function sideBuff(w, side, key)
    local v = w.sides[side][key]
    return v and v > w.time
end

local CW, CH = 32, 24

---@param a {gx: integer, gy: integer}
---@param b {gx: integer, gy: integer}
---@return integer
local function dist(a, b)
    return math.max(math.abs(a.gx - b.gx), math.abs(a.gy - b.gy))
end

---@param u Unit the caster
---@param id integer the spell slot
---@param target table?
---@param lvl integer?
---@return SpellCast
local function newCtx(u, id, target, lvl)
    local w = u.world
    local h = u.h
    -- (a caster is a hero; troop casts get a stand-in)
    ---@cast h -nil
    local sd = w.sides[u.side]
    local c = { u = u, w = w, h = h, id = id, target = target, side = u.side, t = w.time }
    c.lvl = lvl or 1
    -- Area radius: command radius (at most 19) + Command spell 25 % per level;
    -- spells that pass the mastery add 50 % per level above the first (c.rm)
    local base = math.min(h.mod.commandRadius or (5 + h.attr.cha + h.mod.command), 19)
    c.base = base
    local pct = sideBuff(w, u.side, "command") and (sd.commandPct or 25) or 0
    c.r = math.floor(base + pct * base / 100)
    c.rm = math.floor(base + (pct + 50 * (c.lvl - 1)) * base / 100)
    c.empPct = sideBuff(w, u.side, "empower") and (sd.empowerPct or 50) or 0
    c.ext = sideBuff(w, u.side, "extend") and 2 or 1 -- Extend: +100 % duration
    return c
end

-- Targets of an area spell (the host-side spell resolution FUN_004aa840): the units inside a circle of `radius` cells
-- around `from` (the caster by default), at most 24, taken row by row from the top.
-- `pred(o)` (optional) is a further condition on the targets, tested before the cap of 24 (the original's target list is built from
-- the radius, the side and the type flags together: FUN_004aa840).
---@param c SpellCast
---@param who "enemy"|"ally"|"other"|"all"
---@param radius number cells
---@param fn fun(o: Unit)
---@param from {gx: integer, gy: integer}?
---@param pred (fun(o: Unit): boolean?)?
---@return integer count
local function each(c, who, radius, fn, from, pred)
    local w = c.w
    from = from or c.u
    local list = {}
    local r2 = radius * radius
    for _, o in ipairs(w.units) do
        local dx, dy = o.gx - from.gx, o.gy - from.gy
        if o:alive() and dx * dx + dy * dy <= r2 then
            local ok
            if who == "enemy" then ok = w:enemies(c.side, o.side) or (o.side == 6 and c.side ~= 6)
            elseif who == "ally" then ok = o.side == c.side or (not w:enemies(c.side, o.side) and o.side ~= 6)
            elseif who == "other" then ok = o ~= c.u
            else ok = true end
            if ok and (not pred or pred(o)) then list[#list + 1] = o end
        end
    end
    table.sort(list, function(a, b)
        if a.gy ~= b.gy then return a.gy < b.gy end
        if a.gx ~= b.gx then return a.gx < b.gx end
        return (a.id or 0) < (b.id or 0)
    end)
    local n = math.min(24, #list)
    for i = 1, n do fn(list[i]) end
    return n
end

---@param c SpellCast
---@param n integer
---@param radius number
---@return Unit[]
local function nearestEnemies(c, n, radius)
    local list = {}
    each(c, "enemy", radius, function(o) list[#list + 1] = o end)
    table.sort(list, function(a, b) return dist(a, c.u) < dist(b, c.u) end)
    local out = {}
    for i = 1, math.min(n, #list) do out[i] = list[i] end
    return out
end

---@param c SpellCast
---@param x number
---@param y number
---@param cells number
---@param r number
---@param g number
---@param b number
local function ring(c, x, y, cells, r, g, b)
    local w = c.w
    w.effects = w.effects or {}
    w.effects[#w.effects + 1] = { kind = "ring", x = x, y = y, r = cells * CW, col = { r, g, b }, t0 = w.time, dur = 700 }
end

---@param c SpellCast
---@param x0 number
---@param y0 number
---@param x1 number
---@param y1 number
---@param r number
---@param g number
---@param b number
local function bolt(c, x0, y0, x1, y1, r, g, b)
    local w = c.w
    w.effects = w.effects or {}
    w.effects[#w.effects + 1] = { kind = "bolt", x0 = x0, y0 = y0, x1 = x1, y1 = y1, col = { r, g, b }, t0 = w.time,
                                  dur = 350, seed = math.random(1000) }
end

local COL = { fire = { 1, 0.5, 0.1 }, ice = { 0.5, 0.8, 1 }, magic = { 0.8, 0.4, 1 }, heal = { 0.4, 1, 0.5 },
              poison = { 0.5, 0.9, 0.2 }, earth = { 0.7, 0.55, 0.3 }, light = { 1, 1, 0.7 }, dark = { 0.4, 0.2, 0.5 },
              elec = { 0.9, 0.9, 1 } }

---@param c SpellCast
---@param key string a COL key
---@param radius number?
local function aura(c, key, radius)
    local col = COL[key] or COL.magic
    ring(c, c.u.x, c.u.y, radius or c.r, col[1], col[2], col[3])
end

-- Empower raises damage and healing by a percentage (the original's empower effect).
---@param c SpellCast
---@param amount number
---@return integer
local function emp(c, amount) return math.floor((100 + c.empPct) * amount / 100) end

-- seconds of a duration class at mastery m (default: success level - 1)
---@param c SpellCast
---@param kind string a duration class
---@param m integer? the mastery
---@return number seconds
local function dur(c, kind, m)
    local d = durations()[kind]
    local secs = d[1] + (m or c.lvl - 1) * d[2]
    -- the longest duration a cast asked for: how long the view keeps the spell's persistent picture (gfx/spellfx.lua)
    c.durMs = math.max(c.durMs or 0, secs * 1000 * c.ext)
    return secs
end

-- damage dealt by a spell (dtype 1 fire, 2 ice, 3 electricity, 4 magic, 0 physical)
---@param c SpellCast
---@param target Unit|Building
---@param amount number
---@param dtype integer
local function hurt(c, target, amount, dtype)
    if target.kind == "unit" then
        if target.fx then amount = status.reduce(target, dtype, false, amount) end
        if target.h then
            local pct = target.h.mod.resist and target.h.mod.resist[({ "fire", "ice", "electricity", "magic" })[dtype] or ""]
            if pct then amount = amount * (100 - math.min(90, pct)) / 100 end
        end
        if amount > 0 then target:takeDamage(math.floor(amount), c.u) end
    else
        c.w:damageBuilding(target, math.floor(amount), c.u)
    end
end

---@param c SpellCast
---@param target Unit|Building
---@param amount number
local function heal(c, target, amount)
    if target.hp and target.maxHp then
        local before = target.hp
        target.hp = math.min(target.maxHp, target.hp + amount)
        -- "Healing: %d pts" over the army (the army's healing routine FUN_00526700, message 1121); display only
        if target.kind == "unit" and target.hp > before then
            c.w:event("tinymsg", target, 1121, 1, math.floor(target.hp - before))
        end
    end
end

---@param c SpellCast
---@param o Unit
---@param kind string a status
---@param secs number
---@param value any
---@param extra any
local function buff(c, o, kind, secs, value, extra)
    status.add(o, kind, secs * 1000 * c.ext, value, extra)
end

---@param c SpellCast
---@param kind string
---@param secs number
---@param value any
---@param filter (fun(o: Unit): boolean?)?
---@return integer
local function buffGroup(c, kind, secs, value, filter)
    local n = 0
    each(c, "ally", c.r, function(o)
        if not filter or filter(o) then buff(c, o, kind, secs, value) n = n + 1 end
    end)
    aura(c, "light")
    return n
end

---@param c SpellCast
---@param kind string
---@param secs number
---@param value any
---@param radius number?
local function debuffEnemies(c, kind, secs, value, radius)
    each(c, "enemy", radius or c.r, function(o)
        if not (o.fx and o.fx.ward) then buff(c, o, kind, secs, value) end
    end)
end

-- Summoned creatures vanish after `secs` (permanent when nil). Illusions (Spectral Horde, Dragonfear) have a quarter of
-- the hit points and no strength (Unit:stats). They appear around the caster, or around a Black Portal / Circle of Power.
-- What the other sides' hero spells do to an army that `casterSide` has just summoned: Poison Gate poisons it,
-- Corruption (20 + 10 x level percent) may turn it into the corrupting side's army (the network army creation handler
-- FUN_004a49e0; the original also needs army room on the corrupting side and adds the item effect, which
-- openwbc3 does not model; the Sword of Sirian goes through here too).
---@param w World
---@param s Unit the summoned army
---@param casterSide integer
function M.summonedFor(w, s, casterSide)
    for i = 0, 5 do
        local sd = w.sides[i]
        if i ~= casterSide and sd.used then
            if sd.poisonGate and sd.poisonGate > w.time then
                local f = status.add(s, "poison", status.POISON_TIME)
                f.nextTick = w.time + 500
            end
            if sd.corruption and sd.corruption > w.time and w.eco:heroAlive(i)
                and math.random(100) <= (sd.corruptionPct or 0) then
                local cur, max = w.eco:armyLimit(i)
                if cur < max then s.side = i end
            end
        end
    end
end

-- Every summon spell function of the binary (FUN_0057e010 ... FUN_0057f630, the Gate / Elemental / Raise / Spectral / Dragon /
-- Golem ... spells, 1.04) starts with the army-limit check FUN_005776c0 for the type it makes (the Spectral and Dragon spells for the race's
-- type, Arcane Elementals and Raise Champion for the one they picked): the mana is spent already, the spell just does nothing
-- and the announcer says "too many men". The check is for one army, however many the spell makes (Eco:roomFor); the host's
-- spell resolution (FUN_004aa840, case 6) then makes the armies one by one and stops as soon as the side's army count has
-- reached its limit (limit <= current, the count updated by every new army: FUN_004a49e0 -> FUN_00533fb0).
---@param c SpellCast
---@param code string? nil: a unit value of 1 (the Call the Dead check)
---@return boolean
local function roomFor(c, code)
    return c.w.eco:roomFor(c.side, code)
end
M.roomFor = roomFor

---@param c SpellCast
---@param code string
---@param n integer
---@param secs number?
---@param near {gx: integer, gy: integer}?
---@param illusion boolean?
---@return Unit[]
local function summon(c, code, n, secs, near, illusion)
    local w = c.w
    local u = c.u
    near = near or c.portal or u
    local made = {}
    if not roomFor(c, code) then return made end
    for _ = 1, n do
        if c.side < 6 then
            local cur, max = w.eco:armyLimit(c.side)
            if max <= cur then break end
        end
        local x, y = w:nearestFree(near.gx + math.random(-2, 2), near.gy + math.random(-2, 2), 0, 6)
        if x then
            ---@cast y -nil
            local s = w:addUnit(code, c.side, x, y)
            if s then
                if secs then s.summonUntil = w.time + secs * 1000 * c.ext end
                if illusion then
                    s.illusion = true
                    s.maxHp = math.max(1, math.floor(s.maxHp / 4))
                    s.hp = s.maxHp
                end
                M.summonedFor(w, s, c.side)          -- Poison Gate: poisoned; Corruption: may change sides
                made[#made + 1] = s
                ring(c, s.x, s.y, 1.2, 0.9, 0.6, 1)
            end
        end
    end
    return made
end

-- A summoning spell's armies: the spell functions of the binary (FUN_0057e010, FUN_00580260 ... FUN_0057f630, one per
-- summon spell) start the new armies with the starting experience FUN_00557d90 - the troop-XP lords and the Gate power-up, no
-- training - plus `per` experience for every spell level above the first (5, 20 or 50 depending on the spell, 0 for some;
-- the table is in docs/hero.md). The Arcane Elementals spell (FUN_00581a30) adds the Gate power-up's 20 per level a
-- second time (`extra`).
---@param c SpellCast
---@param per number experience per level above the first
---@param code string
---@param n integer
---@param secs number?
---@param extra number?
---@return Unit[]
local function summonXp(c, per, code, n, secs, extra)
    local made = summon(c, code, n, secs)
    local xp = c.w.eco:initialXp(c.side, code, { training = false, gate = true }) + per * (c.lvl - 1) + (extra or 0)
    if xp > 0 then
        for _, u in ipairs(made) do u:addXp(xp) end
    end
    return made
end

---@param c SpellCast
---@param radius number
---@param fn fun(o: Unit)
local function corpses(c, radius, fn)
    for _, o in ipairs(c.w.units) do
        if o.state == "dead" and not o.remove and dist(o, c.u) <= radius then fn(o) end
    end
end

---@param c SpellCast
---@param tier integer
local function giveItem(c, tier)
    local items = require("src.game.items")
    local it = items.random(tier)
    if not it then return end
    local ok = c.h:give(it)
    if not ok then c.w:dropItem(c.u.gx, c.u.gy, it) end
    c.w:event("itemfound", c.u, it, ok and "pack" or "ground")
end

local function isEvil(o) return gamedata.hasTag(o.code, "evil") end
local function isPlanar(o) return gamedata.hasTag(o.code, "planar") end
local function isCavalry(o) return gamedata.hasTag(o.code, "cavalry") end
local function isInfantry(o) return gamedata.hasTag(o.code, "infantry") end
local function isUndead(o) return gamedata.hasTag(o.code, "undead") end
---@param _ Unit|Building
local function isMech(_) return false end -- the army records carry no mechanical flag

---@param c SpellCast
---@param key string a Side timer field
---@param secs number
local function sideTimer(c, key, secs)
    c.w.sides[c.side][key] = c.w.time + secs * 1000 * c.ext
end

-- The spells that fire missiles at their targets (spell effect kind 0x10: Purify, Hand of Flame, Hand of Ice, Ice Storm,
-- Doomstones, Wildfire, Spray Poison, Multi-Target; the spell resolution FUN_004aa840 case 0x10 rolls one d100 per cast and
-- the effect function FUN_004ac0e0 case 0x10 makes one missile (FUN_0058bdd0, the caster as the shooter, no forced damage)
-- per target and gives it the damage and its type, see missiles.lua): the missile flies like an arrow, hits the first enemy
-- it meets, and its damage goes through the victim's armour and the height percentage when it lands, so a caster that dies
-- first does no damage at all. The picture is the cast's type id (the binary's spell message carries it at +0x129).
local ARMOUR_TYPE = { [0] = 0, [1] = 3, [2] = 1, [3] = 2, [4] = 4 }       -- the spells' damage types -> the armour table's
---@param c SpellCast
---@param o Unit|Building
---@param amount number
---@param dtype integer
---@param code string the missile picture
local function fire(c, o, amount, dtype, code)
    c.mroll = c.mroll or math.random(100)
    missiles.launch(c.w, { code = code, kind = "spell", shooter = c.u, side = c.side, target = o,
                           roll = c.mroll, p = { amount = amount, dtype = dtype } })
end

-- A spell's missile lands (Hit): the armour of the victim and the height percentage, nothing if the caster has died.
missiles.handlers.spell = function(world, m, victim)
    local caster = m.shooter
    if not (caster and caster:alive()) then return end
    local Unit = require("src.game.unit")
    local p = m.p
    if victim.kind == "unit" then
        if not victim:alive() then return end
        local strength = powerups.poisonArrow(m.code, caster.type and caster.type.damage or 0)
        if strength > 0 and math.random(100) <= math.max(1, 50 - (victim:resistance() - strength) * 5) then
            status.poison(victim)
        end
    elseif victim.hp <= 0 then
        return
    end
    local dmg = Unit.soften(victim, p.amount, ARMOUR_TYPE[p.dtype] or 0, p.dtype == 0)
    dmg = math.floor(dmg * missiles.heightPercent(world, m, victim) / 100)
    if p.dtype == 0 and dmg > 0 and powerups.missileResistant(victim, caster, m.code) then dmg = math.max(1, math.floor(dmg / 16)) end
    if victim.kind == "unit" then
        if dmg > 0 then victim:takeDamage(dmg, caster) end
    else
        world:damageBuilding(victim, dmg, caster)
    end
end

---@param c SpellCast
---@param n integer
---@param amount number
---@param dtype integer
---@param key string
---@param radius number?
---@param missile string?
---@return integer
local function hitMany(c, n, amount, dtype, key, radius, missile)
    local targets = nearestEnemies(c, n, radius or c.r)
    for _, o in ipairs(targets) do
        local col = COL[key] or COL.magic
        if missile then
            fire(c, o, amount, dtype, missile)
        else
            bolt(c, c.u.x, c.u.y - 20, o.x, o.y - 10, col[1], col[2], col[3])
            hurt(c, o, amount, dtype)
        end
    end
    return #targets
end

-- Area damage; `missile` (a picture code) sends it as missiles (see `fire`), friends are never missile targets
---@param c SpellCast
---@param amount number
---@param dtype integer
---@param key string
---@param radius number?
---@param buildings boolean?
---@param friends boolean?
---@param missile string?
local function areaHurt(c, amount, dtype, key, radius, buildings, friends, missile)
    local rad = radius or c.r
    local col = COL[key] or COL.magic
    local function strike(o)
        if missile then fire(c, o, amount, dtype, missile) else hurt(c, o, amount, dtype) end
    end
    each(c, friends and "other" or "enemy", rad, strike)
    if buildings then
        for _, b in ipairs(c.w.buildings) do
            if b.hp > 0 and (friends or c.w:enemies(c.side, b.side)) and dist(b, c.u) <= rad then strike(b) end
        end
    end
    ring(c, c.u.x, c.u.y, rad, col[1], col[2], col[3])
end

---@param c SpellCast
---@param o Unit a dead army
---@param frac number of its hits
---@return integer revived
local function revive(c, o, frac)
    local w = c.w
    local x, y = w:nearestFree(o.gx, o.gy, o.move, 3)
    if not x then return 0 end
    ---@cast y -nil
    o.state, o.anim, o.frame, o.hp = "idle", 0, 0, math.max(1, o.maxHp * frac)
    o.deadSince = nil
    o.gx, o.gy, o.x, o.y = x, y, x * CW + 16, y * CH + 12
    w.occ[w:index(x, y)] = o
    local sd = w.sides[o.side]
    if o.h and sd and sd.fallenHero then sd.fallenHero = nil end
    ring(c, o.x, o.y, 1.5, 1, 1, 0.7)
    return 1
end


-- The level getter FUN_00526d80: a hero's level is its side's hero level, any other army's its own (experience) level.
---@param o Unit
---@return integer
local function levelOf(o) return o.h and o.h.level or o.level or 0 end
---@param o Unit
---@return boolean
local function isFlyer(o) return o.move == 1 end

-- Replaces a unit by a new one of another type (Mutate, Strip Flesh, Call the Dead).
---@param c SpellCast
---@param o Unit
---@param code string
---@param side integer
---@return Unit?
local function replace(c, o, code, side)
    local w = c.w
    local gx, gy = o.gx, o.gy
    o.remove = true
    if w.occ[w:index(gx, gy)] == o then w.occ[w:index(gx, gy)] = nil end
    local s = w:addUnit(code, side, gx, gy)
    if s then ring(c, s.x, s.y, 1.2, 0.5, 0.2, 0.6) end
    return s
end

-- A building the spell places (walls, portals, circles) at the clicked cell, within the command radius of the hero.
---@param c SpellCast
---@param code string
---@param secs number
---@return Building?
local function place(c, code, secs)
    local w = c.w
    local btype = gamedata.building(code)
    local t = c.target
    if not (btype and t) then return end
    if dist(t, c.u) > math.min(19, c.h.mod.commandRadius) then return end
    local gx, gy = t.gx, t.gy
    if not w:fits(gx, gy, btype.shape) then
        local x, y = w:nearestFree(gx, gy, 0, 2)
        if not (x and w:fits(x, y, btype.shape)) then return end
        gx, gy = x, y
    end
    local b = w:addBuilding({ code = code, side = c.side, x = gx * CW + 16, y = gy * CH + 12, anim = 0, dir = 0, frame = 0 })
    w.eco:initBuilding(b)
    b.complete = true
    b.expireAt = w.time + secs * 1000 * c.ext
    ring(c, b.x, b.y, 2, 0.8, 0.6, 0.3)
    return b
end


-- The library table: `fx.each(c, "enemy", c.r, fn)` ...
M.CW = CW
M.CH = CH
M.dist = dist
M.each = each
M.nearestEnemies = nearestEnemies
M.ring = ring
M.bolt = bolt
M.COL = COL
M.aura = aura
M.emp = emp
M.dur = dur
M.hurt = hurt
M.heal = heal
M.buff = buff
M.buffGroup = buffGroup
M.debuffEnemies = debuffEnemies
M.summon = summon
M.summonXp = summonXp
M.corpses = corpses
M.giveItem = giveItem
M.isEvil = isEvil
M.isPlanar = isPlanar
M.isCavalry = isCavalry
M.isInfantry = isInfantry
M.isUndead = isUndead
M.isMech = isMech
M.sideTimer = sideTimer
M.ARMOUR_TYPE = ARMOUR_TYPE
M.fire = fire
M.hitMany = hitMany
M.areaHurt = areaHurt
M.revive = revive
M.levelOf = levelOf
M.isFlyer = isFlyer
M.replace = replace
M.place = place
M.sideBuff = sideBuff
M.ctx = newCtx

-- Whether a unit or building carries the tag (tags: content/base/tags.lua).
---@param o Unit|Building
---@param tag string
---@return boolean
function M.hasTag(o, tag) return gamedata.hasTag(o.code, tag) end

return M