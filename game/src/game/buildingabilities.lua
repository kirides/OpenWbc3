-- Special abilities of buildings (the extra command button of Market, Reformatory, Summoning Tower, Cathedral ...),
-- after the original's building buttons (layout FUN_004d2300: which button sits in which slot, which power-up enables
-- it; costs), the casts (e.g. Chaos Plague FUN_005771f0, Sword of Sirian FUN_0057a3b0), the host-side spell resolution
-- (FUN_004aa840) and the computer players' ability use (FUN_005001d0 / FUN_00500830): which building offers an
-- ability, to whom (a race, or anyone who has bought the power-up), what it costs and does.
-- Implemented: Trade, Slave Horde, Brood, Rites of Dawn, Dark Citadel, Storm Call, Holy Word, Chaos Plague,
-- Sword of Sirian, Couatl's Wrath, Famine, Elcor's Balm, Summon Wraith / Shadow, gravestone morphing.
-- Feast has no building button in 1.04 (FUN_004d2300 has none; the Zombies' Feast is a unit ability).
--
-- Costs (the 1.04 button handlers: each asks for the price and, through the resource message 0x1fe, takes it; the side
-- record's resources are gold 0x00708fb4, metal 0x00708fb6, crystal 0x00708fb8, stone 0x00708fba, named by the build
-- step FUN_00524450's "need more" lines): Slave Horde 25 gold (0x004d0c50) and Brood 30 gold (0x004d0e50) per hired unit,
-- Rites of Dawn 40 (0x004d11b0), Dark Citadel 100 (0x004d1300), Storm Call 80 (0x004d18a0), Holy Word 200 (0x004d1a00,
-- FUN_004d1ef0), Chaos Plague 1000 (0x004d1ae0, FUN_004d20b0), Sword of Sirian 200 (0x004d1bc0, FUN_004d2130), Famine 500
-- (0x004d1c60), Elcor's Balm 400 (0x004d1e10; FUN_004d2030 takes 300 from a computer side), Summon Wraith 125
-- (0x004d1680) and Summon Shadow 250 crystal (0x004d1460), Couatl's Wrath 750 gold (0x004d1d70, FUN_004d2190).
-- The special-ability keys of KeyMap.txt (FUN_00427f70 -> FUN_00426350, game/abilitykeys.lua) find the building in the
-- selection or anywhere on the map (FUN_00427e30; Holy Word only a BPCA), ask the same prices but have no button timer
-- or target check, and Chaos Plague, Couatl's Wrath and Sword of Sirian cast from there without taking anything
-- (FUN_005771f0 / FUN_0057a1e0 / FUN_0057a3b0 are called directly): M.use with `key`.
-- Effects of the original: Holy Word = 50 magic damage to every evil enemy army within 15 cells (24 targets
-- at most); Chaos Plague = enemy armies within 28 cells (not titans) keep 53 - 3 x power-up level percent of their hit
-- points (at least 5) and get a disease; Sword of Sirian = every corpse within 20 cells becomes a permanent Dancing
-- Sword of the caster; Famine = drains a random non-allied mine that is not run dry of 2000 x level (PFA0..PFA3 owned,
-- Game.txt 0895-0898), leaving at least 1; Elcor's Balm = Major Healing result 1 (+100 hit points, cures) on every
-- own damaged unit but titans; Couatl's Wrath = 5 + level fireballs around the temple, each doing 150 fire damage to
-- every army and building (friend or foe) in a 9x9 cell box where it lands; Summon Wraith / Shadow = one unit at the
-- building; gravestone = the building becomes a Skeleton (free, needs army room).
-- Swords of Sirian start with the starting experience of a new army (FUN_00557d90: side, Dancing Sword, no training,
-- lords, gate) and go through the same Poison Gate / Corruption check as every summoned army (the original's army
-- creation message; spells.lua summonedFor). The computer's one-in-N dice use math.random (lockstep-safe); the
-- original's dice stream cannot be matched, so they are openwbc3's own. The Wrath fireballs are the Titan's (see
-- EFFECT.wrath).
-- Each ability plays its cast sound (the original's per-ability sound, STEZ%02d.wav from the sound archive, at the
-- building).
local content = require("src.content")
local powerups = require("src.game.powerups")
local rules = require("src.game.rules")
local gamedata = require("src.game.gamedata")
local status = require("src.game.status")
local sound = require("src.audio.sound")
local specials = require("src.game.unitspecials")
local missiles = require("src.game.missiles")

local M = {}

M.CLICK = 1000                 -- the one-shots: one press per second and side (the button handlers' static timers)
-- The abilities are the `ability` records of kind "building" (content/base/abilities.lua, documented there). `slot`: 1 = first extra
-- button (below unload), 2 = second one; icon = Panel_Icons index. The engine's view of a record has `buildings`
-- as a set (a race slot instead of `true` where the record names a race for that building) and `races` as a set of race numbers.
---@type table[] the engine's views of the `ability` records of kind "building"
M.list = {}
for _, a in ipairs(content.ability:all()) do
    if a.kind == "building" then
        local def = {}
        for k, v in pairs(a) do def[k] = v end
        def.buildings = {}
        for _, code in ipairs(a.buildings) do
            local race = a.buildingRace and a.buildingRace[code]
            def.buildings[code] = race and content.race:slotOf(race) or true
        end
        if a.races then
            def.races = {}
            for _, id in ipairs(a.races) do def.races[content.race:slotOf(id)] = true end
        end
        M.list[#M.list + 1] = def
    end
end
---@type table<string, table>
M.byId = {}
for _, a in ipairs(M.list) do M.byId[a.id] = a end

-- Abilities `b` can offer its owner: { def, usable }. A weather ability only shows for its races; Trade for the race
-- of its market or anyone who bought the Trade power-up; Holy Word, Chaos Plague, Sword of Sirian and Elcor's Balm for
-- their races or anyone with the power-up; Famine only once it is bought (the original's availability tests of the
-- building buttons, FUN_004d0190 .. FUN_004d07e0).
---@param world World
---@param b Building
---@return {def: table, usable: boolean}[]
function M.of(world, b)
    local side = world.sides[b.side]
    local out = {}
    if not side or not b.complete or b.hp <= 0 or b.side == 6 then return out end
    for _, a in ipairs(M.list) do
        local rule = a.buildings[b.code]
        if rule then
            local offered = true
            if a.races then
                offered = a.races[side.race] == true or (a.orPower and powerups.has(side, a.power)) or false
            elseif type(rule) == "number" then offered = side.race == rule or powerups.has(side, a.power) end
            if offered and a.needsPower and M.level(side, a) == 0 then offered = false end
            if offered then out[#out + 1] = { def = a, usable = M.usable(world, b.side, a) } end
        end
    end
    return out
end

-- Power-up level of a levelled ability: the highest owned family member + 1 (FUN_00437f70 with PFAX / PCNX, the level
-- the buttons pass to the cast; Famine 1..4, Contagion 1..5).
---@param side Side
---@param a table the ability
---@return integer
function M.level(side, a)
    if not a.family then return powerups.has(side, a.power) and 1 or 0 end
    return powerups.level(side, a.family[1])
end

-- Whether the button is enabled (FUN_004d2300): power-up bought, room in the army (Slave Horde, Brood, the gravestone;
-- Summon Wraith / Shadow are enabled without it and do nothing), right weather. No button looks at the price: a press
-- without the means says "need more ...".
---@param world World
---@param sideIndex integer
---@param a table the ability
---@return boolean
function M.usable(world, sideIndex, a)
    local side = world.sides[sideIndex]
    if not a.free and not powerups.has(side, a.power) then return false end
    if a.room then
        local cur, max = world.eco:armyLimit(sideIndex)
        if max - cur <= 0 then return false end
    end
    if a.weather == "day" and not (world.night or world.raining) then return false end
    if a.weather == "night" and world.night then return false end
    if a.weather == "storm" and world.raining then return false end
    return true
end

-- Resource trade rate in percent: 50 plus the Trade skill's effect (2 per level), at most 90 (the trade
-- button, FUN_004d1090 in the binary).
---@param world World
---@param sideIndex integer
---@return number
function M.tradeRate(world, sideIndex)
    local skills = require("src.game.heroskills")
    return math.min(90, 50 + skills.value(world, sideIndex, skills.ids.Trade))
end

-- Effects ------------------------------------------------------------------------------

local function isEvil(u) return gamedata.hasTag(u.code, "evil") end
local function isTitan(u) return gamedata.hasTag(u.code, "titan") end

local function ring(w, x, y, cells, r, g, b)
    w.effects = w.effects or {}
    w.effects[#w.effects + 1] = { kind = "ring", x = x, y = y, r = cells * 32, col = { r, g, b }, t0 = w.time, dur = 700 }
end

local function spend(world, sideIndex, resource, amount)
    local side = world.sides[sideIndex]
    side[resource] = side[resource] - amount
    world:battleStats():resource(sideIndex, resource, amount, "spent")
end

-- Whether `o` counts as an enemy of the side (neutral armies do, like in the original's area count FUN_005002e0).
local function enemyOf(world, sideIndex, o)
    return world:enemies(sideIndex, o.side) or (o.side == 6 and sideIndex ~= 6)
end

-- Enemy armies (alive, not invisible) within `radius` cells (square for the AI scan, circle for a spell), in the order
-- of the host-side spell resolution FUN_004aa840: row by row, at most 24 for spells. `filter` narrows further.
local function enemiesAround(world, b, sideIndex, radius, circle, filter)
    local list = {}
    local r2 = radius * radius
    for _, o in ipairs(world.units) do
        if o:alive() and enemyOf(world, sideIndex, o) and not (o.fx and o.fx.invis) then
            local dx, dy = o.gx - b.gx, o.gy - b.gy
            local inside
            if circle then inside = dx * dx + dy * dy <= r2 else inside = math.abs(dx) <= radius and math.abs(dy) <= radius end
            if inside and (not filter or filter(o)) then list[#list + 1] = o end
        end
    end
    table.sort(list, function(a, c)
        if a.gy ~= c.gy then return a.gy < c.gy end
        if a.gx ~= c.gx then return a.gx < c.gx end
        return (a.id or 0) < (c.id or 0)
    end)
    return list
end

-- The AI's item count weights an army by its hit points: (hits >> 5) + 1.
local function weight(list)
    local n = 0
    for _, o in ipairs(list) do n = n + math.floor((o.maxHp or 0) / 32) + 1 end
    return n
end

local function hurt(world, target, amount, dtype)
    if target.kind == "unit" then
        if target.fx then amount = status.reduce(target, dtype, false, amount) end
        if amount > 0 then target:takeDamage(math.floor(amount), nil) end
    else
        world:damageBuilding(target, math.floor(amount), nil)
    end
end

local EFFECT = {}

-- Holy Word: 50 magic damage (type 4) to evil enemy armies within 15 cells. FUN_004d1ef0 sends missiles
-- (the missile-creating spell effect) with the building as the shooter, so each one rolls against the building's
-- accuracy (missiles.lua) and a miss hurts what it lands on instead.
function EFFECT.holy(world, sideIndex, b)
    local targets = enemiesAround(world, b, sideIndex, 15, true, isEvil)
    ring(world, b.x, b.y, 15, 0.7, 0.8, 1)
    for i = 1, math.min(24, #targets) do
        -- a blue lightning from the temple (EMM2); the damage lands when the missile does
        missiles.launch(world, { code = "EMM2", kind = "holy", shooter = b, side = sideIndex, target = targets[i],
                                 p = { amount = 50, dtype = 4 } })
    end
end

-- A Holy Word missile lands: 50 magic damage through the victim's armour (hit type 2) and the height percentage; the
-- credit goes to nobody (as before), nothing when the temple has fallen meanwhile.
missiles.handlers.holy = function(world, m, victim)
    local b = m.shooter
    if not (b and b.hp > 0) then return end
    if victim.kind == "unit" then
        if not victim:alive() then return end
    elseif victim.hp <= 0 then
        return
    end
    local dmg = require("src.game.unit").soften(victim, m.p.amount, m.p.dtype, false)
    dmg = math.floor(dmg * missiles.heightPercent(world, m, victim) / 100)
    if victim.kind == "unit" then
        if dmg > 0 then victim:takeDamage(dmg, nil) end
    else
        world:damageBuilding(victim, dmg, nil)
    end
end

-- Chaos Plague: a percentage of the hit points stays, and the targets fall ill.
function EFFECT.plague(world, sideIndex, b, a)
    local pct = math.max(5, 53 - 3 * M.level(world.sides[sideIndex], a))
    local targets = enemiesAround(world, b, sideIndex, 28, true, function(o) return not isTitan(o) end)
    ring(world, b.x, b.y, 28, 0.5, 0.9, 0.2)
    for i = 1, math.min(24, #targets) do
        local o = targets[i]
        o.hp = math.max(1, math.floor(o.hp * pct / 100))
        status.disease(o)
    end
end

-- Sword of Sirian: corpses within 20 cells become Dancing Swords (AHLX) of the caster for good.
function EFFECT.sword(world, sideIndex, b)
    local list = {}
    for _, o in ipairs(world.units) do
        if o.state == "dead" and not o.remove then
            local dx, dy = o.gx - b.gx, o.gy - b.gy
            if dx * dx + dy * dy <= 400 then list[#list + 1] = o end
        end
    end
    table.sort(list, function(a, c)
        if a.gy ~= c.gy then return a.gy < c.gy end
        if a.gx ~= c.gx then return a.gx < c.gx end
        return (a.id or 0) < (c.id or 0)
    end)
    ring(world, b.x, b.y, 20, 0.9, 0.9, 1)
    for i = 1, math.min(24, #list) do
        local o = list[i]
        local gx, gy = o.gx, o.gy
        o.remove = true
        if world.occ[world:index(gx, gy)] == o then world.occ[world:index(gx, gy)] = nil end
        local s = world:addUnit("AHLX", sideIndex, gx, gy)
        if s then
            -- FUN_0057a3b0: the sword starts with FUN_00557d90(side, Dancing Sword, no training, lords, gate)
            local xp = world.eco:initialXp(sideIndex, "AHLX", { training = false, gate = true })
            if xp > 0 then s:addXp(xp) end
            require("src.game.spells").summonedFor(world, s, sideIndex)      -- Poison Gate, Corruption
            ring(world, s.x, s.y, 1.2, 0.9, 0.9, 1)
        end
    end
end

-- Famine: a random mine of an enemy loses 2000 x level resources (at least 1 stays).
function EFFECT.famine(world, sideIndex, b, a)
    local mines = {}
    for _, m in ipairs(world.buildings) do
        local sd = world.sides[m.side]
        if m.mine and m.hp > 0 and m.mine.reserve > 0 and m.side ~= sideIndex and m.side ~= 6 and sd and sd.used
            and not sd.defeated and world:enemies(sideIndex, m.side) then
            mines[#mines + 1] = m
        end
    end
    if #mines == 0 then return end
    local m = mines[math.random(#mines)]
    local before = m.mine.reserve
    m.mine.reserve = math.max(1, before - 2000 * M.level(world.sides[sideIndex], a))
    ring(world, m.x, m.y, 3, 0.8, 0.6, 0.2)
    world:event("famine", m, before - m.mine.reserve, sideIndex)
end

-- Couatl's Wrath: 5 + level fireballs around the temple, 150 fire damage to everything in a 9 x 8 box around each.
-- The fireballs are the Titan's ten balls (the explode effect, case 0x23 of the effect function FUN_004ac0e0: Titan
-- fireball missiles made with the cell constructor, forced damage, shot at the table's offsets, FUN_00520f20's table at
-- 0x00608190): they fly from the temple to their cell and burst there, see missiles.lua (a ball that hits something on its
-- last step does not burst). The binary's table holds signed 16-bit cell deltas and skips a ball that would land outside
-- the map.
function EFFECT.wrath(world, sideIndex, b, a)
    local n = math.min(5 + M.level(world.sides[sideIndex], a), 10)
    for i = 1, n do
        local ball = specials.TITAN_BALLS[i]
        local cx, cy = b.gx + ball[1], b.gy + ball[2]
        if cx >= 0 and cy >= 0 and cx <= world.w and cy <= world.h then
            missiles.launch(world, { code = "EMTF", kind = "ball", force = true, gx0 = b.gx, gy0 = b.gy,
                                     gx1 = cx, gy1 = cy, ex = cx * 32 + 16, ey = cy * 24 + 12 })
        end
    end
end

-- Elcor's Balm: Major Healing (result 1): +100 hit points (Empower adds its percentage) and a cure for every
-- damaged own unit but titans. Elcor's Aura (hero skill 44) adds 20 hit points per level on top, after the
-- Empower scaling (verified against the original healing code and the skill effect table).
function EFFECT.balm(world, sideIndex, b)
    local sd = world.sides[sideIndex]
    local amount = 100
    if sd.empower and sd.empower > world.time then amount = math.floor((100 + (sd.empowerPct or 50)) * amount / 100) end
    local hero = world.eco:heroAlive(sideIndex)
    local aura = hero and hero.h and (hero.h.skill[44] or 0) or 0
    amount = amount + 20 * aura
    for _, o in ipairs(world.units) do
        if o:alive() and (o.side == sideIndex or (not enemyOf(world, sideIndex, o) and o.side ~= 6)) and not isTitan(o)
            and o.hp < o.maxHp then
            status.cure(o)
            o.hp = math.min(o.maxHp, o.hp + amount)
        end
    end
    ring(world, b.x, b.y, 12, 0.4, 1, 0.5)
end

-- Whether the button has something to act on (the original beeps otherwise and spends nothing).
local function hasTargets(world, sideIndex, b, a)
    if a.effect == "holy" then return #enemiesAround(world, b, sideIndex, 14, false, isEvil) >= 1 end
    if a.effect == "plague" then return #enemiesAround(world, b, sideIndex, 14, false) >= 1 end
    return true
end

-- What a use takes: the price, but Elcor's Balm takes 100 less from a computer side (FUN_004d2030, after the 400 were
-- asked for) and the computer's Famine nothing (FUN_005019d0 casts without the resource message).
local function taken(world, sideIndex, a, ai)
    local c = a.gold or a.crystal
    if a.effect == "balm" and world.sides[sideIndex].ai then c = c - 100 end
    if a.effect == "famine" and ai then c = 0 end
    return c
end

-- Carries the ability out (called by the "ability" command, i.e. the building button, and with `ai` by the computer
-- players, whose routines check the price and their targets themselves and have no button timer). `key`: pressed with
-- its KeyMap.txt key (game/abilitykeys.lua; FUN_00426350 cases 0x13 / 0x14 / 0x22 / 0x24 / 0x2a / 0x2e): the building
-- the key found (FUN_00427e30 does not ask whether it is finished), the power-up and the price are asked, but there is
-- no button timer and no target check, and `keyUnpaid` abilities take nothing.
---@param world World
---@param sideIndex integer
---@param b Building
---@param id string the ability
---@param ai boolean? the computer's ability sweep
---@param key boolean?
---@return boolean
function M.use(world, sideIndex, b, id, ai, key)
    local a = M.byId[id]
    if not a or b.side ~= sideIndex or b.hp <= 0 or not a.buildings[b.code] then return false end
    if key then
        local fn = EFFECT[a.effect]
        if not (fn and a.key) or M.level(world.sides[sideIndex], a) == 0 then return false end
        local res = a.gold and "gold" or "crystal"
        if (world.sides[sideIndex][res] or 0) < (a.gold or a.crystal) then
            world:event("needmore", sideIndex, res)       -- FUN_0050f1b0, as the buttons
            return false
        end
        fn(world, sideIndex, b, a)
        local price = a.keyUnpaid and 0 or taken(world, sideIndex, a, false)
        if price > 0 then spend(world, sideIndex, res, price) end
        if a.snd then sound.playAt("Assets/SoundFX.xcr", ("STEZ%02d.wav"):format(a.snd), b.gx, b.gy) end
        return true
    end
    if not b.complete then return false end
    if a.dialog then return false end
    if not M.usable(world, sideIndex, a) then return false end
    local side = world.sides[sideIndex]
    if a.morph then
        -- the gravestone turns into a skeleton at its place (free)
        b.hp = 0
        b.destroyed = true
        if b.shape then world:blockShape(b.gx, b.gy, b.shape, false) end
        local x, y = world:nearestFree(b.gx, b.gy, 0, 3)
        local u = world:addUnit(a.morph, sideIndex, x or b.gx, y or b.gy)
        if u then ring(world, u.x, u.y, 1.5, 0.6, 0.3, 0.8) end
        return true
    end
    world.abilityAt = world.abilityAt or {}
    local key = sideIndex .. a.id
    if a.unit then
        -- the hiring buttons: as many as fit (at most `max`), then the button's timer (3 s for Slave Horde / Brood, 1 s
        -- for the summons; armed before the price is looked at), then the price of all of them
        local cur, max = world.eco:armyLimit(sideIndex)
        local n = math.min(a.max, max - cur)
        if n <= 0 then return false end
        if world.abilityAt[key] and world.time < world.abilityAt[key] then return false end
        world.abilityAt[key] = world.time + a.delay
        if side[a.resource] < n * a.each then
            world:event("needmore", sideIndex, a.resource)        -- the announcer's "need more gold / ..."
            return false
        end
        spend(world, sideIndex, a.resource, n * a.each)
        for _ = 1, n do world.eco:spawnNear(b, a.unit) end
        return true
    end
    local res = a.gold and "gold" or "crystal"
    local fn = EFFECT[a.effect]
    if fn and not ai then
        -- the button's one-second timer comes first, armed also when the price or the targets are missing
        if world.abilityAt[key] and world.time < world.abilityAt[key] then return false end
        world.abilityAt[key] = world.time + M.CLICK
    end
    if (side[res] or 0) < (a.gold or a.crystal) then
        world:event("needmore", sideIndex, res)
        return false
    end
    if fn then
        if not ai and not hasTargets(world, sideIndex, b, a) then return false end
        -- Famine takes its crystals also when no mine is found (the button sends the resource message first)
        fn(world, sideIndex, b, a)
        local price = taken(world, sideIndex, a, ai)
        if price > 0 then spend(world, sideIndex, res, price) end
        if a.snd then sound.playAt("Assets/SoundFX.xcr", ("STEZ%02d.wav"):format(a.snd), b.gx, b.gy) end
        return true
    end
    spend(world, sideIndex, res, a.crystal)
    -- the abilities send the weather spell message of the original (the buttons 0x004d11b0, 0x004d1300, 0x004d18a0,
    -- no timer): Rites of Dawn kind 0 (day, fine), Dark Citadel 2 / 3 (night, the rain kept), Storm Call 4 / 5 (a
    -- storm, at night 5); the crystals are gone even when a day / night transition makes the host refuse the message
    local weather = require("src.game.weather")
    if a.weather == "day" then
        weather.spell(world, 0)
    elseif a.weather == "night" then
        weather.spell(world, world.raining and 3 or 2)
    elseif a.weather == "storm" then
        weather.spell(world, world.night and 5 or 4)
    end
    return true
end

-- Computer players (the ability sweep FUN_005001d0 / the decision FUN_00500830): once a second a side looks at
-- its buildings in list order and uses at most one ability; Knave / Knight level sides only look one time in twenty.
-- Per building: Holy Word with 200 crystal and 3 weighted evil enemies within 12 cells (or 1 when the building is below
-- 100 hit points, FUN_00501820), Couatl's Wrath with 750 gold and 5 (weighted) enemies (FUN_005018b0), Chaos Plague
-- with 1000 crystal and 5 (FUN_00501940), Famine one time in 150 with 700 crystal, which it does not pay
-- (FUN_005019d0), Elcor's Balm (Healer only, 400 crystal, pays 300; FUN_005013e0) with weighted 8 damaged own armies
-- anywhere or a hero below half its hit points, Rites of Dawn one time in 100 at night (free for the computer). All
-- need the power-up. Sword of Sirian, the summons and the gravestone are never used.
local AI_CHECK = 1000
local function aiAbility(world, sideIndex, b)
    local side = world.sides[sideIndex]
    local code = b.code
    local function pu(a) return M.level(side, a) > 0 end
    local function box(r, filter) return enemiesAround(world, b, sideIndex, r, false, filter) end
    local function try(id) return M.use(world, sideIndex, b, id, true) end
    if code == "BPCA" or code == "BPMT" then
        if pu(M.byId.holyWord) and side.crystal >= 200 then
            local n = weight(box(12, isEvil))
            if n >= 3 or (n >= 1 and b.hp < 100) then if try("holyWord") then return true end end
        end
    elseif code:sub(1, 3) == "BKL" then
        if pu(M.byId.wrath) and side.gold >= 750 then
            local n = weight(box(12))
            if n >= 5 or (n >= 1 and b.hp < 100) then if try("wrath") then return true end end
        end
    elseif code:sub(1, 3) == "BKR" then
        if math.random(150) == 1 and pu(M.byId.famine) and side.crystal >= 700 then return try("famine") end
    elseif code:sub(1, 3) == "BKG" then
        if pu(M.byId.chaosPlague) and side.crystal >= 1000 then
            local n = weight(box(12))
            if n >= 5 or (n >= 1 and b.hp < 100) then if try("chaosPlague") then return true end end
        end
    elseif code == "BPHE" then
        if pu(M.byId.elcorsBalm) and side.crystal >= 400 then
            local count = 0
            for _, o in ipairs(world.units) do
                if o:alive() and o.side == sideIndex and o.hp < o.maxHp - 40 and not (o.fx and o.fx.invis) then
                    count = count + math.floor(o.maxHp / 32) + 1
                end
            end
            local hero = world.eco:heroAlive(sideIndex)
            if count >= 8 or (hero and hero.hp < hero.maxHp / 2) then return try("elcorsBalm") end
        end
    end
    if (code == "BPCA" or code == "BPMT" or code:sub(1, 3) == "BKL") and math.random(100) == 1
        and pu(M.byId.ritesOfDawn) and (world.night or world.raining) then
        require("src.game.weather").spell(world, 0)
        return true
    end
    return false
end

---@param world World
---@param sideIndex integer
function M.aiUpdate(world, sideIndex)
    local t = world.time
    world.aiAbilityAt = world.aiAbilityAt or {}
    if world.aiAbilityAt[sideIndex] and t < world.aiAbilityAt[sideIndex] then return end
    world.aiAbilityAt[sideIndex] = t + AI_CHECK
    local level = world.sides[sideIndex].aiLevel or 2
    if (level == 1 or level == 2) and math.random(20) ~= 1 then return end
    for _, b in ipairs(world.buildings) do
        if b.side == sideIndex and b.complete and b.hp > 0 and aiAbility(world, sideIndex, b) then return end
    end
end

return M
