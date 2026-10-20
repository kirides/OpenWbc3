-- Self test of the attitude rule engine (game/attitude.lua): hand-made situations on the Bridges map with every other
-- unit taken out of play. `run(check)` reports through the selftest's check function and returns nothing.
local M = {}

---@param check fun(name: string, ok: any) the selftest's check: logs ok / FAIL and counts the failures
function M.run(check)
    local boot = require("src.game.boot")
    local worldMod = require("src.game.world")
    local attitude = require("src.game.attitude")
    local w = worldMod.new(assert(boot.loadScenario("Bridges")), { player = 0 })
    for _, u in ipairs(w.units) do
        u.state, u.hp = "dead", 0
        w.occ[w:index(u.gx, u.gy)] = nil
    end
    ---@return Unit
    local function fresh(code, side, gx, gy)
        local u = w:addUnit(code, side, gx, gy)
        assert(u, "no room for the test unit")
        return u
    end
    -- the field: 30 cells from the nearest map corner, cells that are free and walkable
    local cx, cy = 60, 60
    local function near(e, u, dx, dy) e.gx, e.gy = u.gx + dx, u.gy + dy end
    ---@param u Unit
    local function reset(u)
        u.target, u.goalX, u.goalY, u.path, u.autoChase, u.roaming, u.running = nil, nil, nil, nil, false, nil, nil
        u.guarding, u.att, u.queue, u.patrol = nil, nil, nil, nil
        u:setIdle(w.time)
    end

    -- Fallback (25%): below a quarter of the hits the unit walks to the base; healthy it does nothing
    local u = fresh("AHKX", 0, cx, cy)
    u.attitude = "Fallback25"
    reset(u)
    attitude.think(u, w.time)
    check("attitude: Fallback25 healthy stays", u.goalX == nil)
    u.hp = math.floor(u.maxHp * 0.2)
    local gave = attitude.think(u, w.time)
    local sd = w.sides[0]
    check("attitude: Fallback25 below 25% returns to base", gave and u.goalX and u.autoChase
        and math.max(math.abs(u.goalX - sd.startX), math.abs(u.goalY - sd.startY)) <= 6)
    -- a move order of the player is not touched by a rule that does not override the player
    u:orderMove(cx + 5, cy)
    u.autoChase = false
    check("attitude: Fallback25 respects a player order", not attitude.think(u, w.time) and u.goalX == cx + 5)

    -- Standard: an enemy within 12 cells is attacked, one farther away is not; chased units are dropped once beyond
    local s = fresh("AHKX", 0, cx, cy + 10)
    s.attitude = "standard"
    reset(s)
    local e = fresh("AHKX", 1, cx + 8, cy + 10)
    near(e, s, 8, 0)
    check("attitude: standard attacks an enemy 8 cells away", attitude.think(s, w.time) and s.target == e and s.autoChase)
    near(e, s, 20, 0)
    s.gx = s.gx - 3                                     -- the chase took it away from its post
    check("attitude: ... and gives up, going back to its post, when it is out of the 12 cell box",
        attitude.think(s, w.time) and s.goalX ~= nil and s.target == nil)
    reset(s)
    check("attitude: standard ignores an enemy 20 cells away", not attitude.think(s, w.time) and s.target == nil)

    -- Aggressive: no idle action, so it stops where the chase ended
    local ag = fresh("AHKX", 0, cx, cy + 20)
    ag.attitude = "aggressive"
    reset(ag)
    near(e, ag, 5, 0)
    check("attitude: aggressive attacks", attitude.think(ag, w.time) and ag.target == e)
    near(e, ag, 30, 0)
    ag.state = "attack"
    attitude.think(ag, w.time)
    check("attitude: aggressive drops the chase when the enemy is gone", ag.target == nil and not ag.autoChase)

    -- Stand ground: only what it can hit
    local sg = fresh("AHKX", 0, cx, cy + 30)
    sg.attitude = "standGround"
    reset(sg)
    near(e, sg, 4, 0)
    check("attitude: stand ground leaves an enemy out of reach", not attitude.think(sg, w.time) and sg.target == nil)
    near(e, sg, 1, 0)
    check("attitude: stand ground hits an enemy in reach", attitude.think(sg, w.time) and sg.target == e)

    -- Cowardly: runs from the attacker (hit list) two steps of four cells away from it
    local cw = fresh("AHKX", 0, cx - 10, cy)
    cw.attitude = "cowardly"
    reset(cw)
    near(e, cw, -2, 0)
    attitude.addHit(w, e, cw)
    check("attitude: cowardly runs from its attacker", attitude.think(cw, w.time) and cw.goalX and cw.goalX > cw.gx + 4
        and cw.running)
    reset(cw)
    w.time = w.time + 6000
    near(e, cw, 50, 0)
    local cw2 = cw
    check("attitude: the hit list forgets after 4 seconds", not attitude.think(cw2, w.time) or cw2.goalX == nil
        or cw2.running ~= true)

    -- Defensive: threats count only inside the active area around the guard point
    local df = fresh("AHKX", 0, cx - 25, cy + 10)
    df.attitude = "defensive"
    reset(df)
    df.post, df.autoChase = { df.gx - 15, df.gy }, true
    local e2 = fresh("AHKX", 1, df.gx + 8, df.gy)
    near(e2, df, 8, 0)
    check("attitude: defensive ignores a threat outside its area", not attitude.think(df, w.time) or df.target == nil)
    df.post = { df.gx, df.gy }
    reset(df)
    df.post = { df.gx, df.gy }
    check("attitude: defensive fights a threat inside its area", attitude.think(df, w.time) and df.target == e2)

    -- Guardian: follows a designated unit that is far away
    local boss = fresh("AHKX", 0, cx + 30, cy - 20)
    local gd = fresh("AHKX", 0, cx - 10, cy - 20)
    gd.attitude = "guardian"
    reset(gd)
    gd.guarding = boss
    check("attitude: guardian follows a unit 40 cells away", attitude.think(gd, w.time) and gd.goalX ~= nil)
    gd.guarding = nil
    attitude.think(gd, w.time)
    check("attitude: guardian without designated unit becomes standard", gd.attitude == "standard")

    -- Scout: random movement, no fighting
    local sc = fresh("AHKX", 0, cx + 10, cy - 30)
    sc.attitude = "scout"
    reset(sc)
    check("attitude: scout wanders", attitude.think(sc, w.time) and sc.goalX ~= nil and sc.roaming and not sc.autoChase)

    -- Roaming Guardian (custom file): the hero rule needs a hero, the designated rule a designated unit
    local rg = fresh("AHKX", 0, cx + 20, cy - 30)
    rg.attitude = "RoamingGuardian"
    reset(rg)
    rg.guarding = boss
    check("attitude: Roaming Guardian is designated and catches up", attitude.def.RoamingGuardian.designated
        and attitude.think(rg, w.time) and rg.goalX ~= nil and not rg.autoChase)

    -- the rest in an emptied field away from the towers of the map
    for _, x in ipairs(w.units) do
        x.state, x.hp = "dead", 0
        w.occ[w:index(x.gx, x.gy)] = nil
    end
    w.hitList, w.hitProcessed = nil, nil

    -- Start attitude: Defensive for armies and heroes, Cowardly for the army types that load as 0 (the builders), the
    -- armies of the other sides stand their ground in the tutorial
    local ds = fresh("AHKX", 0, 70, 40)
    local wimp = fresh("ALBX", 0, 72, 40)
    check("attitude: an army starts Defensive", attitude.of(ds) == "defensive" and attitude.get(ds) == attitude.def.defensive)
    check("attitude: a builder starts Cowardly", attitude.of(wimp) == "cowardly")
    ds.attitude = "aggressive"
    check("attitude: a chosen attitude wins", attitude.of(ds) == "aggressive")
    ds.attitude = nil

    -- Neutral armies are threats (but critters never), enemy buildings are, mines / lairs / shops are not; the highest
    -- priority wins: a farther enemy that attacks me beats a nearer one that does not
    local fx, fy = 70, 45
    local me = fresh("AHKX", 0, fx, fy)
    reset(me)
    local mon = fresh("AHKX", 6, fx + 6, fy)
    check("attitude: a neutral army is a threat", attitude.think(me, w.time) and me.target == mon)
    reset(me)
    mon.state, mon.hp = "dead", 0
    w.occ[w:index(mon.gx, mon.gy)] = nil
    local sheep = fresh("ACSH", 6, fx + 3, fy)
    check("attitude: a critter is none", not attitude.think(me, w.time) and me.target == nil)
    sheep.state, sheep.hp = "dead", 0
    w.occ[w:index(sheep.gx, sheep.gy)] = nil
    local tx, ty = w:nearestFree(fx + 8, fy + 4, 0, 4)
    local tower = w:addBuilding({ code = "BWTB", side = 1, x = tx * 32 + 16, y = ty * 24 + 12, anim = 0, dir = 0, frame = 0 })
    w.eco:initBuilding(tower)
    tower.complete = true
    reset(me)
    check("attitude: an enemy building is a threat", attitude.think(me, w.time) and me.target == tower)
    tower.hp = 0
    reset(me)
    local near1 = fresh("AHKX", 1, fx + 3, fy)
    local far1 = fresh("AHKX", 1, fx + 9, fy + 1)
    check("attitude: the nearer enemy wins", attitude.think(me, w.time) and me.target == near1)
    reset(me)
    far1.target = me
    check("attitude: ... unless a farther one attacks me", attitude.think(me, w.time) and me.target == far1)
    for _, x in ipairs({ near1, far1 }) do
        x.state, x.hp = "dead", 0
        w.occ[w:index(x.gx, x.gy)] = nil
    end

    -- A neutral Defensive army fights what comes near
    local gob = fresh("AHKX", 6, fx - 20, fy - 10)
    reset(gob)
    gob.post = { gob.gx, gob.gy }
    local victim = fresh("AHKX", 0, gob.gx + 7, gob.gy)
    check("attitude: a neutral army attacks a unit of a side", attitude.think(gob, w.time) and gob.target == victim)
    victim.state, victim.hp = "dead", 0
    w.occ[w:index(victim.gx, victim.gy)] = nil

    -- A unit that was hit and finds no threat walks off at random (no order, not standing its ground)
    local hit = fresh("AHKX", 0, fx + 10, fy - 25)
    reset(hit)
    hit.wasHit = true
    check("attitude: a hit unit without threats moves off", attitude.think(hit, w.time) == false and hit.wasHit == nil
        and hit.goalX ~= nil and not hit.autoChase)
    reset(hit)
    hit.attitude, hit.wasHit = "standGround", true
    attitude.think(hit, w.time)
    check("attitude: ... not when it stands its ground", hit.goalX == nil)

    -- The slices: every 250 ms the sides without a computer player and the neutral side are marked, a unit is due once
    local sch = fresh("AHKX", 0, fx + 20, fy - 25)
    local t0 = w.time
    attitude.update(w, t0)
    check("attitude: nothing is due before the first slice", not attitude.due(sch))
    attitude.update(w, t0 + attitude.SLICE_MS)
    check("attitude: a slice marks the sides", attitude.due(sch) and w.attSide[6] == w.attSlice)
    sch.attSlice = w.attSide[0]
    check("attitude: a unit is due once per slice", not attitude.due(sch))
    attitude.update(w, t0 + attitude.SLICE_MS + 100)
    check("attitude: ... and the next slice comes after 250 ms", not attitude.due(sch))
    attitude.update(w, t0 + 2 * attitude.SLICE_MS)
    check("attitude: ... then", attitude.due(sch))

    -- The hit list survives a save: units by index, times relative to the clock
    local hv, hi = fresh("AHKX", 0, fx + 25, fy - 25), fresh("AHKX", 1, fx + 26, fy - 25)
    w.hitList, w.hitProcessed = nil, nil
    attitude.addHit(w, hi, hv)
    attitude.addHit(w, tower, hv)
    local uidx, bidx = { [hv] = 1, [hi] = 2 }, { [tower] = 1 }
    local saved = require("src.core.serialize").decode(require("src.core.serialize").encode(attitude.saveHits(w, uidx, bidx)))
    w.hitList = nil
    attitude.restoreHits(w, saved, { hv, hi }, { tower })
    check("attitude: the hit list is saved and restored", #w.hitList == 2 and w.hitList[1].inf == hi and w.hitList[1].vic == hv
        and w.hitList[2].inf == tower and w.hitList[2].t == w.time)

    -- The tests below each take a free block of the map of their own
    local picked = {}
    local function block(wd, ht)
        for y0 = 2, w.h - ht - 2 do
            for x0 = 2, w.w - wd - 2 do
                local ok = true
                for _, r in ipairs(picked) do
                    if x0 < r[1] + r[3] + 14 and r[1] < x0 + wd + 14 and y0 < r[2] + r[4] + 14 and r[2] < y0 + ht + 14 then ok = false break end
                end
                for y = y0, y0 + ht - 1 do
                    if not ok then break end
                    for x = x0, x0 + wd - 1 do
                        if not w:free(x, y, 0) then ok = false break end
                    end
                end
                if ok then picked[#picked + 1] = { x0, y0, wd, ht } return x0, y0 end
            end
        end
        error("no free block")
    end
    local function kill(x) x.state, x.hp = "dead", 0 w.occ[w:index(x.gx, x.gy)] = nil end
    for _, u2 in ipairs(w.units) do if u2:alive() then kill(u2) end end
    for _, b2 in ipairs(w.buildings) do b2.hp = 0 end

    -- The critters' hunt (the best-threat search FUN_005334f0): a wounded Minotaur takes a sheep, a Troll a sheep, a
    -- Catapult a cow (not a camel), a daemon a Soul while its mana is low
    local px, py = block(10, 8)
    local mino = fresh("AMIX", 6, px, py)
    mino.attitude = "aggressive"
    reset(mino)
    local sh = fresh("ACSH", 6, px + 4, py)
    check("hunt: a healthy Minotaur leaves a sheep alone", not attitude.think(mino, w.time) and mino.target == nil)
    mino.hp = mino.maxHp - 40
    check("hunt: a wounded Minotaur takes the sheep", attitude.think(mino, w.time) and mino.target == sh)
    reset(mino)
    local goose = fresh("ACGO", 6, px + 3, py + 1)
    attitude.think(mino, w.time)
    check("hunt: ... a plain Minotaur no goose", mino.target == sh)
    local foe = fresh("AHKX", 0, px, py + 5)
    mino.hp = mino.maxHp - 1000                   -- 1 + 200 beats any real threat
    reset(mino)
    attitude.think(mino, w.time)
    check("hunt: ... and a badly wounded one prefers the animal to an enemy", mino.target == sh)
    kill(mino) kill(sh) kill(goose) kill(foe)
    local tpx, tpy = block(10, 3)
    local troll = fresh("AOMX", 6, tpx, tpy)
    troll.attitude = "aggressive"
    reset(troll)
    local camel = fresh("ACCA", 6, tpx + 3, tpy)
    check("hunt: a Troll leaves a camel alone", not attitude.think(troll, w.time) and troll.target == nil)
    local sheep2 = fresh("ACSH", 6, tpx + 5, tpy)
    check("hunt: a Troll takes a sheep", attitude.think(troll, w.time) and troll.target == sheep2)
    kill(troll) kill(camel) kill(sheep2)
    local cx2, cy2 = block(10, 4)
    local cat = fresh("ASCA", 6, cx2, cy2)
    cat.attitude = "aggressive"
    reset(cat)
    local camel2 = fresh("ACCA", 6, cat.gx + 4, cat.gy)
    check("hunt: a Catapult leaves a camel alone", not attitude.think(cat, w.time) and cat.target == nil)
    local cow = fresh("ACCO", 6, cat.gx + 6, cat.gy)
    check("hunt: a Catapult takes a cow", attitude.think(cat, w.time) and cat.target == cow)
    kill(cat) kill(camel2) kill(cow)
    local dx2, dy2 = block(8, 3)
    local dae = fresh("AADE", 6, dx2, dy2)
    dae.attitude = "aggressive"
    reset(dae)
    local soul = fresh("ACSO", 6, dae.gx + 4, dae.gy)
    dae.mana, dae.maxMana = 20, 20
    check("hunt: a daemon with full mana leaves a Soul alone", not attitude.think(dae, w.time) and dae.target == nil)
    dae.mana = 3
    check("hunt: a daemon short of mana takes the Soul", attitude.think(dae, w.time) and dae.target == soul)
    kill(dae) kill(soul)

    -- The critters' rest and wander (the critter threat reaction FUN_0051a230): geese walk off now and then, cows hardly ever
    local gx0, gy0 = block(10, 6)
    local walkers, cows = {}, {}
    for i = 0, 29 do walkers[#walkers + 1] = fresh("ACGO", 6, gx0 + i % 10, gy0 + math.floor(i / 10)) reset(walkers[#walkers]) end
    for i = 0, 9 do cows[#cows + 1] = fresh("ACCO", 6, gx0 + i, gy0 + 3) reset(cows[#cows]) end
    math.randomseed(7)
    w.attNext = nil
    local started = { 0, 0 }
    for k = 1, 40 do
        attitude.update(w, w.time + k * attitude.SLICE_MS)
        for _, g in ipairs(walkers) do if g.goalX and not g.wasMoving then g.wasMoving = true started[1] = started[1] + 1 end end
        for _, c in ipairs(cows) do if c.goalX and not c.wasMoving then c.wasMoving = true started[2] = started[2] + 1 end end
    end
    check("critters: geese set off on their own, cows hardly ever", started[1] >= 15 and started[2] <= 6)
    for _, g in ipairs(walkers) do kill(g) end
    for _, c in ipairs(cows) do kill(c) end

    -- The stand-ground box has the shape of a big army: a Catapult (2 x 2) reaches one cell farther than a single cell would
    local bx0, by0 = block(24, 3)
    local big = fresh("ASCA", 0, bx0, by0)
    big.attitude = "standGround"
    reset(big)
    local range = big:stats().range
    local en = fresh("AHKX", 1, big.gx + 2 + range - 1, big.gy)
    check("stand ground: the shape of a big army widens the box", attitude.think(big, w.time) and big.target == en)
    reset(big)
    kill(en)
    en = fresh("AHKX", 1, big.gx + 2 + range, big.gy)
    check("stand ground: ... but only by the shape", not attitude.think(big, w.time) and big.target == nil)
    kill(big) kill(en)

    -- A tower that shoots at my side draws the threat search (the threat priority FUN_00533c40: the target of a tower)
    local mx, my = block(14, 12)
    local me2 = fresh("AHKX", 0, mx + 2, my + 6)
    reset(me2)
    local towers = {}
    for _, d in ipairs({ { 7, 2 }, { 9, -2 } }) do
        local tx2, ty2 = mx + 2 + d[1], my + 6 + d[2]
        local t = w:addBuilding({ code = "BWTB", side = 1, x = tx2 * 32 + 16, y = ty2 * 24 + 12, anim = 0, dir = 0, frame = 0 })
        w.eco:initBuilding(t)
        t.complete = true
        towers[#towers + 1] = t
    end
    attitude.think(me2, w.time)
    local first = me2.target
    reset(me2)
    local other = first == towers[1] and towers[2] or towers[1]
    other.target = me2
    check("tower target: a tower shooting at my side comes first", first ~= nil and attitude.think(me2, w.time) and me2.target == other)
    kill(me2)
    for _, t in ipairs(towers) do t.hp = 0 end

    -- Walls are threats for a human side as well (the 1.04 binary skips only buildings under conversion)
    local wx0, wy0 = block(12, 3)
    local me3 = fresh("AHKX", 0, wx0, wy0 + 1)
    reset(me3)
    local wall = w:addBuilding({ code = "BWIC", side = 1, x = (wx0 + 6) * 32 + 16, y = (wy0 + 1) * 24 + 12, anim = 0, dir = 0, frame = 0 })
    w.eco:initBuilding(wall)
    wall.complete = true
    check("walls: a wall is a threat", attitude.think(me3, w.time) and me3.target == wall)
    wall.hp = 0
    kill(me3)

    -- The fog (fog.lua, the simulation's sight of a human side): with fog of war a human side's idle units only find
    -- what stands on a cell they see; buildings must have been seen first
    local fogs = require("src.game.fog")
    w.opts.fogMode = 1
    w.sight = nil
    local sx, sy = block(24, 3)
    sx, sy = sx + 2, sy + 1
    local seer = fresh("AHKX", 0, sx, sy)
    reset(seer)
    local vr = fogs.radius(seer.type.view)
    local far = fresh("AHKX", 1, sx + vr + 2, sy)
    w.attSlice = (w.attSlice or 0) + 1
    check("fog: an enemy beyond sight is no threat", vr + 2 <= 12 and not attitude.think(seer, w.time) and seer.target == nil)
    kill(far)
    far = fresh("AHKX", 1, sx + 3, sy)
    w.attSlice = w.attSlice + 1
    check("fog: an enemy in sight is", attitude.think(seer, w.time) and seer.target == far)
    kill(far)
    reset(seer)
    local fb = w:addBuilding({ code = "BWTB", side = 1, x = (sx + vr + 2) * 32 + 16, y = sy * 24 + 12, anim = 0, dir = 0, frame = 0 })
    w.eco:initBuilding(fb)
    fb.complete = true
    w.attSlice = w.attSlice + 1
    check("fog: a building nobody has seen is no threat", not attitude.think(seer, w.time) and seer.target == nil)
    -- seen once, then out of sight again: no threat while it stands on cells nobody sees
    fb.seen = { [0] = true }
    reset(seer)
    w.attSlice = w.attSlice + 1
    check("fog: a seen building out of sight is no threat either", not attitude.think(seer, w.time) and seer.target == nil)
    seer.gx = sx + 4
    w.attSlice = w.attSlice + 1
    check("fog: ... in sight it is", attitude.think(seer, w.time) and seer.target == fb)
    fb.hp = 0
    kill(seer)
    w.opts.fogMode, w.sight = nil, nil

    -- The tower's own threat search (the building threat search FUN_0052d0d0), once per slice of its side
    local tx0, ty0 = block(30, 10)
    ---@return Building
    local function tower(code, side, gx, gy)
        local t = w:addBuilding({ code = code, side = side, x = gx * 32 + 16, y = gy * 24 + 12, anim = 0, dir = 0, frame = 0 })
        w.eco:initBuilding(t)
        t.complete = true
        return t
    end
    local function slice() w.attSlice = (w.attSlice or 0) + 1 w.attSide = w.attSide or {} for i = 0, 6 do w.attSide[i] = w.attSlice end end
    local tw = tower("BWTB", 0, tx0 + 4, ty0 + 3)
    local tcx, tcy = tw.gx, tw.gy + math.floor((tw.shape.h - 1) / 2)
    local near1 = fresh("AHKX", 1, tcx + 3, tcy)
    local far1 = fresh("AHKX", 1, tcx + 9, tcy)
    slice()
    attitude.towerThink(w, tw)
    check("tower: the best priority wins, the nearer enemy at equal worth",
        tw.target == near1 and tw.targetSide == 1)
    -- the target is kept until the next slice, whatever happens; another slice picks again
    far1.target = tw                                    -- an army going after the tower's side is worth 30 more
    check("tower: the target stays within a slice", (function() attitude.towerThink(w, tw) return tw.target == near1 end)())
    slice()
    attitude.towerThink(w, tw)
    check("tower: ... and the next slice chooses by priority, not distance", tw.target == far1)
    kill(far1) kill(near1)
    slice()
    tw.nextShot = w.time + 500
    attitude.towerThink(w, tw)
    check("tower: nothing in the box drops the target and the shot timer", tw.target == nil and tw.nextShot == nil)
    -- the box is threat centre +- range (12 + the garrison's): an enemy 14 cells away is out of it
    local out1 = fresh("AHKX", 1, tcx + 14, tcy)
    slice()
    attitude.towerThink(w, tw)
    check("tower: an enemy beyond the range is none", tw.target == nil)
    tw.garrison = { fresh("AHKX", 0, tcx, tcy + 5) }     -- a hero in the tower: +2 range
    tw.garrison[1].hero = true
    kill(tw.garrison[1])
    slice()
    attitude.towerThink(w, tw)
    local _, gr = w.eco:garrisonBonus(tw)
    check("tower: the garrison's range counts", (gr >= 1) == (tw.target == out1) and gr >= 1)
    tw.garrison = nil
    kill(out1)
    -- an air-only tower (attack type 2) passes ground armies over, a ground-only one (Mortar) flyers; the local side's
    -- tower never takes a building, a computer side's does
    local at = tower("BAGT", 0, tx0 + 20, ty0 + 3)
    local gr1 = fresh("AHKX", 1, at.gx + 3, at.gy)
    slice()
    attitude.towerThink(w, at)
    check("tower: an air-only tower leaves a ground army alone", at.target == nil)
    local eb = tower("BWTB", 1, at.gx + 5, at.gy + 3)
    slice()
    at.attSlice = nil
    attitude.towerThink(w, at)
    check("tower: a human side's tower takes no building", at.target == nil)
    kill(gr1)
    local aiStub = { sides = { [0] = true } }           -- side 0 has a computer player: all towerThink asks
    ---@cast aiStub AI
    w.ai = aiStub
    slice()
    at.attSlice = nil
    attitude.towerThink(w, at)
    check("tower: a computer side's tower does (an air tower hits buildings)", at.target == eb)
    w.ai = nil
    at.hp, eb.hp = 0, 0
    -- a neutral tower fights too (in a slice of the neutral side)
    tw.hp = 0
    local nt = tower("BWTB", 6, tx0 + 4, ty0 + 8)
    local nv = fresh("AHKX", 0, nt.gx + 4, nt.gy)
    slice()
    attitude.towerThink(w, nt)
    check("tower: a neutral tower shoots at a side's army", nt.target == nv)
    nt.attSlice = nil
    w.attSide[6] = nil                                   -- the tutorial marks no neutral slice
    attitude.towerThink(w, nt)
    check("tower: ... but is idle without a slice of the neutral side", nt.target == nv and nt.attSlice == nil)
    kill(nv)
    nt.hp = 0

    -- The shot cadence (the building update 0x0052c250): the first shot at once, then every interval of the tower's
    -- speed; a target that died meanwhile costs its shot; no target resets the timer
    local sx0, sy0 = tx0, ty0                           -- the field of the tests above (their units are gone)
    local st = tower("BWTB", 0, sx0 + 4, sy0 + 3)
    local sv = fresh("AHKX", 1, st.gx + 4, st.gy)
    w.missiles = w.missiles or {}
    local m0, t0 = #w.missiles, w.time
    slice()
    w.eco:buildingAttack(st, t0)
    local interval = st.nextShot - t0
    check("tower shot: the first shot goes at once, the next one an interval later",
        #w.missiles == m0 + 1 and interval >= 300 and interval <= 6000)
    w.eco:buildingAttack(st, t0 + interval - 1)
    check("tower shot: nothing before the interval is up", #w.missiles == m0 + 1)
    kill(sv)
    w.eco:buildingAttack(st, t0 + interval)
    check("tower shot: a dead target costs the shot but the timer runs on",
        #w.missiles == m0 + 1 and st.nextShot == t0 + 2 * interval)
    slice()
    w.eco:buildingAttack(st, t0 + interval + 1)
    check("tower shot: the next slice drops the dead target and the timer", st.target == nil and st.nextShot == nil)
    st.hp = 0

    -- Healing in a tower (the regeneration tick FUN_0051b820 halves the interval): the garrison regenerates at twice the
    -- rate it has outside, Healing power-ups included
    local hx0, hy0 = tx0, ty0
    local ht = tower("BWTB", 0, hx0 + 3, hy0 + 3)
    local function healed(powerups)
        w.sides[0].powerups = powerups
        local ins, out = fresh("AHKX", 0, hx0 + 8, hy0), fresh("AHKX", 0, hx0 + 9, hy0)
        ins.level, out.level = 0, 0
        assert(ins.maxHp > 12, "test unit has too few hits")
        ins.hp, out.hp = ins.maxHp - 10, out.maxHp - 10
        local h0 = ins.hp
        assert(w.eco:enterGarrison(ins, ht), "no room in the test tower")
        local t = w.time
        ins.regenT, out.regenT = t, t
        for i = 1, 42 do
            t = t + 500
            w.eco:healGarrison(ht, t)
            out:regenerate(t)
        end
        local a, b = ins.hp - h0, out.hp - h0
        w.eco:unload(ht)
        kill(ins) kill(out)
        return a, b
    end
    local inA, outA = healed(nil)
    check("tower healing: twice the normal rate (21 s: 4 points against 2)", inA == 4 and outA == 2)
    local inB, outB = healed({ PRG0 = true })
    check("tower healing: the Healing power-up counts (150 %: 6 points against 3)", inB == 6 and outB == 3)
    w.sides[0].powerups = nil
    ht.hp = 0

    -- Attack-move (the Attack button on open ground): the unit's attitude (the start attitude, Defensive) fights the enemy
    -- it meets on the way and the move goes on to the clicked spot afterwards; a plain move is not diverted (an open
    -- stretch of the map)
    local ax, ay = 18, 14
    local function attackMove(attack)
        local aw = worldMod.new(assert(boot.loadScenario("Bridges")), { player = 0 })
        for _, o in ipairs(aw.units) do
            o.state, o.hp, o.deadSince = "dead", 0, -1e9
            aw.occ[aw:index(o.gx, o.gy)] = nil
        end
        local m = assert(aw:addUnit("AHKX", 0, ax, ay))
        local foe = assert(aw:addUnit("AHKX", 1, ax + 5, ay + 2))
        foe.attitude = "standGround"
        foe.hp = 1
        require("src.game.commands").apply(aw, { t = "move", side = 0, moves = { { m.id, ax + 12, ay } }, attack = attack })
        local fought = false
        for _ = 1, 30 * 30 do
            aw:update(1 / 30)
            if m.target == foe then fought = true end
        end
        return m, foe, fought
    end
    local am, amFoe, amFought = attackMove(true)
    check("attack-move: attacks the enemy met on the way", amFought and not amFoe:alive())
    check("attack-move: then goes on to the clicked spot", am.gx == ax + 12 and am.gy == ay and am.attackMove == nil)
    local _, _, mvFought = attackMove(nil)
    check("attack-move: a plain move walks past", not mvFought)

    -- A Passive side (level 0) is a computer side (DAT_0070d6a4, an AI object from FUN_00504a30) whose turn only runs
    -- the attitude pass FUN_00532530 before FUN_004fa120 returns: a controller without a production model, its units
    -- evaluated on its round-robin turn without the human sides' fog, and the computer spells / ability sweep skipped.
    local scn = assert(boot.loadScenario("Bridges"))
    scn.sides[1].aiLevel = 0
    local pw = worldMod.new(scn, { player = 0 })
    pw.ai = require("src.game.ai").new(pw)
    local pst = pw.ai.sides[1]
    check("passive side: a computer side with a level 0 controller and no production model",
        pw.sides[1].ai and pst and pst.level == 0 and pst.D == nil and pw.ai.sides[0] == nil)
    check("passive side: not a human side for the attitudes", not attitude.humanSide(pw, 1) and attitude.humanSide(pw, 0))
    local marked = false
    for _ = 1, 8 do
        pw.time = pw.time + attitude.SLICE_MS
        attitude.update(pw, pw.time)
        if pw.attSide and pw.attSide[1] == pw.attSlice then marked = true end
    end
    check("passive side: its units get the attitude slice of its round-robin turn", marked)
    pw.ai:think(pst, pw.time)
    check("passive side: the think returns at once (no base, no enemy)", pst.baseX == nil and pst.enemy == nil)
end

return M
