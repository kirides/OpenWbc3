-- Computer player: base, danger, towers, hero retreat, defence and the Rampant ("barbarian") attack.
--
-- Rules of the original, with their routines in the 1.04 binary (the computer player block 0x004f7cb0..0x004ffee0, its
-- think FUN_004fa120):
--  * Toughness (precomputed per type by FUN_00505530): army = combat + speed + hits / 4 + damage / 2 + range; an armed
--    building = 4 combat + 4 speed + 2 hits + 4 damage, an unarmed one 0.
--  * Danger of a unit (FUN_004fac00, decompiled): the toughness of every non-allied, non-neutral
--    army that is on the map and armed building (finished or not) within 16 (army) / 12 (building) + the unit's height
--    cells; the ones whose current target it is count double, or only those when asked "being attacked only". Base safety
--    (FUN_004fbe80) is the same sum within 30 cells of a point, without the doubling.
--  * Enemy choice (FUN_004fa5b0, decompiled): per used, undefeated, non-allied side that still
--    owns something, a score from a bias by the AI level against a human {0, -5, -5, 20, 40, 75, 250, 50} or against
--    another computer side by its level {0, 25, 15, -15, -30, -60, -125, -5}, the damage it did to us (shifted right
--    2 / 3 / 4 / 5 / 6 / 8 for AI opponents by level, 2 for humans; the figure decays by 1, 2 for the current enemy,
--    per think), the hate index of the pair (ai.hate, rolled when the game starts, see ai.lua) and (300 - distance of
--    the two start spots) / 2; at least 1, the first best wins.
--  * Towers (FUN_004f8fa0): at most 3 / 7 / 13 / 20 / 30 / 45 (default 13) towers per AI level (allied towers
--    count); the building with the best "needs towers" ratio gets the next one: required = weight / 64 with the weight
--    from the script's building priority x5, else the best of keep level x keeps, mine size x mines, army production
--    3 x army production, power-up production 3 x power-up production (defaults 100 / 70 / 70 / 40), ratio =
--    ((required - towers within 11 cells) x 100 / (required + 1)) x 4, plus a quarter of the distance to the nearest
--    tower.
--  * Base relocation (FUN_004fbdf0 / FUN_004fc020): when the base safety exceeds 300 and the script
--    allows it (default yes), one of 20 random points that is more than min(30, mapwidth / 4) from the main enemy's
--    start and has safety under 50 becomes the base; tried at most every 5 s.
--  * Hero retreat (FUN_004fc150, only when the script allows it, default yes): a hero under 200 hits that is being
--    attacked runs to the base; it stops when its order is over or it is back over 250 hits and nobody attacks it.
--  * Defence (FUN_004fa380): an enemy within 30 cells of the base that is going after one of our units makes every free
--    army of ours within 35 cells of it attack it.
--  * Rampant (best targets FUN_004fa990, attack FUN_004fa850): every think the best ground and air target of the main
--    enemy are chosen (army 300 - ground targets are not flyers or ships -, building 150, walls 0, the flag of Capture
--    the Flag -500, plus (map height - distance from the base) / 2, plus 70 minus the danger level of the region map;
--    the original asks for the danger of the square (x / 16, y / 16) and the lookup FUN_00509980 divides by 16 again,
--    so it is always the first square's: the same for every target) and every free army fights it (ground + air
--    attackers a random one of both). An army without an attack is skipped (the attack order FUN_0051da60 returns at once).
--  * The neutral side (6) runs this Rampant path as well (binary FUN_004fa120): its enemy is a random one of the used,
--    undefeated sides on every think (FUN_004fa5b0, `sVar1 == 6` branch), its base the scenario's start spot for side 6 (-1,
--    -1 when it has none), and its defence takes every other side as an enemy.
local aidata = require("src.game.aidata")
local economy = require("src.game.economy")
local powerups = require("src.game.powerups")
local bit = require("bit")

local arshift = bit.arshift

local M = {}

-- Toughness ------------------------------------------------------------------------------------------------------

---@param e Unit|Building
---@return number
function M.toughness(e)
    local t = e.type
    if not t then return 200 end
    if e.kind == "building" then
        if (t.damage or 0) <= 0 then return 0 end
        return (t.combat or 0) * 4 + (t.speed or 0) * 4 + (t.hits or 0) * 2 + (t.damage or 0) * 4
    end
    return (t.combat or 0) + (t.speed or 0) + math.floor((t.hits or 0) / 4) + math.floor((t.damage or 0) / 2) + (t.range or 0)
end

local function height(e)
    return e.type and e.type.shape and e.type.shape.h or 1
end

-- Danger to a unit from the hostile armies and buildings around it (FUN_004fac00)
---@param ai AI
---@param st AISide
---@param e Unit|Building
---@param attackedOnly boolean?
---@return number
function M.danger(ai, st, e, attackedOnly)
    local world = ai.world
    local radius = (e.kind == "building" and 12 or 16) + height(e)
    local total = 0
    for _, o in ipairs(world.units) do
        if o.side ~= 6 and world:enemies(st.index, o.side) and o:alive()
            and math.abs(o.gx - e.gx) <= radius and math.abs(o.gy - e.gy) <= radius then
            local d = M.toughness(o)
            if o.target == e then
                total = total + (attackedOnly and d or d * 2)
            elseif not attackedOnly then
                total = total + d
            end
        end
    end
    for _, b in ipairs(world.buildings) do
        if b.side ~= 6 and world:enemies(st.index, b.side) and b.hp > 0
            and math.abs(b.gx - e.gx) <= radius and math.abs(b.gy - e.gy) <= radius then
            local d = M.toughness(b)
            if d > 0 then
                -- a building that is shooting at the unit counts double (FUN_004fac00: damage over 0 and its target is
                -- the unit); an unfinished one counts like a finished one, the original has no such test
                local shooting = b.target == e
                if attackedOnly then
                    if shooting then total = total + d end
                else
                    total = total + (shooting and d * 2 or d)
                end
            end
        end
    end
    return total
end

-- Base safety: hostile strength within 30 cells of a point (FUN_004fbe80)
---@param ai AI
---@param st AISide
---@param gx integer
---@param gy integer
---@return number
function M.baseSafety(ai, st, gx, gy)
    local world = ai.world
    local total = 0
    for _, o in ipairs(world.units) do
        if o.side ~= 6 and world:enemies(st.index, o.side) and o:alive()
            and math.abs(o.gx - gx) <= 30 and math.abs(o.gy - gy) <= 30 then
            total = total + M.toughness(o)
        end
    end
    for _, b in ipairs(world.buildings) do
        if b.side ~= 6 and world:enemies(st.index, b.side) and b.hp > 0 and b.complete
            and math.abs(b.gx - gx) <= 30 and math.abs(b.gy - gy) <= 30 then
            total = total + M.toughness(b)
        end
    end
    return total
end

-- Start locations (the original keeps them in the side records, x / y at DAT_00708fa8 / DAT_00708fac): the scenario's
-- start spot, else the first keep / unit
---@param ai AI
---@param side integer
---@return integer gx
---@return integer gy
function M.startOf(ai, side)
    local sd = ai.world.sides[side]
    if sd.startX and sd.startX >= 0 then return sd.startX, sd.startY end
    for _, b in ipairs(ai.world.buildings) do
        if b.side == side and aidata.isKeep(b.code) then return b.gx, b.gy end
    end
    for _, u in ipairs(ai.world.units) do
        if u.side == side then return u.gx, u.gy end
    end
    return 0, 0
end

-- Enemy choice (FUN_004fa5b0)
-- the biases and the damage shift by level are `aiprofile` fields (content/base/aiprofiles.lua)
local profile = require("src.game.aiprofile")

-- the side still has something on the map (FUN_004fa5b0 tests the side's object list in the table at DAT_00afd4cc; a
-- defeated human that has not left yet has none)
local function ownsSomething(world, side)
    for _, u in ipairs(world.units) do
        if u.side == side and u.state ~= "dead" and not u.remove then return true end
    end
    for _, b in ipairs(world.buildings) do
        if b.side == side and not b.rubbleSince then return true end
    end
    return false
end

---@param ai AI
---@param st AISide
function M.chooseEnemy(ai, st)
    local world = ai.world
    if st.index == 6 then
        -- the neutral side: a random one of the used, undefeated sides every think (binary FUN_004fa5b0, `sVar1 == 6`
        -- branch); it keeps the old choice when no side is left
        local list = {}
        for j = 0, 5 do
            local sd = world.sides[j]
            if sd.used and not sd.defeated then list[#list + 1] = j end
        end
        if #list > 0 then st.enemy = list[math.random(1, #list)] end
        return
    end
    local best, bestP = nil, -1000
    local mx, my = M.startOf(ai, st.index)
    local hate = ai.hate and ai.hate[st.index]
    for j = 0, 5 do
        local sd = world.sides[j]
        if j ~= st.index and sd.used and not sd.defeated and world:enemies(st.index, j) and ownsSomething(world, j) then
            local p = 0
            local dmg = st.damageTaken[j] or 0
            if dmg > 0 then
                st.damageTaken[j] = dmg - ((j == st.enemy and dmg > 1) and 2 or 1)
            end
            local human = world.humans[j] and not sd.ai
            if human then
                p = p + profile.get(st.level, "humanBias", 0)
                p = p + math.floor(dmg / 4)
            else
                p = p + profile.get(sd.aiLevel or 2, "aiBias", 0)
                p = p + math.floor(dmg / profile.get(st.level, "damageShift", 4))
            end
            if hate then p = p + (hate[j] or 0) end
            local sx, sy = M.startOf(ai, j)
            local dist = math.abs(sx - mx) + math.abs(sy - my)
            p = p + math.floor(math.max(0, 300 - dist) / 2)
            p = math.max(p, 1)
            if p > bestP then best, bestP = j, p end
        end
    end
    st.enemy = best
end

-- Towers --------------------------------------------------------------------------------------------------------------


local function categoryLevels(D, code)
    local c = { keep = 0, army = 0, powerup = 0, mine = 0, tower = 0 }
    for _, item in ipairs(D.production[code] or {}) do
        if item:sub(1, 1) == "A" then c.army = 3 else c.powerup = 3 end
    end
    local second = code:sub(2, 2)
    local d = tonumber(code:sub(4, 4)) or 0
    if second == "K" then c.keep = d + 2
    elseif second == "R" then c.mine = d + 1
    elseif second == "T" then c.mine = 5
    elseif second == "W" and code:sub(3, 3) == "T" then c.tower = 3 end
    return c
end

---@param ai AI
---@param st AISide
function M.bestTowerLocation(ai, st)
    local world = ai.world
    local limit = profile.get(st.level, "towerLimit", 13)
    local towers, mine = {}, 0
    for _, b in ipairs(world.buildings) do
        if b.hp > 0 and aidata.isTower(b.code) and b.side ~= 6 and not world:enemies(st.index, b.side) then
            towers[#towers + 1] = b
            if b.side == st.index then mine = mine + 1 end
        end
    end
    local pots = {}
    for _, p in ipairs(st.potential) do
        if p.until_ > st.time then
            pots[#pots + 1] = p
            towers[#towers + 1] = p
            mine = mine + 1
        end
    end
    st.potential = pots
    if mine >= limit then st.bestTower = nil return end
    local params = st.params
    local script = params and params.raceData ~= nil and params.raceData ~= -1
    local def = params and params.defense or { keeps = 100, mines = 70, armyProduction = 70, powerupProduction = 40 }
    local best, bestP = nil, 0
    for _, b in ipairs(world.buildings) do
        if b.side == st.index and b.hp > 0 and not aidata.isTower(b.code) then
            local weight, found = 0, false
            if script and params and params.building[b.code] then
                weight, found = params.building[b.code] * 5, true
            end
            if not found then
                local c = categoryLevels(st.D, b.code)
                weight = math.max(c.keep * def.keeps, c.mine * def.mines, c.army * def.armyProduction,
                                  c.powerup * def.powerupProduction)
            end
            local px, py = b.gx, b.gy + math.floor(((b.shape and b.shape.w) or 1) / 2)
            local nearest, inRange = 1000, 0
            for _, t in ipairs(towers) do
                local d = math.max(math.abs(t.gx - px), math.abs(t.gy - py))
                if d < nearest then nearest = d end
                if d <= 11 then inRange = inRange + 1 end
            end
            local required = math.floor(weight / 64)
            local ratio = required > 0 and math.floor((required - inRange) * 100 / (required + 1)) * 4 or 0
            local p = ratio > 0 and (ratio + math.floor(nearest / 4)) or 0
            if p > bestP then best, bestP = b, p end
        end
    end
    st.bestTower = best and { gx = best.gx, gy = best.gy } or nil
end

-- Base ----------------------------------------------------------------------------------------------------------------

-- A safer base spot: 20 random tries, at most every 5 s (FUN_004fc020)
local function newSafeBase(ai, st)
    local world = ai.world
    if st.lastBaseSearch and st.time < st.lastBaseSearch + 5000 then return nil end
    st.lastBaseSearch = st.time
    local ex, ey = -1000, -1000
    if st.enemy then ex, ey = M.startOf(ai, st.enemy) end
    local lo, hi = 10, world.w - 10
    for _ = 1, 20 do
        local x, y = math.random(lo, hi), math.random(lo, hi)
        if math.max(math.abs(x - ex), math.abs(y - ey)) > math.min(30, math.floor(hi / 4)) then
            if M.baseSafety(ai, st, x, y) < 50 then return x, y end
        end
    end
end

-- The main base point, moved when the base is in danger (FUN_004fbdf0)
---@param ai AI
---@param st AISide
---@return integer? gx
---@return integer? gy
function M.mainBase(ai, st)
    local params = st.params
    local allowed = not params or params.flags.baseRelocation
    if allowed and M.baseSafety(ai, st, st.baseX, st.baseY) > 300 then
        local x, y = newSafeBase(ai, st)
        if x then
            st.baseX, st.baseY = x, y
            st.relocated = (st.relocated or 0) + 1
        end
    end
    return st.baseX, st.baseY
end

-- Hero ----------------------------------------------------------------------------------------------------------------

-- A hurt hero under attack runs home, and stops when healed or its order is over (FUN_004fc150)
---@param ai AI
---@param st AISide
---@param hero Unit?
function M.heroStatus(ai, st, hero)
    local params = st.params
    if params and not params.flags.heroRetreat then return end
    if not hero or not hero:alive() then st.heroRunning = false return end
    local hits = hero.hp
    if not st.heroRunning and hits < 200 and M.danger(ai, st, hero, true) > 0 then
        st.heroRunning = true
        ai.groups.removeUnit(st, hero)
        hero:orderMove(st.baseX, st.baseY)
    elseif st.heroRunning then
        if hero.state == "idle" or (hits >= 250 and M.danger(ai, st, hero, true) == 0) then
            st.heroRunning = false
        end
    end
end

-- Defence -------------------------------------------------------------------------------------------------------------

-- the attack order FUN_0051da60 returns at once for an army without an attack (attack type none: critters, wisps ...)
local function canFight(u) return u:canAttackGround() or u:canAttackAir() end

---@param ai AI
---@param st AISide
---@param units Unit[]
function M.defend(ai, st, units)
    local world = ai.world
    for _, e in ipairs(world.units) do
        -- (the neutral side is allied to nobody but itself: alliance table DAT_00748915, filled by FUN_004de740)
        if e.side ~= st.index and e:alive() and (st.index == 6 or e.side == 6 or world:enemies(st.index, e.side)) then
            local tg = e.target
            if tg and tg.side == st.index and math.abs(e.gx - st.baseX) <= 30 and math.abs(e.gy - st.baseY) <= 30 then
                for _, u in ipairs(units) do
                    if u.state == "idle" and u:alive() and not (u.hero and st.heroRunning) and canFight(u)
                        and math.abs(u.gx - e.gx) < 35 and math.abs(u.gy - e.gy) < 35 then
                        u:orderAttack(e)
                    end
                end
            end
        end
    end
end

-- Conversion -----------------------------------------------------------------------------------------------------------

-- Whether a keep should convert (FUN_004fbc60): it does when the next thing waiting in its order queue (the item
-- in production is not in the queue) is not a building / power-up / research (a first order that is a production of
-- anything but an army says no) and the other sides own resource points within
-- 32 cells of it whose level digits (the 4th character of the code) add up to more than 0 - so level 0 mines alone do
-- not count, the neutral side's mines do.
---@param ai AI
---@param st AISide
---@param keep Building
---@return boolean
function M.shouldPalaceConvert(ai, st, keep)
    local first = keep.queue[1]
    if first and first:sub(1, 1) ~= "A" then return false end
    local count = 0
    for _, b in ipairs(ai.world.buildings) do
        if b.side ~= st.index and not b.destroyed and b.hp > 0 and b.code:sub(2, 2) == "R"
            and math.abs(b.gx - keep.gx) <= 32 and math.abs(b.gy - keep.gy) <= 32
            and (b.gx - keep.gx) ^ 2 + (b.gy - keep.gy) ^ 2 <= 1024 then
            count = count + ((tonumber(b.code:sub(4, 4)) or 0))
        end
    end
    return count > 0
end

-- Keep conversions (FUN_004fbb90, in the 15 s block of the think): while the side has an army that can convert (a hero
-- or general) the keeps do nothing, and the AI player remembers that a converter exists; without one every keep that
-- FUN_004fbc60 accepts and that is not converting yet stops its production and starts converting.
---@param ai AI
---@param st AISide
---@param units Unit[]
---@param blds Building[]
function M.palaceConversions(ai, st, units, blds)
    local eco = ai.world.eco
    local converter = false
    for _, u in ipairs(units) do
        if eco:canConvert(u) then converter = true break end
    end
    st.converterExists = converter
    if converter then return end
    for _, b in ipairs(blds) do
        if economy.isKeep(b.code) and b.complete and not b.convert and M.shouldPalaceConvert(ai, st, b) then
            if b.current or b.waiting or #b.queue > 0 then eco:stopProduction(b) end
            eco:startKeepConversion(b)
        end
    end
end

-- Best conversion square (FUN_004f8820): where the leader of a conversion group stands to convert `target`.
-- Candidate cells are the ring of cells whose distance to the target (floor of the Euclidean distance) is exactly
-- range - 1, that the unit can move to (FUN_0042cb70: terrain, buildings, features and the units standing there) and,
-- on the ground, that lie in a region the converter's region reaches (the region map, airegion.lua: the region
-- expansion FUN_00509320 from the converter's region, then the candidate's region must have been reached; a converter
-- standing on no region gets no square); each earns 300 for every one of up to five buildings of other sides around
-- the target (first rows from the top, left to right, within twice the range) that is within that distance of it, plus
-- 256 less its Chebyshev distance to the converter. The first best one wins; nil when no cell qualifies (the original
-- then returns (-1, -1)).
---@param ai AI
---@param st AISide
---@param target Building
---@param range integer
---@param u Unit the converter
---@return {[1]: integer, [2]: integer}? cell
function M.bestConversionSquare(ai, st, target, range, u)
    local world = ai.world
    local terrain = world.terrain
    range = range - 1
    local ix, iy = target.gx, target.gy
    local function dist(dx, dy) return math.floor(math.sqrt(dx * dx + dy * dy)) end
    local near = {}
    for k, b in ipairs(world.buildings) do
        if b.side ~= st.index and not b.destroyed and b.hp > 0 and math.abs(b.gx - ix) <= range * 2
            and math.abs(b.gy - iy) <= range * 2 then
            near[#near + 1] = { b = b, k = k }
        end
    end
    table.sort(near, function(a, c)
        if a.b.gy ~= c.b.gy then return a.b.gy < c.b.gy end
        if a.b.gx ~= c.b.gx then return a.b.gx < c.b.gx end
        return a.k < c.k
    end)
    local list = {}
    for i = 1, math.min(5, #near) do list[i] = near[i].b end
    local move = u.move
    local layerAir = move == 1
    -- the cell test FUN_0042cb70(x, y, height, move): every blocker of the layer (terrain, buildings and features on
    -- the ground, the units of the same layer)
    local function canMove(x, y)
        if x < 0 or y < 0 or x >= world.w or y >= world.h then return false end
        if not terrain:passable(x, y, move) then return false end
        local i = world:index(x, y)
        if not layerAir and world.static[i] ~= 0 then return false end
        local o = world.occ[i]
        if o and (o.move == 1) == layerAir then return false end
        return true
    end
    local regions, size, startRegion
    if not layerAir then
        regions = ai.region
        size = math.max(1, (u.type and u.type.shape and u.type.shape.h) or 1)
        startRegion = regions:regionAt(u.gx, u.gy, size)
        if not startRegion then return nil end
        regions:expand(startRegion, move, size)
    end
    local best, bestP = nil, 0
    for x = math.max(0, ix - range), math.min(ix + range, world.w - 1) do
        for y = math.max(0, iy - range), math.min(iy + range, world.h - 1) do
            if dist(math.abs(x - ix), math.abs(y - iy)) == range and canMove(x, y) then
                local reachable = layerAir
                if not reachable then
                    local region = regions:regionAt(x, y, size)
                    reachable = region ~= nil and regions:reached(region, size)
                end
                if reachable then
                    local p = 0
                    for _, b in ipairs(list) do
                        if dist(math.abs(x - b.gx), math.abs(y - b.gy)) <= range then p = p + 300 end
                    end
                    p = p + math.max(0, 256 - math.max(math.abs(u.gx - x), math.abs(u.gy - y)))
                    if p > bestP then best, bestP = { x, y }, p end
                end
            end
        end
    end
    return best
end

-- Rampant -------------------------------------------------------------------------------------------------------------

---@param ai AI
---@param st AISide
function M.setBestTarget(ai, st)
    local world = ai.world
    st.bestTarget = {}
    local enemy = st.enemy
    if not enemy then return end
    local mapH = world.h
    local flagIsBait = require("src.game.victory").get(world.victoryRule, "flagGame") == true
    local region = ai.region
    for kind = 1, 2 do                       -- 1 ground, 2 air (the original also keeps a sea target that nothing uses)
        local best, bestP = nil, -1
        local function consider(e, p)
            local d = math.max(math.abs(e.gx - st.baseX), math.abs(e.gy - st.baseY))
            p = p + math.floor((mapH - d) / 2)
            -- the danger lookup FUN_00509980(owner, (x / 16, y / 16)) divides by 16 once more
            p = p + math.max(0, 70 - region:dangerLevel(st.index, arshift(e.gx, 4), arshift(e.gy, 4)))
            if p > bestP then best, bestP = e, p end
        end
        for _, u in ipairs(world.units) do
            if u.side == enemy and u:alive() then
                local ok
                if kind == 1 then ok = u.move ~= 1 and u.move ~= 2 else ok = u.move == 1 end
                if ok then consider(u, 300) end
            end
        end
        for _, b in ipairs(world.buildings) do
            if b.side == enemy and b.hp > 0 then
                local p = 150
                if b.code:sub(2, 2) == "W" and b.code:sub(3, 3) ~= "T" then p = 0 end
                if b.code == "BMFL" and flagIsBait then p = -500 end
                consider(b, p)
            end
        end
        st.bestTarget[kind] = best
    end
end

---@param ai AI
---@param st AISide
---@param units Unit[]
function M.doAttack(ai, st, units)
    local t = st.bestTarget
    if not t or (not t[1] and not t[2]) then return end
    for _, u in ipairs(units) do
        if u.state == "idle" and canFight(u) then
            local tg
            if u:canAttackGround() and u:canAttackAir() then
                tg = (not t[1]) and t[2] or (not t[2]) and t[1] or t[math.random(1, 2)]
            elseif u:canAttackGround() then tg = t[1]
            else tg = t[2] end
            if tg then u:orderAttack(tg) end
        end
    end
end

return M
