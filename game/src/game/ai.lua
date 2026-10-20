-- Computer player, after the original's computer player (the routines named below were decompiled from the 1.04
-- binary).
--
-- The code is split by what it does:
--   aidata.lua    static per-race data from Building.cfg: buildings, armies, power-ups, builders, what needs what,
--                 the army and power-up build order (FUN_004fc7e0, FUN_004ff5f0 / FUN_004ff790)
--   aiplan.lua    the production model: resource list, "time between builds", build order, required building counts,
--                 mines and income, missions of builders / buildings (FUN_004ff470 ...)
--   aigroups.lua  army groups: grouping, types, targets, threat assessment, tower garrisons
--   aibase.lua    danger, enemy choice, towers, base relocation, hero retreat, defence, Rampant attacks
--   aiparams.lua  the `CustomAI/*.ai` scripts
-- This file is the think loop (binary FUN_004fa120), repairs, resignation and the state that goes into saved games
-- (FUN_004fb990 / FUN_004fb730).
--
-- Think order (FUN_004fa120): enemy choice (FUN_004fa5b0), hero retreat (FUN_004fc150), Rampant: best target
-- (FUN_004fa990); defence (FUN_004fa380), the unit list (FUN_004f9f80), missions in progress (FUN_004f84a0(0)), analysis
-- of buildings / armies / power-ups, then unless Rampant: keeps, mine income (FUN_004fc280), tower spot (FUN_004f8fa0),
-- required building counts, the resource list, the groups; every 15 s the times between builds are recalculated and the
-- palace (keep) conversions are looked at (FUN_004fbb90, also the "an army converter exists" flag); then new missions
-- (FUN_004f84a0(1)), special abilities (FUN_005001d0), repairs (FUN_004fffe0) and for Rampant the attack (FUN_004fa850),
-- for the others the resignation test. The neutral side (6) has a computer player too and plays the Rampant path
-- (FUN_004fa120 tests `level == 7 || side == 6`): its lairs' creatures and every other free neutral army go after a
-- random side's best target. openwbc3 runs the think every 2 s per side (the original gives one AI side a time slice
-- per call of its per-tick driver FUN_00505310).
--
-- The level a side plays at (world.sides[i].aiLevel) is the original's AI level 0..7 (Passive, Knave, Knight, Lord,
-- Prince, Warlord, Emperor, Barbarian; the UI calls the last two Squire / Rampant, XCIStrings [0214.*]).
-- A Passive (0) side is a computer side all the same (the computer flag, an AI object) whose turn only runs the side's
-- attitude pass FUN_00532530 (its armies' attitudes, its towers' targets: attitude.lua gives it its round-robin slice
-- and no fog) and returns (FUN_004fa120): no economy, no groups, no special abilities or computer spells (FUN_005001d0),
-- no resignation. Rampant (7) has no economy at all: only
-- repairs, defence and attacks (the Rampant path of FUN_004fa120). Levels 1..6 differ in the production rates and
-- income caps (aiplan.lua), the group sizes, the towers and the repair dice (FUN_004fffe0). A side
-- may carry a `CustomAI/*.ai` script (aiparams.lua) whose priorities replace the defaults (50) and whose main values,
-- group sizes, tower weights, hero boldness / retreat, base relocation and tower garrison share are used.
--
-- Not original (openwbc3's own choices, where the original gives nothing to follow or cannot be reproduced):
--  * the AI pays real resources like the original (production and construction fail when it cannot pay), but power-ups
--    that stay on offer after being bought (research, mercenaries, Knight's Quest) are never bought; the old
--    model of a free power-up every few minutes is gone: the think step of the 1.04 binary has no such call,
--    power-ups come from the resource list like everything else;
--  * no forced keep upgrade after a long wait: the 1.04 binary has no such routine;
--  * the build spot is the nearest legal one (see aiplan.lua);
--  * damage taken per attacker is taken from the "attacked" world event (units; buildings do not raise it).
local economy = require("src.game.economy")
local rules = require("src.game.rules")
local gamedata = require("src.game.gamedata")
local aiparams = require("src.game.aiparams")
local aidata = require("src.game.aidata")
local plan = require("src.game.aiplan")
local aibase = require("src.game.aibase")
local aigroups = require("src.game.aigroups")
local airegion = require("src.game.airegion")

local M = {}
M.THINK_MS = 2000

-- The computer player of one side. Rampant and Passive sides (and the neutral one) have no production model: the fields from
-- `D` to `converterExists` are only set by aiplan.setup (they are nil on such a side).
---@class AISide
---@field index integer             the side
---@field next number               next think (world time)
---@field level integer             the AI level 0..7
---@field params AIParams?          the side's CustomAI script
---@field damageTaken table<integer, integer> side -> the damage it did to us (decays)
---@field potential {gx: integer, gy: integer, until_: number}[] tower spots being built on
---@field groups AIGroup[]          the army groups, in slot order (aigroups.lua)
---@field groupOf table<Unit, AIGroup>
---@field groupSeq integer          the last group id
---@field gtimer integer            the slot the next reassessment starts from
---@field targets table<integer|string, {list: AITarget[], time: number}> target lists: side index or "conv"
---@field builders table<Unit, AIBuildMission> builders on their way to put up a building
---@field builderList AIBuildMission[]
---@field converting table<Building, number> building -> until when a conversion of it is under way
---@field failedSpots {gx: integer, gy: integer, until_: number}[] build spots a builder could not reach
---@field list AINode[]             the resource list (aiplan.lua)
---@field mines AIMine[]
---@field keeps Building[]
---@field required table<string, integer> resource -> need in percent
---@field res table<string, integer> resource .. "Mines" / "Extras" / "Capacity" / "Conversions" -> value
---@field time number               world time of the current think
---@field D AIRaceData              the race's static data
---@field builderCode string?       the race's builder army
---@field keepCode0 string?         the race's level 0 keep
---@field bld table<string, AIBuildingRec>
---@field army table<string, AIArmyRec>
---@field pow table<string, AIPowerupRec>
---@field armyOrder string[]        the build script order of the armies
---@field powOrder string[]         ... and of the power-ups
---@field armyTarget string?        the army the army research works towards
---@field nextCalc number?          next "time between builds" calculation
---@field converterExists boolean?  an army that can convert exists (FUN_004fbb90)
---@field listChanged boolean?
---@field canProduce table<string, boolean>? what the side's buildings can produce now
---@field ancientWisp boolean?      wisps can be merged into an ancient wisp
---@field builtThisCycle boolean?
---@field baseX integer?            the main base cell
---@field baseY integer?
---@field relocated integer?        how often the base moved
---@field lastBaseSearch number?
---@field enemy integer?            the main enemy
---@field heroRunning boolean?      the hero retreats
---@field bestTower {gx: integer, gy: integer}? where the next tower goes
---@field bestTarget table<integer, Unit|Building>? Rampant: 1 the ground, 2 the air target
---@field nextRepair number?
---@field unusedRepairs integer?    repair checks without a repair

-- The computer players of a battle (world.ai).
---@class AI
---@field world World
---@field sides table<integer, AISide> side index -> its computer player (6: the neutral side)
---@field groups table              the aigroups module (aigroups.lua)
---@field debug boolean             WBC3_AIDEBUG is set: log the wish lists
---@field region AIRegion           the region and danger maps (airegion.lua)
---@field hate table<integer, table<integer, integer>> the hate matrix, side -> side -> hate
local AI = {}
AI.__index = AI

---@param self AI
---@param i integer
---@return AISide
local function newSide(self, i)
    local world = self.world
    local s = world.sides[i]
    local st = { index = i, next = 2000 + i * 400, level = i == 6 and 7 or s.aiLevel or 2,
                 params = s.aiFile and aiparams.load(s.aiFile) or nil,
                 damageTaken = {}, potential = {}, groups = {}, groupSeq = 0, gtimer = 0, targets = {} }
    if st.level ~= 7 and st.level ~= 0 then plan.setup(self, st) else
        st.builders, st.converting, st.groupOf, st.failedSpots, st.builderList = {}, {}, {}, {}, {}
        st.list, st.mines, st.keeps, st.required, st.res = {}, {}, {}, {}, {}
        st.time = world.time
    end
    return st
end

-- The hate matrix (binary FUN_00417f80): every pair of sides gets a symmetric "hate" of 1..100 (1..40 in a campaign)
-- that the enemy choice FUN_004fa5b0 adds to its score; in a single-player game one random computer side is made to
-- hate the local player (200) and every other pairing of that side is cut to a quarter (not in network and campaign
-- games). Rolled once when the game starts, saved with the game.
local function initHateIndex(self)
    local world = self.world
    local hate = {}
    for i = 0, 6 do hate[i] = {} end
    local range = world.opts.campaign and 40 or 100
    for i = 0, 6 do
        for j = 0, 6 do
            local roll = math.random(1, range)
            hate[i][j], hate[j][i] = roll, roll
        end
    end
    if not world.opts.campaign and not world.opts.net then
        local ai = {}
        for i = 0, 5 do
            if world.sides[i].used and world.sides[i].ai then ai[#ai + 1] = i end
        end
        if #ai > 0 then
            local pick = ai[math.random(1, #ai)]
            local me = world.player
            if me and me >= 0 and me <= 6 then      -- (headless runs have no local side)
                hate[pick][me], hate[me][pick] = 200, 200
            end
            for i = 0, 6 do
                if i ~= me then
                    hate[pick][i] = math.floor(hate[pick][i] / 4)
                    hate[i][pick] = math.floor(hate[i][pick] / 4)
                end
            end
        end
    end
    self.hate = hate
end

---@param world World
---@return AI
function M.new(world)
    ---@class AI
    local self = setmetatable({ world = world, sides = {}, groups = aigroups, debug = os.getenv("WBC3_AIDEBUG") ~= nil,
                                region = airegion.new(world) }, AI)
    initHateIndex(self)
    for i = 0, 6 do
        local s = world.sides[i]
        -- the neutral side always has a computer player too: the original creates one for it, and the think step
        -- FUN_004fa120 treats it as a Rampant ("barbarian") side (`side == 6`)
        if (s.used and s.ai) or i == 6 then self.sides[i] = newSide(self, i) end
    end
    -- FUN_004fa580: how much each side hurt us steers the choice of the main enemy
    world:listen(function(kind, victim, attacker, dmg)
        if kind == "attacked" and victim and attacker and attacker.side and victim.side then
            local st = self.sides[victim.side]
            if st and (st.damageTaken[attacker.side] or 0) < 10000 then
                st.damageTaken[attacker.side] = (st.damageTaken[attacker.side] or 0) + math.floor(dmg or 0)
            end
        end
    end)
    return self
end

local function dist2(a, b) return (a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 end

-- The unit list (FUN_004f9f80): the side's units that are on the map and its buildings
---@param side integer
---@return Unit[] units
---@return Building[] buildings
function AI:collect(side)
    local units, blds = {}, {}
    for _, u in ipairs(self.world.units) do
        if u.side == side and u:alive() then units[#units + 1] = u end
    end
    for _, b in ipairs(self.world.buildings) do
        if b.side == side and b.hp > 0 then blds[#blds + 1] = b end
    end
    return units, blds
end

-- Finds a legal spot for `code` near (gx, gy), spiralling outwards.
---@param code string
---@param gx integer
---@param gy integer
---@param side integer
---@param avoid {gx: integer, gy: integer}[]?
---@return integer? gx
---@return integer? gy
function AI:findSpot(code, gx, gy, side, avoid)
    local eco = self.world.eco
    -- the original looks for the legal spot nearest to the target within a 50 x 50 cell area (FUN_004f9480)
    for r = 2, 26, 2 do
        for k = 0, (r > 12 and 23 or 15) do
            local a = k / (r > 12 and 24 or 16) * math.pi * 2 + r
            local x = math.floor(gx + math.cos(a) * r + 0.5)
            local y = math.floor(gy + math.sin(a) * r * 0.8 + 0.5)
            local skip = false
            for _, f in ipairs(avoid or {}) do
                if math.abs(f.gx - x) <= 2 and math.abs(f.gy - y) <= 2 then skip = true break end
            end
            if not skip and eco:canPlace(code, x, y, side) then
                -- leave a gap around buildings so paths stay open
                local t = gamedata.building(code)
                ---@cast t -nil
                local clear = true
                for _, c in ipairs(r > 18 and {} or self.world:shapeCells(x, y, { w = t.shape.w + 2, h = t.shape.h + 2 })) do
                    local cx, cy = c[1], c[2] - 1
                    if self.world.terrain:inside(cx, cy) and self.world.static[self.world:index(cx, cy)] ~= 0 then
                        clear = false
                        break
                    end
                end
                if clear then return x, y end
            end
        end
    end
    return nil
end

-- Repairs like the original's FUN_004fffe0: every 20 s, free and fast (45 s). Orcs never repair, knights (level 2) only on 1 in 10 checks,
-- lords (3) on 1 in 4. Normally one building at 62.5% hits or less is repaired; after more than 10 checks without a
-- repair everything at 81.25% or less is.
local REPAIR_CHECK, REPAIR_ALL_AFTER = 20000, 10

---@param st AISide
---@param t number
---@param side Side
---@param blds Building[]
function AI:repairs(st, t, side, blds)
    st.nextRepair = st.nextRepair or REPAIR_CHECK
    if t < st.nextRepair then return end
    st.nextRepair = st.nextRepair + REPAIR_CHECK
    if side.race == economy.ORC then return end
    local level = side.aiLevel or 2
    if level == 2 and math.random(10) ~= 1 then return end
    if level == 3 and math.random(4) ~= 1 then return end
    local all = (st.unusedRepairs or 0) > REPAIR_ALL_AFTER
    for _, b in ipairs(blds) do
        if b.complete and not b.pillaged and not b.repair and not b.convert and b.hp > 0 and b.hp < b.maxHp then
            local ratio = math.floor(math.floor(b.hp) * 16 / b.maxHp)
            if ratio <= (all and 13 or 10) then
                local r = { t0 = t, t1 = t + economy.REPAIR_SECONDS[1] * 1000, total = math.ceil(b.maxHp - b.hp), done = 0,
                            speed = 1 }
                b.repair = r
                st.unusedRepairs = 0
                if not all then return end
            end
        end
    end
    st.unusedRepairs = (st.unusedRepairs or 0) + 1
end

-- The main base spot: the first keep of the side (its start location in a scenario), else the hero or a builder.
---@param self AI
---@param st AISide
---@param units Unit[]
---@param blds Building[]
---@return boolean
local function initBase(self, st, units, blds)
    local keep
    for _, b in ipairs(blds) do if economy.isKeep(b.code) then keep = keep or b end end
    local sd = self.world.sides[st.index]
    if st.index == 6 then
        -- the neutral side's base is its start location as the scenario file has it, (-1, -1) when it names none
        -- (the first think of FUN_004fa120 sets the base to the side's start location)
        st.baseX, st.baseY = sd.startX or -1, sd.startY or -1
        return true
    end
    local base = keep
    if not base and sd.startX and sd.startX >= 0 then
        st.baseX, st.baseY = sd.startX, sd.startY
        return true
    end
    if not base then
        for _, u in ipairs(units) do if u.hero then base = base or u end end
        for _, u in ipairs(units) do if u.code == st.builderCode then base = base or u end end
    end
    if not base then return false end
    st.baseX, st.baseY = base.gx, base.gy
    return true
end

---@param st AISide
---@param t number
function AI:think(st, t)
    local world, eco = self.world, self.world.eco
    local i = st.index
    local side = world.sides[i]
    if side.defeated then return end
    local level = i == 6 and 7 or side.aiLevel or 2     -- the neutral side plays Rampant whatever its record says
    if level == 0 then return end          -- Passive: FUN_004fa120 returns before any handling
    local rampant = level == 7            -- Rampant (the original's Barbarian level): no economy at all
    -- advanced option "AI can resign" (binary FUN_004fa120 / FUN_004fc5a0): a
    -- crushed computer side neutralises itself; never the local side, never a barbarian side
    if world.advanced.aiResign and not rampant and i ~= world.player and not side.resigned
        and require("src.game.advanced").shouldResign(world, i, true) then
        eco:resign(i)
        return
    end
    st.time = t
    if st.level ~= level then
        st.level = level
        if not rampant and not st.D then plan.setup(self, st) end
    end
    local units, blds = self:collect(i)
    if not st.baseX and not initBase(self, st, units, blds) then return end
    local hero = i ~= 6 and eco:heroAlive(i)          -- (the neutral side has no hero)
    if hero and not hero:alive() then hero = nil end

    -- enemy choice, hero retreat (FUN_004fa5b0, FUN_004fc150)
    aibase.chooseEnemy(self, st)
    if hero then aibase.heroStatus(self, st, hero) end
    local army = {}
    for _, u in ipairs(units) do
        if not st.builders or not st.builders[u] then army[#army + 1] = u end
    end
    if rampant then
        aibase.setBestTarget(self, st)
        aibase.defend(self, st, army)
        self:repairs(st, t, side, blds)
        require("src.game.armyabilities").aiThink(world, i)
        aibase.doAttack(self, st, army)
        return
    end
    aibase.defend(self, st, army)

    -- the units and buildings changed hands / died: forget stale references
    for u in pairs(st.groupOf) do
        if not u:alive() or u.side ~= i then st.groupOf[u] = nil end
    end
    plan.continueMissions(self, st)
    plan.analyse(self, st)
    plan.handleResources(self, st)
    aibase.bestTowerLocation(self, st)
    plan.calculateRequired(self, st)
    plan.buildResourceList(self, st)
    -- the base may have to move (FUN_004fbdf0 is asked when something is to be built)
    aibase.mainBase(self, st)
    aigroups.process(self, st, army)
    if t >= (st.nextCalc or 0) then
        plan.calculateTimeBetweenBuilds(self, st)
        st.nextCalc = t + 15000
        aibase.palaceConversions(self, st, units, blds)
    end
    plan.startMissions(self, st, units, blds)
    require("src.game.armyabilities").aiThink(world, i)       -- special abilities (FUN_005001d0)
    self:repairs(st, t, side, blds)
    if self.debug and t % 30000 < M.THINK_MS then
        require("src.core.log").info("%s", self:describe(i))
    end
end

---@param t number world time
function AI:update(t)
    if next(self.sides) then self.region:update(t) end        -- the danger map, every 3 s (FUN_005095a0)
    for i = 0, 6 do
        local st = self.sides[i]
        if st and t >= st.next then
            st.next = t + M.THINK_MS
            self:think(st, t)
        end
        -- (the ability sweep FUN_005001d0 comes after a Passive side's early return in FUN_004fa120)
        if st and i < 6 and st.level ~= 0 and not self.world.sides[i].defeated then
            require("src.game.buildingabilities").aiUpdate(self.world, i)
        end
    end
end

-- A computer takes over a side (a network player left).
---@param side integer
function AI:adopt(side)
    if not self.sides[side] then
        local st = newSide(self, side)
        st.next = self.world.time + 1000
        self.sides[side] = st
    end
end

-- Debug view -----------------------------------------------------------------------------------------------------------

-- The wish list of a side (as the original's debug overlay shows it): `--at 10 "print(W.ai:describe(1))"`, or set the
-- environment variable WBC3_AIDEBUG to log every side's list every 30 s.
---@param i integer
---@return string
function AI:describe(i)
    local st = self.sides[i]
    if not st then return ("side %d: no computer player"):format(i) end
    local lines = { ("side %d level %d t=%ds base %s,%s enemy %s hero %s gold %d metal %d crystal %d stone %d"):format(
        i, st.level or -1, (st.time or 0) / 1000, tostring(st.baseX), tostring(st.baseY), tostring(st.enemy),
        st.heroRunning and "running" or "ok", self.world.sides[i].gold, self.world.sides[i].metal,
        self.world.sides[i].crystal, self.world.sides[i].stone) }
    if st.res and st.res.goldMines then
        lines[#lines + 1] = ("  income g%d m%d c%d s%d (mine points + workers, capped), required %%: g%d m%d c%d s%d"):format(
            plan.income(st, "gold"), plan.income(st, "metal"), plan.income(st, "crystal"), plan.income(st, "stone"),
            st.required.gold or 0, st.required.metal or 0, st.required.crystal or 0, st.required.stone or 0)
    end
    for _, n in ipairs(st.list or {}) do
        local rec = (n.code:sub(1, 1) == "B" and st.bld[n.code]) or (n.code:sub(1, 1) == "A" and st.army[n.code])
            or st.pow[n.code]
        local between = rec and rec.between
        local due = rec and rec.last and between and between >= 0 and ((rec.last + between) - (st.time or 0)) / 1000 or nil
        lines[#lines + 1] = ("  %-5s pri %3d off %4d type %2d between %s due in %s%s"):format(
            n.code, n.pri, n.off, n.types, between and string.format("%.0fs", between / 1000) or "?",
            due and string.format("%.0fs", due) or "?", n.locked and " locked" or "")
    end
    local bl = {}
    for _, b in ipairs((st.D and st.D.buildings) or {}) do
        local r = st.bld[b.code]
        if r and (r.onMap > 0 or r.being > 0 or r.required > 0) then
            bl[#bl + 1] = ("%s %d/%d%s"):format(b.code, r.onMap, r.required, r.being > 0 and ("+" .. r.being) or "")
        end
    end
    if #bl > 0 then lines[#lines + 1] = "  buildings (owned/required): " .. table.concat(bl, ", ") end
    if st.groups and #st.groups > 0 then lines[#lines + 1] = aigroups.describe(st) end
    return table.concat(lines, "\n")
end

-- Saved games ------------------------------------------------------------------------------------------------------------

-- What a saved game keeps of the computer sides (FUN_004fb990: the army / building / power-up data, the resource
-- list, the groups). Units and buildings are saved by their index in the save (`uidx` / `bidx`), times relative to now.
---@param uidx table<Unit, integer>
---@param bidx table<Building, integer>
---@return table
function AI:save(uidx, bidx)
    local t = self.world.time
    local out = {}
    local function ref(e)
        if not e then return nil end
        if e.kind == "building" then return bidx[e] and { "b", bidx[e] } end
        return uidx[e] and { "u", uidx[e] }
    end
    for i, st in pairs(self.sides) do
        if st.D then
            local r = { baseX = st.baseX, baseY = st.baseY, enemy = st.enemy, damage = st.damageTaken,
                        heroRunning = st.heroRunning, converterExists = st.converterExists, nextCalc = (st.nextCalc or 0) - t, next = st.next - t,
                        armyOrder = st.armyOrder, powOrder = st.powOrder, armyTarget = st.armyTarget,
                        required = st.required, relocated = st.relocated, groupSeq = st.groupSeq, gtimer = st.gtimer,
                        nextRepair = st.nextRepair and (st.nextRepair - t), unusedRepairs = st.unusedRepairs,
                        bld = {}, army = {}, pow = {}, list = {}, groups = {}, potential = {} }
            for code, b in pairs(st.bld) do
                r.bld[code] = { last = b.last and (b.last - t), between = b.between }
            end
            for code, a in pairs(st.army) do
                r.army[code] = { pri = a.pri, off = a.off, last = a.last and (a.last - t), between = a.between }
            end
            for code, p in pairs(st.pow) do
                r.pow[code] = { pri = p.pri, last = p.last and (p.last - t), between = p.between }
            end
            for k, n in ipairs(st.list) do
                r.list[k] = { code = n.code, pri = n.pri, orig = n.orig, off = n.off, cost = n.cost, types = n.types }
            end
            for _, p in ipairs(st.potential) do
                r.potential[#r.potential + 1] = { gx = p.gx, gy = p.gy, left = p.until_ - t }
            end
            for k, g in ipairs(st.groups) do
                local rec = { id = g.id, slot = g.slot, type = g.type, minSize = g.minSize, targetSide = g.targetSide,
                              members = {}, stage = g.objective.stage, otype = g.objective.type,
                              target = ref(g.objective.target),
                              attackType = g.attackType, convPoint = g.convPoint }
                for _, u in ipairs(g.members) do
                    local x = uidx[u]
                    if x then rec.members[#rec.members + 1] = x end
                end
                r.groups[k] = rec
            end
            out[i] = r
        elseif st.level == 7 then
            -- a Rampant side (and the neutral one) has no lists, only its timers and the enemy it chose
            out[i] = { lite = true, baseX = st.baseX, baseY = st.baseY, enemy = st.enemy, next = st.next - t,
                       nextRepair = st.nextRepair and (st.nextRepair - t), unusedRepairs = st.unusedRepairs }
        end
    end
    out.extra = { hate = self.hate, region = self.region:save(t) }
    return out
end

---@param data table?
---@param ulist table<integer, Unit>
---@param blist table<integer, Building>
function AI:restore(data, ulist, blist)
    if not data then return end
    local world = self.world
    local t = world.time
    if data.extra then
        if data.extra.hate then self.hate = data.extra.hate end
        self.region:restore(data.extra.region, t)
    end
    for i, r in pairs(data) do
        local st = self.sides[i]
        if st and r.lite then
            st.baseX, st.baseY, st.enemy = r.baseX, r.baseY, r.enemy
            st.next = t + (r.next or 0)
            st.nextRepair = r.nextRepair and (t + r.nextRepair) or nil
            st.unusedRepairs = r.unusedRepairs
        elseif st and st.D then
            st.baseX, st.baseY, st.enemy = r.baseX, r.baseY, r.enemy
            st.damageTaken = r.damage or {}
            st.heroRunning = r.heroRunning
            if r.converterExists ~= nil then st.converterExists = r.converterExists end
            st.nextCalc = t + (r.nextCalc or 0)
            st.next = t + (r.next or 0)
            st.nextRepair = r.nextRepair and (t + r.nextRepair) or nil
            st.unusedRepairs = r.unusedRepairs
            st.armyOrder, st.powOrder = r.armyOrder or st.armyOrder, r.powOrder or st.powOrder
            st.armyTarget = r.armyTarget
            st.required = r.required or st.required
            st.relocated = r.relocated
            st.groupSeq, st.gtimer = r.groupSeq or 0, r.gtimer or 0
            for code, v in pairs(r.bld or {}) do
                local b = st.bld[code]
                if b then b.last, b.between = v.last and (t + v.last), v.between end
            end
            for code, v in pairs(r.army or {}) do
                local a = st.army[code]
                if a then a.pri, a.off, a.last, a.between = v.pri, v.off, v.last and (t + v.last), v.between end
            end
            for code, v in pairs(r.pow or {}) do
                local p = st.pow[code]
                if p then p.pri, p.last, p.between = v.pri, v.last and (t + v.last), v.between end
            end
            st.list = {}
            for k, n in ipairs(r.list or {}) do
                st.list[k] = { code = n.code, pri = n.pri, orig = n.orig, off = n.off, cost = n.cost, types = n.types,
                               locked = false }
            end
            st.potential = {}
            for _, p in ipairs(r.potential or {}) do
                st.potential[#st.potential + 1] = { gx = p.gx, gy = p.gy, until_ = t + p.left }
            end
            st.groups, st.groupOf, st.targets = {}, {}, {}
            for k, rec in ipairs(r.groups or {}) do
                local g = { id = rec.id, slot = rec.slot or (k - 1), type = rec.type, members = {}, minSize = rec.minSize,
                            targetSide = rec.targetSide, objective = { type = rec.otype, stage = rec.stage }, px = -1, py = -1,
                            strength = 0,
                            longRange = 0, conv = 0, attackType = rec.attackType or 0, convPoint = rec.convPoint }
                for _, ui in ipairs(rec.members or {}) do
                    local u = ulist[ui]
                    if u and u:alive() then
                        g.members[#g.members + 1] = u
                        st.groupOf[u] = g
                    end
                end
                if rec.target then
                    local e = (rec.target[1] == "b" and blist or ulist)[rec.target[2]]
                    g.objective.target = e
                    if not e then g.objective = { type = 0, stage = 0 } end
                end
                st.groups[#st.groups + 1] = g
            end
            st.listChanged = false
        end
    end
end

return M
