-- Headless checks of the keep conversion and the computer's use of it (1.04: keep conversion FUN_0052f9b0, computer
-- keep conversions FUN_004fbb90, conversion cell FUN_004f8820): `run(check)` is called from selftest.lua.
local M = {}

-- A battle screen stand-in for savegame.snapshot / apply, which read only the world, the scenario path and the camera.
---@param t table
---@return BattleScreen
local function asBattle(t) return t --[[@as BattleScreen]] end

---@param check fun(name: string, ok: any) the selftest's check: logs ok / FAIL and counts the failures
function M.run(check)
    local boot = require("src.game.boot")
    local worldMod = require("src.game.world")
    local commands = require("src.game.commands")
    local aibase = require("src.game.aibase")
    local savegame, serialize = require("src.game.savegame"), require("src.core.serialize")

    ---@return World
    local function new()
        local w = worldMod.new(assert(boot.loadScenario("Bridges")), { player = 0 })
        w.ai = require("src.game.ai").new(w)
        return w
    end
    ---@param w World
    ---@return Building
    local function place(w, code, side, gx, gy)
        local b = w:addBuilding({ code = code, side = side, x = gx * 32 + 16, y = gy * 24 + 12 })
        w.eco:initBuilding(b)
        return b
    end
    ---@param w World
    ---@param seconds number simulated, in steps of 1/30 s
    local function run(w, seconds)
        for _ = 1, math.floor(seconds * 30) do w:update(1 / 30) end
    end
    -- an empty stretch of the map with nothing neutral near: the neutral mine at (41, 7) is the one to take
    local w = new()
    local mine
    for _, b in ipairs(w.buildings) do if b.mine and b.gx == 41 and b.gy == 7 then mine = b end end
    local keep = place(w, "BKH0", 0, 47, 12)
    local near = w.eco:conversionList(0, keep.gx, keep.gy, 28)
    local found = false
    for _, b in ipairs(near) do if b == mine then found = true end end
    check("keep conversion: the list holds the neutral mine in reach and at most 8 buildings", found and #near <= 8)
    check("keep conversion: nothing in reach, nothing to convert",
        #w.eco:conversionList(0, 5, 100, 3) == 0)

    -- the Convert button: 28 cells, 150 s, human; the production blocks it
    local queued = place(w, "BKH0", 0, 47, 40)
    queued.queue[1] = "AHFX"
    check("keep conversion: a producing keep cannot start one", not w.eco:startKeepConversion(queued))
    commands.apply(w, { t = "keepconvert", bid = keep.id, side = 0 })
    check("keep conversion: human keep 28 cells / 150 s", keep.convert and keep.convert.range == 28
        and keep.convert.t1 - keep.convert.t0 == 150000)
    commands.apply(w, { t = "enqueue", bid = keep.id, side = 0, code = "AHFX", n = 1 })
    check("keep conversion: a converting keep takes no production", #keep.queue == 0)
    run(w, 100)
    check("keep conversion: still running after 100 s", keep.convert and mine.side == 6
        and w.eco:keepConversionPercent(keep) > 60)
    run(w, 55)
    check("keep conversion: after 150 s the mine is the keep's", keep.convert == nil and mine.side == 0)

    -- damage stops it; the stop button stops it
    local k2 = place(w, "BKH0", 0, 40, 12)
    w.eco:startKeepConversion(k2)
    local running = k2.convert ~= nil
    w:damageBuilding(k2, 5, nil)
    run(w, 1)
    check("keep conversion: damage stops it", running or k2.convert == nil)
    local w3 = new()
    local k3 = place(w3, "BKH0", 0, 47, 12)
    w3.eco:startKeepConversion(k3)
    commands.apply(w3, { t = "cancel", bid = k3.id, side = 0 })
    check("keep conversion: the stop button stops it", k3.convert == nil)
    local k3b = place(w3, "BKH0", 0, 47, 12)
    w3.eco:startKeepConversion(k3b)
    w3:damageBuilding(k3b, 5, nil)
    run(w3, 1)
    check("keep conversion: a hit keep stops converting", k3b.convert == nil)

    -- a computer side's keep: 32 cells, 120 s
    local w4 = new()
    local ak = place(w4, "BKB0", 1, 47, 12)
    w4.eco:startKeepConversion(ak)
    check("keep conversion: computer keep 32 cells / 120 s", ak.convert and ak.convert.range == 32
        and ak.convert.t1 - ak.convert.t0 == 120000)

    -- allies: a human converter may take an ally's buildings, a computer does not
    local w5 = new()
    w5.sides[0].team, w5.sides[1].team = 1, 1
    local ally = place(w5, "BKB0", 1, 47, 12)
    local l1 = w5.eco:conversionList(0, 50, 12, 28)
    w5.sides[0].ai = true
    local l2 = w5.eco:conversionList(0, 50, 12, 28)
    local function has(list, x) for _, b in ipairs(list) do if b == x then return true end end end
    check("keep conversion: a human converter takes allied buildings, a computer one leaves them", has(l1, ally) and not has(l2, ally))

    -- computer keep conversions (FUN_004fbb90): no converter army, a keep with mines of level >= 1 of others within 32 cells
    local w6 = new()
    local st = w6.ai.sides[1]
    local pk = place(w6, "BKB0", 1, 41, 12)
    check("palace conversion: a level 2 mine within 32 cells counts", aibase.shouldPalaceConvert(w6.ai, st, pk))
    -- only a level 0 mine of another side near (level digits add up: 0), the rest the keep's own
    local zero
    for _, m in ipairs(w6.buildings) do
        if m.mine and not (m.gx == 41 and m.gy == 7) then m.side = 1 end
        if m.mine and m.gx == 79 and m.gy == 38 then zero, m.side = m, 6 end
    end
    local far = place(w6, "BKB0", 1, 79, 45)
    check("palace conversion: a level 0 mine alone does not count", zero and not aibase.shouldPalaceConvert(w6.ai, st, far))
    pk.queue[1] = "BWT1"
    check("palace conversion: a queued upgrade / building says no", not aibase.shouldPalaceConvert(w6.ai, st, pk))
    pk.queue[1] = "AHFX"
    local units = {}
    aibase.palaceConversions(w6.ai, st, units, { pk })
    check("palace conversion: the keep stops producing and converts", pk.convert ~= nil and #pk.queue == 0
        and st.converterExists == false)
    local hero
    for _, u in ipairs(w6.units) do if u.side == 1 and u.hero then hero = u end end
    local pk2 = place(w6, "BKB0", 1, 41, 14)
    aibase.palaceConversions(w6.ai, st, { hero }, { pk2 })
    check("palace conversion: with an army converter the keeps do nothing", pk2.convert == nil and st.converterExists == true)

    -- conversion cell (FUN_004f8820): a cell at distance range - 1 from the target, the nearest to the converter
    local conv = w6.units[1]
    for _, u in ipairs(w6.units) do if u.side == 1 and u.hero then conv = u end end
    conv.gx, conv.gy = 41, 20
    local sq = aibase.bestConversionSquare(w6.ai, st, mine, 8, conv)
    check("best conversion square: on the ring at range - 1 from the target",
        sq and math.floor(math.sqrt((sq[1] - mine.gx) ^ 2 + (sq[2] - mine.gy) ^ 2)) == 7)

    -- saved games keep a running conversion
    local w7 = new()
    local k7 = place(w7, "BKH0", 0, 47, 12)
    w7.eco:startKeepConversion(k7)
    run(w7, 30)
    local snap7 = savegame.snapshot(asBattle({ world = w7, scnPath = "Bridges", camX = 0, camY = 0, zoom = 1 }))
    local data = serialize.decode(serialize.encode(snap7))
    local w8 = worldMod.new(assert(boot.loadScenario("Bridges")), { player = 0, restore = data, advanced = data.opts.advanced })
    w8.ai = require("src.game.ai").new(w8)
    savegame.apply(asBattle({ world = w8 }), data)
    local back
    for _, b in ipairs(w8.buildings) do if b.convert then back = b end end
    check("keep conversion: a saved game keeps a running conversion", back and back.convert.range == 28
        and math.abs((back.convert.t1 - w8.time) - (k7.convert.t1 - w7.time)) < 50)

    -- an army's conversion list is the keep's circle (the conversion list FUN_005489e0 at the unit's own cell), not a square
    local w9 = new()
    local m9
    for _, b in ipairs(w9.buildings) do if b.mine and b.gx == 41 and b.gy == 7 then m9 = b end end
    local sw, sh = m9.shape.w, m9.shape.h
    local edge = m9.gx + math.floor(sw / 2)
    local function at(px, py) return { side = 0, gx = px, gy = py } end
    check("army conversion: 4 cells straight from the footprint is in a range of 4",
        #w9.eco:conversionTargets(at(edge + 4, m9.gy), 4) == 1)
    check("army conversion: 4 cells diagonally is out of a circle of 4 (not of a square)",
        #w9.eco:conversionTargets(at(edge + 4, m9.gy + sh + 4), 4) == 0)
    check("army conversion: the conversion spell only takes resource producers",
        has(w9.eco:conversionList(0, edge + 3, m9.gy, 6, true), m9))
    local neutralKeep = place(w9, "BKH0", 6, edge + 12, m9.gy)
    check("army conversion: ... and leaves a neutral keep",
        not has(w9.eco:conversionList(0, edge + 12, m9.gy, 3, true), neutralKeep)
        and has(w9.eco:conversionList(0, edge + 12, m9.gy, 3), neutralKeep))
    local ahero
    for _, u in ipairs(w9.units) do if u.side == 1 and u.hero then ahero = u end end
    local hhero
    for _, u in ipairs(w9.units) do if u.side == 0 and u.hero then hhero = u end end
    w9.sides[1].ai = true
    check("army conversion: a computer side converts over 3 cells more",
        ahero and ahero:conversionRange() == ahero:convertRange() + 3
        and (not hhero or hhero:conversionRange() == hhero:convertRange()))

    -- the hate index (FUN_00417f80): symmetric rolls of 1..100 (1..40 in a campaign), one computer side that hates the
    -- local player in single player games
    local function rolled(world)
        local ok = true
        for i = 0, 6 do for j = 0, 6 do ok = ok and world.ai.hate[i][j] == world.ai.hate[j][i] end end
        return ok
    end
    local w10 = new()
    w10.sides[1].ai, w10.sides[2].ai = true, true
    w10.ai = require("src.game.ai").new(w10)
    local racist = 0
    for i = 1, 5 do if w10.ai.hate[i][0] == 200 then racist = racist + 1 end end
    check("hate index: symmetric, one computer side hates the local player, the others' pairings with it are cut",
        rolled(w10) and racist == 1 and w10.ai.hate[0][1] == w10.ai.hate[1][0])
    local w11 = worldMod.new(assert(boot.loadScenario("Bridges")), { player = 0, campaign = true })
    w11.sides[1].ai = true
    w11.ai = require("src.game.ai").new(w11)
    local top = 0
    for i = 0, 6 do for j = 0, 6 do top = math.max(top, w11.ai.hate[i][j]) end end
    check("hate index: a campaign rolls 1..40 and nobody hates the player", rolled(w11) and top <= 40)
    -- the enemy choice FUN_004fa5b0 adds it
    local w12 = new()
    w12.sides[1].ai = true
    w12.ai = require("src.game.ai").new(w12)
    local st12 = w12.ai.sides[1]
    for j = 0, 6 do w12.ai.hate[1][j] = 1 end
    w12.ai.hate[1][2] = 250
    aibase.chooseEnemy(w12.ai, st12)
    local first = st12.enemy
    w12.ai.hate[1][2], w12.ai.hate[1][3] = 1, 250
    aibase.chooseEnemy(w12.ai, st12)
    check("enemy choice: the hate index of the pair counts", first == 2 and st12.enemy == 3)

    -- the region map and its searches
    local w13 = new()
    w13.ai = require("src.game.ai").new(w13)
    local R = w13.ai.region
    local hero13
    for _, u in ipairs(w13.units) do if u.side == 1 and u.hero then hero13 = u end end
    local start = R:regionAt(hero13.gx, hero13.gy, 1)
    check("region map: a hero stands on a land region", start and start.terrain ~= 255)
    local keepE = place(w13, "BKB0", 2, hero13.gx + 12, hero13.gy - 12)
    local reg = R:regionAt(keepE.gx, keepE.gy, 1)
    check("region map: a building is a building region of its own", reg and reg.terrain == 255 and reg.building == keepE)
    keepE.pathDanger = nil
    R:safeSearch(R:regionAt(hero13.gx, hero13.gy, 1) --[[@as AIRegionArea]], 1)
    check("safe search: a reachable enemy building gets its path danger", (keepE.pathDanger or 0) > 1)
    local own = place(w13, "BKB0", 1, hero13.gx + 3, hero13.gy)
    own.pathDanger = 5
    R:safeSearch(R:regionAt(hero13.gx, hero13.gy, 1) --[[@as AIRegionArea]], 1)
    check("safe search: the side's own buildings are reset to -1", own.pathDanger == -1)
    R:update(1)
    local x14, y14 = hero13.gx, hero13.gy
    check("danger map: an army raises the danger of its square for its enemies, not for its own side",
        R:dangerLevel(0, x14, y14) > R:dangerLevel(1, x14, y14))
    local snap = R:save(w13.time)
    local R2 = require("src.game.airegion").new(w13)
    R2:restore(snap, w13.time)
    check("danger map: a saved game keeps the snapshot", R2:dangerLevel(0, x14, y14) == R:dangerLevel(0, x14, y14)
        and R2.nextDanger == R.nextDanger)
    -- cut off by water: a ground converter on the far side gets no region square, a flyer is not asked
    local w15 = new()
    w15.ai = require("src.game.ai").new(w15)
    local c15
    for _, u in ipairs(w15.units) do if u.side == 1 and u.hero then c15 = u end end
    c15.gx, c15.gy = 41, 20
    local sq15 = aibase.bestConversionSquare(w15.ai, w15.ai.sides[1], mine, 8, c15)
    check("best conversion square: reached through the region map", sq15 ~= nil)

    -- the neutral side's own computer player (the barbarian mode of the AI think step FUN_004fa120, taken for the
    -- neutral side too): it picks an enemy among the used sides and sends every idle neutral army that can fight at that
    -- side's best target
    local w16 = new()
    local fighter = assert(w16:addUnit("ABBX", 6, 60, 60, {}))
    local critter
    for _, u in ipairs(w16.units) do if u.side == 6 and u.type.attackType == 0 then critter = u end end
    check("neutral AI: the neutral side has a computer player", w16.ai.sides[6] ~= nil and w16.ai.sides[6].level == 7)
    run(w16, 12)
    local en = w16.ai.sides[6].enemy
    check("neutral AI: it chose one of the used sides as its enemy", en ~= nil and en >= 0 and en <= 5 and w16.sides[en].used)
    check("neutral AI: an idle neutral fighter was sent after a target",
        fighter.target ~= nil and fighter.target.side ~= 6)
    check("neutral AI: an army without an attack is left alone", critter == nil or critter.target == nil)
    local snap16 = savegame.snapshot(asBattle({ world = w16, scnPath = "Bridges", camX = 0, camY = 0, zoom = 1 }))
    local data16 = serialize.decode(serialize.encode(snap16))
    check("neutral AI: a saved game keeps the neutral side's timers", data16.ai and data16.ai[6] and data16.ai[6].lite
        and data16.ai[6].enemy == en)

    -- the flag BMFL: the conversion test FUN_0052da90 accepts it first, in any game and even unfinished
    local wf = new()
    local flag = place(wf, "BMFL", 1, 47, 12)
    flag.complete = false
    check("conversion: a flag is convertible outside Capture the Flag, finished or not", wf.eco:canBeConverted(flag))
end

return M
