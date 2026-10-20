-- Computer player: the production model of the original's computer player ("time between builds"), the build order and
-- the missions.
--
-- Rules, with where they were checked: "binary" = the 1.04 game binary (decompiled in Ghidra).
--  * The AI keeps a resource list of wanted things (builders, armies, power-ups, production buildings, towers, army
--    research, power-up research) with priorities and a type bit each (FUN_004fb400; types 1 army, 2 power-up,
--    4 army research, 8 power-up research, 16 production, 32 defence, 64 builder).
--  * Every 15 s, and whenever the list changed, FUN_004ff470 gives each node a "time between builds":
--    per type, the summed priorities of the nodes that cost a resource, the mine income of that resource (capped per AI
--    level) and the type's production rate (FUN_004ffab0) turn into an interval per resource; the node's time is
--    the largest of the four intervals times 4000 ms (per resource type: binary FUN_004fe300; rates binary
--    FUN_004ffab0; income and its caps FUN_004ffee0; the level factor of FUN_004ff400 is not used: FUN_004ff470 passes
--    it to FUN_004fe250, which ignores it). Dragons and titans are quicker at higher levels.
--  * An item is only started when its time has passed (FUN_004f8600) and it can be paid (the AI pays real resources;
--    FUN_004fb330 looks at stock only for a resource whose income is under 8). While the AI owns fewer than three
--    buildings (walls and resource points not counted) everything is allowed at once.
--  * Armies enter the list with their priority (script value, else 50) and a priority offset that grows with the time
--    since the last one was built; a never-built army gets 10 minutes of credit ("the first one for free").
--  * Production buildings: the building (with at least one standing or under way) with the lowest owned / required ratio
--    (ratio times its level) joins with priority 90, an upgrade also gets offset 90. Required numbers come from
--    binary FUN_004fc9a0: priority share of the armies the building produces times
--    a level factor 40 / 60 / 100 / 140 / 180 / 250 (default 120) / 10, plus 1 (2 for the elf keeps).
--  * Build order: the army research node asks for the buildings (priority 150, 220 for the builder's own building) and
--    power-ups (140) the next army of the build script order needs; power-up research (80) the same for power-ups.
--  * Mines (binary FUN_004fc280): a mine counts 2 / 4 / 8 (+ Income power-up level) by size (1 when dry),
--    the workers inside count extra, a resource with 4..8 mine points gets +6, a mine more than 21 cells from every keep
--    "needs a keep". Builders: priority 100 under 4 builders, else 50 + (free mine places - builders + 4) / 4, at most 100.
-- Power-ups that stay on offer after being bought (research, mercenaries, the Knight's Quest) are never "researched", so
-- the resource list buys them again and again, like the original (binary FUN_004fead0
-- takes the first power-up of the race list that can be built and is neither researched nor being researched).
-- Not original (openwbc3's own, kept to what the original data leaves open): an army is only started when the
-- army limit has room; the build spot is the nearest legal one around the target (the exact search of FUN_004f9480 is
-- not reproduced); the army-research search checks "buildable" on the building it looks at (the
-- original's search was not traced in the 1.04 binary yet).
local economy = require("src.game.economy")
local rules = require("src.game.rules")
local gamedata = require("src.game.gamedata")
local aidata = require("src.game.aidata")
local powerups = require("src.game.powerups")

local M = {}

-- resource type bits of the resource list
local T_ARMY, T_POWERUP, T_ARMY_RESEARCH, T_POWERUP_RESEARCH, T_PRODUCTION, T_DEFENCE, T_BUILDER = 1, 2, 4, 8, 16, 32, 64
M.T = { army = T_ARMY, powerup = T_POWERUP, armyResearch = T_ARMY_RESEARCH, powerupResearch = T_POWERUP_RESEARCH,
        production = T_PRODUCTION, defence = T_DEFENCE, builder = T_BUILDER }
local TYPE_ORDER = { T_BUILDER, T_DEFENCE, T_ARMY, T_POWERUP, T_ARMY_RESEARCH, T_POWERUP_RESEARCH, T_PRODUCTION }
local RES = require("src.content").resource:ids() --[[@as string[] ]]

-- The shares by AI level 1..6 (Knave .. Emperor; binary FUN_004ffab0 / FUN_004ffee0 / FUN_004fc9a0), the income cap (default 35, Rampant)
-- and the buildings factor (default 120) are `aiprofile` records (content/base/aiprofiles.lua).
local profile = require("src.game.aiprofile")
local RATE_KEY = { [T_ARMY] = "army", [T_POWERUP] = "powerup", [T_ARMY_RESEARCH] = "armyResearch", [T_POWERUP_RESEARCH] = "powerupResearch",
                   [T_PRODUCTION] = "production", [T_DEFENCE] = "defence", [T_BUILDER] = "builder" }

local function dice(n) return math.random(1, n) end

-- An entry of the resource list (the wish list).
---@class AINode
---@field code string
---@field pri integer               priority
---@field orig integer              the priority it entered with
---@field off integer               priority offset
---@field cost table<string, integer>
---@field types integer             resource type bits (M.T)
---@field locked boolean            a builder is on its way to put it up

-- What a computer side knows about one of its race's buildings.
---@class AIBuildingRec
---@field code string
---@field onMap integer             finished ones (an upgrade counts for the levels below too)
---@field being integer             under construction / on the way
---@field required integer          the required number, -1 none
---@field between number            time between builds (ms), -1 unset
---@field last number?              when one was last started (world time)
---@field buildable boolean         a builder may construct it (or it is an upgrade level)
---@field canBeBuilt boolean?       requirements met now

-- ... about one of its armies.
---@class AIArmyRec
---@field code string
---@field pri integer               priority (script, else 50), -1 never
---@field off integer               priority offset
---@field avail boolean             can be produced now
---@field onMap integer
---@field inProd integer
---@field between number
---@field last number?
---@field titan boolean

-- ... about one of its power-ups.
---@class AIPowerupRec
---@field code string
---@field pri integer
---@field researched boolean
---@field researching boolean
---@field canBeBuilt boolean
---@field between number
---@field last number?
---@field never boolean             not a power-up of the content (never bought)

-- A resource point as the mine assignment sees it.
---@class AIMine
---@field b Building
---@field resource string
---@field size integer
---@field dry boolean
---@field owned boolean
---@field inMine integer            workers inside (8 when dry)
---@field going integer             builders on their way in
---@field converting boolean        our conversion of it is under way
---@field needsKeep boolean?        not ours and more than 21 cells from every keep of ours

-- A builder on its way to put up a building.
---@class AIBuildMission
---@field u Unit
---@field code string
---@field t0 number

---@param st AISide
local function level(st) return st.level end

-- Resource list ---------------------------------------------------------------------------------------------------

---@param st AISide
---@param code string
---@return AINode?
function M.findNode(st, code)
    for _, n in ipairs(st.list) do
        if n.code == code then return n end
    end
end

---@param st AISide
---@param rtype integer
---@return AINode?
function M.nodeOfType(st, rtype)
    for _, n in ipairs(st.list) do
        if n.types % (rtype * 2) >= rtype then return n end
    end
end

local function hasType(n, rtype) return n.types % (rtype * 2) >= rtype end

---@param st AISide
---@param code string
---@return (AIBuildingRec|AIArmyRec|AIPowerupRec)?
local function record(st, code)
    local k = code:sub(1, 1)
    if k == "B" then return st.bld[code]
    elseif k == "A" then return st.army[code]
    elseif k == "P" or k == "R" then return st.pow[code] end
end

-- List changed (FUN_004fafd0)
local function listChanged(st, code, added)
    st.listChanged = true
    local r = record(st, code)
    if not r then return end
    local k = code:sub(1, 1)
    if added then
        r.last = k == "A" and st.time - 600000 or st.time
    else
        r.between = -1
    end
end

---@param st AISide
---@param code string
function M.removeNode(st, code)
    for i, n in ipairs(st.list) do
        if n.code == code then
            table.remove(st.list, i)
            listChanged(st, code, false)
            return
        end
    end
end

-- Affordability (FUN_004fb330): stock only matters for a resource with an income under 8
---@param ai AI
---@param st AISide
---@param cost table<string, integer>
---@return boolean
function M.canAffordThing(ai, st, cost)
    local eco = ai.world.eco
    local side = ai.world.sides[st.index]
    for _, r in ipairs(RES) do
        if M.income(st, r) < 8 and eco:price(st.index, cost[r] or 0) > side[r] then return false end
    end
    return true
end

---@param ai AI
---@param st AISide
---@param code string
---@param priority integer
---@param cost table<string, integer>
---@param rtype integer
function M.addNode(ai, st, code, priority, cost, rtype)
    if not M.canAffordThing(ai, st, cost) then return end
    for _, n in ipairs(st.list) do
        if n.code == code then
            n.pri = n.pri + priority
            if not hasType(n, rtype) then n.types = n.types + rtype end
            listChanged(st, code, true)
            return
        end
    end
    local at = #st.list + 1
    for i, n in ipairs(st.list) do
        if n.pri < priority then at = i break end
    end
    table.insert(st.list, at, { code = code, pri = priority, orig = priority, off = 0, cost = cost, types = rtype,
                                locked = false })
    listChanged(st, code, true)
end

local function setOffset(st, code, off)
    local n = M.findNode(st, code)
    if n then n.off = off end
end

---@param ai AI
---@param st AISide
---@param code string
---@return table<string, integer>
local function costOf(ai, st, code)
    local info = ai.world.eco:itemInfo(code, st.index)
    return info and info.cost or { gold = 0, metal = 0, crystal = 0, stone = 0 }
end

-- Mines and income --------------------------------------------------------------------------------------------------

-- Resource income (FUN_004ffee0): mine points plus the workers inside, capped by the AI level
---@param st AISide
---@param r string resource
---@return integer
function M.income(st, r)
    local v = (st.res[r .. "Mines"] or 0) + (st.res[r .. "Extras"] or 0)
    local cap = profile.get(st.level, "incomeCap", 35)
    if cap ~= -1 and v > cap then v = cap end
    return v
end

local function mineSize(b)
    return (tonumber(b.code:sub(4, 4)) or 0) + 1
end

-- Mine list (FUN_004fb550 / FUN_004fb680) and mine assignment (FUN_004fc280)
---@param ai AI
---@param st AISide
function M.handleResources(ai, st)
    local world = ai.world
    local res = { goldMines = 0, goldExtras = 0, goldCapacity = 0, goldConversions = 0,
                  metalMines = 0, metalExtras = 0, metalCapacity = 0, metalConversions = 0,
                  crystalMines = 0, crystalExtras = 0, crystalCapacity = 0, crystalConversions = 0,
                  stoneMines = 0, stoneExtras = 0, stoneCapacity = 0, stoneConversions = 0 }
    local income = powerups.level(world.sides[st.index], "PIB0")
    st.mines = {}
    -- builders on their way into a mine
    local going = {}
    for _, u in ipairs(world.units) do
        if u.side == st.index and u.task and u.task.kind == "mine" and u.task.building and u:alive() then
            going[u.task.building] = (going[u.task.building] or 0) + (u:canWorkInMine() == 2 and 2 or 1)
        end
    end
    for _, b in ipairs(world.buildings) do
        if b.mine and b.hp > 0 and b.complete then
            local r = b.mine.resource
            local dry = b.mine.reserve <= 0
            local amount = 1
            if not dry then
                local size = mineSize(b)
                amount = (size == 1 and 2 or size == 2 and 4 or size == 3 and 8 or 1)
                amount = amount + ((size >= 1 and size <= 3) and income or 0)
            end
            local owned = b.side == st.index
            local m = { b = b, resource = r, size = mineSize(b), dry = dry, owned = owned,
                        inMine = dry and 8 or b.mine.workers, going = going[b] or 0,
                        converting = st.converting[b] ~= nil and st.converting[b] > st.time }
            if owned then
                res[r .. "Mines"] = res[r .. "Mines"] + amount
                if not dry then
                    res[r .. "Extras"] = res[r .. "Extras"] + b.mine.workers
                    res[r .. "Capacity"] = res[r .. "Capacity"] + 8
                end
            elseif m.converting then
                res[r .. "Conversions"] = res[r .. "Conversions"] + amount
            elseif dry then
                m.needsKeep = false
            else
                m.needsKeep = true
                for _, k in ipairs(st.keeps) do
                    if math.max(math.abs(b.gx - k.gx), math.abs(b.gy - k.gy)) < 22 then m.needsKeep = false break end
                end
            end
            st.mines[#st.mines + 1] = m
        end
    end
    -- one mine of a kind still sustains production
    for _, r in ipairs(RES) do
        local v = res[r .. "Mines"]
        if v >= 4 and v <= 8 then res[r .. "Mines"] = v + 6 end
    end
    st.res = res
end

-- Analysis of the side's buildings, armies and power-ups -----------------------------------------------------------

---@param ai AI
---@param st AISide
function M.analyse(ai, st)
    local world, eco = ai.world, ai.world.eco
    local i = st.index
    local sd = world.sides[i]
    local D = st.D
    for _, r in pairs(st.bld) do r.onMap, r.being = 0, 0 end
    for _, r in pairs(st.army) do r.onMap, r.inProd = 0, 0 end
    for _, r in pairs(st.pow) do r.researching = false end
    st.keeps = {}
    local canProduce = {}
    -- buildings
    for _, b in ipairs(world.buildings) do
        if b.side == i and b.hp > 0 then
            local rec = st.bld[b.code]
            if economy.isKeep(b.code) then st.keeps[#st.keeps + 1] = b end
            if b.complete then
                if rec then
                    rec.onMap = rec.onMap + 1
                    -- an upgraded building also counts for the levels below it
                    local d = aidata.level(b.code)
                    if d and d > 0 then
                        for lv = d - 1, 0, -1 do
                            local lower = st.bld[b.code:sub(1, 3) .. lv]
                            if lower then lower.onMap = lower.onMap + 1 end
                        end
                    end
                end
                if not b.pillaged and not b.mine then
                    for _, code in ipairs(eco:productionList(b)) do canProduce[code] = true end
                    local cur = b.current and b.current.code
                    local function count(code)
                        local k = code:sub(1, 1)
                        if k == "A" then
                            local a = st.army[code]
                            if a then a.inProd = a.inProd + 1 end
                        elseif k == "B" then
                            local o = st.bld[code]
                            if o then o.being = o.being + 1 end
                        elseif k == "P" or k == "R" then
                            local p = st.pow[code]
                            if p then p.researching = true end
                        end
                    end
                    if cur then count(cur) end
                    for _, code in ipairs(b.queue or {}) do count(code) end
                end
            elseif rec then
                rec.being = rec.being + 1
            end
        end
    end
    -- builders on their way to place a building
    for _, u in ipairs(world.units) do
        if u.side == i and u:alive() then
            local a = st.army[u.code]
            if a then a.onMap = a.onMap + 1 end
            if u.task and u.task.kind == "build" then
                local o = st.bld[u.task.code]
                if o then o.being = o.being + 1 end
            end
        end
    end
    st.canProduce = canProduce
    -- armies
    for _, a in pairs(st.army) do
        a.avail = false
        if canProduce[a.code] and a.code ~= "AEAX" and eco:requirementsMet(i, a.code) then
            a.avail = true
            if a.titan and sd.producedTitan then a.avail = false end
        end
        if not a.avail then a.between = -1 end
    end
    -- power-ups
    for _, p in pairs(st.pow) do
        p.researched = powerups.has(sd, p.code)
        p.canBeBuilt = canProduce[p.code] == true and eco:requirementsMet(i, p.code) and powerups.offered(sd, p.code)
            and not p.never
    end
    st.ancientWisp = st.builderCode == "AEBX" and canProduce["AEAX"] == true and eco:requirementsMet(i, "AEAX")
    -- buildings
    for _, r in pairs(st.bld) do
        r.canBeBuilt = false
        if eco:requirementsMet(i, r.code) then
            r.canBeBuilt = M.multiLevelOk(st, r)
        end
    end
end

-- Upgrade levels (FUN_004fcdd0): a level above 0 needs a spare building of the level below
---@param st AISide
---@param r AIBuildingRec
---@return boolean
function M.multiLevelOk(st, r)
    local d = aidata.level(r.code)
    if d and d > 0 then
        local lower = st.bld[r.code:sub(1, 3) .. (d - 1)]
        if not lower then return false end
        return lower.onMap - r.onMap - r.being > 0
    end
    return true
end

-- Required numbers of buildings --------------------------------------------------------------------------------------


local function handleMultiLevel(st, bp, armiesAvail)
    local D = st.D
    -- runs of buildings whose codes end in 0, 1, 2 ... one after the other
    local runs, start, last = {}, nil, nil
    for idx, b in ipairs(D.buildings) do
        local d = aidata.level(b.code)
        if not start and d == 0 then
            start, last = idx, 0
        elseif start then
            if d == nil then
                runs[#runs + 1] = { start, idx - 1 }
                start = nil
            elseif d ~= last + 1 then
                runs[#runs + 1] = { start, idx - 1 }
                start = nil
                if d == 0 then start, last = idx, 0 end
            else
                last = d
            end
        end
    end
    if start then runs[#runs + 1] = { start, #D.buildings } end
    for _, run in ipairs(runs) do
        local s, e = run[1], run[2]
        local highest, highestPri, total = nil, 0, 0
        for k = s, e do
            local v = bp[k]
            if v ~= -1 then
                if v >= highestPri then highestPri, highest = v, k end
                total = total + v
            end
        end
        if highest then
            for k = e, s, -1 do
                if k == highest then
                    bp[k] = total
                elseif bp[k] ~= -1 then
                    bp[k] = bp[k] * total / highestPri
                    bp[k] = bp[k] >= 0 and math.floor(bp[k]) or math.ceil(bp[k])
                end
            end
        end
        local maxy, found = nil, false
        for k = e, s, -1 do
            if maxy == nil or maxy == -1 then
                maxy = bp[k]
            elseif bp[k] < maxy then
                bp[k] = maxy
            else
                maxy = bp[k]
            end
            found = found or armiesAvail[k]
            if found then armiesAvail[k] = true end
        end
    end
end

---@param ai AI
---@param st AISide
function M.calculateRequired(ai, st)
    local D = st.D
    local factor = profile.get(st.level, "buildingsFactor", 120)
    local bp, avail, totalP = {}, {}, 0
    for k, b in ipairs(D.buildings) do
        local rec = st.bld[b.code]
        if not rec.buildable then
            bp[k] = -1
        else
            avail[k] = false
            local pri, now = 0, 0
            for _, a in ipairs(D.armies) do
                local ar = st.army[a.code]
                if ar.pri ~= -1 then
                    local builder = gamedata.hasTag(a.code, "undeadMorph") and "BAGR" or D.builderOf[a.code]
                    if builder == b.code then
                        if ar.avail or a.code == st.armyTarget then avail[k] = true end
                        pri = pri + ar.pri
                        if avail[k] then now = now + ar.pri end
                    end
                end
            end
            bp[k] = now > 0 and now or -1
            totalP = totalP + pri
        end
    end
    handleMultiLevel(st, bp, avail)
    for k, b in ipairs(D.buildings) do
        local rec = st.bld[b.code]
        if bp[k] ~= -1 and totalP > 0 then
            local extra = (b.code == "BKE0" or b.code == "BKW0" or b.code == "BKT0") and 2 or 1
            rec.required = math.floor(bp[k] * factor / (totalP * 10)) + extra
        else
            rec.required = -1
        end
    end
end

-- The resource list -----------------------------------------------------------------------------------------------

local function handleBuilders(ai, st)
    local builder = st.builderCode
    local a = builder and st.army[builder]
    if not a then return end
    local inList = M.findNode(st, builder)
    if inList and not a.avail then
        M.removeNode(st, builder)
        inList = nil
    end
    if not a.avail then return end
    local current = a.onMap + a.inProd
    local vacancy = 0
    for _, r in ipairs(RES) do vacancy = vacancy + (st.res[r .. "Capacity"] or 0) - (st.res[r .. "Extras"] or 0) end
    local needed = vacancy - current + 4
    local pri
    local wisps = builder == "AEBX"
    if wisps then needed = 0 end               -- wisps do not work in mines
    if wisps and st.ancientWisp then pri = 100          -- they are merged into ancient wisps
    elseif current < 4 then pri = 100
    elseif needed > 0 then pri = math.min(100, 50 + math.floor(needed / 4))
    else pri = 0 end
    if pri > 0 then
        if inList then
            inList.pri = pri
        else
            M.addNode(ai, st, builder, pri, costOf(ai, st, builder), T_BUILDER)
        end
    elseif inList then
        M.removeNode(st, builder)
    end
end

local function handleArmies(ai, st)
    for _, a in ipairs(st.D.armies) do
        local ar = st.army[a.code]
        if ar.avail then
            local node = M.findNode(st, a.code)
            if node then
                local since = math.max(0, math.floor((st.time - (ar.last or st.time)) / 1024))
                node.off = ar.off + since
            elseif a.code ~= st.builderCode and (ar.pri > 0 or (ar.pri == 0 and ar.off > 0)) then
                M.addNode(ai, st, a.code, ar.pri, costOf(ai, st, a.code), T_ARMY)
                setOffset(st, a.code, ar.off + 100)
            end
        elseif M.findNode(st, a.code) and a.code ~= st.builderCode then
            M.removeNode(st, a.code)
        end
    end
end

local function handlePowerups(ai, st)
    local cur = M.nodeOfType(st, T_POWERUP)
    if cur then
        local p = st.pow[cur.code]
        if not p or p.researched or not p.canBeBuilt then M.removeNode(st, cur.code) else return end
    end
    for _, d in ipairs(st.D.powerups) do
        local p = st.pow[d.code]
        if p.canBeBuilt and not p.researched and not p.researching then
            M.addNode(ai, st, d.code, p.pri, costOf(ai, st, d.code), T_POWERUP)
            return
        end
    end
end

local function isUpgrade(code)
    local d = aidata.level(code)
    return d ~= nil and d > 0 and code:sub(1, 1) == "B"
end

local function handleProduction(ai, st)
    local node = M.nodeOfType(st, T_PRODUCTION)
    if node and node.locked then return end
    if node then
        local r = st.bld[node.code]
        if not r or not r.canBeBuilt then M.removeNode(st, node.code) else return end
    end
    local best, lowest, highestDiff
    for _, b in ipairs(st.D.buildings) do
        local r = st.bld[b.code]
        if r.required ~= -1 and r.canBeBuilt and (r.onMap + r.being) > 0 and r.buildable and M.multiLevelOk(st, r) then
            local num = r.being + r.onMap
            local diff = r.required - num
            if diff > 0 then
                local d = aidata.level(b.code)
                local lvl = d and d + 1 or 1
                local ratio = math.floor(num * 128 / r.required) * lvl
                if not best or ratio < lowest then
                    best, lowest, highestDiff = r, ratio, diff
                elseif ratio == lowest and diff > highestDiff then
                    best, highestDiff = r, diff
                end
            end
        end
    end
    if not best then return end
    M.addNode(ai, st, best.code, 90, costOf(ai, st, best.code), T_PRODUCTION)
    if isUpgrade(best.code) then setOffset(st, best.code, 90) end
end

local function handleDefence(ai, st)
    local node = M.nodeOfType(st, T_DEFENCE)
    if node then
        local r = st.bld[node.code]
        if not r or not r.canBeBuilt then M.removeNode(st, node.code) else return end
    end
    local n = 0
    for _, b in ipairs(st.D.buildings) do
        local r = st.bld[b.code]
        if r.buildable then
            local c = b.code:sub(2, 2)
            if c ~= "W" and c ~= "R" then n = n + r.onMap end
        end
    end
    if n < 3 then return end
    local towers = {}
    for _, b in ipairs(st.D.buildings) do
        if b.code:sub(2, 2) == "W" and st.bld[b.code].canBeBuilt then towers[#towers + 1] = b.code end
    end
    if #towers == 0 then return end
    local code = towers[dice(#towers)]
    if st.bestTower then
        M.addNode(ai, st, code, 90, costOf(ai, st, code), T_DEFENCE)
    end
end

-- the army research / power-up research nodes: the first army of the build script order that lacks something
local function handleResearch(ai, st, isArmy)
    local rtype = isArmy and T_ARMY_RESEARCH or T_POWERUP_RESEARCH
    local node = M.nodeOfType(st, rtype)
    if node and node.locked then return end
    if node then
        local k = node.code:sub(1, 1)
        if k == "B" then
            local r = st.bld[node.code]
            if not r or not r.canBeBuilt or r.onMap > 0 then M.removeNode(st, node.code) else return end
        elseif k == "P" or k == "R" then
            local p = st.pow[node.code]
            if not p or not p.canBeBuilt or p.researched then M.removeNode(st, node.code) else return end
        else
            M.removeNode(st, node.code)
        end
    end
    local D = st.D
    local order = isArmy and st.armyOrder or st.powOrder
    local builderBuilding = st.builderCode and D.builderOf[st.builderCode]
    if isArmy then st.armyTarget = nil end
    for _, code in ipairs(order) do
        local needB, needP = D.needB[code], D.needP[code]
        local builtAll = true
        local bestCode, bestKind, bestPri
        for _, b in ipairs(D.buildings) do
            if needB[b.code] then
                local r = st.bld[b.code]
                if r.onMap + r.being == 0 and r.buildable then
                    builtAll = false
                    if r.canBeBuilt then
                        local pri = isArmy and 150 or (100 + (math.max(0, r.required) * 16))
                        if b.code == builderBuilding then pri = pri + 70 end
                        if not bestPri or pri > bestPri then bestCode, bestKind, bestPri = b.code, "B", pri end
                    end
                end
            end
        end
        if isArmy then
            for _, p in ipairs(D.powerups) do
                if needP[p.code] then
                    local pr = st.pow[p.code]
                    if not pr.researched and not pr.researching then
                        builtAll = false
                        if pr.canBeBuilt then
                            if not bestPri or 140 > bestPri then bestCode, bestKind, bestPri = p.code, "P", 140 end
                        end
                    end
                end
            end
        end
        if not bestCode and not builtAll then
            if isArmy then st.armyTarget = code end
            return
        elseif not builtAll then
            local cost = costOf(ai, st, bestCode)
            M.addNode(ai, st, bestCode, isArmy and 100 or 80, cost, rtype)
            if bestKind == "B" and isUpgrade(bestCode) then setOffset(st, bestCode, 100)
            elseif bestKind == "P" and isArmy then setOffset(st, bestCode, 100) end
            if isArmy then st.armyTarget = code end
            return
        end
    end
end

---@param ai AI
---@param st AISide
function M.buildResourceList(ai, st)
    handleBuilders(ai, st)
    handleArmies(ai, st)
    handlePowerups(ai, st)
    handleProduction(ai, st)
    handleDefence(ai, st)
    handleResearch(ai, st, true)
    handleResearch(ai, st, false)
    if st.listChanged then
        M.calculateTimeBetweenBuilds(ai, st)
        st.listChanged = false
    end
end

-- Times --------------------------------------------------------------------------------------------------------------

-- Resource priorities (FUN_004fb100): how much of each resource the wishes need, in percent of the largest
---@param ai AI
---@param st AISide
function M.calculateRequired100(ai, st)
    local req = { gold = 0, metal = 0, crystal = 0, stone = 0 }
    for _, n in ipairs(st.list) do
        if n.code:sub(1, 1) ~= "A" then
            for _, r in ipairs(RES) do req[r] = req[r] + math.floor((n.cost[r] or 0) * n.pri / 256) end
        else
            local t = gamedata.army(n.code)
            local secs = t and math.max(1, t.buildTime) or 20
            for _, r in ipairs(RES) do req[r] = req[r] + math.floor((n.cost[r] or 0) * n.pri / secs) end
        end
    end
    local highest = math.max(req.gold, req.metal, req.crystal, req.stone)
    if highest == 0 then st.required = req return end
    for _, r in ipairs(RES) do req[r] = math.floor(req[r] * 100 / highest) end
    for _, r in ipairs(RES) do
        if M.income(st, r) < 4 then req[r] = req[r] + 105 end
    end
    st.required = req
end

---@param st AISide
---@param rtype integer
---@return number
local function rateOf(st, rtype)
    local p = st.params
    local main = p and p.main
    if main and main.armyProduction ~= 0 then
        ---@cast p -nil
        -- a script that sets the main production value (the custom branch of FUN_004ffab0)
        if rtype == T_BUILDER then return math.floor(p.flags.buildersInMines * 150 / 100)
        elseif rtype == T_DEFENCE then return main.defenseTowers
        elseif rtype == T_PRODUCTION then return math.floor(main.armyProduction * 150 / 100)
        elseif rtype == T_POWERUP_RESEARCH then return main.powerupUpgrades
        elseif rtype == T_ARMY_RESEARCH then return math.floor(main.armyUpgrades * 130 / 100)
        elseif rtype == T_POWERUP then return math.floor(main.powerupUpgrades * 150 / 100)
        elseif rtype == T_ARMY then return math.floor(main.armyUpgrades * 250 / 100) end
    end
    return profile.rate(st.level, RATE_KEY[rtype], 60)
end
M.rate = rateOf


local function calculateType(ai, st, rtype)
    local P = { gold = 0, metal = 0, crystal = 0, stone = 0 }
    for _, n in ipairs(st.list) do
        if hasType(n, rtype) then
            for _, r in ipairs(RES) do
                if (n.cost[r] or 0) > 0 then P[r] = P[r] + n.pri end
            end
        end
    end
    local rate = rateOf(st, rtype)
    for _, n in ipairs(st.list) do
        if hasType(n, rtype) and n.code ~= "MR00" then
            local worst = 0
            for _, r in ipairs(RES) do
                local iv
                if n.pri == 0 then
                    iv = r == "crystal" and 1000 or 10000
                else
                    local inc = math.floor(M.income(st, r) * rate / 100)
                    iv = math.floor((n.cost[r] or 0) * P[r] / (n.pri * inc + 1))
                end
                if iv > worst then worst = iv end
            end
            if n.pri == 0 then worst = 10000 end
            local t = worst * 4000
            local k = n.code:sub(1, 1)
            local rec = record(st, n.code)
            if rec then
                if k == "P" or k == "R" then
                    if (rec.between or 0) == 0 or t < rec.between then
                        if gamedata.hasTag(n.code, "aiDragon") then
                            local l = st.level
                            if l == 2 then t = math.floor(t / 2) elseif l == 3 then t = math.floor(t / 3)
                            elseif l >= 4 then t = math.floor(t / 4) end
                        end
                        rec.between = t
                    end
                else
                    if (rec.between or 0) == 0 or t < rec.between then rec.between = t end
                end
            end
        end
    end
end

---@param ai AI
---@param st AISide
function M.calculateTimeBetweenBuilds(ai, st)
    M.calculateRequired100(ai, st)
    for _, n in ipairs(st.list) do
        local rec = record(st, n.code)
        if rec then rec.between = 0 end
    end
    for _, t in ipairs(TYPE_ORDER) do calculateType(ai, st, t) end
end

-- Time check (FUN_004f8600)
---@param st AISide
---@param code string
---@return boolean
function M.checkTimestamp(st, code)
    local count = 0
    for _, b in ipairs(st.D.buildings) do
        local c = b.code:sub(2, 2)
        if c ~= "R" and c ~= "W" then
            local r = st.bld[b.code]
            count = count + r.being + r.onMap
        end
    end
    if count < 3 then return true end
    local r = record(st, code)
    if not r then return false end
    local k = code:sub(1, 1)
    if r.between == -1 or r.between == nil then
        if k == "B" and code:sub(2, 2) == "K" then return false end
        r.between = 50000
        return true
    end
    return st.time > (r.last or 0) + r.between
end

-- Time stamp (FUN_004f8750)
---@param st AISide
---@param code string
function M.updateTimestamp(st, code)
    local r = record(st, code)
    if r then r.last = st.time end
    local k = code:sub(1, 1)
    if k == "B" or k == "P" or k == "R" then M.removeNode(st, code) end
end

-- Missions ---------------------------------------------------------------------------------------------------------------

-- The best node (highest priority + offset + dice) among `check` (set of codes) that passes its timestamp.
---@param st AISide
---@param check table<string, boolean>
---@return AINode?
local function bestNode(st, check)
    local best, bestAmount
    for _, n in ipairs(st.list) do
        if not n.locked and check[n.code] and M.checkTimestamp(st, n.code) then
            local amount = n.pri + n.off + dice(30)
            if not best or amount > bestAmount then best, bestAmount = n, amount end
        end
    end
    return best
end

-- Where a building goes: a tower near the best tower spot, a further keep near a mine that needs one (when no
-- converter army exists), everything else next to the main base (FUN_004fe060).
---@param ai AI
---@param st AISide
---@param code string
---@return integer gx
---@return integer gy
function M.buildTarget(ai, st, code)
    local keeps = st.bld[code] and aidata.isKeep(code)
    if keeps and code == st.keepCode0 then
        local rec = st.bld[code]
        if rec.onMap + rec.being > 0 and not st.converterExists then
            for _, m in ipairs(st.mines) do
                if not m.owned and m.needsKeep then return m.b.gx, m.b.gy end
            end
        end
    end
    if aidata.isTower(code) and st.bestTower then return st.bestTower.gx, st.bestTower.gy end
    return st.baseX, st.baseY + 2
end

local function canBuildNow(ai, st)
    return not st.builtThisCycle
end

-- A builder looks for a building to construct or a mine to work in.
---@param ai AI
---@param st AISide
---@param u Unit
---@return boolean
local function builderMission(ai, st, u)
    local world, eco = ai.world, ai.world.eco
    local check = {}
    local any = false
    for _, code in ipairs(eco:constructionList(st.index)) do
        if st.bld[code] then check[code] = true any = true end
    end
    local node = any and bestNode(st, check)
    if node then
        if not canBuildNow(ai, st) then return false end
        local info = eco:itemInfo(node.code, st.index)
        if not info or not eco:canAfford(st.index, info.cost) then return false end
        local tx, ty = M.buildTarget(ai, st, node.code)
        -- spots a builder could not reach recently are skipped (the original checks the region map for this)
        local avoid = {}
        for _, f in ipairs(st.failedSpots) do
            if f.until_ > st.time then avoid[#avoid + 1] = f end
        end
        st.failedSpots = avoid
        local x, y = ai:findSpot(node.code, tx, ty, st.index, avoid)
        if not x then return false end
        ---@cast y -nil
        if #world:findPath(u, x, y) == 0 then
            avoid[#avoid + 1] = { gx = x, gy = y, until_ = st.time + 180000 }
            return false
        end
        u:orderBuild(node.code, x, y)
        if aidata.isTower(node.code) then
            st.potential[#st.potential + 1] = { gx = x, gy = y, until_ = st.time + 90000 }     -- FUN_004f9400
        end
        node.locked = true
        local rec = { u = u, code = node.code, t0 = st.time }
        st.builders[u] = rec
        st.builderList[#st.builderList + 1] = rec
        st.builtThisCycle = true
        return true
    end
    return false
end

-- Excess builders go into a mine with room (FUN_004fd940, the mine part).
---@param ai AI
---@param st AISide
---@param u Unit
---@param freeBuilders integer
---@return boolean
local function mineMission(ai, st, u, freeBuilders)
    if freeBuilders <= 2 then return false end
    if not u:canWorkInMine() or u:canWorkInMine() == 0 then return false end
    local a = st.army[u.code]
    if a and u.code == st.builderCode then
        if a.onMap + a.inProd <= 3 then return false end
    elseif a then
        if (u.type and u.type.hits or 0) >= 100 then return false end
    elseif u.hero then
        return false
    end
    local best, bestPri
    for _, m in ipairs(st.mines) do
        if m.owned and m.inMine + m.going < 8 and m.b.complete and not m.b.pillaged and not m.dry then
            local pri = math.floor((st.required[m.resource] or 0) / 4)
            pri = pri + math.max(0, 20 - math.floor(math.max(math.abs(u.gx - m.b.gx), math.abs(u.gy - m.b.gy)) / 4))
            pri = pri + dice(30)
            if not bestPri or pri > bestPri then best, bestPri = m, pri end
        end
    end
    if best then
        u:orderEnterMine(best.b)
        return true
    end
    return false
end

-- A building looks for something to produce.
---@param ai AI
---@param st AISide
---@param b Building
---@return boolean
local function productionMission(ai, st, b)
    local world, eco = ai.world, ai.world.eco
    local check = {}
    for _, code in ipairs(eco:productionList(b)) do
        local k = code:sub(1, 1)
        if k == "A" then
            local a = st.army[code]
            if a and a.avail then check[code] = true end
        elseif k == "P" or k == "R" then
            local p = st.pow[code]
            if p and p.canBeBuilt and not p.researched then check[code] = true end
        elseif k == "B" then
            -- the upgrade of this very building to the next level
            local d = aidata.level(b.code)
            if d and code == b.code:sub(1, 3) .. (d + 1) then check[code] = true end
        end
    end
    local node = bestNode(st, check)
    if not node then return false end
    local info = eco:itemInfo(node.code, st.index)
    if not info or not eco:canAfford(st.index, info.cost) then return false end
    if node.code:sub(1, 1) == "A" then
        local cur, max = eco:armyLimit(st.index)
        local t = gamedata.army(node.code)
        if cur + math.max(1, t and t.unitValue or 1) > max then return false end
    end
    eco:enqueue(b, node.code)
    M.updateTimestamp(st, node.code)
    return true
end

-- Missions (FUN_004f84a0, flag false): builders in progress (placing the building, then forgetting the node lock) ...
---@param ai AI
---@param st AISide
function M.continueMissions(ai, st)
    for k = #st.builderList, 1, -1 do
        local m = st.builderList[k]
        local u = m.u
        local node = M.findNode(st, m.code)
        local done = false
        if not u:alive() and not u.hidden then
            if node then node.locked = false end
            done = true
        elseif u.hidden then
            -- inside the construction site: the build went ahead
            M.updateTimestamp(st, m.code)
            done = true
        elseif not (u.task and u.task.kind == "build") or st.time - m.t0 > 90000 then
            if node then node.locked = false end
            done = true
            if u.task and u.task.kind == "build" then
                -- never got there: give the spot up for a while
                st.failedSpots[#st.failedSpots + 1] = { gx = u.task.gx, gy = u.task.gy, until_ = st.time + 180000 }
                u:stop()
            end
        end
        if done then
            st.builders[u] = nil
            table.remove(st.builderList, k)
        end
    end
end

-- ... and new missions for the idle ones (FUN_004f84a0 with flag true / FUN_004fd940)
---@param ai AI
---@param st AISide
---@param units Unit[]
---@param buildings Building[]
function M.startMissions(ai, st, units, buildings)
    local world = ai.world
    st.builtThisCycle = false
    -- production buildings first (they never block anything), then builders
    for _, b in ipairs(buildings) do
        if b.complete and not b.mine and not b.pillaged and not b.current and #b.queue == 0 and b.hp > 0
            and not economy.isMine(b.code) and (st.bld[b.code] or economy.isKeep(b.code)) then
            productionMission(ai, st, b)
        end
    end
    local free = 0
    for _, u in ipairs(units) do
        if u.code == st.builderCode and not (u.task and u.task.kind == "mine") then free = free + 1 end
    end
    for _, u in ipairs(units) do
        if u.code == st.builderCode or (not u.hero and u:canWorkInMine() > 0) then
            local group = st.groupOf[u]
            if (u.state == "idle" or group) and not st.builders[u] and not (u.task and u.task.kind) then
                local done = false
                if not u.hero and powerups.buildSkill(u) > 0 then
                    done = builderMission(ai, st, u)
                end
                if done then
                    ai.groups.removeUnit(st, u)
                elseif mineMission(ai, st, u, free) then
                    ai.groups.removeUnit(st, u)
                    free = free - 1
                end
            end
        end
    end
end

-- Setup -------------------------------------------------------------------------------------------------------------------

---@param ai AI
---@param st AISide
function M.setup(ai, st)
    local world, eco = ai.world, ai.world.eco
    local side = world.sides[st.index]
    local D = aidata.forRace(side.race)
    st.D = D
    st.level = side.aiLevel or 2
    st.builderCode = economy.BUILDER[side.race]
    st.bld, st.army, st.pow = {}, {}, {}
    st.list, st.required = {}, { gold = 0, metal = 0, crystal = 0, stone = 0 }
    st.res = {}
    st.mines, st.keeps = {}, {}
    st.builders, st.converting, st.groupOf, st.failedSpots, st.builderList = {}, {}, {}, {}, {}
    st.time = world.time
    -- what a builder may construct
    local buildable = {}
    for _, code in ipairs(eco:constructionList(st.index)) do buildable[code] = true end
    for _, b in ipairs(D.buildings) do
        local rec = { code = b.code, onMap = 0, being = 0, required = 0, between = -1,
                      buildable = buildable[b.code] == true or (aidata.level(b.code) or 0) > 0 }
        st.bld[b.code] = rec
        if aidata.isKeep(b.code) and aidata.level(b.code) == 0 then st.keepCode0 = b.code end
    end
    local params = st.params
    local useScript = params and params.raceData ~= nil and params.raceData ~= -1
    for _, a in ipairs(D.armies) do
        local pri = 50
        if useScript and params then pri = params.army[a.code] or -1 end
        st.army[a.code] = { code = a.code, pri = pri, off = 0, avail = false, onMap = 0, inProd = 0, between = -1,
                            titan = a.code:sub(1, 2) == "AT" and a.code:sub(4, 4) == "X" }
    end
    for _, p in ipairs(D.powerups) do
        local pri = 50
        if useScript and params then pri = params.powerup[p.code] or -1 end
        st.pow[p.code] = { code = p.code, pri = pri, researched = false, researching = false, canBeBuilt = false,
                           between = -1,
                           never = not powerups.exists(p.code) }
    end
    -- build script order: the auto-detected order, then (a script's priorities) by priority, a generic AI randomised
    local order = aidata.armyOrder(D, st.builderCode, buildable)
    local script = {}
    for _, code in ipairs(order) do
        if st.army[code].pri ~= -1 then script[#script + 1] = code end
    end
    if useScript then
        -- FUN_004fc7e0: repeatedly the unused army of the highest priority (earlier in the order on a tie)
        local sorted, used = {}, {}
        for _ = 1, #script do
            local bi
            for k, code in ipairs(script) do
                if not used[k] and (not bi or st.army[code].pri > st.army[script[bi]].pri) then bi = k end
            end
            if not bi then break end
            used[bi] = true
            sorted[#sorted + 1] = script[bi]
        end
        script = sorted
    else
        -- FUN_004fc8d0: some armies (never the first) get their priority shaken by 1d80 - 40 = -39..+40
        -- (dice FUN_00458e70(1, 80, -40)); the d100 share is drawn when the AI is set up (FUN_004f7830)
        local count = math.max(0, #script - 1)
        local random = math.random(1, 100)
        local maxRemove = math.max(1, math.floor(count * random / 100))
        local n = math.random(1, maxRemove) - 1
        local removed = {}
        for _ = 1, n do
            if count < 1 then break end
            local k
            repeat k = math.random(1, count) until not removed[k]
            removed[k] = true
            local code = script[k + 1]
            st.army[code].pri = st.army[code].pri + math.random(1, 80) - 40
        end
    end
    st.armyOrder = script
    local porder = {}
    for _, code in ipairs(aidata.powerupOrder(D)) do
        if st.pow[code].pri ~= -1 then porder[#porder + 1] = code end
    end
    st.powOrder = porder
    st.nextCalc = 0
    st.converterExists = true          -- starts true; the keep conversions (FUN_004fbb90) set it every 15 s
    st.listChanged = true
end

return M
