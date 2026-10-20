-- Save and load of a skirmish in progress. A save holds the scenario, the
-- state of the sides (resources), every building (construction, production,
-- mines), every living unit (position, life, hero progression, current order, order queue, patrol and guard duty),
-- items on the ground, the missiles in flight and the explored map. Not stored: a running conversion, spell casting, queued orders that refer
-- to something not saved, and the timed unit effects the original's army save record has no room for - the effects
-- that are kept are drunk, the immolation (fanatic is the original's type 2 ability, immol a fire hit's type 0 / 1,
-- berserk the Berserker spell's type 2), poison, disease and invisibility, plus a merge in progress.
-- The sacrifice cooldown is not stored: the original's is a real-time value of the command button code, not save data
-- (not traced in the 1.04 binary yet).
local ffi = require("ffi")
local serialize = require("src.core.serialize")
local log = require("src.core.log")

local M = { SLOTS = 8, VERSION = 1 }

local RES = require("src.content").resource:ids()

local function path(slot) return ("saves/slot%d.lua"):format(slot) end

-- Run-length coding of the explored bytes: alternating counts, starting with 0s.
local function rle(buf, n)
    local runs, cur, count = {}, 0, 0
    for i = 0, n - 1 do
        local v = buf[i] ~= 0 and 1 or 0
        if v == cur then count = count + 1
        else
            runs[#runs + 1] = count
            cur, count = v, 1
        end
    end
    runs[#runs + 1] = count
    return runs
end

local function unrle(runs, buf, n)
    local i, cur = 0, 0
    for _, c in ipairs(runs) do
        if cur == 1 then
            for k = i, math.min(n, i + c) - 1 do buf[k] = 1 end
        end
        i, cur = i + c, 1 - cur
    end
end

-- The timed unit effects the original keeps in a save (the army record of the .WB3 save, written by FUN_00445c20 and
-- read by FUN_00446150: the drunk flag and its expiry, the immolation fields, the poison and disease data, the
-- invisibility flag and its expiry, the psych bits and their timer for fear, terror, awe, chaos and the immunity
-- flag). Times are relative to the saved world time.
local function fxRecord(u, t)
    local f = u.fx
    if not f then return nil end
    local r
    for _, kind in ipairs({ "drunk", "fanatic", "immol", "berserk", "poison", "disease", "invis", "fear", "terror", "awe",
                           "chaos", "psychimmune" }) do
        local e = f[kind]
        if e then
            local s = { t1 = e.t1 - t }
            if e.nextTick then s.tick = e.nextTick - t end
            if e.t0 then s.t0 = e.t0 - t end
            if e.res then s.res = e.res end
            if e.oldAttitude then s.att = e.oldAttitude end
            if e.value then s.value = e.value end
            r = r or {}
            r[kind] = s
        end
    end
    return r
end

local function unitRecord(u, t)
    local r = { code = u.code, side = u.side, gx = u.gx, gy = u.gy, hp = u.hp, name = u.name, attitude = u.attitude,
                illusion = u.illusion, morphMod = u.morphMod, maxHp = u.maxHp }
    if u.mana then r.mana = u.mana end
    if u.ammo and u.ammo > 0 then r.ammo = u.ammo end          -- the Troll's sheep / the Catapult's cows
    if u.lastLeech then r.leech = u.lastLeech - t end         -- a Black Mage's mana leech pause
    if u.summonUntil then r.summon = u.summonUntil - t end     -- a timed summon or a Soul vanishes later
    if u.xp then r.xp, r.level = u.xp, u.level or 0 end
    if u.armorLoss then r.armorLoss = u.armorLoss end          -- the acid breath's armour reduction
    if u.retinueIndex then r.retinue = u.retinueIndex end
    if u.canRetinue then r.canRetinue = true end
    if u.wasHit then r.wasHit = true end                       -- the army's was-hit flag, read by the next attitude evaluation
    if u.formationType then r.fmType, r.fmDir = u.formationType, u.formationDir end   -- formation.lua: per army
    r.attSlice = u.attSlice                                    -- the attitude slice the unit was last evaluated in
    if u.cmdIn then r.cmdIn, r.cmdTimer = true, u.cmdTimer end     -- inside a hero's command radius
    if u.h then
        r.hero = u.h:save()
        r.kills = u.h.kills
        r.potions = { health = u.h.potions.health, mana = u.h.potions.mana }
    end
    local fx = fxRecord(u, t)
    if fx then r.fx = fx end
    return r
end

local function buildingRecord(world, b, t)
    local r = {
        code = b.code, side = b.side, x = b.x, y = b.y, hp = b.hp, maxHp = b.maxHp, name = b.name,
        anim = b.anim, dir = b.dir, complete = b.complete, queue = b.queue, rally = b.rally, waiting = b.waiting,
        continuous = b.continuous,
        destroyed = b.destroyed, rubble = b.rubbleSince and t - b.rubbleSince or nil,
        wreck = b.wreck, attitude = b.attitude,
        towerLevel = b.towerLevel, towerKind = b.towerKind,       -- the hero-level scaling of a starting tower
    }
    if b.pillaged then r.pillaged = b.pillaged - t end
    if b.seen then                                      -- the sides that have seen the building (the per-side seen flags)
        r.seen = {}
        for side = 0, 5 do if b.seen[side] then r.seen[#r.seen + 1] = side end end
    end
    if b.pathDanger and b.pathDanger ~= 0 then r.pathDanger = b.pathDanger end     -- the computer's safe search (its wait counter)
    if b.expireAt then r.expire = b.expireAt - t end
    if b.morphMod then r.morphMod = b.morphMod end
    if b.quest then
        r.quest = { state = b.quest.state, id = b.quest.id, prefix = b.quest.prefix, name = b.quest.name,
                    expiry = b.quest.expiry and b.quest.expiry - t or nil }
    end
    if b.lair then
        r.lair = { next = b.lair.next - t, activeTime = b.lair.activeTime - t }
    end
    if b.shop then
        r.shop = { items = b.shop.items, hatred = b.shop.hatred }
    end
    if b.repair then
        r.repair = { done = t - b.repair.t0, total = b.repair.t1 - b.repair.t0, hits = b.repair.total,
                     repaired = b.repair.done, speed = b.repair.speed }
    end
    if b.convert then
        r.convert = { done = t - b.convert.t0, total = b.convert.t1 - b.convert.t0, range = b.convert.range, hp = b.convert.hp }
    end
    if b.mine then r.mine ={ workers = b.mine.workers, reserve = b.mine.reserve } end
    if b.current then
        r.current = { code = b.current.code, cost = b.current.cost, name = b.current.name,
                      done = t - b.current.t0, total = b.current.t1 - b.current.t0, full = b.current.full }
    end
    if b.garrison and #b.garrison > 0 then
        r.garrison = {}
        for _, u in ipairs(b.garrison) do r.garrison[#r.garrison + 1] = unitRecord(u, t) end
    end
    if b.site then
        r.site = { done = t - b.site.t0, total = b.site.t1 - b.site.t0 }
        if b.site.builder then r.site.builder = unitRecord(b.site.builder, t) end
    end
    return r
end

-- Unit orders. Units and buildings are referred to by their index in the saved lists (ids are not kept over a load): a
-- reference is { ref = "u" | "b", i = index }; an order that refers to something that is not saved is dropped.
local function enc(v, uidx, bidx)
    local tv = type(v)
    if tv == "table" then
        if v.kind == "unit" then
            return uidx[v] and { ref = "u", i = uidx[v] } or nil, not uidx[v]
        elseif v.kind == "building" then
            return bidx[v] and { ref = "b", i = bidx[v] } or nil, not bidx[v]
        end
        local out = {}
        for k, x in pairs(v) do
            local e, bad = enc(x, uidx, bidx)
            if bad then return nil, true end
            out[k] = e
        end
        return out
    elseif tv == "function" or tv == "userdata" or tv == "thread" then
        return nil, true
    end
    return v
end

local function dec(v, ulist, blist)
    if type(v) ~= "table" then return v end
    if v.ref == "u" then return ulist[v.i], not ulist[v.i] end
    if v.ref == "b" then return blist[v.i], not blist[v.i] end
    local out = {}
    for k, x in pairs(v) do
        local e, bad = dec(x, ulist, blist)
        if bad then return nil, true end
        out[k] = e
    end
    return out
end

-- The order a unit is carrying out, its waiting queue, patrol and guard duty.
local function saveOrders(u, uidx, bidx)
    local cur
    -- a target that died this tick is no order any more (the way back, if any, is saved instead)
    local target = u.target
    if target and (target.kind == "unit" and not target:alive() or target.kind == "building" and target.hp <= 0) then
        target = nil
    end
    if u.task then cur = { kind = "task", task = u.task }
    elseif target then cur = { kind = "attack", target = target, auto = u.autoChase or nil }
    elseif u.goalX then
        -- auto / roam / running: a way back, random walk or flight of the unit's own attitude (attitude.lua)
        cur = { kind = "move", x = u.goalX, y = u.goalY, auto = u.autoChase or nil, roam = u.roaming or nil,
                running = u.running or nil }
    end
    local r = {}
    if cur then
        cur.pace = u.pace
        r.cur = enc(cur, uidx, bidx)
    end
    if u.queue and #u.queue > 0 then
        r.queue = {}
        for _, o in ipairs(u.queue) do
            local e = enc(o, uidx, bidx)           -- "fn" orders (closures) cannot be saved
            if e and o.kind ~= "fn" then r.queue[#r.queue + 1] = e end
        end
    end
    if u.patrol then r.patrol = { points = u.patrol.points, index = u.patrol.index, heading = u.patrol.heading } end
    if u.guarding and uidx[u.guarding] then r.guard = uidx[u.guarding] end
    if u.post then r.post = u.post end
    if u.att then r.att = { action = u.att.action, extra = u.att.extra, tx = u.att.tx, ty = u.att.ty } end
    if next(r) == nil then return nil end
    return r
end

local function restoreOrders(u, r, ulist, blist)
    if r.queue then
        u.queue = {}
        for _, o in ipairs(r.queue) do
            local d = dec(o, ulist, blist)
            if d then u.queue[#u.queue + 1] = d end
        end
        if #u.queue == 0 then u.queue = nil end
    end
    if r.patrol then
        u.patrol = { points = r.patrol.points, index = r.patrol.index, heading = r.patrol.heading }
    end
    if r.guard and ulist[r.guard] then u.guarding = ulist[r.guard] end
    u.post = r.post
    u.att = r.att
    if r.cur then
        local d = dec(r.cur, ulist, blist)
        if d then
            u:runOrder(d)
            if d.kind == "move" then u.autoChase, u.roaming, u.running = d.auto or false, d.roam or nil, d.running or nil end
        end
    end
end

-- Builds the save table for a running battle screen.
---@param battle BattleScreen
---@return table data the save (plain data for serialize)
function M.snapshot(battle)
    local world = battle.world
    local t = world.time
    local data = {
        version = M.VERSION, scn = battle.scnPath, random = battle.random, time = t, saved = os.time(),
        content = require("src.content.mods").describe(require("src.content")),      -- the mods the game was played with
        hero = (require("src.game.profile").current() or {}).id,      -- the active hero; Load Game lists only its saves
        title = battle.scn and battle.scn.header and battle.scn.header.name or battle.scnPath,
        opts = { player = world.player, resurrect = world.opts.resurrect, campaign = world.opts.campaign,
                 profile = world.opts.profile, heroRace = world.opts.heroRace, startPoints = world.opts.startPoints,
                 quests = world.opts.quests,
                 techLevel = world.techLevel, mods = world.mods, fogMode = battle.fogMode, victory = world.victoryRule,
                 advanced = world.advanced },
        speed = world.speed,
        victoryEnd = world.victoryEnd, victoryClock = world.clock and world.victoryEnd and { total = world.clock.total,
                                                                                              t0 = world.clock.t0 } or nil,
        camera = { x = battle.camX, y = battle.camY, zoom = battle.zoom },
        radius = battle.showRadius or nil,       -- the original saves the command radius display with the overlay
        eco = { income = world.eco.nextIncome - t },
        sides = {}, units = {}, buildings = {}, chests = {},
    }
    local bidx, byId = {}, {}
    for i, b in ipairs(world.buildings) do bidx[b] = i; byId[b.id] = i end
    for i = 0, 6 do
        local s = world.sides[i]
        local r = { race = s.race, defeated = s.defeated, resigned = s.resigned, fallenHero = s.fallenHero, powerups = s.powerups,
                    producedTitan = s.producedTitan, aiLevel = s.aiLevel, aiFile = s.aiFile, aiHero = s.aiHero,
                    questsCompleted = s.questsCompleted, spellBonus = s.spellBonus, knightsQuest = s.knightsQuest }
        for _, k in ipairs(RES) do r[k] = s[k] end
        if s.quest then
            -- the shrine the quest came from is kept by index: ids do not survive a load
            r.quest = { id = s.quest.id, prefix = s.quest.prefix, count = s.quest.count, name = s.quest.name,
                        expiry = s.quest.expiry - t, srcB = byId[s.quest.srcId], srcSide = s.quest.srcSide }
        end
        data.sides[i] = r
    end
    local uidx, saved = {}, {}
    for _, u in ipairs(world.units) do
        if u.state ~= "dead" and not u.hidden and not u.remove then
            saved[#saved + 1] = u
            uidx[u] = #saved
        end
    end
    for i, u in ipairs(saved) do
        data.units[i] = unitRecord(u, t)
        data.units[i].orders = saveOrders(u, uidx, bidx)
        if u.merge then
            -- a merge is stored as the leader's arrival count or the leader it vanishes into (by index)
            if u.merge.into then
                local ref = uidx[u.merge.into]
                if ref then data.units[i].merge = { into = ref } end
            else
                data.units[i].merge = { arrived = u.merge.arrived }
            end
        end
    end
    for _, b in ipairs(world.buildings) do data.buildings[#data.buildings + 1] = buildingRecord(world, b, t) end
    for _, c in ipairs(world.chests) do
        local ids
        if c.items then
            ids = {}
            for k, it in ipairs(c.items) do ids[k] = it.id end
        end
        data.chests[#data.chests + 1] = { id = c.item and c.item.id, ids = ids, resource = c.resource, gx = c.gx, gy = c.gy, dir = c.dir }
    end
    local ev = world.events
    data.events = { flags = ev.flags, flagMask = ev.flagMask, counters = ev.counters, stats = ev.stats, state = {} }
    if ev.clock then data.events.clock = { left = ev.clock.total - (world.time - ev.clock.t0), flag = ev.clock.flag } end
    for i, e in ipairs(ev.list) do
        data.events.state[i] = { fired = e.fired, done = e.done or false, next = e.next and (e.next - t) or nil }
    end
    data.night, data.raining = world.night or false, world.raining or false
    data.weather = require("src.game.weather").save(world)      -- storm, rain target, transition, timer
    data.ai = world.ai and world.ai.save and world.ai:save(uidx, bidx)       -- the computer players' lists, times and groups
    data.missiles = require("src.game.missiles").save(world, uidx, bidx)     -- the missiles in flight
    local attitude = require("src.game.attitude")
    data.attitude = { hits = attitude.saveHits(world, uidx, bidx), schedule = attitude.saveSchedule(world),
                      towers = attitude.saveTowers(world, uidx, bidx) }
    if world.sight then                                 -- the simulation's fog of the human sides (fog.lua)
        data.sight = {}
        for side = 0, 5 do
            local f = world.sight[side]
            if f and f.simSlice then
                data.sight[#data.sight + 1] = { side = side, slice = f.simSlice, explored = rle(f.explored, f.w * f.h),
                                                visible = rle(f.visible, f.w * f.h) }
            end
        end
    end
    data.stats = world.stats and world.stats.sides      -- kills, heroes slain ...: the end-of-battle experience reads them
    data.brought = world.brought                        -- retinue slots that came into the battle (who fell afterwards)
    data.fallen = world.fallen                          -- the retinue slots that fell and by whom (the killer the army records)
    local fog = world.fog
    if fog then data.explored = rle(fog.explored, fog.w * fog.h) end
    return data
end

local function restoreUnit(world, r)
    local u = world:addUnit(r.code, r.side, r.gx, r.gy, { name = r.name, level = r.level, xp = r.xp })
    if not u then return nil end
    u.canRetinue = r.canRetinue
    u.wasHit, u.attSlice = r.wasHit, r.attSlice
    u.formationType, u.formationDir = r.fmType, r.fmDir       -- absent in older saves: the defaults
    u.retinueIndex = r.retinue
    if r.hero then
        if not u.h then u:makeHero(r.hero) else u.h = require("src.game.hero").new(u, r.hero) end
        u.h.kills = r.kills or 0
        if r.potions then u.h.potions = { health = r.potions.health, mana = r.potions.mana } end
        if u.side == world.player and world.opts.profile then world:applyProfileHero(u) end     -- voice set, Ironman
    end
    u.attitude = r.attitude
    u.illusion, u.morphMod = r.illusion, r.morphMod
    if r.maxHp and not u.h then u.maxHp = r.maxHp end      -- illusions, Chaos morphs
    if r.mana then u.mana = r.mana end                     -- spellcasting troops keep their mana
    if r.ammo then u.ammo = r.ammo end
    if r.leech then u.lastLeech = world.time + r.leech end
    if r.summon then u.summonUntil = world.time + r.summon end
    if r.cmdIn then u.cmdIn, u.cmdTimer = true, r.cmdTimer end
    if r.xp then u.xp, u.level = r.xp, r.level or 0 end    -- plain troops keep their experience
    u.armorLoss = r.armorLoss
    if r.fx then
        local fx = {}
        for kind, s in pairs(r.fx) do
            local e = { t1 = world.time + s.t1 }
            if s.tick then e.nextTick = world.time + s.tick end
            if s.t0 then e.t0 = world.time + s.t0 end
            if s.res then e.res = s.res end
            if s.att then e.oldAttitude = s.att end
            if s.value then e.value = s.value end
            fx[kind] = e
        end
        u.fx = fx
    end
    u.hp = math.min(u.maxHp, r.hp or u.maxHp)
    if u.hp <= 0 then u.hp = 1 end
    return u
end

-- Fills a freshly created world (created with opts.restore) from a save.
---@param battle BattleScreen
---@param data table
function M.apply(battle, data)
    local world = battle.world
    local eco = world.eco
    world.time = data.time
    for i = 0, 6 do
        local r, s = data.sides[i], world.sides[i]
        if r and s then
            for _, k in ipairs(RES) do s[k] = r[k] or s[k] end
            s.defeated = r.defeated
            s.resigned = r.resigned
            s.fallenHero = r.fallenHero
            s.powerups = r.powerups
            s.spellBonus = r.spellBonus
            s.knightsQuest = r.knightsQuest
            s.producedTitan = r.producedTitan
            -- the AI level and script are the player's choice, not in the scenario file
            if r.aiLevel then s.aiLevel = r.aiLevel end
            s.aiFile = r.aiFile
            s.aiHero = require("src.game.aihero").clean(r.aiHero)
            local st = world.ai and world.ai.sides[i]
            if st then st.params = s.aiFile and require("src.game.aiparams").load(s.aiFile) or nil end
        end
    end
    if data.speed then world.speed = data.speed end                   -- the game speed of the battle (an older save: normal)
    world.victoryEnd = data.victoryEnd
    if data.victoryClock then world.clock = { total = data.victoryClock.total, t0 = data.victoryClock.t0 } end
    local ulist, blist = {}, {}
    for bi, r in ipairs(data.buildings) do
        local b = world:addBuilding({ code = r.code, side = r.side, x = r.x, y = r.y, anim = r.anim, dir = r.dir,
                                      name = r.name, towerLevel = r.towerLevel or 0, starting = r.towerKind == "start" })
        blist[bi] = b
        b.maxHp = r.maxHp or b.maxHp
        b.hp = r.hp
        b.complete = r.complete
        eco:initBuilding(b)
        b.complete = r.complete ~= false
        b.queue = r.queue or {}
        b.waiting = r.waiting
        b.continuous = r.continuous
        b.rally = r.rally
        b.attitude = r.attitude
        b.destroyed = r.destroyed
        if r.quest then
            b.quest = { state = r.quest.state, id = r.quest.id, prefix = r.quest.prefix, name = r.quest.name,
                        expiry = r.quest.expiry and world.time + r.quest.expiry or nil }
        end
        if r.lair then
            b.lair = { next = world.time + r.lair.next,
                       activeTime = r.lair.activeTime and world.time + r.lair.activeTime or nil }
        end
        if r.shop and b.shop then
            b.shop.items = r.shop.items
            b.shop.hatred = r.shop.hatred
        end
        if r.mine and b.mine then b.mine.workers, b.mine.reserve = r.mine.workers, r.mine.reserve end
        if r.pillaged then b.pillaged = world.time + r.pillaged end
        if r.seen then
            b.seen = {}
            for _, side in ipairs(r.seen) do b.seen[side] = true end
        end
        b.pathDanger = r.pathDanger
        if r.expire then b.expireAt = world.time + r.expire end
        b.morphMod = r.morphMod
        if r.repair then
            local p = r.repair
            b.repair = { t0 = world.time - p.done, t1 = world.time - p.done + p.total, total = p.hits, done = p.repaired,
                         speed = p.speed }
        end
        if r.convert then
            local c = r.convert
            b.convert = { t0 = world.time - c.done, t1 = world.time - c.done + c.total, range = c.range, hp = c.hp }
        end
        if r.current then
            local c = r.current
            b.current = { code = c.code, cost = c.cost, name = c.name, t0 = world.time - c.done,
                          t1 = world.time - c.done + c.total, full = c.full }
        end
        if r.site then
            b.site = { t0 = world.time - r.site.done, t1 = world.time - r.site.done + r.site.total }
            if r.site.builder then
                local u = restoreUnit(world, r.site.builder)
                if u then
                    b.site.builder = u
                    u:vanish()
                end
            end
        end
        for _, gr in ipairs(r.garrison or {}) do
            local u = restoreUnit(world, gr)
            if u then
                b.garrison = b.garrison or {}
                b.garrison[#b.garrison + 1] = u
                u.garrisoned = b
                u:vanish()
            end
        end
        if r.rubble then
            b.rubbleSince = world.time - r.rubble
            b.wreck = r.wreck
            if b.shape then world:blockShape(b.gx, b.gy, b.shape, false) end
        end
    end
    -- a side's quest names its shrine by index into the saved buildings, so it can be re-pointed
    for i = 0, 6 do
        local r, s = data.sides[i], world.sides[i]
        if r and r.quest and s then
            local src = blist[r.quest.srcB]
            if src then
                s.quest = { id = r.quest.id, prefix = r.quest.prefix, count = r.quest.count, name = r.quest.name,
                            expiry = world.time + r.quest.expiry, srcId = src.id, srcSide = src.side }
            end
        end
    end
    for ui, r in ipairs(data.units) do ulist[ui] = restoreUnit(world, r) end
    -- a merge in progress: the leader keeps its arrival count, the followers point at their leader
    for ui, r in ipairs(data.units) do
        if r.merge and ulist[ui] then
            if r.merge.into and ulist[r.merge.into] then
                ulist[ui].merge = { into = ulist[r.merge.into] }
            elseif r.merge.arrived then
                ulist[ui].merge = { arrived = r.merge.arrived }
            end
        end
    end
    -- orders last: they refer to other units and buildings
    for ui, r in ipairs(data.units) do
        if r.orders and ulist[ui] then restoreOrders(ulist[ui], r.orders, ulist, blist) end
    end
    -- the missiles in flight (an older save has none); their handlers sit in the modules that fire them
    require("src.game.spells")
    require("src.game.buildingabilities")
    require("src.game.missiles").restore(world, data.missiles, ulist, blist)
    local items = require("src.game.items")
    for _, c in ipairs(data.chests) do
        if c.resource then world:dropResource(c.gx, c.gy, c.resource, c.dir)
        elseif c.ids then
            local list = {}
            for _, id in ipairs(c.ids) do list[#list + 1] = items.get(id) end
            world:dropChest(c.gx, c.gy, list, c.dir)
        else world:dropItem(c.gx, c.gy, items.get(c.id), c.dir) end
    end
    if data.events then
        local ev = world.events
        ev.flags, ev.counters = data.events.flags or {}, data.events.counters or {}
        ev.flagMask = data.events.flagMask or 0
        ev.stats = data.events.stats or ev.stats
        local ck = data.events.clock
        if ck then
            ev.clock = { total = ck.left, t0 = world.time, flag = ck.flag }
            world.clock = ev.clock
        end
        for i, st in ipairs(data.events.state or {}) do
            local e = ev.list[i]
            if e then
                e.fired, e.done = st.fired, st.done or nil
                if st.next then e.next = world.time + st.next end
            end
        end
    end
    if data.weather then
        require("src.game.weather").load(world, data.weather)
    else                                                -- an older save: day / night and rain only
        world.night, world.raining = data.night or false, data.raining or false
        world.rainTarget = world.raining and require("src.game.weather").NEW_RAIN or 0
        world.rainDrops, world.rainBase, world.rainEnding = world.rainTarget, world.rainTarget, false
    end
    if data.ai and world.ai and world.ai.restore then world.ai:restore(data.ai, ulist, blist) end
    if data.attitude then                                   -- the attitude slice schedule and the hit list (4 s of hits)
        local attitude = require("src.game.attitude")
        attitude.restoreSchedule(world, data.attitude.schedule)
        attitude.restoreHits(world, data.attitude.hits, ulist, blist)
        attitude.restoreTowers(world, data.attitude.towers, ulist, blist)
    end
    for _, r in ipairs(data.sight or {}) do
        local f = require("src.game.fog").sightOf(world, r.side)
        if f then
            unrle(r.explored, f.explored, f.w * f.h)
            unrle(r.visible, f.visible, f.w * f.h)
            f.simSlice = r.slice
        end
    end
    if data.stats then world:battleStats().sides = data.stats end
    if data.brought then world.brought = data.brought end
    if data.fallen then world.fallen = data.fallen end
    eco.nextIncome = world.time + (data.eco and data.eco.income or 0)
    eco.nextVictory = world.time + 3000
    if data.explored and world.fog then
        unrle(data.explored, world.fog.explored, world.fog.w * world.fog.h)
    end
    battle.restoreCamera = data.camera
    battle.restoreRadius = data.radius
end

-- Files ------------------------------------------------------------------------------

---@param slot integer
---@param data table
---@return boolean
function M.write(slot, data)
    love.filesystem.createDirectory("saves")
    local ok, err = love.filesystem.write(path(slot), serialize.encode(data))
    if not ok then log.warn("save failed: %s", tostring(err)) end
    return ok
end

---@param slot integer
---@return table?
function M.read(slot)
    if not love.filesystem.getInfo(path(slot)) then return nil end
    local data = serialize.decode(love.filesystem.read(path(slot)) or "")
    if not data or data.version ~= M.VERSION then return nil end
    return data
end

---@param slot integer
function M.delete(slot) love.filesystem.remove(path(slot)) end

-- Deletes the saved games of a hero (the original keeps one `<hero>.wb3` per hero and deletes it when a battle gave the
-- hero experience, so a lost fight cannot be replayed from it); returns how many slots were removed.
---@param id string?
---@return integer
function M.deleteForHero(id)
    local n = 0
    if not id then return 0 end
    for i = 1, M.SLOTS do
        local d = M.read(i)
        if d and d.hero == id then
            M.delete(i)
            n = n + 1
        end
    end
    return n
end

-- Short descriptions of all slots (nil = empty) for the slot list.
---@return ({title: string?, time: number, saved: number, hero: string?}|false)[]
function M.list()
    local out = {}
    for i = 1, M.SLOTS do
        local d = M.read(i)
        out[i] = d and { title = d.title, time = d.time, saved = d.saved, hero = d.hero } or false
    end
    return out
end

-- Whether the saved game fits the content that is loaded: units and spells of a mod are looked up by their ids, so the same mods (and the
-- same files) must be loaded. Saves from before the mod runtime count as made with the original content. Returns true or false, text.
---@param data table
---@return boolean
---@return string? why
function M.fits(data)
    local content = require("src.content")
    local mods = require("src.content.mods")
    local theirs = data.content or { hash = nil, mods = {} }
    if not data.content then
        local any
        for _, m in ipairs(mods.loaded()) do if m.scope ~= "cosmetic" then any = true end end
        if not any then return true end
        return false, "saved without mods, but mods are loaded now"
    end
    return mods.compare(theirs, content)
end

-- Starts a battle from a save (pushes the battle screen). Returns false and a text when it cannot.
---@param slot integer
---@return boolean
---@return string? why
function M.start(slot)
    local data = M.read(slot)
    if not data then return false end
    local fits, why = M.fits(data)
    if not fits then
        log.warn("save: slot %d does not fit the loaded content: %s", slot, tostring(why))
        return false, why
    end
    local boot = require("src.game.boot")
    -- a random map is made again from its seed and settings
    local scn = data.random and require("src.game.randommap").build(data.random) or boot.loadScenario(data.scn)
    if not scn then
        log.error("save: scenario %s not found", tostring(data.scn))
        return false
    end
    for i = 0, 5 do
        local r = data.sides[i]
        if r and scn.sides and scn.sides[i] then scn.sides[i].race = r.race end
    end
    local opts = data.opts or {}
    opts.restore = data
    opts.scnPath = data.scn
    opts.random = data.random
    require("src.core.screens").push(require("src.screens.battle"), scn, opts)
    return true
end

return M
