-- Computer player: army groups, after the group system of the 1.04 binary (decompiled in Ghidra): the group walk
-- FUN_004f5610, the per-group update FUN_004f39f0, the mission stages FUN_004f3b00, the member orders FUN_004f42a0 with
-- the threat test FUN_004f3e70 and the unit handlers FUN_004f4320 / 4390 / 4460 / 4530 / 4690 / 47c0 / 4a90 / 4b40 /
-- 4d50, the activation FUN_004f3520, the target side FUN_004f4e30, the reassessment FUN_004f6530, the idle armies
-- FUN_004f5700, the group choice FUN_004f59e0, the tower vacancies FUN_004f71e0, the tower order FUN_004f72e0, the group
-- types FUN_004f6d90 and the target choice FUN_004f66f0, the target lists FUN_004f6160 (attack) / FUN_004f6340
-- (conversion) with the target priority FUN_004f5e90 and the resource need FUN_004f5e00, the new group FUN_004f5570.
-- Details worth noting are below (sea units count as air for the threat test, an army without an attack passes it, the
-- regrouping of an idle member, hits tests of the idle builders, the tower list, the 100 group slots, the 200 entry target
-- lists, the stored combat in an army's priority, the map rows of the conversion list).
--
--  * Idle armies are put into groups (FUN_004f5700 / FUN_004f59e0): a hero always opens a new group, a
--    converter (hero, general) opens one while fewer than three conversion groups exist; otherwise the best-fitting
--    group that is not full (500 + 50 while recruiting + 200 for a hero group, minus 50 for a tough unit in a group that
--    is not a kick-butt / generals one), skipping groups that do not suit the unit (long range, kick-butt over 100 hits,
--    generals only for generals, slow units in conversion groups, ground / air attack compatibility, groups that are far
--    away). A builder under 50 hits is never grouped. A share of the land army (the script's "armies in towers", default
--    20 %; the garrisoned armies and the builders putting up a building count as in towers, being off the map) is sent
--    into towers with room instead (units over 2 set-up points only when the script allows it).
--  * Group types are given once (FUN_004f6d90): conversion (up to 3, groups of up to 3 with a converter), long range
--    (up to 2), generals (one, a single general), kick-butt (single unit over 100 hits, odds level-dependent), weak
--    (a single weak unit), large (odds level-dependent), mine killer (odds by level, at most 3) or normal. A group
--    activates when it has its minimum size (script sizes, default normal 10-12, long range 4-5, mine killer 6-8,
--    kick-butt 7-10, large 15-17, generals 6-9, times 40 / 60 / 80 / 100 / 130 / 160 % by level; conversion 1-3), when it
--    holds a hero, or when the army is within 4 of its limit.
--  * An active group picks the side to attack (the main enemy; at higher levels sometimes another human) and a target
--    (FUN_004f66f0: 700 + target priority, + 100 / - 200 conversion bonus, + 50 / 100 / 200 attack bonus by group
--    type, - distance, + 500 for keeping the target, + 2d100 for a new one); the target list of a side is rebuilt every
--    15 s; the groups are reassessed one per think (a hero group every think). Members move to the target with the
--    leader (the group's slowest speed), regroup when scattered (separation over 20 within 40 cells of the target),
--    attack the target at 20 cells, and threat-assess every think: enemy armies attacking us, armed buildings and other
--    buildings within 14 cells are fought first.
--  * Target priorities (FUN_004f5e90): temple 150, lair 1, resource point from our need of the resource (half the
--    required percentage shifted by the size, + 10), flag 250, keep 40 x (level + 1), tower 40, wall 10, anything else
--    25, plus 500 - 2 x distance from our base; a resource point near an enemy start loses 200 / 100 / 60 (within 15 /
--    30 / 60 cells) or gains 40 (over 80). An army is only a target when its side has no buildings (30 + half its stored
--    combat + (256 - distance from our base) / 8).
--  * Not verifiable / own: the lists are rebuilt on the game clock (the original reads the wall clock),
--    and the order of the entries within a map row of the conversion list is the world's.
-- The target choice (binary FUN_004f66f0, decompiled) also runs a
-- "safe search" of the region map (airegion.lua) from the group leader's region: the cost of the way to a building,
-- with the danger of the squares on it, is the building's path danger and takes part in the priority; a group that
-- already has a target whose way is still cheap enough keeps it (the -2 result).
-- Not original (openwbc3's own): a conversion group's leader without a "best conversion square" walks straight to the
-- building;
-- the minimum / maximum size of a weak group (the original reads past its table) is 12; "range" in the long-range
-- tests is the .ARM range as openwbc3 stores it.
local aibase = require("src.game.aibase")
local aidata = require("src.game.aidata")
local economy = require("src.game.economy")
local powerups = require("src.game.powerups")
local rules = require("src.game.rules")

local M = {}

local NORMAL, LONGRANGE, MINEKILLER, KICKBUTT, LARGE, GENERALS, WEAK, CONVERSION, CUSTOM, NONE = 0, 1, 2, 3, 4, 5, 6, 7, 8, 9
M.TYPE = { NORMAL = NORMAL, LONGRANGE = LONGRANGE, MINEKILLER = MINEKILLER, KICKBUTT = KICKBUTT, LARGE = LARGE,
           GENERALS = GENERALS, WEAK = WEAK, CONVERSION = CONVERSION, CUSTOM = CUSTOM, NONE = NONE }
-- (the debug labels of FUN_004f4f70 are Normal, Long Range, Mine Killer, Kick-Butt, Large, Generals, Conversion)
M.TYPE_NAMES = { [0] = "normal", "long range", "mine killer", "kick-butt", "large", "generals", "weak", "conversion",
                 "custom", "none" }
local STAGE_INIT, STAGE_MOVE, STAGE_MAIN, STAGE_DONE, STAGE_REGROUP = 0, 1, 2, 3, 4
local OBJ_NONE, OBJ_RECRUIT, OBJ_ATTACK = 0, 1, 2
local MAX_SIZE = 32
-- The original's fixed tables (binary): 100 group slots (the new group `FUN_004f5570` refuses a 101st, `FUN_004f5610`
-- walks the slots in order and reassesses one per call), 200 entries per target list (`FUN_004f6160` / `FUN_004f6340`
-- stop at 200) and, in the conversion bookkeeping of the target choice (`FUN_004f66f0`), only the first 10 slots are
-- looked at when counting the groups that already go for a target.
local GROUP_SLOTS, MAX_TARGETS, COUNTED_SLOTS = 100, 200, 10

-- The default group sizes by type are the settings ai.groupMin / ai.groupMax, the size factor (default 50) and the chance to change the
-- target side (default 0) by level are in the `aiprofile` records.
local settings = require("src.content").setting
local profile = require("src.game.aiprofile")

local function dice(n) return math.random(1, n) end

-- A group's mission: recruit, attack `target` (the stages STAGE_*) or none.
---@class AIObjective
---@field type integer              OBJ_NONE / OBJ_RECRUIT / OBJ_ATTACK
---@field stage integer
---@field target (Unit|Building)?

-- An army group of a computer side.
---@class AIGroup
---@field id integer
---@field slot integer              0..99, the order the groups are processed in
---@field type integer              M.TYPE
---@field members Unit[]
---@field objective AIObjective
---@field minSize boolean           active: it reached its minimum size
---@field targetSide integer?
---@field leader Unit?
---@field px integer                the leader's cell, -1 without a leader
---@field py integer
---@field strength number           summed toughness
---@field longRange integer         long-range members
---@field conv integer              members that can convert
---@field speed number?             the slowest member's speed
---@field attackType integer        0 undefined, 1 ground, 2 air
---@field hero boolean?             holds a hero
---@field convPoint {[1]: integer, [2]: integer}? the best conversion square of the target
---@field threatOf table<Unit, (Unit|Building)?>? what each member saw last think
---@field missionTarget (Unit|Building)? the building the members go for together

-- An entry of a target list.
---@class AITarget
---@field e Unit|Building
---@field pri number
---@field danger number
---@field kind "conv"|"attack"
---@field groups integer            conversion groups already going for it

local function allied(world, a, b)
    if a == b then return true end
    if a == 6 or b == 6 then return false end
    local sa, sb = world.sides[a], world.sides[b]
    return sa.team ~= 0 and sa.team == sb.team
end

local function cheb(ax, ay, bx, by) return math.max(math.abs(ax - bx), math.abs(ay - by)) end

local function isGeneral(u)
    return u.hero or u.general or (rules.armyInfo(u.code) or {}).general == true
end

-- the army's building skill, a hero's 10 included
local function canBuild(u)
    return u.hero or powerups.buildSkill(u) > 0
end

local function range(u) return u:stats().range or 0 end

-- Group sizes --------------------------------------------------------------------------------------------------------

local function sizeOf(st, gtype)
    local p = st.params
    local lo, hi
    if gtype == WEAK or gtype == NONE then
        if gtype == NONE then lo, hi = 10, 10 else lo, hi = settings:value("ai.groupMax")[0], settings:value("ai.groupMax")[0] end
    elseif p and p.groups then
        lo, hi = p.groups.min[gtype + 1], p.groups.max[gtype + 1]
    end
    return lo or settings:value("ai.groupMin")[gtype] or 10, hi or settings:value("ai.groupMax")[gtype] or 10
end

local function groupMax(g, st)
    local hi
    if g.hero then hi = math.floor(MAX_SIZE / 2)
    elseif g.type == CONVERSION then hi = 3
    else
        local _, mx = sizeOf(st, g.type)
        hi = math.floor(mx * profile.get(st.level, "sizeFactor", 50) / 100)
    end
    return math.min(MAX_SIZE - 2, hi)
end

---@param st AISide
---@param g AIGroup
---@return boolean
function M.isFull(st, g)
    return #g.members >= groupMax(g, st)
end

-- Group bookkeeping ------------------------------------------------------------------------------------------------

-- New group (FUN_004f5570): the lowest free slot of 100, none when all are taken. `st.groups` stays in slot order,
-- which is the order the original processes them in.
local function newGroup(ai, st)
    if #st.groups >= GROUP_SLOTS then return nil end
    local used = {}
    for _, o in ipairs(st.groups) do used[o.slot] = true end
    local slot = 0
    while used[slot] do slot = slot + 1 end
    st.groupSeq = st.groupSeq + 1
    local g = { id = st.groupSeq, slot = slot, type = NONE, members = {}, objective = { type = OBJ_RECRUIT, stage = 0 },
                minSize = false, targetSide = nil, leader = nil, px = -1, py = -1, strength = 0, longRange = 0,
                conv = 0, speed = nil, attackType = 0 }
    local at = #st.groups + 1
    for i, o in ipairs(st.groups) do
        if o.slot > slot then at = i break end
    end
    table.insert(st.groups, at, g)
    return g
end

local function hasHero(g)
    for _, u in ipairs(g.members) do if u.hero then return true end end
    return false
end

---@param st AISide
---@param u Unit
function M.removeUnit(st, u)
    local g = st.groupOf[u]
    if not g then return end
    st.groupOf[u] = nil
    for i, m in ipairs(g.members) do
        if m == u then table.remove(g.members, i) break end
    end
    if #g.members == 0 then g.minSize = false end
    if u:alive() and u.state ~= "idle" then u:stop() end
end

local function updateStats(ai, st, g)
    local eco = ai.world.eco
    -- the dead and the garrisoned leave
    for i = #g.members, 1, -1 do
        local u = g.members[i]
        if not u:alive() or u.side ~= st.index then
            table.remove(g.members, i)
            st.groupOf[u] = nil
        end
    end
    if #g.members == 0 then g.minSize = false end
    -- leader: the hero, else the first converter, else the toughest unit
    g.leader = nil
    local bestT, conv = 0, false
    for _, u in ipairs(g.members) do
        if u.hero then g.leader = u break
        elseif eco:canConvert(u) then
            if not conv then g.leader, conv = u, true end
        elseif not conv then
            local t = aibase.toughness(u)
            if t > bestT then bestT, g.leader = t, u end
        end
    end
    g.hero = hasHero(g)
    local strength, conva, long, minSpeed = 0, 0, 0, 50
    for _, u in ipairs(g.members) do
        strength = strength + aibase.toughness(u)
        if eco:canConvert(u) then conva = conva + 1 end
        if range(u) > 12 then long = long + 1 end
        local sp = u:stats(true).speed
        if sp < minSpeed then minSpeed = sp end
    end
    g.strength, g.conv, g.longRange = strength, conva, long
    g.speed = minSpeed ~= 50 and minSpeed or nil
    if g.leader then g.px, g.py = g.leader.gx, g.leader.gy else g.px, g.py = -1, -1 end
end

local function addUnit(ai, st, g, u)
    if #g.members >= MAX_SIZE then return end
    g.members[#g.members + 1] = u
    st.groupOf[u] = g
    if #g.members == 1 then
        -- FUN_004f3470: ground and ground + air attackers make a ground group, air attackers an air group, an army without
        -- an attack leaves the type undefined (0)
        local at = u.type and u.type.attackType or 0
        if at == 1 or at == 3 then g.attackType = 1 elseif at == 2 then g.attackType = 2 end
    end
    updateStats(ai, st, g)
end

-- Side choice --------------------------------------------------------------------------------------------------------

local function setTargetSide(ai, st, g)
    local world = ai.world
    local factor = profile.get(st.level, "sideChange", 0)
    if dice(100) > factor then g.targetSide = st.enemy return end
    local best, bestRoll = nil, 0
    for j = 0, 5 do
        local sd = world.sides[j]
        if sd.used and not sd.defeated and world.humans[j] and not sd.ai and not allied(world, st.index, j) then
            local roll = dice(100)
            if roll > bestRoll then best, bestRoll = j, roll end
        end
    end
    g.targetSide = best or st.enemy
end

local function activate(ai, st, g)
    g.minSize = true
    setTargetSide(ai, st, g)
end

local function checkActivation(ai, st, g)
    if g.minSize then return end
    if g.hero then
        activate(ai, st, g)
    else
        local lo
        if g.type == CONVERSION then lo = 1
        else
            local mn = sizeOf(st, g.type)
            lo = math.floor(mn * profile.get(st.level, "sizeFactor", 50) / 100)
        end
        if #g.members >= lo then activate(ai, st, g) end
    end
    if not g.minSize then g.objective = { type = OBJ_RECRUIT, stage = 0 } end
end

-- Targets ------------------------------------------------------------------------------------------------------------

local function resourcePriority(st, resource, size)
    local p = math.floor((st.required[resource] or 0) / 2)
    return p * 2 ^ size + 10
end

local function targetPriority(ai, st, e, sideHasBuildings)
    local world = ai.world
    if e.kind == "building" then
        if e.hp <= 0 or e.pillaged then return 0 end
        local c1, c2, c3 = e.code:sub(2, 2), e.code:sub(3, 3), e.code:sub(4, 4)
        local p
        if c1 == "T" then p = 150
        elseif c1 == "L" then return 1
        elseif c1 == "R" then
            local size = tonumber(c3) or 0
            p = resourcePriority(st, e.mine and e.mine.resource or "gold", size)
        elseif e.code == "BMFL" then p = 250
        elseif c1 == "K" then local l = tonumber(c3) or 0 p = (l + 1) * 40
        elseif c1 == "W" then p = c2 == "T" and 40 or 10
        else p = 25 end
        p = p + math.max(0, 500 - 2 * cheb(e.gx, e.gy, st.baseX, st.baseY))
        if c1 == "R" then
            for j = 0, 5 do
                local sd = world.sides[j]
                if sd.used and not allied(world, j, st.index) then
                    local sx, sy = aibase.startOf(ai, j)
                    local d = cheb(sx, sy, e.gx, e.gy)
                    if d < 15 then p = p - 200 elseif d < 30 then p = p - 100 elseif d < 60 then p = p - 60
                    elseif d > 80 then p = p + 40 end
                end
            end
        end
        return p
    end
    if sideHasBuildings then return 0 end
    if not e:alive() then return 0 end
    -- the army's stored combat (the field the combat value FUN_0051bd10 starts from, +0x92): level gains, a hero's own
    -- value and morphs included, no power-ups, weather or status effects
    local p = 30 + math.floor(e:baseStats().combat / 2)
    p = p + math.floor(math.max(0, 256 - cheb(e.gx, e.gy, st.baseX, st.baseY)) / 8)
    return p
end

-- Target lists (attack FUN_004f6160 / conversion FUN_004f6340 of the binary, 200 entries at most):
-- targets of one side (key = side index) or the conversion list (key = "conv").
--  * attack list: everything the side owns, in the side list's order (openwbc3: buildings, then armies), but the flag; an
--    entry needs a priority over 0; a building that produces resources is a "conv" entry, a pillaged one is dropped. Armies
--    only get a priority when the side owns no building at all (a pillaged one counts, FUN_004f6160's own scan).
--  * conversion list: the temples, resource points and flags of every side not allied to the computer (neutral ones
--    too), pillaged ones left out, taken from the map's rows 0 .. width - 1 (the loop bound of the original is the map's
--    width, not its height, so on a map taller than wide the lower rows are never searched). The order within a row is
--    the display chain's, openwbc3 keeps the world's order.
local function refreshTargets(ai, st, key)
    local world = ai.world
    local list = {}
    local function add(entry)
        if #list >= MAX_TARGETS then return false end
        list[#list + 1] = entry
        return true
    end
    if key == "conv" then
        local cand = {}
        for i, b in ipairs(world.buildings) do
            local c = b.code:sub(2, 2)
            if b.hp > 0 and b.gy < world.w and not allied(world, b.side, st.index)
                and (c == "T" or c == "R" or b.code == "BMFL") and not b.pillaged then
                cand[#cand + 1] = { b = b, i = i }
            end
        end
        table.sort(cand, function(x, y)
            if x.b.gy ~= y.b.gy then return x.b.gy < y.b.gy end
            return x.i < y.i
        end)
        for _, c in ipairs(cand) do
            local b = c.b
            local p = targetPriority(ai, st, b, true)
            if p > 0 and not add({ e = b, pri = p, danger = aibase.danger(ai, st, b), kind = "conv", groups = 0 }) then
                break
            end
        end
    else
        if allied(world, st.index, key) then st.targets[key] = { list = {}, time = st.time } return end
        local hasBuildings = false
        for _, b in ipairs(world.buildings) do
            if b.side == key and b.hp > 0 then hasBuildings = true break end
        end
        local full = false
        for _, b in ipairs(world.buildings) do
            if full then break end
            if b.side == key and b.hp > 0 and b.code ~= "BMFL" and not b.pillaged then
                local p = targetPriority(ai, st, b, hasBuildings)
                if p > 0 then
                    full = not add({ e = b, pri = p, danger = aibase.danger(ai, st, b),
                                     kind = b.mine and "conv" or "attack", groups = 0 })
                end
            end
        end
        for _, u in ipairs(world.units) do
            if full then break end
            if u.side == key and u:alive() then
                local p = targetPriority(ai, st, u, hasBuildings)
                if p > 0 then
                    full = not add({ e = u, pri = p, danger = aibase.danger(ai, st, u), kind = "attack", groups = 0 })
                end
            end
        end
    end
    st.targets[key] = { list = list, time = st.time }
end

local function targetValid(ai, st, e)
    if e.kind == "building" then return e.hp > 0 and not e.pillaged end
    return e:alive()
end

-- C integer division: truncates towards zero
local function trunc(x)
    if x < 0 then return -math.floor(-x) end
    return math.floor(x)
end

-- Target choice (FUN_004f66f0): the target of the list of `key`, nil for none, or KEEP (the -2 of the original) when
-- the group's current target is still safe to reach and stays.
local KEEP = {}
local function bestTarget(ai, st, g, key)
    local world = ai.world
    local t = st.targets[key]
    if not t or st.time > t.time + 15000 then
        refreshTargets(ai, st, key)
        t = st.targets[key]
    end
    local convert = g.type == CONVERSION
    local params = st.params
    local boldness = params and params.flags.heroBoldness or 50
    -- the safe search (FUN_0050b0f0) from the leader's region (land, size 1); without a leader on a region there is no
    -- path danger
    local safe = false
    local leader = g.leader
    if leader and leader:alive() then
        local start = ai.region:regionAt(leader.gx, leader.gy, 1)
        if start then
            ai.region:safeSearch(start, leader.side)
            safe = true
        end
    end
    if safe and g.objective.type ~= OBJ_NONE and g.objective.type ~= OBJ_RECRUIT then
        local e = g.objective.target
        -- (the original reads the same field of an army target, a waiting counter that is -1 unless it waits: not modelled)
        if e and targetValid(ai, st, e) and e.kind == "building" then
            local pd = e.pathDanger or 0
            if pd ~= -1 then
                if g.hero then
                    if pd < math.floor(math.floor(g.strength / 2) * (25 + boldness) / 100) then return KEEP end
                elseif pd < math.floor(g.strength / 2) then
                    return KEEP
                end
            end
        end
    end
    if convert and key == "conv" then
        for _, entry in ipairs(t.list) do
            entry.groups = 0
            for _, o in ipairs(st.groups) do
                if o.slot < COUNTED_SLOTS and o.objective.target == entry.e then entry.groups = entry.groups + 1 end
            end
        end
    end
    local best, bestP
    for k, entry in ipairs(t.list) do
        local e = entry.e
        if targetValid(ai, st, e) and not allied(world, e.side, st.index)
            and not (safe and e.kind == "building" and e.pathDanger == -1) then      -- -1: the search did not get there
            local dangerForMe = entry.danger - g.strength
            local p = 700 + entry.pri
            if safe and e.kind == "building" then
                local pathDanger = math.floor((e.pathDanger or 0) / 2)
                if g.hero then
                    local modify = math.max(0, pathDanger - g.strength) + dangerForMe * 2
                    p = p - trunc(modify * (100 - boldness) / 50)
                else
                    p = p - math.floor(math.max(0, pathDanger - g.strength) / 2)
                end
            end
            local skip = false
            if entry.kind == "conv" then
                if convert then
                    if entry.danger == 0 then p = p + 100 else p = p - 200 end
                    if entry.groups > 0 and g.objective.target ~= e then p = p - 400 * entry.groups end
                else
                    if g.type == MINEKILLER then
                        if e.side == 6 then skip = true else p = p + 100 end
                    else
                        skip = true
                    end
                end
            else
                if convert then
                    p = p - 200
                elseif g.type ~= MINEKILLER then
                    local c1, c2 = e.code:sub(2, 2), e.code:sub(3, 3)
                    if c1 == "W" and c2 == "T" then
                        p = p + (g.type == LONGRANGE and 200 or 100)
                    else
                        p = p + 50
                    end
                else
                    p = p - 100
                end
            end
            if not skip then
                p = p - cheb(e.gx, e.gy, g.px, g.py)
                local same = g.objective.type ~= OBJ_NONE and g.objective.target == e
                if same then p = p + 500 else p = p + dice(100) + dice(100) end
                if not bestP or p > bestP then best, bestP = e, p end
            end
        end
    end
    return best
end

local function reassess(ai, st, only)
    local world = ai.world
    for _, g in ipairs(st.groups) do
        if g.minSize and (g == only or g.hero or g.objective.type == OBJ_NONE) then
            local side = g.targetSide
            if side and world.sides[side].defeated then
                setTargetSide(ai, st, g)
                side = g.targetSide
            end
            local key = g.type == CONVERSION and "conv" or side
            if key ~= nil then
                local target = bestTarget(ai, st, g, key)
                if target == KEEP then
                    -- the current mission stays
                elseif target then
                    if not (g.objective.type ~= OBJ_NONE and g.objective.target == target) then
                        g.objective = { type = OBJ_ATTACK, stage = 0, target = target }
                    end
                else
                    g.objective = { type = OBJ_NONE, stage = 0 }
                end
            end
        end
    end
end

-- Group behaviour -------------------------------------------------------------------------------------------------------

local function separation(g)
    local mx, large = 0, 0
    for _, u in ipairs(g.members) do
        local h = u.type and u.type.shape and u.type.shape.h or 1
        if h > 1 then
            large = large + 1
        else
            local d = cheb(u.gx, u.gy, g.px, g.py)
            if d > mx and d < 25 then mx = d end
        end
    end
    if large < 4 then return mx end
    return 0
end

local function processObjective(ai, st, g)
    local o = g.objective
    if o.type == OBJ_NONE or o.type == OBJ_RECRUIT then return end
    local world = ai.world
    local e = o.target
    if not e or not targetValid(ai, st, e) or allied(world, e.side, st.index) then
        g.objective = { type = OBJ_NONE, stage = 0 }
        return
    end
    local dist = cheb(g.px, g.py, e.gx, e.gy)
    if o.stage == STAGE_INIT then
        if dist < 20 then o.stage = STAGE_MAIN g.convPoint = nil else o.stage = STAGE_MOVE end
    end
    if o.stage ~= STAGE_REGROUP and g.type ~= CONVERSION then
        if dist < 40 and separation(g) > 20 then
            o.stage = STAGE_REGROUP
            return
        end
    end
    if o.stage == STAGE_MOVE then
        if dist < 20 then o.stage = STAGE_MAIN g.convPoint = nil end
    elseif o.stage == STAGE_REGROUP then
        if separation(g) < 10 then
            o.stage = dist < 20 and STAGE_MAIN or STAGE_MOVE
        end
    end
end

local function moveTo(u, x, y, pace)
    if u.goalX == x and u.goalY == y and not u.target and not u.task then return end
    u:orderMove(x, y)
    u.pace = pace
end

local function moveToLeader(g, u)
    if cheb(u.gx, u.gy, g.px, g.py) >= 5 then
        if u.goalX and not u.target and not u.task and cheb(u.goalX, u.goalY, g.px, g.py) < 5 then return end
        u:orderMove(g.px, g.py)
        u.pace = g.speed
    end
end

local function isLeader(g, u) return g.leader == u end

local function attackTarget(u, e)
    if u.target ~= e then u:orderAttack(e) end
end

local function unitRecruit(g, u)
    if isLeader(g, u) then
        if u.state ~= "idle" then u:stop() end
    else
        moveToLeader(g, u)
    end
end

local function unitMoving(ai, st, g, u)
    local e = g.objective.target
    if not isLeader(g, u) and cheb(u.gx, u.gy, g.px, g.py) > 10 then
        moveToLeader(g, u)
        return
    end
    if not (u.goalX == e.gx and u.goalY == e.gy and not u.target) then
        u:orderMove(e.gx, e.gy)
        u.pace = g.speed
    end
end

-- Conversion (FUN_004f4940): the leader walks to the best conversion square of the target (worked out once per main action
-- stage) and converts when it stands within 3 cells of it. Not original: when no such square exists (the original then
-- moves to (-1, -1)) the leader walks to the building and converts there.
local function unitConvert(ai, st, g, u)
    local e = g.objective.target
    local eco = ai.world.eco
    if not eco:canConvert(u) then return end
    if e.kind ~= "building" or e.hp <= 0 or not economy.convertible(e.code) then return end
    if not g.convPoint then
        g.convPoint = aibase.bestConversionSquare(ai, st, e, u:convertRange(), u)
    end
    local p = g.convPoint
    if not p then
        if u.converting or (u.task and u.task.kind == "convert") then return end
        u:orderConvert(e)
        st.converting[e] = st.time + economy.CONVERT_TIME + 30000
        return
    end
    if math.abs(u.gx - p[1]) < 3 and math.abs(u.gy - p[2]) < 3 then
        if u.converting or (u.task and u.task.kind == "convert") then return end
        u:convertHere()
        st.converting[e] = st.time + economy.CONVERT_TIME + 30000
    elseif not (u.goalX == p[1] and u.goalY == p[2] and not u.target) then
        u:orderMove(p[1], p[2])
        u.pace = g.speed
    end
end

local function unitAttacking(ai, st, g, u)
    local e = g.objective.target
    local conversion = false
    if g.type == CONVERSION and e.kind == "building" then
        local c = e.code:sub(2, 2)
        if e.mine or c == "T" then conversion = true end
    end
    if isLeader(g, u) then
        if conversion then unitConvert(ai, st, g, u) else attackTarget(u, e) end
    else
        if conversion then moveToLeader(g, u) else attackTarget(u, e) end
    end
end

local function unitRegrouping(g, u)
    if isLeader(g, u) then
        if u.state ~= "idle" and not u.target then u:stop() end
    else
        -- only a member that has an order which is not an attack goes back to the leader (FUN_004f4a90): one with no
        -- order stays where it is
        if u.state ~= "idle" and not u.target then moveToLeader(g, u) end
    end
end

-- Threat test (FUN_004f3e70): what a member sees around it. Returns level (0 none, 1 building / unarmed, 2 armed building,
-- 3 army attacking us) and the entity.
local function threat(ai, st, g, u, current)
    local world, eco = ai.world, ai.world.eco
    local me = st.index
    local ux, uy = u.gx, u.gy
    local bestE, bestP, maxLevel = nil, 0, 0
    local function consider(e, level, p)
        if level > maxLevel then maxLevel = level end
        if not bestE or p > bestP then bestE, bestP = e, p end
    end
    for _, e in ipairs(world.units) do
        if e.side ~= 6 and e.side ~= me and e:alive() and not allied(world, e.side, me)
            and math.abs(e.gx - ux) <= 14 and math.abs(e.gy - uy) <= 14 then
            -- ground = land or hover; air and SEA count as "air" (FUN_004f3e70); an attack-less army passes both tests
            local ground = e.move == 0 or e.move == 3
            local at = u.type and u.type.attackType or 0
            if not ((at == 1 and not ground) or (at == 2 and ground)) then
                local p = 1000 - 2 * cheb(ux, uy, e.gx, e.gy)
                if e == current then p = p + 1 end
                local tg = e.target
                if tg and tg.side and allied(world, tg.side, me) then
                    consider(e, 3, p + 2000)
                elseif not g.hero then
                    consider(e, 1, p)
                end
            end
        end
    end
    for _, b in ipairs(world.buildings) do
        if b.side ~= me and b.hp > 0 and not allied(world, b.side, me) and math.abs(b.gx - ux) <= 14
            and math.abs(b.gy - uy) <= 14 then
            local info = rules.building(b.code)
            local suitable = not b.mine and not (info and (info.searchable or info.shop))
                and not (info and info.lair and g.type ~= KICKBUTT) and b.code ~= "BMFL"
                and b.code:sub(2, 2) ~= "T" and b.code:sub(2, 2) ~= "R"
            if suitable then
                local p = 1000 - 2 * cheb(ux, uy, b.gx, b.gy)
                if b == current then p = p + 1 end
                -- armed: the real damage, a garrison's included (the building's damage getter 0x0052e9e0 asked for the
                -- real value), finished or not
                local gDmg = eco:garrisonBonus(b)
                if (b.type and b.type.damage or 0) + gDmg > 0 then
                    consider(b, 2, p + 1000)
                else
                    consider(b, 1, p)
                end
            end
        end
    end
    return maxLevel, bestE
end

local function doUnitActions(ai, st, g)
    local high = 0
    local threats = {}
    for _, u in ipairs(g.members) do
        local level, e = threat(ai, st, g, u, g.threatOf and g.threatOf[u])
        threats[u] = { level = level, e = e }
        if level > high then high = level end
    end
    g.threatOf = {}
    for u, t in pairs(threats) do g.threatOf[u] = t.e end
    if high == 0 then
        local o = g.objective
        for _, u in ipairs(g.members) do
            if o.type == OBJ_RECRUIT or o.type == OBJ_NONE then
                unitRecruit(g, u)
            elseif o.stage == STAGE_INIT then
                unitRecruit(g, u)
            elseif o.stage == STAGE_MOVE then
                unitMoving(ai, st, g, u)
            elseif o.stage == STAGE_MAIN then
                unitAttacking(ai, st, g, u)
            elseif o.stage == STAGE_REGROUP then
                unitRegrouping(g, u)
            end
        end
    elseif high == 3 then
        -- every member helps the member nearest to it that is under attack
        for _, u in ipairs(g.members) do
            local bestM, bestD
            for _, m in ipairs(g.members) do
                if threats[m].level == 3 then
                    local d = cheb(u.gx, u.gy, m.gx, m.gy)
                    if not bestD or d < bestD then bestM, bestD = m, d end
                end
            end
            if bestM and threats[bestM].e then attackTarget(u, threats[bestM].e) end
        end
    else
        -- buildings and towers: all members go for the target the first member chose (or the leader of the choice)
        local chosen
        for _, u in ipairs(g.members) do
            if threats[u].level == high then
                if not chosen then chosen = threats[u].e
                elseif g.missionTarget and g.missionTarget == threats[u].e then chosen = threats[u].e end
            end
        end
        if chosen then
            g.missionTarget = chosen
            for _, u in ipairs(g.members) do attackTarget(u, chosen) end
        end
    end
end

local function processGroup(ai, st, g)
    updateStats(ai, st, g)
    if #g.members == 0 then return false end
    local eco = ai.world.eco
    local cur, max = eco:armyLimit(st.index)
    if cur > max - 4 and not g.minSize then activate(ai, st, g) end
    processObjective(ai, st, g)
    doUnitActions(ai, st, g)
    return true
end

-- Towers --------------------------------------------------------------------------------------------------------------

local function towerVacancies(ai, st)
    local eco = ai.world.eco
    local list, free, total = {}, 0, 0
    for _, b in ipairs(ai.world.buildings) do
        if b.side == st.index then
            local cap = eco:garrisonCap(b)
            if cap > 0 then
                local n = eco:garrisoned(b)
                if n < cap then list[#list + 1] = { b = b, free = cap - n } end
                free = free + cap - n
                total = total + cap
                if #list == 39 then break end             -- the original's list holds 39 towers (FUN_004f71e0)
            end
        end
    end
    return list, free, total
end

local function sendIntoTower(ai, st, u, towers)
    local best, bestD
    for _, t in ipairs(towers) do
        if t.free > 0 then
            local d = cheb(st.baseX, st.baseY, t.b.gx, t.b.gy) + dice(200)
            if not bestD or d < bestD then best, bestD = t, d end
        end
    end
    if not best then return false end
    -- (the tower's free places are not counted down here, as in the original: FUN_004f72e0 only tests them)
    u:orderGarrison(best.b)
    return true
end

-- Group types -------------------------------------------------------------------------------------------------------------

local function updateGroupTypes(ai, st)
    local counts = { [0] = 0, 0, 0, 0, 0, 0, 0, 0, 0 }
    for _, g in ipairs(st.groups) do
        if g.type == LONGRANGE and g.longRange == 0 then g.type = NONE
        elseif g.type == CONVERSION and g.conv == 0 then g.type = NONE end
        if g.type ~= NONE then counts[g.type] = counts[g.type] + 1 end
    end
    local level = st.level
    local factor = ({ 0, 0, 1, 2, 3, 4 })[level] or 0
    if counts[CONVERSION] < 3 then
        for _, g in ipairs(st.groups) do
            if counts[CONVERSION] >= 3 then break end
            if g.type ~= CONVERSION and g.conv > 0 and #g.members <= 3 then
                if g.type ~= NONE then counts[g.type] = counts[g.type] - 1 end
                g.type = CONVERSION
                counts[CONVERSION] = counts[CONVERSION] + 1
            end
        end
    end
    if counts[LONGRANGE] < 2 then
        for _, g in ipairs(st.groups) do
            if counts[LONGRANGE] >= 2 then break end
            if g.type == NONE and g.longRange > 0 then
                g.type = LONGRANGE
                counts[LONGRANGE] = counts[LONGRANGE] + 1
            end
        end
    end
    if counts[NORMAL] >= 1 and counts[GENERALS] < 1 then
        for _, g in ipairs(st.groups) do
            if g.type == NONE and #g.members == 1 and isGeneral(g.members[1]) then
                g.type = GENERALS
                counts[GENERALS] = 1
                break
            end
        end
    end
    if factor > 0 then
        for _, g in ipairs(st.groups) do
            if g.type == NONE and #g.members == 1 and g.members[1].hp >= 100 and dice(10) <= factor then
                g.type = KICKBUTT
                counts[KICKBUTT] = counts[KICKBUTT] + 1
                break
            end
        end
    end
    for _, g in ipairs(st.groups) do
        if g.type == NONE and #g.members == 1 then
            local u = g.members[1]
            local weak
            if range(u) < 4 then weak = u.hp < 70 else weak = (u:stats().damage or 0) < 20 end
            if weak then
                g.type = WEAK
                counts[WEAK] = counts[WEAK] + 1
            end
        end
    end
    for _, g in ipairs(st.groups) do
        if g.type == NONE then
            if dice(10) <= factor then
                g.type = LARGE
                counts[LARGE] = counts[LARGE] + 1
            end
            break
        end
    end
    local mk = ({ 0, 1, 2, 3, 4, 5 })[level] or 0
    for _, g in ipairs(st.groups) do
        if g.type == NONE and #g.members >= 3 then
            if dice(10) <= mk and counts[MINEKILLER] <= 2 then
                g.type = MINEKILLER
                counts[MINEKILLER] = counts[MINEKILLER] + 1
            else
                g.type = NORMAL
                counts[NORMAL] = counts[NORMAL] + 1
            end
            break
        end
    end
end

-- Group choice (FUN_004f59e0)
local function attackCompatible(group, unit)
    if unit == 1 then return group == 1
    elseif unit == 2 then return group == 2
    elseif unit == 3 then return group == 1 end
    return true
end

local function findGroup(ai, st, u)
    local eco = ai.world.eco
    local counts = { [0] = 0, 0, 0, 0, 0, 0, 0, 0, 0 }
    for _, g in ipairs(st.groups) do
        if g.type ~= NONE then counts[g.type] = counts[g.type] + 1 end
    end
    if u.hero then return newGroup(ai, st) end         -- nil when all 100 slots are taken: the army stays ungrouped
    local convert = eco:canConvert(u)
    if convert and counts[CONVERSION] < 3 then return newGroup(ai, st) end
    local st2 = u:stats()
    local fLong = (st2.range or 0) >= 16
    local speed = st2.speed or 0
    local at = u.type and u.type.attackType or 0
    local best, bestP
    for _, g in ipairs(st.groups) do
        local p = 500
        local skip = false
        if M.isFull(st, g) then
            if not g.minSize then activate(ai, st, g) end
            skip = true
        end
        if not skip then
            local t = g.type
            if t == CONVERSION then
                if speed < 3 then skip = true elseif speed < 8 then p = p - 50 end
            elseif t == LONGRANGE then
                if fLong and g.longRange >= 2 then skip = true end
            elseif t == GENERALS then
                if not isGeneral(u) then skip = true end
            elseif t == KICKBUTT then
                if u.hp < 100 then skip = true end
            elseif t == MINEKILLER or t == NORMAL then
                if fLong then skip = true end
            end
        end
        if not skip then
            if g.type == WEAK then
                if (st2.range or 0) < 4 then
                    if u.hp >= 70 then skip = true end
                elseif (st2.damage or 0) >= 20 then skip = true end
            elseif g.type ~= CONVERSION then
                if (st2.range or 0) < 4 then
                    if u.hp < 70 then skip = true end
                elseif (st2.damage or 0) < 20 then skip = true end
            end
        end
        if not skip then
            if g.longRange > 0 then
                if convert then skip = true end
            elseif g.conv > 0 then
                if speed < 4 then skip = true end
            end
        end
        if not skip then
            if u.hp >= 100 and g.type ~= KICKBUTT and g.type ~= GENERALS then p = p - 50 end
            if g.objective.type == OBJ_RECRUIT then p = p + 50 end
            if not attackCompatible(g.attackType, at) then skip = true end
        end
        if not skip then
            local d = cheb(u.gx, u.gy, g.px, g.py)
            if (g.minSize and d > 20) or d > 100 then
                if not g.hero then skip = true end
            end
        end
        if not skip and g.hero then
            if #g.members > 4 and dice(8) < 8 then skip = true else p = p + 200 end
        end
        if not skip and (not bestP or p > bestP) then best, bestP = g, p end
    end
    return best or newGroup(ai, st)
end

-- Idle armies (FUN_004f5700)
local function processIdle(ai, st, units)
    local eco = ai.world.eco
    local params = st.params
    local armiesInTowers = params and params.flags.armiesInTowers or 20
    local toughInTowers = params and params.flags.toughUnitsInTowers or false
    local towers, free, totalPlaces = towerVacancies(ai, st)
    -- the armies that are off the map count as "in towers" (`FUN_004f5700` tests the off-map flag): the garrisoned ones and
    -- the builders that are putting up a building (the construction message, `FUN_004f6f80`, takes the builder off the map
    -- and keeps it in the building until it is finished). A mine worker is deleted when it goes in (`FUN_0051a130` marks
    -- it dead, the original counts it only until the list is cleaned up), so it is not counted here.
    local inTowers, goingIn, totalGuys = 0, 0, 0
    for _, u in ipairs(ai.world.units) do
        if u.side == st.index and u.hidden and not u.remove then inTowers = inTowers + 1 end
    end
    totalGuys = inTowers
    for _, u in ipairs(units) do
        if u.task and u.task.kind == "garrison" then
            goingIn = goingIn + 1
            totalGuys = totalGuys + 1
        elseif not canBuild(u) and u.move == 0 then
            totalGuys = totalGuys + 1
        end
    end
    local quota = math.floor(armiesInTowers * totalGuys / 100)
    local need = math.min(math.max(0, quota - (inTowers + goingIn)), free)
    for _, u in ipairs(units) do
        local skip = false
        if st.builders[u] or (u.task and u.task.kind ~= "garrison" and u.task.kind) then skip = true end
        if u.hero and st.heroRunning then skip = true end
        if canBuild(u) and u.maxHp < 50 then skip = true end      -- the most hits it can have (0x0051c3f0)
        if u.code == "ASFP" then skip = true end                 -- ferries do not join groups
        if not skip then
            local g = st.groupOf[u]
            if g then
                -- the group may have been disbanded
                local present = false
                for _, o in ipairs(st.groups) do if o == g then present = true end end
                if not present then st.groupOf[u] = nil end
            else
                local sent = false
                if need > 0 and u:canGarrison() and not u.hero then
                    local ok = true
                    if not toughInTowers and (u.type and u.type.setupPoints or 0) > 2 then ok = false end
                    if ok and not (u.task and u.task.kind == "garrison") then
                        if sendIntoTower(ai, st, u, towers) then
                            need = need - 1
                            sent = true
                        end
                    end
                end
                if not sent and not (u.task and u.task.kind == "garrison") then
                    local g2 = findGroup(ai, st, u)
                    if g2 then
                        addUnit(ai, st, g2, u)
                        updateGroupTypes(ai, st)
                        checkActivation(ai, st, g2)
                    end
                end
            end
        end
    end
end

-- Group walk (FUN_004f5610)
---@param ai AI
---@param st AISide
---@param units Unit[] the side's free armies
function M.process(ai, st, units)
    -- the slots in order, a group that is done leaves at once (FUN_004f5610)
    local i = 1
    while i <= #st.groups do
        if processGroup(ai, st, st.groups[i]) then i = i + 1 else table.remove(st.groups, i) end
    end
    -- one group per think is reassessed: the next used slot from the pointer on, then the pointer moves past it
    local bySlot = {}
    for _, g in ipairs(st.groups) do bySlot[g.slot] = g end
    local p, steps = st.gtimer % GROUP_SLOTS, 0
    if not bySlot[p] then
        repeat
            p = (p + 1) % GROUP_SLOTS
            steps = steps + 1
        until bySlot[p] or steps == GROUP_SLOTS
        st.gtimer = p
    end
    if bySlot[p] then
        reassess(ai, st, bySlot[p])
        st.gtimer = (p + 1) % GROUP_SLOTS
    end
    processIdle(ai, st, units)
    updateGroupTypes(ai, st)
    for _, g in ipairs(st.groups) do checkActivation(ai, st, g) end
end

-- Debugging -------------------------------------------------------------------------------------------------------------

---@param st AISide
---@return string
function M.describe(st)
    local out = {}
    for _, g in ipairs(st.groups) do
        local o = g.objective
        local target = o.target and (o.target.code .. "@" .. o.target.gx .. "," .. o.target.gy) or "-"
        out[#out + 1] = ("  group %d %s n=%d str=%d %s at %d,%d obj=%s stage=%d -> %s side %s"):format(
            g.id, M.TYPE_NAMES[g.type], #g.members, g.strength, g.minSize and "active" or "recruiting", g.px, g.py,
            o.type == OBJ_ATTACK and "attack" or o.type == OBJ_RECRUIT and "recruit" or "none", o.stage or 0, target,
            tostring(g.targetSide))
    end
    return table.concat(out, "\n")
end

return M
