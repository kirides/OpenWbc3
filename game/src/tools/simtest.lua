-- Headless simulation check: `love game --selftest --sim <scenario> [ai]`.
-- With "ai" every side is computer controlled and the run lasts 10 game minutes.
local log = require("src.core.log")

local M = {}

-- A battle screen stand-in for savegame.snapshot / apply, which read only the world, the scenario path and the camera.
---@param t table
---@return BattleScreen
local function asBattle(t) return t --[[@as BattleScreen]] end

-- Two minutes of an all-AI game on every scenario of the install; logs the ones that raise an error.
function M.runAll()
    local config = require("src.core.config")
    local fs = require("src.core.fs")
    local failures = 0
    for _, dir in ipairs({ "Scenario", "CampaignScenario" }) do
        for _, name in ipairs(fs.list(config.gamedir .. "/" .. dir, "%.scn$")) do
            local ok, err = pcall(M.run, dir .. "/" .. name, "ai", 2, true)
            if not ok then
                failures = failures + 1
                log.error("%s: %s", name, tostring(err))
            end
        end
    end
    log.info("all scenarios: %d failures", failures)
end

-- Save / load round trip: simulate, snapshot, serialize, rebuild, compare, keep simulating.
---@param name string? scenario (default Bridges)
function M.saveLoad(name)
    local boot = require("src.game.boot")
    local savegame = require("src.game.savegame")
    local serialize = require("src.core.serialize")
    name = name or "Bridges"
    local function make(restore)
        local s = assert(boot.loadScenario(name))
        -- the advanced options travel in the save (the battle screen hands data.opts to the world)
        local w = require("src.game.world").new(s, { player = 99, restore = restore,
            advanced = restore and restore.opts.advanced or { toughTowers = true, noItems = true, aiResign = true, resignKills = false } })
        w.ai = require("src.game.ai").new(w)
        return w, s
    end
    local world = make()
    world.speed = 1.5
    for _ = 1, 30 * 120 do world:update(1 / 30) end
    -- a night storm with a day / night change under way must come back as it was
    local weather = require("src.game.weather")
    world.randomWeather = true
    weather.spell(world, 5)
    -- drag-built walls: the builder's order queue (one build order per section) must come back
    local wallBuilder
    for _, u in ipairs(world.units) do
        if not wallBuilder and u.side < 6 and u:alive() and not u.hero and not u.hidden
            and require("src.game.powerups").buildSkill(u) > 0 then wallBuilder = u end
    end
    if wallBuilder then
        local sections = {}
        for i = 1, 3 do sections[i] = { code = "BWG0", gx = wallBuilder.gx + 2 * i, gy = wallBuilder.gy + 3 } end
        require("src.game.commands").apply(world, { t = "build", side = wallBuilder.side, id = wallBuilder.id,
                                                    sections = sections })
    end
    -- a missile in flight (a fireball over the whole map) must come back with its flight
    local shooter, victim
    for _, u in ipairs(world.units) do
        if u.side < 6 and u:alive() and not u.hidden then
            if not shooter then shooter = u elseif not victim and world:enemies(shooter.side, u.side) then victim = u end
        end
    end
    if shooter and victim then
        require("src.game.missiles").launch(world, { code = "EMF0", kind = "unit", shooter = shooter, side = shooter.side,
                                                      target = victim, x0 = shooter.x, y0 = shooter.y - 20, roll = 1 })
        world.missiles[#world.missiles].nextT = world.time + 200
    end
    -- the attitude hit list (a hit of a second ago) and the evaluation schedule must come back
    if shooter and victim then
        world.hitList = { { inf = shooter, vic = victim, t = world.time - 1000 } }
        world.hitProcessed = world.time - 300
        victim.wasHit = true
    end
    -- the formation type / direction of an army (formation.lua) must come back with the unit
    local fmUnit
    if shooter then fmUnit = shooter; shooter.formationType, shooter.formationDir = 5, 3 end
    local snap = savegame.snapshot(asBattle({ world = world, scnPath = name, camX = 0, camY = 0, zoom = 1 }))
    local data = serialize.decode(serialize.encode(snap))
    assert(data, "snapshot does not survive serialization")
    local w2 = make(data)
    savegame.apply(asBattle({ world = w2 }), data)
    if wallBuilder then
        local found
        for _, u in ipairs(w2.units) do
            if u.queue and #u.queue == 2 and u.queue[2].kind == "build" and u.queue[2].code == "BWG0"
                and u.queue[2].gx == wallBuilder.gx + 6 and u.task and u.task.kind == "build" then found = true end
        end
        assert(found, "save/load lost the queued wall sections")
        log.info("save/load: queued wall sections 3/3")
    end
    local function count(w)
        local u, b = 0, 0
        for _, x in ipairs(w.units) do if x.state ~= "dead" and not x.hidden and not x.remove then u = u + 1 end end
        for _, x in ipairs(w.buildings) do if x.hp > 0 then b = b + 1 end end
        return u, b, w.sides[0].gold
    end
    assert(weather.state(w2) == weather.state(world) and w2.lightning == world.lightning and w2.rainTarget == world.rainTarget
        and w2.rainDrops == world.rainDrops and w2.rainEnding == world.rainEnding
        and w2.randomWeather and w2.weatherAt == world.weatherAt and (w2.shift ~= nil) == (world.shift ~= nil),
        "save/load lost the weather")
    log.info("save/load: weather state %d, target %d", weather.state(w2), w2.rainTarget)
    if fmUnit then
        local u2
        for _, u in ipairs(w2.units) do
            if u.formationType == 5 and u.formationDir == 3 and u.code == fmUnit.code and u.side == fmUnit.side then u2 = u end
        end
        assert(u2, "save/load lost the formation of an army")
        log.info("save/load: army formation kept")
    end
    assert(w2.speed == 1.5, "save/load lost the game speed")
    assert(w2.attSlice == world.attSlice and w2.attAi == world.attAi and w2.attNext - w2.time == world.attNext - world.time,
        "save/load lost the attitude slice schedule")
    if shooter and victim then
        local h = w2.hitList and w2.hitList[1]
        assert(h and #w2.hitList == 1 and h.t == w2.time - 1000 and h.inf.side == shooter.side and h.vic.side == victim.side
            and w2.hitProcessed == w2.time - 300, "save/load lost the attitude hit list")
        log.info("save/load: attitude hit list and slice %d kept", w2.attSlice)
    end
    assert(w2.advanced.toughTowers and w2.advanced.noItems and w2.advanced.aiResign and not w2.advanced.resignKills
        and not w2.advanced.tournament and w2.advanced.points == world.advanced.points, "save/load lost the advanced options")
    log.info("save/load: game speed %.2f, advanced options kept", w2.speed)
    assert(#w2.missiles == #world.missiles, "save/load lost the missiles in flight")
    for i, m in ipairs(world.missiles) do
        local r = w2.missiles[i]
        assert(r and r.code == m.code and r.frame == m.frame and r.maxSteps == m.maxSteps and r.nextT == m.nextT
            and (r.shooter == nil) == (m.shooter == nil), "save/load changed a missile")
    end
    log.info("save/load: %d missiles in flight kept", #w2.missiles)
    local u1, b1, g1 = count(world)
    local u2, b2, g2 = count(w2)
    log.info("save/load: units %d/%d buildings %d/%d gold %d/%d", u1, u2, b1, b2, g1, g2)
    assert(u1 == u2 and b1 == b2 and g1 == g2, "save/load mismatch")
    -- computer players: resource list, build timing, army data and groups come back
    do
        local function aiState(w)
            local out = {}
            for i = 0, 5 do
                local st = w.ai.sides[i]
                if st and st.D then
                    local codes, members = {}, 0
                    for _, n in ipairs(st.list) do codes[#codes + 1] = n.code .. ":" .. n.pri .. ":" .. n.off end
                    for _, g in ipairs(st.groups) do members = members + #g.members end
                    local armies = 0
                    for _, a in pairs(st.army) do armies = armies + a.pri + (a.between or 0) end
                    out[#out + 1] = ("s%d [%s] groups %d members %d base %s,%s army %d"):format(i, table.concat(codes, " "),
                        #st.groups, members, tostring(st.baseX), tostring(st.baseY), armies)
                end
            end
            return table.concat(out, "|")
        end
        local a1, a2 = aiState(world), aiState(w2)
        log.info("save/load: computer player state %s", a2)
        assert(a1 == a2 and a1 ~= "", "save/load lost the computer players' state: " .. a1 .. " vs " .. a2)
    end
    -- orders: every unit that was moving, attacking or working on a task, or had queued orders, patrol or guard duty,
    -- must still have them
    local function orders(w)
        local n = 0
        for _, x in ipairs(w.units) do
            if x.state ~= "dead" and not x.hidden and not x.remove
                and (x.goalX or x.target or x.task or (x.queue and #x.queue > 0) or x.patrol or x.guarding) then
                n = n + 1
            end
        end
        return n
    end
    -- plant a queue, a patrol and a guard duty on the first own units so that the round trip has something to keep
    local planted = 0
    local mine = {}
    for _, x in ipairs(world.units) do if x.side == 0 and x:alive() and not x.hero then mine[#mine + 1] = x end end
    if #mine >= 3 then
        mine[1]:orderMove(mine[1].gx + 3, mine[1].gy)
        mine[1]:enqueue({ kind = "move", x = mine[1].gx + 6, y = mine[1].gy })
        mine[2]:setPatrol({ { mine[2].gx + 4, mine[2].gy } })
        mine[3]:setGuard(mine[1])
        mine[1].ammo = 3                                      -- a Troll's sheep / a Catapult's cows
        mine[2].summonUntil = world.time + 50000              -- a timed summon / a Soul
        planted = 3
        snap = savegame.snapshot(asBattle({ world = world, scnPath = name, camX = 0, camY = 0, zoom = 1 }))
        data = serialize.decode(serialize.encode(snap))
        w2 = make(data)
        savegame.apply(asBattle({ world = w2 }), data)
    end
    local o1, o2 = orders(world), orders(w2)
    log.info("save/load: units with orders %d/%d (%d planted)", o1, o2, planted)
    assert(o1 == o2, "save/load lost unit orders")
    local function specials(w)
        local ammo, timed, left = 0, 0, 0
        for _, x in ipairs(w.units) do
            if x.state ~= "dead" and not x.hidden and not x.remove then
                ammo = ammo + (x.ammo or 0)
                if x.summonUntil then timed, left = timed + 1, left + x.summonUntil - w.time end
            end
        end
        return ammo, timed, left
    end
    local a1, t1, l1 = specials(world)
    local a2, t2, l2 = specials(w2)
    log.info("save/load: ammunition %d/%d, timed units %d/%d", a1, a2, t1, t2)
    assert(a1 == a2 and t1 == t2 and math.abs(l1 - l2) < 1, "save/load lost ammunition or unit timers")
    -- retinue: a troop's level (with its hits), the retinue slot, the recruit flag and the brought slots come back
    if #mine >= 3 then
        local v = mine[3]
        v:addXp(70)
        v.retinueIndex, v.canRetinue = 2, true
        world.brought = { [0] = { [2] = true } }
        local snap3 = savegame.snapshot(asBattle({ world = world, scnPath = name, camX = 0, camY = 0, zoom = 1 }))
        local data3 = serialize.decode(serialize.encode(snap3))
        local w3 = make(data3)
        savegame.apply(asBattle({ world = w3 }), data3)
        local found
        for _, x in ipairs(w3.units) do
            if x.retinueIndex == 2 and x.side == 0 then found = x end
        end
        assert(found and found.level == v.level and found.xp == v.xp and found.maxHp == v.maxHp and found.canRetinue
            and w3.brought[0] and w3.brought[0][2], "save/load lost the retinue data of a unit")
        log.info("save/load: retinue slot, level %d, hits %d and recruit flag kept", found.level, found.maxHp)
    end
    -- the acid breath's armour reduction and the evil breath's drained hero experience come back
    do
        local v, hero
        for _, x in ipairs(world.units) do
            if x.state ~= "dead" and not x.hidden and not x.remove then
                if x.hero and not hero then hero = x elseif not x.hero and not v then v = x end
            end
        end
        if v and hero and hero.h then
            v.armorLoss = 6
            hero.h.xp = math.max(0, require("src.game.hero").xpFor(hero.h.level) - 7)
            local snap5 = savegame.snapshot(asBattle({ world = world, scnPath = name, camX = 0, camY = 0, zoom = 1 }))
            local data5 = serialize.decode(serialize.encode(snap5))
            local w5 = make(data5)
            savegame.apply(asBattle({ world = w5 }), data5)
            local lost, drained = 0, false
            for _, x in ipairs(w5.units) do
                if x.armorLoss == 6 then lost = lost + 1 end
                if x.hero and x.side == hero.side and x.h and x.h.xp == hero.h.xp then drained = true end
            end
            assert(lost == 1 and drained, "save/load lost an armour reduction or drained experience")
            log.info("save/load: armour reduction and drained hero experience kept")
            v.armorLoss, hero.h.xp = nil, require("src.game.hero").xpFor(hero.h.level)
        end
    end
    -- retinue: the fallen slots and their killers (recorded by FUN_00520e60) come back
    do
        world.fallen = { [0] = { [3] = "AOMX", [4] = "" } }
        local snap4 = savegame.snapshot(asBattle({ world = world, scnPath = name, camX = 0, camY = 0, zoom = 1 }))
        local data4 = serialize.decode(serialize.encode(snap4))
        local w4 = make(data4)
        savegame.apply(asBattle({ world = w4 }), data4)
        assert(w4.fallen[0] and w4.fallen[0][3] == "AOMX" and w4.fallen[0][4] == "", "save/load lost who killed a retinue member")
        log.info("save/load: fallen retinue members and their killers kept")
    end
    -- psych effects (psych.lua): chaos, terror and the immunity flag keep their remaining time
    do
        local v
        for _, x in ipairs(world.units) do
            if x.state ~= "dead" and not x.hero and not x.hidden and not x.remove then v = x break end
        end
        if v then
            v.fx = v.fx or {}
            v.fx.chaos = { t1 = world.time + 20000 }
            v.fx.psychimmune = { t1 = world.time + 25000 }
            local snap4 = savegame.snapshot(asBattle({ world = world, scnPath = name, camX = 0, camY = 0, zoom = 1 }))
            local data4 = serialize.decode(serialize.encode(snap4))
            local w4 = make(data4)
            savegame.apply(asBattle({ world = w4 }), data4)
            local found
            for _, x in ipairs(w4.units) do
                if x.code == v.code and x.side == v.side and x.gx == v.gx and x.gy == v.gy and x.fx and x.fx.chaos then
                    found = x
                end
            end
            assert(found and math.abs(found.fx.chaos.t1 - w4.time - 20000) < 1 and found.fx.psychimmune
                and math.abs(found.fx.psychimmune.t1 - w4.time - 25000) < 1, "save/load lost a psych effect")
            log.info("save/load: chaos and psych immunity timers kept")
            v.fx.chaos, v.fx.psychimmune = nil, nil
            if next(v.fx) == nil then v.fx = nil end
        end
    end
    -- one-shot power-ups: the research bonus of the battle and the chosen Knight's Quest foes come back
    do
        local pu = require("src.game.powerups")
        for i = 0, 5 do
            if world.sides[i].used and world.eco:heroAlive(i) then pu.research(world, i, 3) break end
        end
        pu.chooseFoe(world, 0, 1)
        pu.chooseFoe(world, 0, 3)
        snap = savegame.snapshot(asBattle({ world = world, scnPath = name, camX = 0, camY = 0, zoom = 1 }))
        data = serialize.decode(serialize.encode(snap))
        w2 = make(data)
        savegame.apply(asBattle({ world = w2 }), data)
        local function research(w)
            local out = {}
            for i = 0, 5 do
                local n = 0
                for sph = 0, 12 do n = n + pu.spellBonus(w.sides[i], sph) end
                out[#out + 1] = n .. ":" .. table.concat(pu.questFoes(w.sides[i]), ",")
            end
            return table.concat(out, " ")
        end
        log.info("save/load: research and quest foes %s / %s", research(world), research(w2))
        assert(research(world) == research(w2), "save/load lost research or Knight's Quest foes")
        assert(research(world):find("2:") and #pu.questFoes(w2.sides[0]) == 2, "research or quest test did not run")
        local h1, h2 = world.eco:heroAlive(0), w2.eco:heroAlive(0)
        if h1 and h2 then
            local sp = require("src.game.spells")
            for sph = 0, 12 do
                assert(sp.castSkill(h1.h, sph) == sp.castSkill(h2.h, sph), "save/load lost the research casting skill")
            end
        end
    end
    -- the simulation's fog of a human side (fog.lua) and the towers' targets: explored / visible cells, the buildings seen
    -- and the tower targets come back as they were
    do
        local fogs = require("src.game.fog")
        world.opts.fogMode = 1
        world.attSlice = (world.attSlice or 0) + 1
        local f1 = fogs.refresh(world, 0)
        local tower, victim
        for _, b in ipairs(world.buildings) do
            if b.hp > 0 and b.side == 1 and not tower then tower = b end
        end
        for _, u in ipairs(world.units) do
            if u.side == 0 and u:alive() and not victim then victim = u end
        end
        if tower and victim then tower.target, tower.targetSide, tower.nextShot, tower.attSlice = victim, victim.side, world.time + 777, 5 end
        local snapF = savegame.snapshot(asBattle({ world = world, scnPath = name, camX = 0, camY = 0, zoom = 1,
            fogMode = 1 }))
        local dataF = serialize.decode(serialize.encode(snapF))
        local wF = require("src.game.world").new(assert(boot.loadScenario(name)), { player = 99, restore = dataF, fogMode = 1,
            advanced = dataF.opts.advanced })
        wF.ai = require("src.game.ai").new(wF)
        savegame.apply(asBattle({ world = wF }), dataF)
        local f2 = wF.sight and wF.sight[0]
        assert(f1 and f2 and f2.simSlice == f1.simSlice, "save/load lost the simulation's fog")
        local ex, vis, ex2, vis2, seen, seen2 = 0, 0, 0, 0, 0, 0
        for i = 0, f1.w * f1.h - 1 do
            if f1.explored[i] ~= 0 then ex = ex + 1 end
            if f1.visible[i] ~= 0 then vis = vis + 1 end
            if f2.explored[i] ~= 0 then ex2 = ex2 + 1 end
            if f2.visible[i] ~= 0 then vis2 = vis2 + 1 end
        end
        for _, b in ipairs(world.buildings) do if b.seen and b.seen[0] and b.hp > 0 then seen = seen + 1 end end
        for _, b in ipairs(wF.buildings) do if b.seen and b.seen[0] and b.hp > 0 then seen2 = seen2 + 1 end end
        log.info("save/load: fog explored %d/%d, visible %d/%d, buildings seen %d/%d", ex, ex2, vis, vis2, seen, seen2)
        assert(ex == ex2 and vis == vis2 and ex > 0 and seen == seen2 and seen > 0, "save/load changed the simulation's fog")
        if tower and victim then
            local t2, tb
            for _, b in ipairs(wF.buildings) do
                if b.target and b.side == 1 and b.gx == tower.gx and b.gy == tower.gy then t2, tb = b.target, b end
            end
            assert(t2 and t2.code == victim.code and t2.gx == victim.gx and t2.gy == victim.gy, "save/load lost a tower's target")
            assert(tb.targetSide == victim.side and tb.attSlice == 5 and tb.nextShot - wF.time == 777,
                "save/load lost a tower's shot timer or slice")
            log.info("save/load: tower target kept")
        end
        world.opts.fogMode, world.sight = nil, nil
        for _, b in ipairs(world.buildings) do b.seen = nil end
    end
    for _ = 1, 30 * 120 do w2:update(1 / 30) end
    log.info("save/load: restored world ran 2 more minutes, %d units", #w2.units)
end

-- One simulation: `name` is a scenario, "all" (M.runAll) or "saveload" (M.saveLoad of the scenario in `mode`); `mode`
-- "ai" (every side a computer player, 10 minutes), "storm" (a forced night storm, 8 minutes) or nil (side 0 attacks
-- the nearest enemy, 1 minute).
---@param name string?
---@param mode string?
---@param minutesOverride number?
---@param quiet boolean? no progress lines
function M.run(name, mode, minutesOverride, quiet)
    if name == "all" then return M.runAll() end
    if name == "saveload" then return M.saveLoad(mode) end
    local boot = require("src.game.boot")
    local s = assert(boot.loadScenario(name or "Bridges"))
    local world = require("src.game.world").new(s, { player = mode == "ai" and 99 or 0, randomWeather = mode == "storm" })
    world.ai = require("src.game.ai").new(world)
    if mode == "storm" then require("src.game.weather").spell(world, 5) end      -- a forced night storm, random weather on
    local minutes = minutesOverride or (mode == "ai" and 10) or (mode == "storm" and 8) or 1
    if mode ~= "ai" then
        local mine = {}
        for _, u in ipairs(world.units) do if u.side == 0 then mine[#mine + 1] = u end end
        local target, bestD
        for _, u in ipairs(world.units) do
            if world:enemies(0, u.side) then
                local d = (u.x - mine[1].x) ^ 2 + (u.y - mine[1].y) ^ 2
                if not bestD or d < bestD then target, bestD = u, d end
            end
        end
        for _, u in ipairs(mine) do u:orderAttack(target) end
    end
    world:listen(function(kind, a, b)
        if kind == "defeated" or kind == "gameover" then log.info("t=%ds event %s %s", world.time / 1000, kind, tostring(type(a) == "table" and table.concat(a, ",") or a)) end
    end)
    local t0 = os.clock()
    for step = 1, 30 * 60 * minutes do
        world:update(1 / 30)
        if step % (30 * 60) == 0 and not quiet then
            local parts = {}
            for i = 0, 5 do
                local sd = world.sides[i]
                if sd.used then
                    local units, blds, workers = 0, 0, 0
                    for _, u in ipairs(world.units) do if u.side == i and u:alive() then units = units + 1 end end
                    for _, b in ipairs(world.buildings) do
                        if b.side == i and b.hp > 0 then
                            blds = blds + 1
                            if b.mine then workers = workers + b.mine.workers end
                        end
                    end
                    local hero = world.eco:heroAlive(i)
                    local hs = hero and hero.h and ("L%d/%dxp k%d i%d"):format(hero.h.level, hero.h.xp, hero.h.kills,
                        #hero.h.pack + (function() local n = 0 for _ in pairs(hero.h.equipped) do n = n + 1 end return n end)()) or "-"
                    parts[#parts + 1] = ("s%d[%s] u%d b%d w%d g%d H(%s)"):format(i, sd.defeated and "X" or "", units, blds, workers, sd.gold, hs)
                end
            end
            log.info("t=%dmin %s", world.time / 60000, table.concat(parts, " | "))
        end
        if world.over then break end
    end
    if mode == "storm" then
        local weather = require("src.game.weather")
        log.info("storm run: weather state %d, night %s, rain %s (%d drops)", weather.state(world), tostring(world.night),
            tostring(world.raining), world.rainDrops or 0)
    end
    log.info("%s simulated in %.1fs (%d units)", name, os.clock() - t0, #world.units)
end

return M
