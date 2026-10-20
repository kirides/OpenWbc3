-- Headless checks against the original game data: `love game --selftest`.
local config = require("src.core.config")
local log = require("src.core.log")

local M = {}

function M.run(args)
    if not config.load(args) then return 1 end
    local vfs = require("src.vfs.vfs")
    local t0 = os.clock()
    vfs.init(config.gamedir, config.language)
    log.info("mount took %.3fs", os.clock() - t0)
    local modArgs = { "--no-mods" }                 -- the checks run on the original content, whatever the player enabled
    for i = 1, #args do if args[i] == "--mod" then modArgs = args end end
    require("src.content.mods").configure(modArgs)
    require("src.content.loader").setup()
    for i = 1, #args do
        if args[i] == "--sim" then
            require("src.tools.simtest").run(args[i + 1], args[i + 2])
            return 0
        end
        if args[i] == "--lua" then
            -- run a dev script after the archives are mounted: --lua file.lua [args...]
            local chunk, err = loadfile(args[i + 1])
            if not chunk then log.error("%s", err) return 1 end
            chunk(unpack(args, i + 2))
            return 0
        end
        if args[i] == "--ls" then
            -- list archive entries: --ls [lua-pattern [archive]]
            for _, p in ipairs(vfs.list(args[i + 1], args[i + 2])) do print(p) end
            return 0
        end
        if args[i] == "--dump" then
            -- write an entry to a file: --dump entry out
            local data = vfs.find(args[i + 1])
            if not data then log.error("not found") return 1 end
            local f = assert(io.open(args[i + 2], "wb"))
            f:write(data) f:close()
            return 0
        end
        if args[i] == "--ani" then
            -- dump animation records: --ani CODE[,CODE...]
            local sprite = require("src.formats.sprite")
            local bin = require("src.core.bin")
            for code in (args[i + 1] or ""):gmatch("[^,]+") do
                local data, arch = vfs.find(code .. ".ani")
                if data then
                    ---@cast arch -nil
                    local info = sprite.parseAni(data)
                    for k = 0, 8 do
                        local a = info[k]
                        if a.used then
                            local name = code .. sprite.SUFFIX[k]
                            local sheet = vfs.find(name .. ".rle") or vfs.find(name .. ".bmp")
                            local w, h = 0, 0
                            if sheet and sheet:sub(1, 2) == "BM" then
                                w, h = bin.u32(sheet, 18), bin.u32(sheet, 22)
                            elseif sheet then
                                w, h = bin.u16(sheet, 6), bin.u16(sheet, 8)
                            end
                            log.info("%s[%d] %s frames %d eff %d,%d origin %d,%d size %dx%d act %d sheet %dx%d",
                                code, k, arch.key, a.frames, a.effect[1], a.effect[2], a.originX, a.originY,
                                a.width, a.height, a.effectActivation, w, h)
                        end
                    end
                else
                    log.warn("%s: no .ani", code)
                end
            end
            return 0
        end
    end
    local failures = 0
    ---@param name string
    ---@param cond any a true value passes
    local function check(name, cond)
        if cond then log.info("ok   %s", name) else log.error("FAIL %s", name) failures = failures + 1 end
    end
    -- a hand-built stand-in (map record, campaign state, screen ...) that carries only the fields the check reads
    ---@param t table
    ---@return any
    local function partial(t) return t end
    local cfg = vfs.read("System.xcr", "Army.cfg")
    check("decrypt Army.cfg", cfg and cfg:find("%[") ~= nil)
    if cfg then log.info("Army.cfg head: %q", cfg:sub(1, 120)) end
    local wav = vfs.read("Assets/SoundFX.xcr", "Whip.wav")
    check("read Whip.wav", wav and wav:sub(1, 4) == "RIFF")
    local bmp = vfs.find("NewScenario.bmp")
    check("find NewScenario.bmp", bmp and bmp:sub(1, 2) == "BM")
    -- scenarios
    local scn = require("src.formats.scn")
    local scnwrite = require("src.formats.scnwrite")
    local fs = require("src.core.fs")
    do
        -- the original file list's 40-byte name slots (binary FUN_00402ad0): longer names are left out
        local dir = love.filesystem.getSaveDirectory() .. "/selftest-filelist"
        fs.mkdirs(dir)
        local short, long = ("a"):rep(35) .. ".scn", ("b"):rep(36) .. ".scn"      -- 39 and 40 characters
        for _, n in ipairs({ short, long }) do
            local f = io.open(dir .. "/" .. n, "wb")
            if f then f:write("x") f:close() end
        end
        local got = fs.fileList(dir, "%.scn$")
        check("file list: names of 40 or more characters are left out (binary FUN_00402ad0)", #got == 1 and got[1] == short)
        for _, n in ipairs({ short, long }) do os.remove(dir .. "/" .. n) end
        love.filesystem.remove("selftest-filelist")     -- the (now empty) folder too (os.remove cannot on Windows)
    end
    local okCount, total = 0, 0
    for _, dir in ipairs({ "Scenario", "CampaignScenario" }) do
        for _, name in ipairs(fs.list(config.gamedir .. "/" .. dir, "%.scn$")) do
            total = total + 1
            local data = assert(fs.read(config.gamedir .. "/" .. dir .. "/" .. name))
            local s, err = scn.parse(data)
            local good = s and s.tiles and #s.armies + #s.buildings + #s.features > 0
            if good then
                ---@cast s -nil
                for _, a in ipairs(s.armies) do
                    if (a.x - 16) % 32 ~= 0 or (a.y - 12) % 24 ~= 0 then good = false end
                end
            end
            if good then
                -- the editor's writer must keep what it read (chunk order differs from the originals, so compare parsed)
                ---@cast s -nil
                local out = scnwrite.write(s)
                local again = scn.parse(out)
                local same = again and #again.armies == #s.armies and #again.buildings == #s.buildings
                    and #again.features == #s.features and scnwrite.write(again) == out
                if not same then good = false end
            end
            if good then okCount = okCount + 1 else log.warn("scn %s: %s", name, tostring(err or "bad positions")) end
            if name == "Bridges.SCN" and s then
                log.info("Bridges: %s %dx%d tiles %dx%d armies %d buildings %d features %d items %d events %d",
                    s.header.name, s.width, s.height, s.tilesW, s.tilesH, #s.armies, #s.buildings, #s.features,
                    #s.items, #s.events)
                local a, b = s.armies[1], s.buildings[1]
                if a then log.info("army %s owner %d side %d at %d,%d hits %d", a.code, a.owner, a.side, a.x, a.y, a.hits) end
                if b then log.info("building %s side %d at %d,%d anim %d dir %d", b.code, b.side, b.x, b.y, b.anim, b.dir) end
                log.info("tile0 %s part %d size %d", s.tiles[0].id, s.tiles[0].part, s.tiles[0].size)
                for i = 0, 6 do
                    local sd = s.sides[i]
                    log.info("side %d used %s race %d color %d team %d start %d,%d", i, tostring(sd.used), sd.race, sd.color, sd.team, sd.startX, sd.startY)
                end
            end
        end
    end
    check(("parse scenarios %d/%d"):format(okCount, total), okCount == total)
    -- events (src/formats/evt.lua): every shipped scenario's events survive read -> write -> read unchanged (as tables
    -- and, record by record, as bytes); the pool of EVENTS/*.EVT reads and is named by Names.cfg
    do
        local evt = require("src.formats.evt")
        local function same(a, b)
            if type(a) ~= "table" then return a == b end
            for k, v in pairs(a) do
                if k ~= "raw" and not same(v, b[k]) then return false end
            end
            for k in pairs(b) do if k ~= "raw" and a[k] == nil then return false end end
            return true
        end
        local events, bad = 0, 0
        for _, dir in ipairs({ "Scenario", "CampaignScenario", "Tutorial" }) do
            for _, name in ipairs(fs.list(config.gamedir .. "/" .. dir, "%.scn$")) do
                local s = scn.parse(assert(fs.read(config.gamedir .. "/" .. dir .. "/" .. name)))
                local again = s and scn.parse(scnwrite.write(s))
                if not again or not s or #again.events ~= #s.events then bad = bad + 1 else  -- (again implies s)
                    for i, e in ipairs(s.events) do
                        events = events + 1
                        if not same(e, again.events[i]) or scnwrite.eventRecord(e) ~= e.raw then bad = bad + 1 end
                    end
                end
            end
        end
        check(("scenario events round trip (%d events)"):format(events), events > 200 and bad == 0)
        local pool = evt.pool()
        local unnamed = 0
        for _, p in ipairs(pool) do
            if p.name == "Unknown Event" or #p.event.effects == 0 or not p.used then unnamed = unnamed + 1 end
        end
        check(("event pool %d templates"):format(#pool), #pool >= 39 and unnamed == 0)
    end
    -- the editor's event model: a pool event is added, edited, saved and fires in a battle
    do
        local lib = require("src.game.editorlib")
        local evt = require("src.formats.evt")
        local boot = require("src.game.boot")
        local sc = assert(boot.loadScenario("Bridges"))
        local entry
        for _, p in ipairs(evt.pool()) do if p.code == "EFLG" then entry = p end end
        local n0 = #lib.userEvents(sc)
        local e = assert(lib.addEvent(sc, entry))
        -- a timer event: after 1 second set flag 9, once (condition 0, no map position)
        e.cond.condition, e.onMap, e.seconds, e.shots = 0, false, 1, 1
        e.effects[1].number, e.effects[1].type = 9, 0
        local e2 = assert(lib.addEvent(sc, entry))
        e2.cond.condition, e2.onMap, e2.seconds = 0, false, 2
        e2.effects[1].number = 8
        check("editor events: add", #lib.userEvents(sc) == n0 + 2 and lib.moveEvent(sc, n0 + 2, -1) == n0 + 1)
        lib.removeEvent(sc, n0 + 1)         -- the second one moved up; drop it again
        local back = assert(scn.parse(scnwrite.write(sc)))
        local last = back.events[#back.events]
        check("editor events: saved", #back.events == #sc.events and last.effects[1].number == 9
            and last.cond.condition == 0 and last.seconds == 1 and last.code == "EFLG")
        local w = require("src.game.world").new(back, { player = 0 })
        for _ = 1, 30 * 3 do w:update(1 / 30) end
        check("editor events: edited event fires", w.events.flags[9] and not w.events.flags[8])
        -- a new scenario gets the standard victory event in slot 0 and reads back with it
        local ns = lib.newScenario("T", 64, "")
        local nb = assert(scn.parse(scnwrite.write(ns)))
        check("editor events: new scenario", #nb.events == 1 and nb.events[1].cond.condition == 10
            and #lib.userEvents(nb) == 0)
    end
    -- custom AI scripts: every shipped CustomAI/*.ai must parse and hold sane values
    do
        local aiparams = require("src.game.aiparams")
        local files = aiparams.list()
        check("custom AI scripts found", #files >= 14)
        local bad = 0
        for _, f in ipairs(files) do
            local p = aiparams.load(f.file)
            if not p or p.race < -1 or p.race > 15 then bad = bad + 1 else
                for _, t in ipairs({ p.army, p.powerup, p.building }) do
                    for _, pri in pairs(t) do
                        if pri < 0 or pri > 100 then bad = bad + 1 end
                    end
                end
                for k = 1, 6 do
                    if p.groups.min[k] > p.groups.max[k] then bad = bad + 1 end
                end
            end
        end
        check(("custom AI scripts %d/%d"):format(#files - bad, #files), bad == 0)
        -- the one shipped script with custom groups (the records are read, the AI does not use them)
        local bomber = aiparams.load("A_Bomber.ai")
        if bomber then
            local g = bomber.custom[3]
            check("custom AI groups (A_Bomber)", bomber.customGroups and g.used and g.name == "Tower Bombers"
                and g.attack.towers == 100 and g.sub[2].name == "Grunt Guys" and g.sub[2].min == 4
                and g.sub[2].max == 6 and #g.sub[2].armies == 3 and not bomber.custom[6].used)
        end
    end
    -- custom unit attitudes: every shipped CustomUnitAI/*.uai must parse, and the rule engine must know them
    do
        local uai = require("src.formats.uai")
        local attitude = require("src.game.attitude")
        local files = uai.files()
        check("custom attitudes found", #files >= 4)
        local bad = 0
        for _, f in ipairs(files) do
            local ai, why = uai.load(f.file)
            if not ai or ai.size < 1 or ai.size > 100 or ai.icon >= 12 or #ai.rules == 0 and not ai.idle then
                bad = bad + 1
                log.warn("uai %s: %s", f.file, tostring(why))
            else
                for _, r in ipairs(ai.rules) do
                    if r.priority > 100 or #r.conds == 0 or r.action.code > 10 then bad = bad + 1 end
                    for _, c in ipairs(r.conds) do
                        if c.code > 8 or c.unit > 2 then bad = bad + 1 end
                    end
                end
            end
            if not attitude.def[f.root] then bad = bad + 1 end
        end
        check(("custom attitudes %d/%d"):format(#files - bad, #files), bad == 0)
        local fb = uai.load("Fallback25.uai")
        check("Fallback25 rules", fb and #fb.rules == 2 and fb.icon == 10 and fb.rules[2].priority == 100
            and fb.rules[2].conds[1].code == 5 and fb.rules[2].conds[1].extra[1] == 25 and fb.rules[2].action.code == 0)
        check("attitude names", attitude.name("Fallback25") == "Fallback (25%)" and attitude.name("standard") ~= nil)
        require("src.tools.attitudetest").run(check)
    end
    -- editor model: new map, painting (incl. a big tile), objects, write and read back
    do
        local lib = require("src.game.editorlib")
        local terrainMod = require("src.game.terrain")
        local cat = lib.tileCatalog()
        check("tile catalogue", #cat.entries > 100 and lib.baseTile() ~= nil)
        local ns = lib.newScenario("Test", 64, "x")
        local terr = terrainMod.new(ns)
        local big
        for _, e in ipairs(cat.entries) do
            if e.kind == "tile" and select(2, lib.tileInfo(e.id)) == 1 then big = e break end
        end
        local changed = big and lib.paintTile(ns, terr, big, 2, 2)
        local code = (require("src.game.rules").armyList()[1] or {}).code
        lib.add(ns, "armies", code or "ACCO", 5, 5, 0)
        lib.add(ns, "buildings", (require("src.game.rules").buildingList()[1] or {}).code or "BRM1", 8, 8, 1)
        lib.setStart(ns, 0, 3, 3)
        ns.minimap = lib.minimap(ns, terr)
        local back = scn.parse(scnwrite.write(ns))
        check("editor scenario round trip", back and back.width == 64 and #back.tiles + 1 == 49 and #back.armies == 1
            and #back.buildings == 1 and back.sides[0].startX == 3 and back.header.name == "Test"
            and (not big or (changed and #changed == 4 and back.tiles[3 * 7 + 3].part == 3)))
    end
    -- scenario events: conditions only fire when they are met, effects follow their own numbers
    do
        local boot = require("src.game.boot")
        local sc = assert(boot.loadScenario("Bridges"))
        local function ev(cond, effects, extra)
            local e = { cond = { owner = 0, condition = cond, number = 1, target = 0xFFFFFFFF, flags = 0, radius = 1 },
                        effects = effects, code = "TEST", shots = 1, onMap = cond ~= 0, seconds = 0, x = 5, y = 5 }
            for k, v in pairs(extra or {}) do
                if k == "cond" then for ck, cv in pairs(v) do e.cond[ck] = cv end else e[k] = v end
            end
            return e
        end
        local function flag(n, slot) return { slot = slot or 1, effect = 2, number = n, type = 0, ownerType = 0, ownerData = 0, text = "", x = 0, y = 0, location = 0 } end
        local function sound() return { slot = 2, effect = 7, number = 0, type = 0, ownerType = 0, ownerData = 0, text = "x", x = 0, y = 0, location = 0 } end
        sc.events = {
            ev(5, { flag(3) }),                                           -- kill: not at the start
            ev(0, { flag(4) }, { seconds = 2, cond = { flags = 8 } }),    -- timer behind flag 3
            ev(0, { flag(5), sound() }, { seconds = 1 }),                 -- sound only once
            ev(2, { flag(6) }, { cond = { owner = 6 }, x = 120, y = 120 }), -- a hero far away
            ev(24, { flag(7) }),                                          -- the player selects an army
        }
        local target
        for _, b in ipairs(sc.buildings) do if b.side ~= 0 and b.side ~= 6 then target = b break end end
        local function pack(code) return code:byte(1) + code:byte(2) * 256 + code:byte(3) * 65536 + code:byte(4) * 16777216 end
        sc.events[#sc.events + 1] = ev(8, { flag(8) }, { cond = { target = pack(target.code) } })   -- razed by us
        local w = require("src.game.world").new(sc, { player = 0 })
        local sounds = 0
        w:listen(function(kind) if kind == "sound" then sounds = sounds + 1 end end)
        for _ = 1, 30 * 4 do w:update(1 / 30) end
        local fl = w.events.flags
        check("event: kill condition waits", not fl[3] and not fl[4])
        check("event: effects use their own number", fl[5] and sounds == 1)
        check("event: hero far away", not fl[6])
        local killer, victim
        for _, u in ipairs(w.units) do
            if u.side == 0 and not killer then killer = u end
            if u.side ~= 0 and not victim then victim = u end
        end
        if killer and victim then w:event("kill", killer, victim) end
        check("event: nothing selected yet", not fl[7])
        require("src.game.commands").apply(w, { t = "select", side = 0, ids = { killer.id } })
        local victimBuilding
        for _, b in ipairs(w.buildings) do if b.code == target.code and b.side == target.side then victimBuilding = b break end end
        w:damageBuilding(victimBuilding, 1e6, nil)           -- no attacker, no credit
        for _ = 1, 30 do w:update(1 / 30) end
        check("event: selection and unattributed razing", fl[7] and not fl[8])
        local other
        for _, b in ipairs(w.buildings) do if b.code == target.code and b.hp > 0 and b.side == target.side then other = b break end end
        if other then w:damageBuilding(other, 1e6, killer) end
        for _ = 1, 30 * 4 do w:update(1 / 30) end
        check("event: kill then flag-gated timer", fl[3] and fl[4])
        check("event: razing credited to the attacker", other == nil or fl[8])
    end
    -- end-of-battle experience (battlexp.lua): hand-computed from the original's rules
    do
        local bx = require("src.game.battlexp")
        local function sum(over)
            local t = { time = 600000, size = 128, tech = 5, pitched = false, campaign = false, fogMode = 1, me = 0,
                        sides = {
                [0] = { used = true, human = true, aiLevel = 2, resources = 2, allies = {}, defeated = false, won = true,
                        quests = 2, heroKills = 30, kills = 120, heroesSlain = 2, heroDied = false },
                [1] = { used = true, human = false, aiLevel = 2, resources = 2, allies = {}, defeated = true, won = false,
                        quests = 0, heroKills = 0, kills = 0, heroesSlain = 0, heroDied = false },
            } }
            for k, v in pairs(over or {}) do t[k] = v end
            return t
        end
        -- 5 (128 map) + 80 (victory alone) + 20 (2 quests) + 6 (30 hero kills) + 40 (120 kills) + 10 (side beaten)
        -- + 5 (a Knight opponent) + 20 (2 heroes slain) = 186, x 110 % (fog and hidden) = 204, tech 5: x 10 / 10
        check("battle xp: normal victory", bx.side(sum(), 0) == 204)
        local died = sum()
        died.sides[0].heroDied = true
        check("battle xp: a fallen hero keeps 3/4", bx.side(died, 0) == 153)
        -- the beaten side: 5 (map) + 4 (defeat) + 10 (it is defeated) = 19, x 110 % = 20
        check("battle xp: the loser gets 4 for the defeat", bx.side(sum(), 1) == 20)
        check("battle xp: short game", bx.side(sum({ time = 100000 }), 0) == 1 and bx.side(sum({ time = 100000, pitched = true }), 0) == 5
            and bx.side(sum({ time = 100000, tech = 0 }), 1) == 3 and bx.side(sum({ time = 100000 }), 1) == 0)
        check("battle xp: no fog / hidden map factors", bx.side(sum({ fogMode = 3 }), 0) == 148
            and bx.side(sum({ fogMode = 4 }), 0) == 167 and bx.side(sum({ fogMode = 2 }), 0) == 186)
        check("battle xp: tech level 0 shifts", bx.side(sum({ tech = 0 }), 0) == 25)
        local xp, removed = bx.local_(100, true, false, true, 5)
        local xp2, removed2 = bx.local_(100, true, true, true, 5)
        check("battle xp: ironman", xp == 200 and not removed and xp2 == 0 and removed2 and bx.local_(100, true, false, false, 999) == 0)
    end
    -- hero skills: the effect table of the binary and what the economy skills do
    do
        local HS = require("src.game.heroskills")
        check("skill effects (binary table)", HS.effect(2, 3) == 30 and HS.effect(35, 2) == 20 and HS.effect(51, 2) == 6
            and HS.effect(67, 3) == 6 and HS.effect(55, 4) == 4 and HS.effect(23, 2) == 10 and HS.effect(66, 2) == 40)
        local sc = assert(require("src.game.boot").loadScenario("Bridges"))
        local w = require("src.game.world").new(sc, { player = 0 })
        local hero = w.eco:heroAlive(0)
        if hero and hero.h then
            w.sides[0].gold, w.sides[0].stone = 0, 0
            w.eco:income(w.time)
            local g0, s0 = w.sides[0].gold, w.sides[0].stone
            w.sides[0].gold, w.sides[0].stone = 0, 0
            hero.h.skill[55], hero.h.skill[56] = 3, 2                  -- Wealth 3, Quarrying 2
            w.eco:income(w.time)
            check("skills: Wealth and Quarrying add to every income", w.sides[0].gold == g0 + 3 and w.sides[0].stone == s0 + 2)
            hero.hp = 0
            hero.state = "dead"
            w.sides[0].gold = 0
            w.eco:income(w.time)
            check("skills: nothing while the hero is dead", w.sides[0].gold == g0)
        end
        local ba = require("src.game.buildingabilities")
        check("skills: trade rate", ba.tradeRate(w, 0) >= 50 and ba.tradeRate(w, 0) <= 90)
    end
    -- unit special abilities against the 1.04 handler FUN_00426350 / button builder FUN_004d3200: spell, mana, one caster
    -- per press, Freeze's 45 / 20, Invisibility for every caster, the casting level (level + 1) / 5 + 1
    do
        local aa = require("src.game.armyabilities")
        local A = aa.ABILITIES
        check("abilities: Ring of Fire is spell 54, Purify spell 6, Pillar of Fire 35 mana, Freeze 45 / 20, Blending PBLE",
            A.ringOfFire.spell == 54 and A.purify.spell == 6 and A.pillarOfFire.mana == 35
            and A.freeze.mana == 45 and A.freeze.cost == 20 and A.invisibility.power.ALBX == "PBLE")
        local sc = assert(require("src.game.boot").loadScenario("Bridges"))
        local w = require("src.game.world").new(sc, { player = 0 })
        local hero = assert(w.eco:heroAlive(0))
        local function add(code, dx)
            local u = assert(w:addUnit(code, 0, hero.gx + dx, hero.gy + 4))
            u.mana, u.recoverUntil = 100, nil
            return u
        end
        local m1, m2 = add("AHGW", 0), add("AHGW", 1)
        check("abilities: a press casts with one unit", aa.use(w, 0, { m1, m2 }, "cure") == 1
            and m1.mana == 70 and m2.mana == 100)
        local ice = add("AEOX", 2)
        ice.mana = 25
        check("abilities: Freeze needs and takes 20", aa.use(w, 0, { ice }, "freeze") == 1 and ice.mana == 5)
        local g1, g2 = add("AKGX", 3), add("AKGX", 4)
        check("abilities: Invisibility for every selected caster", aa.use(w, 0, { g1, g2 }, "invisibility") == 2
            and g1.mana == 65 and g2.mana == 65)
        local lvl, on = nil, true
        w:listen(function(kind, _, _, c) if on and kind == "spellbegin" then lvl = c and c.lvl end end)
        m2.level, m2.recoverUntil = 4, nil
        aa.use(w, 0, { m2 }, "cure")
        local four = lvl
        m1.level, m1.recoverUntil, m1.mana = 3, nil, 100
        aa.use(w, 0, { m1 }, "cure")
        on = false
        check("abilities: the casting level is (level + 1) / 5 + 1", four == 2 and lvl == 1)
    end
    -- building abilities against the 1.04 button handlers 0x004d0c50..0x004d1e10 and the computer's FUN_00501940 /
    -- FUN_005018b0 / FUN_005019d0 / FUN_005013e0: prices, the one-second timer, what the computer pays, who sees a button
    do
        local ba = require("src.game.buildingabilities")
        local B = ba.byId
        check("building abilities: Chaos Plague 1000 crystal, Sword of Sirian 200, Couatl's Wrath 750 gold",
            B.chaosPlague.crystal == 1000 and B.swordOfSirian.crystal == 200 and B.wrath.gold == 750)
        local sc = assert(require("src.game.boot").loadScenario("Bridges"))
        local w = require("src.game.world").new(sc, { player = 0 })
        local side = w.sides[0]
        local hero = assert(w.eco:heroAlive(0))
        side.powerups = side.powerups or {}
        local function building(code, power)
            local b = w:addBuilding({ code = code, side = 0, x = (hero.gx + 8) * 32 + 16, y = hero.gy * 24 + 12 })
            b.complete = true
            if power then side.powerups[power] = true end
            return b
        end
        local wrath = building("BKL0", "PCWR")
        side.gold = 749
        local short = ba.use(w, 0, wrath, "wrath")
        side.gold = 750
        local early = ba.use(w, 0, wrath, "wrath")
        w.time = w.time + 1001
        local ok = ba.use(w, 0, wrath, "wrath")
        check("building abilities: Wrath needs 750 gold, a short press arms the 1 s timer, a use takes 750",
            not short and not early and ok and side.gold == 0)
        local sword = building("BPSS", "PSWS")
        side.crystal = 200
        check("building abilities: Sword of Sirian takes 200 crystal", ba.use(w, 0, sword, "swordOfSirian") and side.crystal == 0)
        local famine = building("BKR0")
        local race = side.race
        side.race = 14
        local shown = false
        for _, e in ipairs(ba.of(w, famine)) do if e.def.id == "famine" then shown = true end end
        side.powerups.PFA0 = true
        local bought = false
        for _, e in ipairs(ba.of(w, famine)) do if e.def.id == "famine" then bought = true end end
        side.crystal = 500
        local used = ba.use(w, 0, famine, "famine")
        local paid = side.crystal
        side.crystal = 700
        ba.use(w, 0, famine, "famine", true)
        check("building abilities: Famine shows with the power-up, the button takes 500, the computer nothing",
            not shown and bought and used and paid == 0 and side.crystal == 700)
        side.race = 7
        local hostel = building("BPHS")
        local trade = false
        for _, e in ipairs(ba.of(w, hostel)) do if e.def.id == "trade" then trade = true end end
        check("building abilities: the Hostel offers Trade to the Wood Elves", trade)
        local healer = building("BPHE", "PELC")
        side.ai = true
        side.crystal = 399
        local poor = ba.use(w, 0, healer, "elcorsBalm", true)
        side.crystal = 400
        local rich = ba.use(w, 0, healer, "elcorsBalm", true)
        check("building abilities: the computer's Elcor's Balm needs 400 crystal and pays 300",
            not poor and rich and side.crystal == 100)
        side.ai, side.race = nil, race
        side.powerups.PAS0, side.powerups.PSLH = true, true
        local limit = w.eco.armyLimit
        w.eco.armyLimit = function() return 30, 30 end
        check("building abilities: Summon Wraith is not greyed by a full army, Slave Horde is",
            ba.usable(w, 0, B.summonWraith) and not ba.usable(w, 0, B.slaveHorde))
        w.eco.armyLimit = limit
    end
    -- the KeyMap.txt ability keys (abilitykeys.lua) against FUN_00426350 / FUN_00427cf0 / FUN_00427e30: the selected
    -- caster, the on-screen fallback in column order, Invisibility's selection loop, a building case without payment
    do
        local keys = require("src.game.abilitykeys")
        local commands = require("src.game.commands")
        local sc = assert(require("src.game.boot").loadScenario("Bridges"))
        local w = require("src.game.world").new(sc, { player = 0 })
        local hero = assert(w.eco:heroAlive(0))
        local function add(code, dx, dy)
            local u = assert(w:addUnit(code, 0, hero.gx + dx, hero.gy + (dy or 4)))
            u.maxMana, u.mana, u.recoverUntil = math.max(u.maxMana or 0, 100), 100, nil
            return u
        end
        local function run(cmds)
            for _, c in ipairs(cmds) do
                c.side = 0
                commands.apply(w, c)
            end
        end
        local x0, y0 = hero.gx, hero.gy + 3
        local view = { x0, y0, x0 + 8, y0 + 2 }
        local far = add("AHGW", 30, 30)
        local right, left = add("AHGW", 6), add("AHGW", 2)
        local cmds, done = keys.press(w, 0, { 11 }, { far }, view)         -- Cure (case 0xb), Far Mage selected
        check("ability keys: the selected caster casts and the key is used up", done and #cmds == 1
            and cmds[1].ids[1] == far.id and cmds[1].key)
        run(cmds)
        check("ability keys: the cast takes the mana", far.mana == 70 and left.mana == 100)
        far.mana = 10
        cmds, done = keys.press(w, 0, { 11 }, { far }, view)
        check("ability keys: without mana in the selection, the first caster on the screen (column order)",
            done and #cmds == 1 and cmds[1].ids[1] == (left.gx <= right.gx and left or right).id)
        -- a Cure button press (hud: the record's case, as the 1.04 action 0x004cf9d0 pushes 0xb): the selected mage is
        -- out of mana, so one on the screen casts
        local aa = require("src.game.armyabilities")
        cmds, done = keys.case(w, 0, aa.ABILITIES.cure.key, { far }, view)
        run(cmds)
        check("ability keys: a button press with no caster in the selection uses one on the screen",
            done and #cmds == 1 and cmds[1].ids[1] ~= far.id and far.mana == 10
            and (left.mana == 70 or right.mana == 70))
        cmds, done = keys.press(w, 0, { 11 }, { far }, { x0 + 40, y0 + 40, x0 + 41, y0 + 41 })
        check("ability keys: nothing on the screen, the key goes on to the next case / shortcut", not done and #cmds == 0)
        local g1, g2 = add("AKGX", 1, 6), add("AKGX", 3, 6)
        cmds, done = keys.press(w, 0, { 13 }, { g1, g2 }, view)            -- Invisibility (case 0xd)
        check("ability keys: Invisibility casts with every selected Black Guard and is not done",
            not done and #cmds == 1 and #cmds[1].ids == 2)
        run(cmds)
        check("ability keys: Invisibility's loop pays for each caster", g1.mana == 65 and g2.mana == 65)
        local side = w.sides[0]
        side.powerups = side.powerups or {}
        side.powerups.PCN0 = true
        local temple = w:addBuilding({ code = "BKG0", side = 0, x = (hero.gx + 8) * 32 + 16, y = hero.gy * 24 + 12 })
        temple.complete = true
        side.crystal = 1000
        cmds, done = keys.press(w, 0, { 34 }, {}, view)                    -- Chaos Plague (case 0x22), found on the map
        check("ability keys: Chaos Plague finds its building anywhere and is not done", not done and #cmds == 1
            and cmds[1].bid == temple.id)
        local fx0 = #(w.effects or {})
        run(cmds)
        run(cmds)
        check("ability keys: Chaos Plague's key casts twice in a row (no timer) and takes nothing",
            #(w.effects or {}) == fx0 + 2 and side.crystal == 1000)
        side.crystal = 999
        cmds = keys.press(w, 0, { 34 }, {}, view)
        run(cmds)
        check("ability keys: Chaos Plague's key still asks for the price", #w.effects == fx0 + 2)
    end
    -- hero skills in battle: troop-XP lords, rune hits, the hero's melee skills, Leech, Vampirism, Assassin, Shadow Strength
    do
        local Unit = require("src.game.unit")
        local pu = require("src.game.powerups")
        local sc = assert(require("src.game.boot").loadScenario("Bridges"))
        local w = require("src.game.world").new(sc, { player = 0 })
        local hero = w.eco:heroAlive(0)
        local h = hero and hero.h
        if h then
            ---@cast hero -nil
            local function set(id, n) h.skill[id] = n h:recalc() end
            local base = w.eco:initialXp(0, "ADBX")
            set(87, 3)                                                  -- Brewmaster 3: 12 for dwarves only
            check("lords: Brewmaster gives dwarves experience", w.eco:initialXp(0, "ADBX") == base + 12
                and w.eco:initialXp(0, "AHBX") == base)
            set(98, 2)                                                  -- Slimemaster 2: 10 for the Slime
            check("lords: Slimemaster is unit specific", w.eco:initialXp(0, "AGSL") == base + 10
                and w.eco:initialXp(0, "ADBX") == base + 12)
            w.sides[0].powerups = w.sides[0].powerups or {}
            w.sides[0].powerups.PGA0 = true
            check("lords: Gate power-up only when asked for", w.eco:initialXp(0, "AHBX", { gate = true }) == base + 20
                and w.eco:initialXp(0, "AHBX") == base and w.eco:initialXp(0, "AHBX", { training = false }) == 0)
            hero.mana = 100                                             -- a summoning spell starts armies with the Gate XP
            local spiders = 0
            for _, u in ipairs(w.units) do if u.code == "AKLX" and u.side == 0 then spiders = spiders + 1 end end
            local cast = require("src.game.spells").unitCast(hero, -4, 0)
            local made
            for _, u in ipairs(w.units) do
                if u.code == "AKLX" and u.side == 0 then spiders = spiders - 1 if spiders < 0 then made = u end end
            end
            check("gate: a summoned army starts with the Gate power-up experience", cast and made and made.xp == 20)
            do      -- a full army limit: the summon does nothing, the announcer is told (the army-limit check FUN_005776c0)
                local realLimit, heard, on = w.eco.armyLimit, nil, true
                w:listen(function(kind, a, b) if on and kind == "toomanymen" then heard = { a, b } end end)
                ---@diagnostic disable-next-line: duplicate-set-field -- a stub, restored below
                w.eco.armyLimit = function() return 20, 20 end
                local units0 = #w.units
                hero.mana, hero.recoverUntil = 100, nil
                local spells = require("src.game.spells")
                spells.unitCast(hero, -4, 0)
                check("army limit: a summon spell makes nothing when the unit value does not fit", #w.units == units0)
                check("army limit: the refusal raises 'too many men' for the side, forced", heard and heard[1] == hero.side
                    and heard[2] == true)
                local mana = hero.mana
                hero.recoverUntil = nil
                local ok, why = spells.unitCast(hero, -4, 20, nil, "AKLX")
                check("army limit: a button's check comes before the mana is spent", not ok and why == "limit" and hero.mana == mana)
                ---@diagnostic disable-next-line: duplicate-set-field -- a stub, restored below
                w.eco.armyLimit = function() return 17, 20 end                  -- a Queen Spider's unit value is above 3
                heard, hero.recoverUntil = nil, nil
                local t = assert(require("src.game.gamedata").army("AKLX"))
                local fits = 17 + (t.unitValue or 0) <= 20            -- 1: it fits
                spells.unitCast(hero, -4, 0)
                check("army limit: current + unit value above the maximum is refused, otherwise it fits",
                    (#w.units > units0) == fits and (heard ~= nil) == (not fits))
                -- the host makes the armies one by one and stops when the count reaches the limit (FUN_004aa840 case 6):
                -- Quasits at result 4 (four of them) with room for two
                local qv = math.max(1, assert(require("src.game.gamedata").army("AVBX")).unitValue or 1)
                local before = #w.units
                local function newOf(code)
                    local n = 0
                    for i = before + 1, #w.units do if w.units[i].code == code and w.units[i].side == 0 then n = n + 1 end end
                    return n
                end
                ---@diagnostic disable-next-line: duplicate-set-field -- a stub, restored below
                w.eco.armyLimit = function() return 20 - 2 * qv + newOf("AVBX") * qv, 20 end
                hero.recoverUntil = nil
                spells.castItemSpell(hero, 10, 4)
                check("army limit: a summon stops making armies when the side reaches its limit", newOf("AVBX") == 2)
                -- the number of armies: the result level only where the binary's summon routine sets it, otherwise one
                ---@diagnostic disable-next-line: duplicate-set-field -- a stub, restored below
                w.eco.armyLimit = function() return 0, 250 end
                local ONE = { [14] = "AAIM", [19] = "AADE", [29] = "AAEA AAEE AAEF AAEW", [37] = "AUXX", [43] = "AUJX",
                              [49] = "AUXX AUMX AUGX AUAX" }
                for _, id in ipairs({ 14, 19, 29, 37, 43, 49 }) do
                    before = #w.units
                    hero.recoverUntil = nil
                    spells.castItemSpell(hero, id, 4)
                    local n, ok = 0, true
                    for i = before + 1, #w.units do
                        n = n + 1
                        if not ONE[id]:find(w.units[i].code, 1, true) then ok = false end
                    end
                    check("summons: spell " .. id .. " makes one army at result 4 (the binary's count 1)", n == 1 and ok)
                end
                -- the four-choice spells (FUN_0057dd20 / FUN_0057ea70): the dialog's pick, carried by the cast command, is
                -- the army; the computer never casts them (FUN_00502ed0)
                local fxlib, commands = require("src.game.fx"), require("src.game.commands")
                for _, id in ipairs({ 29, 49 }) do
                    local codes = {}
                    for code in ONE[id]:gmatch("%S+") do codes[#codes + 1] = code end
                    local made = true
                    for i = 0, 3 do
                        before = #w.units
                        spells.defs[id].run(fxlib.ctx(hero, id, { choice = i }, 2))
                        made = made and #w.units == before + 1 and w.units[#w.units].code == codes[i + 1]
                    end
                    check("choice spells: spell " .. id .. " makes the chosen army for each of the four", made
                        and spells.targetKind(id) == "choice" and #spells.choices(id) == 4 and spells.defs[id].ai == nil)
                    hero.recoverUntil, hero.pendingCast = nil, nil
                    local known, mana0 = hero.h.spells[id], hero.h.mana
                    hero.h.spells[id], hero.h.mana = true, 500
                    commands.apply(w, { t = "cast", id = hero.id, spell = id, target = { choice = 3 }, side = hero.side })
                    local pc = hero.pendingCast
                    hero.pendingCast = nil
                    commands.apply(w, { t = "cast", id = hero.id, spell = id, target = { choice = 7 }, side = hero.side })
                    local bad = hero.pendingCast
                    hero.pendingCast, hero.h.spells[id], hero.h.mana = nil, known, mana0
                    check("choice spells: the cast command carries the choice, a choice outside 0..3 is refused",
                        pc and pc.id == id and pc.target.choice == 3 and bad == nil)
                end
                check("choice spells: Change Weather has the four weather pictures", spells.targetKind(28) == "choice"
                    and spells.choices(28)[4].picture == "EWTH" and spells.choices(28)[4].frame == 3)
                before = #w.units
                hero.recoverUntil = nil
                spells.castItemSpell(hero, 40, 3)
                check("summons: Raise Skeleton makes result + 1", newOf("AUIX") == 4)
                w.eco.armyLimit = realLimit
                on = false
            end
            do      -- hit list: a hit without an inflictor counts (the victim is its own inflictor), poison is no hit
                local victim = w:addUnit("AHBX", 0, hero.gx + 6, hero.gy + 6)
                if victim then
                    local st = require("src.game.status")
                    w.hitList = {}
                    victim.maxHp, victim.hp = 100, 100
                    st.poison(victim)
                    local f = victim.fx.poison
                    f.nextTick = w.time
                    st.update(victim, w.time)
                    check("hit list: poison takes hit points off without a hit", victim.hp == 99 and #w.hitList == 0 and not victim.wasHit)
                    victim:takeDamage(1, nil)
                    check("hit list: a hit without an inflictor is listed with the victim as its own inflictor",
                        #w.hitList == 1 and w.hitList[1].vic == victim and w.hitList[1].inf == victim)
                    victim:die(w.time)
                end
            end
            set(61, 2)                                                  -- Life Rune 2: 10 percent of a Unicorn's hits
            check("runes: Life Rune raises Unicorn hits", w.eco:runeHits(0, "AEDX", 100) == 10
                and w.eco:runeHits(0, "AHBX", 100) == 0)
            local foe = w:addUnit("AHBX", 1, hero.gx + 4, hero.gy)     -- a human
            local dwarf = w:addUnit("ADBX", 1, hero.gx + 4, hero.gy + 2)
            if foe and dwarf then
                set(35, 2)                                              -- Manslayer 2: 20 against humans
                set(39, 1)                                              -- Dwarfslayer 1: 10 against dwarves
                set(46, 1)                                              -- Demolition 1: 10 against buildings
                check("melee skills: slayers by target kind", Unit.heroMeleeBonus(hero, foe) == 20
                    and Unit.heroMeleeBonus(hero, dwarf) == 10 and Unit.heroMeleeBonus(hero, { kind = "building" }) == 10)
                ---@param target Unit
                ---@return number lost hit points
                local function loss(target)
                    local saved = math.random
                    ---@diagnostic disable-next-line: duplicate-set-field -- a stub, restored below
                    math.random = function() return 1 end              -- a deathblow
                    target.hp, target.maxHp = 100000, 100000
                    hero:strike(target)
                    math.random = saved
                    return 100000 - target.hp
                end
                local with = loss(foe)
                set(35, 0)
                check("melee skills: Manslayer raises the damage of a strike", with > loss(foe))
                set(53, 2)
                check("hero combat: Vampirism skill", h.mod.vampirism == h:effect(53) and h.mod.vampirism > 0)
                set(51, 2)
                check("hero combat: Assassin skill", pu.assassin(hero) == 6)
                local d0 = h.mod.damage
                set(34, 2)
                check("hero combat: Mighty Blow adds damage", h.mod.damage == d0 + 4)
                local weather = require("src.game.weather")
                local c0 = hero:stats().combat
                w.night = true
                local race = weather.combatMod(w, hero.code)            -- the hero's own race at night / by day
                w.night = false
                race = race - weather.combatMod(w, hero.code)
                w.night = true
                set(54, 2)
                check("hero combat: Shadow Strength only at night", hero:stats().combat == math.max(1, c0 + 10 + race))
                w.night = false
                check("hero combat: no Shadow Strength by day", hero:stats().combat == c0)
                set(52, 3)                                              -- Leech 3: 6 mana per kill, once a second
                h.mana = 0
                require("src.game.spells").onKill(hero, foe)
                local m1 = h.mana
                require("src.game.spells").onKill(hero, foe)
                local m2 = h.mana
                w.time = w.time + 1001
                require("src.game.spells").onKill(hero, foe)
                check("hero combat: Leech gives mana per kill with a pause", m1 == 6 and m2 == 6 and h.mana == 12)
            end
        end
    end
    -- one-shot power-ups: Spell / Arcane Research, foreign mercenaries, Knight's Quest
    do
        local pu = require("src.game.powerups")
        local spells = require("src.game.spells")
        local sc = assert(require("src.game.boot").loadScenario("Bridges"))
        local w = require("src.game.world").new(sc, { player = 0 })
        local hero = w.eco:heroAlive(0)
        local h = hero and hero.h
        local events = {}
        w:listen(function(kind, a, b, c) events[#events + 1] = { kind, a, b, c } end)
        local function total() local n = 0 for _, v in pairs(w.sides[0].spellBonus or {}) do n = n + v end return n end
        check("one-shot: research and mercenaries are never owned", pu.exists("PSPR") and pu.exists("POMC")
            and pu.offered(w.sides[0], "PSPR") and pu.offered(w.sides[0], "POMA") and pu.offered(w.sides[0], "PQKN"))
        if h then
            ---@cast hero -nil
            local before = {}
            for s = 0, 12 do before[s] = spells.castSkill(h, s) end
            pu.grant(w, 0, "PSPR")
            check("research: Spell Research gives +1 to one sphere", total() == 1 and events[#events][1] == "spellresearch"
                and events[#events][3] ~= nil and events[#events][4] == 1)
            local sphere = events[#events][3]
            check("research: it adds to the hero's casting skill", spells.castSkill(h, sphere) == before[sphere] + 1)
            pu.grant(w, 0, "PARR")
            check("research: Arcane Research gives +2 and the power-up stays on offer", total() == 3
                and not pu.has(w.sides[0], "PSPR") and pu.offered(w.sides[0], "PARR"))
            hero.hp, hero.state = 0, "dead"
            local n = #events
            pu.grant(w, 0, "PSPR")
            check("research: nothing without a living hero (game string 0x83)", total() == 3 and events[n + 1]
                and events[n + 1][1] == "spellresearch" and events[n + 1][3] == nil)
            hero.hp, hero.state = hero.maxHp, "idle"
        end
        -- foreign mercenaries: a unit of the level's list at the building, above the army limit
        local keep
        for _, b in ipairs(w.buildings) do
            if b.side == 0 and b.complete and b.hp > 0 and not keep then keep = b end
        end
        if keep then
            ---@type boolean?
            local ok = true
            for _, level in ipairs({ "POMA", "POMB", "POMC" }) do
                local count = #w.units
                local u = pu.foreignMercenary(w, 0, level, keep)
                ---@type boolean?
                local inList = false
                for _, c in ipairs(assert(pu.mercenaries(level))) do inList = inList or (u and u.code == c) end
                ok = ok and u ~= nil and inList and #w.units == count + 1 and u.side == 0
            end
            check("mercenaries: one unit of each level's list for the side", ok and #pu.mercenaries("POMA") == 28
                and #pu.mercenaries("POMB") == 27 and #pu.mercenaries("POMC") == 15)
            local cur, max = w.eco:armyLimit(0)
            w.sides[0].gold = 10000
            for _ = 1, 40 do pu.foreignMercenary(w, 0, "POMA", keep) end
            local cur2 = w.eco:armyLimit(0)
            check("mercenaries: they ignore the army limit", cur2 > max and cur2 > cur)
        end
        -- Fame cheapens the mercenaries by 25 / 33 / 50 percent
        local base = w.eco:itemInfo("POMC", 0).cost.gold
        w.sides[0].powerups = w.sides[0].powerups or {}
        w.sides[0].powerups.PFM0 = true
        local c1 = w.eco:itemInfo("POMC", 0).cost.gold
        w.sides[0].powerups.PFM1 = true
        local c2 = w.eco:itemInfo("POMC", 0).cost.gold
        w.sides[0].powerups.PFM2 = true
        local c3 = w.eco:itemInfo("POMC", 0).cost.gold
        check("mercenaries: Fame discount", c1 == math.floor(base * 75 / 100) and c2 == math.floor(base * 67 / 100)
            and c3 == math.floor(base * 50 / 100))
        w.sides[0].powerups.PFM0, w.sides[0].powerups.PFM1, w.sides[0].powerups.PFM2 = nil, nil, nil
        -- Knight's Quest: four candidates, the first free slot takes the choice, permanent after three picks
        local cand = pu.questCandidates(w, 0)
        check("quest: four candidate foes", #cand == 4)
        local foe = cand[1]
        check("quest: choosing fills the first free slot", pu.chooseFoe(w, 0, 1) and pu.questFoes(w.sides[0])[1] == foe
            and not pu.chooseFoe(w, 0, 1))
        pu.chooseFoe(w, 0, 2)
        pu.knightsQuest(w, 0)
        check("quest: not permanent with two foes", not pu.has(w.sides[0], "PQKN"))
        pu.chooseFoe(w, 0, 3)
        pu.knightsQuest(w, 0)
        check("quest: permanent once three were chosen", pu.has(w.sides[0], "PQKN") and not pu.offered(w.sides[0], "PQKN"))
        pu.chooseFoe(w, 0, 4)
        check("quest: four slots", #pu.questFoes(w.sides[0]) == 4 and not pu.chooseFoe(w, 0, 1))
        local knight, victim = { code = "AHFX", side = 0, world = w }, { code = foe, kind = "unit" }
        local squire, human = { code = "AHBX", side = 0, world = w }, { code = "AHBX", kind = "unit" }
        check("quest: a knight killing a chosen foe gets 25 experience (50 with the Order of the Grail)",
            pu.questKillXp(knight, victim) == 25 and (function()
                w.sides[0].powerups.POGL = true
                local v = pu.questKillXp(knight, victim)
                w.sides[0].powerups.POGL = nil
                return v == 50
            end)() and pu.questKillXp(squire, victim) == 0
            and pu.questKillXp(knight, human) == 0)
    end
    -- weather: the combat modifiers of the army combat value (FUN_0051bd10), the timer's transition tables, the spell
    -- kinds, save / load
    do
        local weather = require("src.game.weather")
        local pu = require("src.game.powerups")
        local sc = assert(require("src.game.boot").loadScenario("Bridges"))
        local w = require("src.game.world").new(sc, { player = 0 })
        local function mod(code, night, rain)
            w.night, w.raining = night, rain
            return weather.combatMod(w, code)
        end
        -- the 1.04 binary's rules (FUN_0051bd10): night Orcs / Undead +2, Dark Elves +1, Humans -1, Shadow +5; day High
        -- Elves / Ssrathi +1; rain Dwarves -1, Undead / Daemons +1; no rain Wood Elves / Fey +1
        check("weather: Orc +2 at night, Human -1", mod("AOBX", true, true) == 2 and mod("AHBX", true, true) == -1)
        check("weather: Dwarf -1 in rain, +0 by day without", mod("ADBX", false, true) == -1 and mod("ADBX", false, false) == 0)
        check("weather: Undead +2 at night and +1 in rain", mod("AUIX", true, true) == 3 and mod("AUIX", false, false) == 0)
        check("weather: Shadow +5 at night", mod("AUXX", true, true) == 8)
        check("weather: High Elf +1 by day", mod("AEIX", false, true) == 1 and mod("AEIX", true, true) == 0)
        check("weather: Wood Elf +1 without rain", mod("AWIX", false, false) == 1 and mod("AWIX", false, true) == 0)
        check("weather: Dark Elf +1 at night", mod("AKIX", true, true) == 1)
        w.night, w.raining = false, false
        -- the unit stats carry it, at least 1
        local orc
        for _, u in ipairs(w.units) do if u.code == "AOBX" or pu.flags(u.code) % 512 >= 256 then orc = u break end end
        if orc then
            local c = orc:stats().combat
            w.night = true
            check("weather: unit combat at night", orc:stats().combat == math.max(1, c + 2))
            w.night = false
        end
        -- the weather state (FUN_0049e320) only sees night / rain / storm
        w.night, w.raining, w.lightning = false, false, false
        check("weather: state 0", weather.state(w) == 0)
        w.raining = true
        check("weather: state 1", weather.state(w) == 1)
        w.lightning = true
        check("weather: state 4", weather.state(w) == 4)
        w.night = true
        check("weather: state 11", weather.state(w) == 11)
        -- spells: Storm at night makes a night storm, a transition blocks the next spell, Light / Darkness flips
        w.night, w.raining, w.lightning, w.shift = false, false, false, nil
        check("weather: Rain spell", weather.spell(w, 1) and w.raining and not w.lightning and w.rainTarget == 300
            and w.rainDrops == 30 and w.rainBase == 80)
        check("weather: Light / Darkness keeps the rain", weather.lightDarkKind(w) == 3)
        check("weather: Storm kind", weather.stormKind(w, 1) == 1 and weather.stormKind(w, 2) == 4)
        weather.spell(w, 0)
        -- the rain finish (FUN_0049bd90) only marks the rain: the rain test (FUN_0049bb10) stays true while the drops thin
        -- out to the base level (FUN_0049b6d0)
        check("weather: spell kind 0 marks the rain as ending, it still rains", w.raining and w.rainEnding)
        w.weatherAt = w.time + 1e9                                  -- keep the random timer out of this check
        w.rainDrops, w.rainFrame = 100, math.floor(w.time / weather.TICK)
        w.time = math.floor(w.time + 10.5 * weather.TICK) + 1
        weather.update(w)
        check("weather: an ending rain loses one drop a frame", w.raining and w.rainDrops == 90)
        w.time = math.floor(w.time + 10 * weather.TICK) + 1
        weather.update(w)
        check("weather: the rain ends at the base level", not w.raining and w.rainDrops == 0 and not w.lightning)
        weather.setRain(w, 0, false)
        weather.finishRain(w)
        w.time = math.floor(w.time + 300 * weather.TICK) + 1
        w.weatherAt = w.time + 1e9
        weather.update(w)
        check("weather: a rain ended below its base level never ends (the binary's quirk)",
            w.raining and w.rainDrops == 30)
        w.raining, w.rainEnding = false, false
        weather.setRain(w, 2, false)                                -- heavy: base 512, capped to the target 300
        w.rainDrops, w.time = 299, math.floor(w.time + 3 * weather.TICK)
        w.weatherAt = w.time + 1e9
        weather.update(w)
        check("weather: the rain grows by one drop a frame to the target", w.rainDrops == 300 and w.rainBase == 300)
        weather.finishRain(w)
        w.time = math.floor(w.time + 2 * weather.TICK) + 1
        weather.update(w)
        check("weather: a heavy rain at full strength ends at once", not w.raining)
        w.night, w.shift = false, nil
        check("weather: night spell starts a transition", weather.spell(w, 2) and weather.transitioning(w) and not w.night)
        check("weather: a transition refuses the next spell", weather.spell(w, 0) == false)
        w.time = w.time + 3000
        weather.update(w)
        check("weather: the night comes with the end of the transition", w.night and not weather.transitioning(w))
        weather.spell(w, 5)
        check("weather: storm kind 5", w.raining and w.lightning and w.rainTarget == 80)
        -- the timer: day, fine never changes without random weather; a rainy day always rolls (seeded)
        w.night, w.raining, w.lightning, w.shift = false, false, false, nil
        w.randomWeather = false
        w.weatherAt = w.time - weather.MIN_TIME
        weather.update(w)
        -- the transition tables, state by state as in the jump tables of FUN_0049e360 (case 2 fine, case 1 improve)
        local tr = weather.TRANSITIONS
        local function same(t, want) for s = 0, 13 do if (t[s] or s) ~= want[s + 1] then return false end end return true end
        check("weather: the fine / improve / worsen / hell transitions are the binary's",
            same(tr.fine, { 0, 0, 0, 1, 0, 0, 1, 0, 0, 1, 8, 1, 8, 8 }) and same(tr.improve, { 0, 0, 1, 1, 0, 4, 4, 0, 0, 8, 8, 8, 11, 11 })
            and same(tr.hell, { 13, 6, 6, 13, 6, 6, 13, 10, 10, 13, 13, 13, 13, 6 }) and tr.worsen[1] == 2 and tr.worsen[13] == 6)
        check("weather: day, fine stays", not w.night and not w.raining and w.weatherAt == w.time + weather.MIN_TIME)
        -- 2000 timer rolls from "day, light rain" (state 1): it must always end in a state of the table
        local seen = {}
        math.randomseed(42)
        for _ = 1, 400 do
            w.night, w.raining, w.lightning, w.shift, w.rainEnding = false, true, false, nil, false
            w.weatherAt = w.time - weather.MIN_TIME
            weather.update(w)
            -- a rain that the rain finish marked is fine weather in the making (it keeps raining while it thins out)
            seen[(w.rainEnding and 0 or weather.state(w)) .. (w.night and "n" or "d")] = true
        end
        check("weather: timer from day / light rain reaches fine and storms", seen["0d"] and seen["2d"] == nil
            and (seen["4d"] or seen["1d"]))
        -- save / load round trip of the weather record
        w.night, w.raining, w.lightning, w.rainTarget = true, true, true, 150
        w.rainDrops, w.rainBase, w.rainEnding = 77, 80, true
        w.shift = { to = "day", t0 = w.time - 500, t1 = w.time + 2000, per = 13 }
        local d = weather.save(w)
        w.night, w.raining, w.lightning, w.rainTarget, w.shift = false, false, false, 0, nil
        w.rainDrops, w.rainBase, w.rainEnding = 0, 0, false
        weather.load(w, d)
        check("weather: save / load", w.night and w.raining and w.lightning and w.rainTarget == 150 and w.shift
            and w.rainDrops == 77 and w.rainBase == 80 and w.rainEnding
            and w.shift.to == "day" and math.abs(w.shift.t1 - w.shift.t0 - 52 * weather.TICK) < 1)
    end
    -- unit specials: death specials, critter pick-ups, ammunition, army limit bonus, damage spell override
    do
        local specials = require("src.game.unitspecials")
        local status = require("src.game.status")
        local sc = assert(require("src.game.boot").loadScenario("Bridges"))
        local w = require("src.game.world").new(sc, { player = 0 })
        local hero = assert(w.eco:heroAlive(0))
        local bx, by = hero.gx + 6, hero.gy + 6
        local function count(code, side)
            local n = 0
            for _, u in ipairs(w.units) do if u.code == code and u.side == side and u:alive() then n = n + 1 end end
            return n
        end
        -- titan: ten balls, fire for a Human / Dwarf titan, magic for the V A F K U G races
        local titan = w:addUnit("ATHX", 1, bx, by)
        local m0 = #w.missiles
        if titan then titan:die(w.time, nil) end
        check("titan explosion: ten fire balls", titan and #w.missiles - m0 == 10 and w.missiles[#w.missiles].code == "EMTF")
        local titan2 = w:addUnit("ATVX", 1, bx, by)
        m0 = #w.missiles
        if titan2 then titan2:die(w.time, nil) end
        check("titan explosion: magic balls for the Daemons", titan2 and #w.missiles - m0 == 10
            and w.missiles[#w.missiles].code == "EMTM")
        w.missiles = {}                       -- the balls would burst over the units of the tests that follow
        -- Ancient Treant -> two Treants, Spider Priestess -> six Spiders
        local t0 = count("AWJX", 1)
        local oak = w:addUnit("AWKX", 1, bx + 3, by)
        if oak then oak:die(w.time, nil) end
        check("Ancient Treant splits into two Treants", count("AWJX", 1) == t0 + 2)
        local s0 = count("AKKX", 1)
        local priestess = w:addUnit("AKOX", 1, bx + 6, by)
        if priestess then priestess:die(w.time, nil) end
        check("Spider Priestess leaves six Spiders", count("AKKX", 1) == s0 + 6)
        -- Firebomb: the explosion hits the neighbours of other sides, not its own
        local bomb = w:addUnit("AASX", 1, bx + 10, by + 4)
        local foe = bomb and w:addUnit("AHBX", 0, bomb.gx + 1, bomb.gy)
        local pal = bomb and w:addUnit("AHBX", 1, bomb.gx - 1, bomb.gy)
        local far = bomb and w:addUnit("AHBX", 0, bomb.gx + 3, bomb.gy)
        local ring2 = bomb and w:addUnit("AHBX", 0, bomb.gx + 2, bomb.gy)
        if foe and pal and far and ring2 then
            ---@cast bomb -nil
            foe.maxHp, foe.hp, ring2.maxHp, ring2.hp = 500, 500, 500, 500           -- survive the blast
            local f0, p0, d0, r0 = foe.hp, pal.hp, far.hp, ring2.hp
            local dmg = bomb:stats().damage
            local Unit = require("src.game.unit")
            local e1, e2 = Unit.soften(foe, dmg, 3, false), Unit.soften(ring2, require("bit").arshift(dmg, 1), 3, false)
            local emitted = {}
            w:listen(function(kind, a, b) if kind == "emit" then emitted[#emitted + 1] = b end end)
            bomb:die(w.time, nil)
            check("Firebomb explosion hurts enemies around it, not its own side or the far ones",
                foe.hp < f0 and pal.hp == p0 and far.hp == d0)
            check("Firebomb explosion: the outer ring takes half the damage (binary SAR at 0x00529bff)",
                f0 - foe.hp == e1 and r0 - ring2.hp == e2 and e2 < e1)
            check("Firebomb explosion: the particle emitter is asked for", emitted[1] == "explode")
        end
        -- Troll and sheep: pick-up rules, counter, throw
        local troll = w:addUnit("AOMX", 0, bx, by + 8)
        local sheep = troll and w:addUnit("ACSH", 6, bx + 1, by + 8)
        if sheep then
            ---@cast troll -nil
            check("Troll walks over to a sheep (range 0, damage 100)", specials.meleeOnly(troll, sheep)
                and specials.pickupDamage(troll, sheep) == 100 and not specials.meleeOnly(troll, hero))
            troll.target = sheep
            check("Troll's attack range against a sheep is melee", troll:attackRange() == 1)
            troll.target = nil
            sheep:die(w.time, troll)
            check("Troll collects a killed sheep as ammunition", troll.ammo == 1 and sheep.deadSince > w.time - 20000)
            local code, factor = specials.throwAmmo(troll, 5)
            check("Troll throws a sheep for triple damage", code == "ACSH" and factor == 3 and troll.ammo == 0
                and specials.throwAmmo(troll, 5) == nil)
            troll.ammo = 1
            check("a non crushing missile throws nothing", specials.throwAmmo(troll, 0) == nil and troll.ammo == 1)
        end
        -- a retinue member that falls remembers the unit type that killed it (retinue removal FUN_00520e60), a building is -1
        local lamb = w:addUnit("ACSH", 6, bx + 6, by + 8)
        local lamb2 = w:addUnit("ACSH", 6, bx + 7, by + 8)
        if lamb and lamb2 and troll then
            lamb.retinueIndex, lamb2.retinueIndex = 3, 4
            lamb:die(w.time, troll)
            lamb2:die(w.time, nil)
            local fallen = w.fallen[6] or {}
            check("retinue: a fallen member remembers its killer's type, nothing is \"\"", fallen[3] == "AOMX" and fallen[4] == "")
        end
        -- Catapult and cow: only within 20 cells, may attack again at once
        local cat = w:addUnit("ASCA", 0, bx + 2, by + 10)
        local cow = cat and w:addUnit("ACCO", 6, bx + 3, by + 10)
        if cow then
            ---@cast cat -nil
            cat.attack = { t0 = w.time - 100, period = 1500, frames = 4, activation = 2, struck = true }
            cow:die(w.time, cat)
            check("Catapult collects a cow and may fire again at once", cat.ammo == 1 and cat.attack.period <= 100)
        end
        -- a Reaper's XP and a Minotaur that does not eat a Soul
        local reaper = w:addUnit("AVJX", 0, bx + 12, by + 8)
        local soul = reaper and w:addUnit("ACSO", 6, bx + 13, by + 8)
        if soul then
            ---@cast reaper -nil
            local xp0 = reaper.xp or 0
            soul:die(w.time, reaper)
            check("Reaper gets 20 experience from a Soul", (reaper.xp or 0) == xp0 + 20)
        end
        local mino = w:addUnit("AMIX", 0, bx + 12, by + 10)
        local soul2 = mino and w:addUnit("ACSO", 6, bx + 13, by + 10)
        if soul2 then
            ---@cast mino -nil
            mino.hp = 1
            soul2:die(w.time, mino)
            check("a Minotaur does not eat a Soul", mino.hp == 1)
            local sheep2 = assert(w:addUnit("ACSH", 6, bx + 14, by + 10))
            sheep2:die(w.time, mino)
            check("a Minotaur eats a sheep for 20 hits", mino.hp == 21)
        end
        -- Succubus: a Soul that lives 120 s; the Queen Spider's eggs hatch four Spiders
        local fxLog = {}
        w:listen(function(kind, a, b) if kind == "emit" then fxLog[#fxLog + 1] = (a.code or "?") .. ":" .. b end end)
        local succ = w:addUnit("AVIX", 1, bx + 16, by)
        local victim = succ and w:addUnit("AHBX", 0, bx + 17, by)
        if victim then
            local c0 = count("ACSO", 6)
            victim:die(w.time, succ)
            check("Succubus kill: the soul sparkle effect (ESSP) over the Soul", fxLog[#fxLog] == "ACSO:ESSP")
            local found
            for _, u in ipairs(w.units) do if u.code == "ACSO" and u:alive() and u.summonUntil then found = u end end
            check("Succubus kill leaves a neutral Soul for 120 s", count("ACSO", 6) == c0 + 1 and found
                and found.summonUntil == w.time + 120000)
        end
        local queen = w:addUnit("AKLX", 1, bx + 18, by + 8)
        local prey = queen and w:addUnit("AHBX", 0, bx + 19, by + 8)
        if prey then
            local nb = #w.buildings
            prey:die(w.time, queen)
            local eggs
            for _, b in ipairs(w.buildings) do if b.code == "BMEG" then eggs = b end end
            check("Queen Spider kill lays Spider Eggs for 40 s", #w.buildings == nb + 1 and eggs
                and eggs.expireAt == w.time + 40000 and eggs.side == 1)
            check("Spider Eggs: the chaos effect (ECHE) at the eggs", fxLog[#fxLog] == "BMEG:ECHE")
            if eggs then
                local sp0 = count("AKKX", 1)
                local cur, max = w.eco:armyLimit(1)
                local real = w.eco.armyLimit
                w.eco.armyLimit = function() return cur, cur + 3 end        -- three free slots: only three Spiders
                w.time = eggs.expireAt
                w:update(0)
                w.eco.armyLimit = real
                check("Spider Eggs hatch min(4, free slots) Spiders when they expire", count("AKKX", 1) == sp0 + 3)
                check("hatching spiders show the soul sparkle", fxLog[#fxLog] == "AKKX:ESSP")
            end
        end
        -- Black Mage: 5 mana per kill once a second (mana leech FUN_00526de0), with the mana leech effect (EMLE)
        local mage = w:addUnit("AHGB", 1, bx + 22, by + 4)
        local mprey = mage and w:addUnit("AHBX", 0, bx + 23, by + 4)
        local mprey2 = mage and w:addUnit("AHBX", 0, bx + 23, by + 5)
        -- mprey2 is only there with a mage
        ---@cast mage -nil
        if mprey2 and mage.maxMana and mage.maxMana > 10 then
            ---@cast mprey -nil
            mage.mana = 0
            mprey:die(w.time, mage)
            local m1 = mage.mana
            check("Black Mage: 5 mana for a kill, with the mana leech effect", m1 == 5 and fxLog[#fxLog] == "AHGB:EMLE")
            mprey2:die(w.time, mage)
            check("Black Mage: at most one leech a second", mage.mana == 5)
        end
        -- Knight Lord / Warlord in the army limit (only while the side has its hero)
        if w.eco:heroAlive(0) then
            local _, max0 = w.eco:armyLimit(0)
            w:addUnit("AHEX", 0, bx + 20, by + 12)
            w:addUnit("ABEX", 0, bx + 21, by + 12)
            local _, max1 = w.eco:armyLimit(0)
            check("army limit: Knight Lord +2, Warlord +1", max1 == max0 + 3)
        end
        -- the damage spell override: a melee unit gains the breath, a stronger shooter keeps its attack
        local melee = w:addUnit("AHBX", 0, bx + 22, by + 12)
        if melee then
            local base = melee:stats()
            status.add(melee, "firebreath", 60000, 5)
            local st = melee:stats()
            check("Fire Breathing gives a melee unit fire damage at range 5", base.range <= 1 and st.range == 5
                and st.damageType == 3 and st.damage >= 5)
            status.remove(melee, "firebreath")
            status.add(melee, "icefloe", 60000, 5)
            check("Ice Floe gives ice damage at range 12", melee:stats().range == 12 and melee:stats().damageType == 1)
            status.remove(melee, "icefloe")
        end
        local shooter = w:addUnit("APMX", 0, bx + 24, by + 12)
        if shooter and shooter:stats().range > 1 then
            local b = shooter:stats()
            status.add(shooter, "firebreath", 60000, 1)
            local st = shooter:stats()
            check("a weaker Fire Breathing leaves a shooter alone", st.range == b.range and st.damageType == b.damageType)
        end
    end
    -- psych auras: chaos / terror from the type records' psych effects, the saving throw, the chaos rules of the stats
    do
        local psych = require("src.game.psych")
        local status = require("src.game.status")
        local sc = assert(require("src.game.boot").loadScenario("Bridges"))
        local w = require("src.game.world").new(sc, { player = 0 })
        local hero = assert(w.eco:heroAlive(0))
        local ax, ay = hero.gx + 10, hero.gy + 2
        local realRandom = math.random
        local knight = w:addUnit("AUAX", 1, ax, ay)                     -- Doom Knight: chaos, strength 12, range 6
        local victim = w:addUnit("AHBX", 0, ax + 3, ay)
        local farOne = w:addUnit("AHBX", 0, ax + 9, ay)
        local zombie = w:addUnit("AUBX", 0, ax + 3, ay + 2)             -- undead: immune to chaos
        local orc = w:addUnit("AOBX", 0, ax + 2, ay + 3)                -- orcs: the effect lasts 50 % longer
        local friend = w:addUnit("AHBX", 1, ax + 2, ay - 2)
        if knight and victim and farOne and zombie and orc and friend then
            check("psych: the Doom Knight has a chaos aura", knight.type.psych.type == 4 and knight.type.psych.range == 6)
            local base = victim:baseStats()
            status.add(victim, "combat", 60000, 5)
            check("psych: no effect before the aura", not psych.busy(victim) and victim:stats().combat > base.combat)
            ---@diagnostic disable-next-line: duplicate-set-field -- a stub, restored below
            math.random = function() return 1 end                      -- every saving throw fails
            psych.update(w)
            math.random = realRandom
            check("psych: chaos for 30 s on an enemy within the range", victim.fx.chaos
                and victim.fx.chaos.t1 == w.time + 30000)
            check("psych: not outside the range, not on its own side, not on the undead", not psych.busy(farOne)
                and not psych.busy(friend) and not psych.busy(zombie))
            check("psych: orcs are under chaos for 90 s", orc.fx and orc.fx.chaos and orc.fx.chaos.t1 == w.time + 90000)
            local st = victim:stats()
            check("psych: chaos caps combat at the base value and takes the armour away", st.combat == base.combat
                and st.armor == 0 and victim:resistance() <= base.resistance)
            status.add(victim, "firebreath", 60000, 40)
            st = victim:stats()
            check("psych: chaos ignores damage spell effects", st.damage == base.damage and st.range == base.range
                and st.damageType == base.damageType)
            local t = w.time + 30000
            status.update(victim, t)
            check("psych: chaos ends after 30 s", not (victim.fx and victim.fx.chaos) and victim:stats().armor > 0)
            -- resisted: immune to psych effects for 30 s, and no new roll while it lasts
            local lucky = w:addUnit("AHBX", 0, ax + 4, ay + 1)
            if lucky then
                ---@diagnostic disable-next-line: duplicate-set-field -- a stub, restored below
                math.random = function() return 100 end
                psych.update(w)
                check("psych: a resisted aura leaves 30 s of immunity", lucky.fx and lucky.fx.psychimmune
                    and not lucky.fx.chaos and lucky.fx.psychimmune.t1 == w.time + 30000)
                ---@diagnostic disable-next-line: duplicate-set-field -- a stub, restored below
                math.random = function() return 1 end
                psych.update(w)
                math.random = realRandom
                check("psych: while immune nothing new happens", not lucky.fx.chaos)
            end
            -- terror: a Dragon makes an army drop its orders and run instead of attacking
            local dragon = w:addUnit("AADR", 1, ax, ay + 8)
            local man = w:addUnit("AHBX", 0, ax + 2, ay + 8)
            if dragon and man then
                man:orderMove((ax + 6) * 32, (ay + 8) * 24)
                ---@diagnostic disable-next-line: duplicate-set-field -- a stub, restored below
                math.random = function() return 1 end
                psych.update(w)
                math.random = realRandom
                check("psych: terror takes the orders away", man.fx and man.fx.terror and man.fx.terror.t1 == w.time + 15000
                    and not man.goalX)
                man:orderAttack(dragon)
                check("psych: a terrified army does not attack", man.target == nil)
            end
        end
        math.random = realRandom
    end
    -- missiles: the hit chance tables, the miss offsets, what a miss lands on, the Scare / Awe rules
    do
        local missiles = require("src.game.missiles")
        local psych = require("src.game.psych")
        local status = require("src.game.status")
        check("missiles: the tables of the binary", missiles.ARMY[0] == 1 and missiles.ARMY[1] == 10 and missiles.ARMY[25] == 99
            and missiles.BUILDING[0] == 10 and missiles.BUILDING[25] == 99 and missiles.ARMY[14] == 78)
        check("missiles: the eight directions of a line (FUN_0040a8f0)", missiles.dir8(0, 0, 0, -5) == 0
            and missiles.dir8(0, 0, 5, 0) == 2
            and missiles.dir8(0, 0, 3, 3) == 3 and missiles.dir8(0, 0, 0, 4) == 4 and missiles.dir8(0, 0, -3, 3) == 5
            and missiles.dir8(0, 0, -5, 0) == 6 and missiles.dir8(0, 0, -3, -3) == 7 and missiles.dir8(0, 0, 1, -3) == 0
            and missiles.dir8(0, 0, 3, -1) == 2 and missiles.dir8(0, 0, 3, -2) == 1)
        local heights = {}
        local fakeWorld = { w = 40, h = 40, terrain = { heightAt = function(_, x, y) return heights[y * 40 + x] or 0 end },
                            eco = { buildingCombat = function() return 12 end } }
        local function unit(gx, gy, combat, speed)
            return { kind = "unit", gx = gx, gy = gy, stats = function() return { combat = combat or 10, speed = speed or 12 } end }
        end
        local archer, target = unit(5, 5, 10), unit(15, 5, 10, 12)
        check("missiles: combat 10 against speed 12 at range: index 8, 50 percent", missiles.chance(fakeWorld, archer, target) == 50)
        check("missiles: halved next to the target", missiles.chance(fakeWorld, archer, unit(6, 6, 10, 12)) == 25)
        archer.fx = { fear = {}, awe = {} }
        check("missiles: fear and awe take 20 each", missiles.chance(fakeWorld, archer, target) == 10)
        archer.fx.terror = {}
        check("missiles: fear, awe and terror never leave less than 1", missiles.chance(fakeWorld, archer, target) == 1)
        archer.fx = nil
        heights[5 * 40 + 5] = 2
        check("missiles: 10 for every level of height", missiles.chance(fakeWorld, archer, target) == 70)
        check("missiles: no target, no speed or height", missiles.chance(fakeWorld, unit(5, 5, 10)) == 60)
        check("missiles: clipped to 99", missiles.chance(fakeWorld, unit(5, 5, 99), target) == 99)
        local tower = { kind = "building", gx = 5, gy = 5 }
        check("missiles: a tower with combat 12 against speed 12 at range: index 10, 65 percent",
            missiles.chance(fakeWorld, tower, target) == 65)
        check("missiles: a tower next to the target: index 6 - 2, 35 percent", missiles.chance(fakeWorld, tower, unit(6, 5, 10, 12)) == 35)
        heights[5 * 40 + 5] = nil
        -- the flight of a miss: roll 90 against 50 at 10 cells: 1 + 1 + 2 = 4, one cell, 32 x 24 pixels, sideways
        local aimShot = missiles.aim(fakeWorld, archer, target, 90)
        check("missiles: a miss lands one cell sideways (even roll: to the left of the line of fire)",
            aimShot.miss and aimShot.gx == 15 and aimShot.gy == 4 and aimShot.px == 0 and aimShot.py == -24)
        aimShot = missiles.aim(fakeWorld, archer, target, 91)
        check("missiles: an odd roll turns the other way", aimShot.miss and aimShot.gx == 15 and aimShot.gy == 6 and aimShot.py == 24)
        check("missiles: a roll at or under the chance flies true", not missiles.aim(fakeWorld, archer, target, 50).miss
            and missiles.aim(fakeWorld, archer, target, 51).miss)
        aimShot = missiles.aim(fakeWorld, unit(5, 5, 10), unit(7, 5, 0, 0), 100)     -- 100 against 50 at 2 cells: 1 + 1 + 0
        check("missiles: a close miss of inaccuracy 2 moves a cell", aimShot.miss and aimShot.gx == 7 and aimShot.gy == 4)
        aimShot = missiles.aim(fakeWorld, unit(5, 5, 99), unit(7, 5, 0, 0), 100)
        check("missiles: the smallest inaccuracy moves only the picture",
            aimShot.miss and aimShot.gx == 7 and aimShot.gy == 5 and aimShot.py ~= 0)
        aimShot = missiles.aim(fakeWorld, archer, unit(35, 5, 10, 12), 100)          -- inaccuracy 1 + 1 + 7 = 9: two cells
        check("missiles: a long miss lands two cells away", aimShot.miss and aimShot.gx == 35 and aimShot.gy == 3 and aimShot.py == -48)
        -- what a miss lands on
        local sc = assert(require("src.game.boot").loadScenario("Bridges"))
        local w = require("src.game.world").new(sc, { player = 0 })
        local hero = assert(w.eco:heroAlive(0))
        local ax, ay = hero.gx + 10, hero.gy + 2
        local foe = w:addUnit("AHBX", 1, ax + 1, ay + 1)
        local own = w:addUnit("AHBX", 0, ax + 8, ay + 1)
        local function at(gx, gy) return { gx = gx, gy = gy } end      -- a cell: what a miss lands on, a target
        if foe and own then
            check("missiles: a missile hurts the first occupied cell of the 2 x 2 block, if it is an enemy",
                missiles.victim(w, 0, at(foe.gx, foe.gy)) == foe and missiles.victim(w, 0, at(foe.gx - 1, foe.gy - 1)) == foe)
            check("missiles: a friendly army stops the search, a block of the other side's army hurts it",
                missiles.victim(w, 0, at(own.gx, own.gy)) == nil and missiles.victim(w, 1, at(own.gx, own.gy)) == own)
        end
        -- missile flight: steps, the first enemy on the way, arcs, the dead shooter, the lead, splash, a titan's ball, a save
        do
            local fw = require("src.game.world").new(sc, { player = 0 })
            local serialize = require("src.core.serialize")
            local function runLength(len)          -- a row of free cells with free rows above and below
                for gy = 4, fw.h - 6 do
                    for gx = 2, fw.w - len - 2 do
                        local ok = true
                        for dx = 0, len do
                            for dy = -1, 7 do
                                if not fw:free(gx + dx, gy + dy, 0) or (dy == 0 and fw.terrain:heightAt(gx + dx, gy) ~= fw.terrain:heightAt(gx, gy)) then
                                    ok = false
                                    break
                                end
                            end
                            if not ok then break end
                        end
                        if ok then return gx, gy end
                    end
                end
            end
            local gx, gy = runLength(24)
            check("missile flight: a free field for the tests", gx ~= nil)
            if gx then
                ---@return Unit
                local function spawn(side, dx, dy)
                    local u = assert(fw:addUnit("AHBX", side, gx + dx, gy + dy))
                    u.maxHp, u.hp = 5000, 5000
                    return u
                end
                local function fly(m, ms)           -- advance the missiles by ms milliseconds of the missile clock
                    for t = m.t0, m.t0 + ms, 25 do missiles.update(fw, t) end
                end
                local function launch(sh, tg, code, extra)
                    local s = { code = code, kind = "unit", shooter = sh, side = sh.side, target = tg, x0 = sh.x, y0 = sh.y - 20, roll = 1 }
                    for k, v in pairs(extra or {}) do s[k] = v end
                    return missiles.launch(fw, s)
                end
                local sh, far, near = spawn(0, 0, 0), spawn(1, 9, 0), spawn(1, 4, 0)
                local m = launch(sh, far, "EMF0")
                check("missile flight: 9 cells at medium speed are 13 steps of 50 ms", m.n == 13 and m.ft == 50 and m.maxSteps == 13)
                check("missile flight: a missile keeps what it was shot at (the cast's target picture, gfx/spellfx.lua)", m.target == far)
                fly(m, 1000)
                check("missile flight: a fireball hits the first enemy on the way and stops there",
                    near.hp < 5000 and far.hp == 5000 and m.done and m.maxSteps < 13)
                near.hp, far.hp = 5000, 5000
                m = launch(sh, far, "EMA0")
                check("missile flight: 9 cells at fast speed are 9 steps of 25 ms, an arrow's arc has the heights 1 2 3 2 1",
                    m.n == 9 and m.ft == 25 and m.steps[0].h == 1 and m.steps[1].h == 2 and m.steps[4].h == 3 and m.steps[8].h == 1)
                fly(m, 1000)
                check("missile flight: an arrow flies over the troops between and hits its target", near.hp == 5000 and far.hp < 5000)
                far.hp = 5000
                local dead = spawn(0, 0, 2)
                m = launch(dead, far, "EMF0")
                dead:die(fw.time, nil)
                fly(m, 1000)
                check("missile flight: a shooter that dies on the way does no damage", far.hp == 5000 and m.done)
                near:die(fw.time, nil)                                  -- the enemy in the way is gone, a friend stands there
                local friend = spawn(0, 4, 0)
                m = launch(sh, far, "EMF0")
                fly(m, 1000)
                check("missile flight: friends in the way are no obstacle", friend.hp == 5000 and far.hp < 5000)
                far.hp = 5000
                -- a walking target is led by its direction
                far.state, far.dir = "step", 2
                m = launch(sh, far, "EMF0")
                check("missile flight: a walking target is led", m.gx1 > far.gx and m.x1 > far.x)
                far.state, far.dir = "idle", nil
                fly(m, 1000)
                -- the height percentage
                local hts = { [3 * 40 + 3] = 1 }
                local hw = { terrain = { heightAt = function(_, x, y) return hts[y * 40 + x] or 0 end } }
                local function from(h0) return { h0 = h0 } end          -- a missile starting at height h0
                check("missile flight: the height percentage table", missiles.heightPercent(hw, from(3), at(3, 3)) == 130
                    and missiles.heightPercent(hw, from(0), at(5, 5)) == 100
                    and missiles.heightPercent(hw, from(0), at(3, 3)) == 80
                    and missiles.heightPercent(hw, from(9), at(5, 5)) == 300)
                -- splash: the catapult's rock hurts its victim and the cells round it with less
                local mid, side1, side2 = spawn(1, 12, 6), spawn(1, 13, 6), spawn(1, 15, 6)
                m = launch(sh, mid, "EMC1", { dmgMul = 20 })
                check("missile flight: a catapult rock has a very slow high arc and splashes", m.n == 48 and m.steps[24].h == 6)
                fly(m, 3000)
                local lossMid, lossNear = 5000 - mid.hp, 5000 - side1.hp
                check("missile flight: the rock hurts the cells round the landing with 3/4 of the damage",
                    lossMid > 0 and lossNear > 0 and lossNear < lossMid and side2.hp == 5000)
                -- a titan's ball: 150 damage in the box, none outside, nobody gets the credit
                local cx, cy = gx + 18, gy
                local inside, outside, ownIn = spawn(1, 15, 0), spawn(1, 23, 0), spawn(0, 17, 2)
                m = missiles.launch(fw, { code = "EMTF", kind = "ball", force = true, gx0 = gx + 10, gy0 = gy, gx1 = cx, gy1 = cy,
                                          x0 = 0, y0 = 0, ex = cx * 32 + 16, ey = cy * 24 + 12 })
                check("missile flight: a titan ball is a very slow high arc, 8 cells = 30 steps", m.n == 30 and m.steps[29].h == 1)
                fly(m, 3000)
                check("missile flight: the ball bursts over everything in its box, friend or foe",
                    inside.hp < 5000 and ownIn.hp < 5000 and outside.hp == 5000 and m.done)
                -- a save and a load in mid-flight
                far.hp = 5000
                m = launch(sh, far, "EMF0")
                fly(m, 200)
                local uidx, bidx = {}, {}
                for i, u in ipairs(fw.units) do uidx[u] = i end
                for i, b in ipairs(fw.buildings) do bidx[b] = i end
                local saved = serialize.decode(serialize.encode(missiles.save(fw, uidx, bidx)))
                local ulist, blist = {}, {}
                for i, u in ipairs(fw.units) do ulist[i] = u end
                for i, b in ipairs(fw.buildings) do blist[i] = b end
                missiles.restore(fw, saved, ulist, blist)
                local r = fw.missiles[1]
                check("missile flight: a missile in flight survives a save", #fw.missiles == 1 and r.frame == m.frame and r.n == m.n
                    and r.shooter == sh and r.steps[3].px == m.steps[3].px and r.nextT == m.nextT)
                fly(r, 1000)
                check("missile flight: and lands after the load", far.hp < 5000 and r.done)
                -- the after-images: an arrow (5 trail frames) is done 5 frames after it landed and keeps that over a save
                far.hp = 5000
                m = launch(sh, far, "EMA0")
                local k = 0
                while not m.landed and k < 40 do k = k + 1; missiles.update(fw, m.t0 + 25 * k) end
                local landedAt = m.frame
                check("missile flight: an arrow has landed but its trail lives on", m.landed and not m.done and m.trail == 5 and m.ix ~= nil)
                local uidx2, bidx2, ulist2, blist2 = {}, {}, {}, {}
                for i, u in ipairs(fw.units) do uidx2[u], ulist2[i] = i, u end
                for i, b in ipairs(fw.buildings) do bidx2[b], blist2[i] = i, b end
                missiles.restore(fw, serialize.decode(serialize.encode(missiles.save(fw, uidx2, bidx2))), ulist2, blist2)
                local r2 = fw.missiles[1]
                check("missile flight: a landed missile with its trail survives a save", r2 and r2.landed and r2.ix == m.ix and r2.trail == 5)
                while r2 and not r2.done and k < 80 do k = k + 1; missiles.update(fw, m.t0 + 25 * k) end
                check("missile flight: the trail ends five frames after the landing", r2 and r2.done and r2.frame == r2.maxSteps - 1 + 5 and #fw.missiles == 0)
                check("missile flight: sheet rows follow the original's 16 way table",
                    missiles.missileDirection(0, 0, 1, 0) == 2 and missiles.missileDirection(0, 0, 0, -1) == 0
                    and missiles.missileDirection(0, 0, 1, -1) == 1 and missiles.missileDirection(0, 0, 2, -1) == 9
                    and missiles.missileDirection(0, 0, -1, 0) == 6 and missiles.missileDirection(0, 0, 0, 1) == 4)
                -- a titan shooter's missile ignores the armour; the good / evil breath doubles against the opposite
                far.hp = 5000
                local titan = fw:addUnit("ATFX", 0, gx + 2, gy + 4)
                if titan then
                    titan:strike(far, { code = "EMA1" })
                    check("missile flight: a titan's missile does its plain damage, armour ignored", far.hp == 5000 - titan:stats().damage)
                    titan.hp = 0
                    titan:die(fw.time, nil)
                end
                far.hp = 5000
                sh:strike(far, { code = "EMF4", dmgMul = 40 })
                local plain = 5000 - far.hp
                far.hp = 5000
                sh:strike(far, { code = "EMF4", dmgMul = 40, dbl = "good" })
                check("missile flight: the evil breath does double damage to the good", plain > 0 and 5000 - far.hp == plain * 2)
                far.hp = 5000
                -- the void ends a flight (EMX0), and a building's pixel decides whether it is hit
                local vi = (gy + 2) * fw.w + gx + 5
                local old = fw.terrain.terrain[vi]
                fw.terrain.terrain[vi] = 9
                local s2, t2 = spawn(0, 0, 2), spawn(1, 9, 2)
                local effects0 = #(fw.effects or {})
                m = launch(s2, t2, "EMF0")
                fly(m, 1000)
                fw.terrain.terrain[vi] = old
                check("missile flight: the void stops a missile and puffs", m.maxSteps < m.n and t2.hp == 5000
                    and #(fw.effects or {}) > effects0 and fw.effects[#fw.effects].code == "EMX0")
                local bld = fw.buildings[1]
                if bld and bld.set and bld.set.effectCentre then
                    local cx, cy = bld.set:effectCentre()
                    check("missile flight: the effect point of a building is solid, a pixel far off is not",
                        missiles.solid(fw, bld, bld.x - cx, bld.y - cy) and not missiles.solid(fw, bld, bld.x + 5000, bld.y))
                end
                -- the dragon breath: the end cell, then the cells round it with 3/4, the second ring with 9/16; friends and the far are spared
                local c0, r1, r2, out, ally = spawn(1, 6, 4), spawn(1, 7, 4), spawn(1, 8, 4), spawn(1, 9, 4), spawn(0, 5, 4)
                m = launch(sh, c0, "EMF1", { dmgMul = 40 })
                fly(m, 1000)
                local l0, l1, l2 = 5000 - c0.hp, 5000 - r1.hp, 5000 - r2.hp
                check("missile flight: the breath hurts the end cell, the ring with 3/4 and the second ring with 9/16",
                    l0 > 0 and l1 > 0 and l1 < l0 and l2 > 0 and l2 < l1 and out.hp == 5000 and ally.hp == 5000)
                -- the start pixel: the combat point of the facing direction from the corner of the selection rectangle (the frame of
                -- the current animation), else the middle of the rectangle; heroes never use the points (FUN_0053df60)
                local cat = fw:addUnit("ASCA", 0, gx + 1, gy + 1)
                if cat and cat.type and cat.type.combatPoints then
                    cat.anim, cat.dir = 2, 2
                    local info = cat.set.info[2]
                    local px, py = missiles.startPoint(cat, cat.gx, cat.gy, gx + 9, gy + 1)
                    local pt = cat.type.combatPoints[3]
                    check("start pixel: a catapult shoots from its combat point of the direction it faces",
                        px == cat.x - info.originX + pt[1] and py == cat.y - info.originY + pt[2])
                    cat.dir = 6
                    local qx = missiles.startPoint(cat, cat.gx, cat.gy, gx - 9, gy + 1)
                    check("start pixel: and from the other point when it turns round", qx == cat.x - info.originX + cat.type.combatPoints[7][1] and qx ~= px)
                    cat.hp = 0
                    cat:die(fw.time, nil)
                end
                local cx0, cy0 = missiles.startPoint(sh, sh.gx, sh.gy, gx + 9, gy)
                local si = sh.set.info[sh.anim or 0]
                check("start pixel: a unit without combat points shoots from the middle of its selection rectangle",
                    cx0 == sh.x - si.originX + math.floor(si.width / 2) and cy0 == sh.y - si.originY + math.floor(si.height / 2))
                local bx, by = missiles.startPoint(nil, 10, 5)
                check("start pixel: a ball without a shooter starts in the middle of its cell", bx == 10 * 32 + 16 and by == 5 * 24 + 12)
                for _, b in ipairs(fw.buildings) do
                    if b.type and b.type.combatPoints and b.set and b.set.info[0] and b.set.info[0].used then
                        local x1, y1 = missiles.startPoint(b, b.gx, b.gy, b.gx + 9, b.gy)
                        local d = missiles.dir8(b.gx, b.gy, b.gx + 9, b.gy)
                        local i0 = b.set.info[0]
                        check("start pixel: a building shoots from its combat point towards the target",
                            d == 2 and x1 == b.x - i0.originX + b.type.combatPoints[3][1] and y1 == b.y - i0.originY + b.type.combatPoints[3][2])
                        break
                    end
                end
                -- the acid breath reduces the armour of what it hurts by 2 each time (for good, at least 0), the evil breath drains 10
                -- experience (troops and heroes, no level lost), the good breath crystallizes an army it kills (no corpse, +100 crystal;
                -- not under a Life Ward)
                local rec = require("src.content").missile._recs
                local armour0 = c0:stats(true).armor
                m = launch(sh, c0, "EMF3", { dmgMul = 1 })
                fly(m, 1000)
                check("breath: the acid breath takes 2 armour from the end cell and the ring, not from the far",
                    c0.armorLoss == 2 and r1.armorLoss == 2 and not out.armorLoss and c0:stats(true).armor == math.max(0, armour0 - 2))
                m = launch(sh, c0, "EMF3", { dmgMul = 1 })
                fly(m, 1000)
                check("breath: the reductions stack and never take the armour below 0", c0.armorLoss == 4
                    and c0:stats(true).armor == math.max(0, armour0 - 4) and c0:completeArmour()[0] == c0:stats(true).armor)
                local xp0, lvl0 = 30, c0.level or 0
                c0.xp, r1.xp = xp0, 5
                m = launch(sh, c0, "EMF4", { dmgMul = 1 })
                fly(m, 1000)
                check("breath: the evil breath drains 10 experience, at least down to 0, and the level stays",
                    c0.xp == xp0 - 10 and r1.xp == 0 and (c0.level or 0) == lvl0)
                local Unit = require("src.game.unit")
                local heroH = assert(hero.h)
                local hx = heroH.xp
                Unit.breathSpecial(sh, hero, rec.EMF4.attack)
                check("breath: a hero's experience is drained too", heroH.xp == math.max(0, hx - 10))
                heroH.xp = hx
                local side0 = fw.sides[0]
                side0.crystal = 0
                local doomed, warded = spawn(1, 6, 6), spawn(1, 10, 6)
                doomed.hp, warded.hp = 1, 1
                warded.fx = warded.fx or {}
                warded.fx.lifeward = { t1 = fw.time + 60000 }
                m = launch(sh, doomed, "EMF5", { dmgMul = 40 })
                fly(m, 1000)
                check("breath: the good breath crystallizes an army it kills: gone without a corpse, 100 crystal for the shooter",
                    doomed.state == "dead" and doomed.remove and side0.crystal == 100)
                m = launch(sh, warded, "EMF5", { dmgMul = 40 })
                fly(m, 1000)
                check("breath: an army under a Life Ward is not crystallized", not warded.remove and side0.crystal == 100)
                -- the Crystal Tower's shot crystallizes the army it kills (FUN_0052d2f0: special attack 5 for BWTF), another tower's not
                local gd = require("src.game.gamedata")
                local ct = fw:addBuilding({ code = "BWTF", side = 0, x = gx * 32 + 16, y = (gy + 10) * 24 + 12, anim = 0, dir = 0, frame = 0 })
                check("crystal tower: only BWTF carries the crystallizing shot", gd.hasTag("BWTF", "crystalTower")
                    and not gd.hasTag("BWTB", "crystalTower"))
                if ct then
                    ct.hp = math.max(1, ct.hp)
                    local tcode = require("src.game.rules").building("BWTF").missile
                    local function towerShot(tg, crystal)
                        local tm = missiles.launch(fw, { code = tcode, kind = "tower", shooter = ct, side = 0, target = tg,
                            p = { combat = 50, damage = 20, dtype = 0, range = 8, base = 20, crystal = crystal } })
                        tm.done = true                      -- straight to the impact (nothing in the way)
                        missiles.handlers.tower(fw, tm, tg)
                    end
                    side0.crystal = 0
                    local v1, v2 = spawn(1, 4, 9), spawn(1, 6, 9)
                    v1.hp, v2.hp = 1, 1
                    towerShot(v1, true)
                    towerShot(v2, nil)
                    check("crystal tower: the army its shot kills is crystallized (no corpse, 100 crystal), a plain tower's kill is not",
                        v1.state == "dead" and v1.remove and v2.state == "dead" and not v2.remove and side0.crystal == 100)
                end
                -- a thrown goblin gets up again (one in eight, a cell with nothing on it, room in the army limit)
                local realRandom, realLimit = math.random, fw.eco.armyLimit
                ---@diagnostic disable-next-line: duplicate-set-field -- a stub, restored below
                math.random = function() return 1 end
                fw.eco.armyLimit = function() return 0, 100 end
                local before = #fw.units
                m = missiles.launch(fw, { code = "AOSX", kind = "unit", shooter = sh, side = 0, gx0 = gx, gy0 = gy, gx1 = gx + 3, gy1 = gy + 7,
                                          x0 = sh.x, y0 = sh.y - 20, ex = (gx + 3) * 32 + 16, ey = (gy + 7) * 24 + 12 })
                fly(m, 4000)
                math.random, fw.eco.armyLimit = realRandom, realLimit
                local goblin = fw:unitAt(gx + 3, gy + 7)
                check("missile flight: a thrown goblin may get up again, rampant", goblin and goblin.code == "AOSX" and goblin.side == 0
                    and goblin.attitude == "rampant" and #fw.units == before + 1)
            end
        end
        -- Scare and Awe: no saving throw, only the immunities of the bonus flags (FUN_005286c0), the aura's times
        local spells = require("src.game.spells")
        local realRandom = math.random
        local victim = w:addUnit("AHBX", 1, hero.gx + 2, hero.gy)
        local orc = w:addUnit("AOBX", 1, hero.gx + 2, hero.gy + 1)
        local zombie = w:addUnit("AUBX", 1, hero.gx + 3, hero.gy)
        if victim and orc and zombie then
            assert(hero.h).mana = 100
            ---@diagnostic disable-next-line: duplicate-set-field -- a stub, restored below
            math.random = function() return 100 end                    -- a saving throw would always succeed
            spells.castItemSpell(hero, 31, 1)                           -- Scare
            math.random = realRandom
            check("psych spells: Scare frightens an enemy without a roll, for 45 s", victim.fx and victim.fx.fear
                and victim.fx.fear.t1 == w.time + 45000)
            check("psych spells: the slow races stay afraid three times as long", orc.fx and orc.fx.fear
                and orc.fx.fear.t1 == w.time + 135000)
            check("psych spells: the undead are immune", not (zombie.fx and zombie.fx.fear))
            victim.fx.fear = nil
            victim.fx.psychimmune = { t1 = w.time + 30000 }
            hero.recoverUntil = nil
            spells.castItemSpell(hero, 33, 1)                           -- Awe: an army that resisted an aura is not spared
            check("psych spells: Awe for 30 s whatever flags the army carries", victim.fx.awe and victim.fx.awe.t1 == w.time + 30000)
            check("psych spells: the casting hero is left alone", not (hero.fx and (hero.fx.fear or hero.fx.awe)))
            status.add(victim, "drunk", 60000)
            check("psych spells: a drunk army is immune", psych.apply(victim, "fear") == false)
        end
        math.random = realRandom
        -- Spell Resisted (host spell resolution FUN_004aa840): Banish, Mutate, Strip Flesh and Rot send the "resisted" event for the armies they
        -- do not take - an army's level counts (FUN_00526d80), a hero, an animal (FUN_00528280) and a Rot victim without poison do not
        local resisted
        w:listen(function(kind, a) if kind == "resisted" and resisted then resisted[a] = (resisted[a] or 0) + 1 end end)
        local function cast(id)
            resisted, hero.recoverUntil = {}, nil
            spells.castItemSpell(hero, id, 1)
        end
        local weak = w:addUnit("AHBX", 1, hero.gx + 1, hero.gy + 3)
        local veteran = w:addUnit("AHBX", 1, hero.gx + 2, hero.gy + 3)
        local sheep = w:addUnit("ACSH", 6, hero.gx + 3, hero.gy + 3)
        local imp, impVet = w:addUnit("AAIM", 1, hero.gx + 1, hero.gy + 4), w:addUnit("AAIM", 1, hero.gx + 2, hero.gy + 4)
        if weak and veteran and sheep and imp and impVet then
            veteran.level, impVet.level = 5, 5
            cast(18)                                                    -- Banish (result 1: levels below 2 die)
            check("spell resisted: Banish kills an extraplanar army of level 1, the one of level 5 resists", not imp:alive()
                and impVet:alive() and resisted[impVet] == 1 and not resisted[imp] and not resisted[weak])
            cast(46)                                                    -- Strip Flesh
            check("spell resisted: Strip Flesh takes the level 0 army, the veteran and the animal resist",
                weak.remove and not veteran.remove and resisted[veteran] == 1 and resisted[sheep] == 1 and not resisted[weak])
            local weak2 = w:addUnit("AHBX", 1, hero.gx + 1, hero.gy + 3)
            cast(38)                                                    -- Mutate
            check("spell resisted: Mutate turns the level 0 army into an animal, the veteran and the animal resist",
                weak2 and weak2.remove and resisted[veteran] == 1 and resisted[sheep] == 1 and not resisted[weak2])
            status.poison(veteran)
            cast(108)                                                   -- Rot
            check("spell resisted: Rot shows the line for a poisoned army of a high level only", resisted[veteran] == 1
                and not resisted[sheep] and not resisted[impVet])
        end
    end
    -- speech: the announcer's timers, the unit speech rules and the events the simulation raises for them
    do
        local speech = require("src.audio.speech")
        local S = speech.SYSTEM
        local an = speech.announcer(100)
        check("speech: the first message plays", an:request(S.needGold, 100.0, 0) == S.needGold)
        check("speech: a second one within 11 ticks is held back", an:request(S.needMetal, 100.2, 0) == nil)
        check("speech: and plays after them", an:request(S.needMetal, 100.3, 0) == S.needMetal)
        check("speech: a priority message always gets through", an:request(S.victory, 100.31, 0) == S.victory)
        an = speech.announcer(0)
        check("speech: troops under attack plays", an:request(S.troopsUnderAttack, 1, 0) == S.troopsUnderAttack)
        check("speech: and not again within about 19 s", an:request(S.troopsUnderAttack, 18, 0) == nil)
        check("speech: but another message does", an:request(S.needGold, 19, 0) == S.needGold)
        check("speech: troops under attack after 21 counter steps",
            an:request(S.troopsUnderAttack, 30, 0) == S.troopsUnderAttack)
        an = speech.announcer(0)
        check("speech: too many men plays", an:request(S.tooManyMen, 1, 20) == S.tooManyMen)
        check("speech: not for the same army limit", an:request(S.tooManyMen, 2, 20) == nil)
        check("speech: but when the limit changed", an:request(S.tooManyMen, 3, 24) == S.tooManyMen)
        an:forceTooManyMen()
        check("speech: or when forced", an:request(S.tooManyMen, 4, 24) == S.tooManyMen)
        check("speech: option Sometimes lets 2 in 5 select lines through", speech.allowed(1, "Select", 1)
            and speech.allowed(1, "Order", 2) and not speech.allowed(1, "Order", 3) and speech.allowed(1, "Ready", 5)
            and not speech.allowed(0, "Ready", 1) and speech.allowed(2, "Select", 5))
        local n1, last = speech.pickVariant("Select", 3, 80, 0)
        local n2 = speech.pickVariant("Select", 3, 80, last)
        local n3 = speech.pickVariant("Order", 4, 99, 0)
        check("speech: variants follow the thresholds and avoid a repeat", n1 == 3 and n2 == 2 and n3 == 4
            and speech.pickVariant("Order", 2, 10, 0) == 1 and speech.pickVariant("Select", 1, 99, 0) == 1)
        local sp = speech.speaker(0)
        check("speech: select speech at the start, then 1.15 s apart", sp:take("Select", 0.5)
            and not sp:take("Order", 1.0) and sp:take("Order", 1.7) and not sp:take("Deathblow", 1.8)
            and sp:take("Deathblow", 2.2))
        check("speech: the Ready line has its own 0.4 s timer", sp:takeReady(1) and not sp:takeReady(1.2)
            and sp:takeReady(1.5))
        local hero = { hero = true, maxHp = 10 }
        local troop = { type = { combat = 5, speed = 8, hits = 30 }, maxHp = 30 }
        check("speech: a hero speaks for the group, a general before the troops", speech.voicePriority(hero) == 10000
            and speech.voicePriority(troop) == 5 * 4 + 8 * 2 + 30 and speech.voicePriority(troop, true) == 566)

        local sc = assert(require("src.game.boot").loadScenario("Bridges"))
        local w = require("src.game.world").new(sc, { player = 0 })
        local log = {}
        w:listen(function(kind, a, b, c) log[#log + 1] = { kind, a, b, c } end)
        local function seen(kind)
            local out = {}
            for _, e in ipairs(log) do if e[1] == kind then out[#out + 1] = e end end
            return out
        end
        local h0 = assert(w.eco:heroAlive(0))
        local foe = w:addUnit("AHBX", 1, h0.gx + 8, h0.gy)
        local mine = w:addUnit("AHBX", 0, h0.gx + 9, h0.gy)
        -- the damage rides along with "attacked"
        if foe and mine then
            mine:takeDamage(7, foe)
            local ev = seen("attacked")[1]
            check("speech: attacked carries the damage", ev and ev[2] == mine and ev[3] == foe and ev[4] == 7)
        end
        -- a titan after two minutes is announced, one at the start is not
        local t0 = #seen("titan")
        w.time = 1000
        w:addUnit("ATHX", 1, h0.gx + 12, h0.gy)
        check("speech: no titan line in the first two minutes", #seen("titan") == t0)
        w.time = 121000
        local titan = w:addUnit("ATHX", 1, h0.gx + 14, h0.gy)
        check("speech: a later titan is announced", #seen("titan") == t0 + 1 and seen("titan")[t0 + 1][2] == titan)
        -- a stuck production says "too many men" once
        local prod, army
        for _, e in ipairs(require("src.game.rules").buildList(w.sides[0].race)) do
            if not prod and e.id:sub(1, 1) == "B" then
                local b = w:addBuilding({ code = e.id, side = 0, x = (h0.gx + 30) * 32 + 16, y = (h0.gy + 4) * 24 + 12 })
                b.complete = true
                for _, code in ipairs(w.eco:productionList(b)) do
                    if code:sub(1, 1) == "A" then prod, army = b, code break end
                end
            end
        end
        if prod then
            local realLimit = w.eco.armyLimit
            w.eco.armyLimit = function() return 10, 10 end
            prod.current = { code = army, cost = {}, name = army, t0 = w.time - 100, t1 = w.time - 1 }
            local n0 = #seen("toomanymen")
            w.eco:updateBuilding(prod, w.time)
            w.eco:updateBuilding(prod, w.time + 100)
            check("speech: a full army limit is announced once", #seen("toomanymen") - n0 == 1 and prod.current
                and prod.current.full)
            w.eco.armyLimit = realLimit
            w.eco:updateBuilding(prod, w.time + 200)
            check("speech: and production goes on when there is room", prod.current == nil)
        end
        -- a builder without the means: the missing resource comes with the event
        local builder
        for _, u in ipairs(w.units) do
            if u.side == 0 and not u.hero and u:alive() and w.eco:constructionList(0)[1] then builder = u break end
        end
        if builder then
            local side = w.sides[0]
            side.gold, side.metal, side.stone, side.crystal = 0, 0, 0, 0
            local code = w.eco:constructionList(0)[1]
            local spot
            for dy = -10, 10 do
                for dx = -10, 10 do
                    if not spot and w.eco:canPlace(code, builder.gx + dx, builder.gy + dy, 0) then spot = { builder.gx + dx, builder.gy + dy } end
                end
            end
            local ok, why, short = false, nil, nil
            if spot then ok, why, short = w.eco:startConstruction(builder, code, spot[1], spot[2], w.time) end
            check("speech: a building without resources names the missing one",
                spot ~= nil and ok == false and why == "cost" and short ~= nil)
            -- an ability the side cannot pay for says so
            local abilities = require("src.game.buildingabilities")
            local n0 = #seen("needmore")
            local b = w:addBuilding({ code = "BPCA", side = 0, x = (h0.gx + 25) * 32 + 16, y = (h0.gy + 25) * 24 + 12 })
            b.complete = true
            w.sides[0].powerups = w.sides[0].powerups or {}
            w.sides[0].powerups.PHOL = true
            abilities.use(w, 0, b, "holyWord")
            check("speech: an ability the side cannot pay for says need more",
                #seen("needmore") == n0 + 1 and seen("needmore")[n0 + 1][3] == "crystal")
        end
        -- new buildings available: a requirement that gets built shows up in eco:available
        local rules = require("src.game.rules")
        local race = w.sides[0].race
        local set = rules.raceSets(race)
        local base = w.eco:available(0)
        local found
        for _, code in ipairs(set.buildings) do
            local req = rules.requirements(race, code)
            if not base[code] and #req == 1 and req[1]:sub(1, 1) == "B" and not w.eco:hasBuilt(0, req[1]) then
                found = { code, req[1] }
                break
            end
        end
        if found then
            local b = w:addBuilding({ code = found[2], side = 0, x = (h0.gx + 20) * 32 + 16, y = (h0.gy + 20) * 24 + 12 })
            b.complete = true
            local now = w.eco:available(0)
            check("speech: a finished requirement makes a building available", now[found[1]] == true)
        else
            check("speech: a building with one missing requirement exists to test with", false)
        end
    end
    -- advanced options: storage defaults, the forced combinations, tough towers, no items, AI resign, resignation,
    -- tournament and "I am the greatest"
    do
        local Advanced = require("src.game.advanced")
        local gameopts = require("src.core.gameopts")
        local config = require("src.core.config")
        local boot = require("src.game.boot")
        local worldMod = require("src.game.world")
        local gamedata = require("src.game.gamedata")
        -- storage: no [advanced] section = the first-run defaults, a section with gaps = the read defaults of the binary
        local keep = config.ini
        config.ini = {}
        local first = gameopts.advanced()
        check("advanced: first-run defaults", first.randomWeather == false and first.resignKills and first.aiResign
            and not first.tournament and first.points == 10 and not first.greatest and not first.toughTowers and not first.noItems)
        config.ini = { advanced = { thoughtowers = "true" } }
        local gap = gameopts.advanced()
        check("advanced: values missing from an existing key", gap.randomWeather and gap.resignKills and gap.aiResign
            and gap.points == 15 and gap.toughTowers and not gap.noItems and not gap.greatest)
        config.ini = { advanced = { tournamentmodepoints = "99", tournamentmode = "1" } }
        check("advanced: points are clamped 4..50", gameopts.advanced().points == 50 and gameopts.advanced().tournament)
        config.ini = keep
        local forced = Advanced.enforce({ greatest = true, aiResign = true, tournament = true })
        check("advanced: I am the greatest forces random weather and resignation on, AI resign and tournament off",
            forced.greatest and forced.randomWeather and forced.resignKills and not forced.aiResign and not forced.tournament)
        check("advanced: I am the greatest does not exist in multiplayer", not Advanced.enforce({ greatest = true }, true).greatest)
        check("advanced: a world without options keeps the old rules", Advanced.normalize(nil).resignKills
            and not Advanced.normalize(nil).randomWeather and not Advanced.normalize(nil).aiResign)
        local function new(adv, extra)
            local opts = { player = 0, advanced = adv }
            for k, v in pairs(extra or {}) do opts[k] = v end
            return worldMod.new(assert(boot.loadScenario("Bridges")), opts)
        end
        -- tough towers: 750 hits, speed 3, combat and damage doubled, range + 1; only race towers
        local plain = new(nil)
        local tough = new({ toughTowers = true })
        local function tower(w)
            local code = gamedata.raceVariant("BWTC", w.sides[1].race)
            return w:addBuilding({ code = code, side = 1, x = 40 * 32 + 16, y = 40 * 24 + 12 })
        end
        local t0, t1 = tower(plain), tower(tough)
        check("advanced: tough towers have 750 hits", t1.hp == 750 and t1.maxHp == 750 and t0.maxHp ~= 750)
        check("advanced: tough towers double combat and damage, +1 range, speed 3",
            t1.type.combat == t0.type.combat * 2 and t1.type.damage == t0.type.damage * 2
            and t1.type.range == t0.type.range + 1 and t1.type.speed == 3)
        local wall = tough:addBuilding({ code = "BWG0", side = 1, x = 44 * 32 + 16, y = 44 * 24 + 12 })
        check("advanced: tough towers leave walls alone", wall.maxHp ~= 750)
        -- hero-level scaling of towers placed at the start: hits + 10 L, speed + L / 20, combat + L / 10, damage + L / 4
        -- (random map starting towers L / 50 and L / 5); not for a character, a tower built later or a campaign game
        local function startTower(extra, adv, character)
            local scn = assert(boot.loadScenario("Bridges"))
            local code = gamedata.raceVariant("BWTC", scn.sides[1].race or 0)
            scn.buildings[#scn.buildings + 1] = { code = code, side = 1, x = 40 * 32 + 16, y = 40 * 24 + 12, character = character }
            local opts = { player = 0, advanced = adv, humans = { [0] = true, [1] = true }, heroes = { [0] = { level = 7 }, [1] = { level = 23 } } }
            for k, v in pairs(extra or {}) do opts[k] = v end
            local w = worldMod.new(scn, opts)
            for _, b in ipairs(w.buildings) do if b.code == code and b.x == 40 * 32 + 16 then return b, w end end
        end
        local base = tower(plain)
        local s1 = startTower()
        check("advanced: a start tower scales with the highest hero level",
            s1.maxHp == base.maxHp + 230 and s1.hp == s1.maxHp and s1.type.speed == base.type.speed + 1
            and s1.type.combat == base.type.combat + 2 and s1.type.damage == base.type.damage + 5)
        local s2 = startTower(nil, { toughTowers = true })
        check("advanced: tough towers and the level add up", s2.maxHp == 750 + 230 and s2.type.speed == 4
            and s2.type.combat == base.type.combat * 2 + 2)
        check("advanced: a character tower is not scaled", startTower(nil, nil, true).maxHp == base.maxHp)
        check("advanced: no scaling in a campaign game", startTower({ campaign = true }).maxHp == base.maxHp)
        check("advanced: a tower built later is not scaled", tower(s1 and select(2, startTower())).maxHp == base.maxHp)
        do   -- a saved game brings the scaled tower back as it was
            local savegame, serialize = require("src.game.savegame"), require("src.core.serialize")
            local sw = select(2, startTower())
            local screen = partial({ world = sw, scnPath = "Bridges", camX = 0, camY = 0, zoom = 1 })
            local data = serialize.decode(serialize.encode(savegame.snapshot(screen)))
            local w2 = worldMod.new(assert(boot.loadScenario("Bridges")), { player = 0, restore = data, advanced = data.opts.advanced })
            w2.ai = require("src.game.ai").new(w2)
            savegame.apply(partial({ world = w2 }), data)
            local back
            for _, b in ipairs(w2.buildings) do if b.towerLevel then back = b end end
            check("advanced: a saved game keeps the scaled start tower", back and back.towerLevel == 23 and back.maxHp == s1.maxHp
                and back.type.combat == s1.type.combat and back.type.damage == s1.type.damage and back.type.speed == s1.type.speed)
        end
        local tw = startTower({ advanced = { tournament = true, points = 12 } })
        check("advanced: tournament mode scales with the tournament level", tw.maxHp == base.maxHp + 120)
        local rscn = require("src.game.randommap").fromName("random:5:sides=2")
        local function starts(l)
            local w = worldMod.new(rscn, { player = 0, humans = { [0] = true }, heroes = { [0] = { level = l } }, startForces = false })
            local list = {}
            for _, b in ipairs(w.buildings) do if gamedata.isRaceTower(b.code) then list[#list + 1] = b end end
            return list
        end
        local r0, r1 = starts(1), starts(50)
        check("advanced: random map starting towers scale (L / 50, L / 5)", #r0 == 6 and #r1 == 6
            and r1[1].maxHp == r0[1].maxHp + 490 and r1[1].type.speed == r0[1].type.speed + 1
            and r1[1].type.damage == r0[1].type.damage + 10 and r1[1].type.combat == r0[1].type.combat + 5)
        -- no items: the bonuses of worn items do not count
        local function combatOf(w)
            local h = w.eco:heroAlive(0).h
            h.equipped = { [0] = { powers = { { type = "combat", data = 7 } } } }
            h:recalc()
            return h.mod.combat
        end
        check("advanced: no items removes the item bonuses", combatOf(plain) - combatOf(new({ noItems = true })) == 7)
        -- the hero's weapon (worn slot 3) names the damage type and is the only item whose damage powers count
        do
            local hu = assert(plain.eco:heroAlive(0))
            local h = assert(hu.h)
            local baseDamage, baseType = (function() h.equipped = {}; h:recalc(); return h.mod.damage, hu:stats().damageType end)()
            h.equipped = { [3] = { powers = { { type = "slashing", data = 2 }, { type = "fire", data = 4 } } },
                           [1] = { powers = { { type = "crushing", data = 9 } } } }
            h:recalc()
            check("hero weapon: only the weapon's damage powers count, the last names the damage type",
                h.mod.damage == baseDamage + 6 and hu:stats().damageType == 3)
            h.equipped = { [1] = { powers = { { type = "crushing", data = 9 } } } }
            h:recalc()
            check("hero weapon: no weapon leaves the type record's damage type",
                h.mod.damage == baseDamage and hu:stats().damageType == baseType)
            h.equipped = {}
            h:recalc()
            -- mana cost (FUN_00529fa0): table cost x (100 - items' discount - Mana Flow 25) %, at least 25 %
            local spells = require("src.game.spells")
            local c40 = (function() for id = 0, 129 do if spells.COST[id] == 40 then return id end end end)()
            h.equipped = { [5] = { powers = { { type = "mana discount", data = 20 } } } }
            h:recalc()
            local withItem = spells.cost(hu, c40)
            plain.sides[0].manaflow = plain.time + 1000
            local withBoth = spells.cost(hu, c40)
            h.equipped = { [5] = { powers = { { type = "mana discount", data = 90 } } } }
            h:recalc()
            local floor25 = spells.cost(hu, c40)
            plain.sides[0].manaflow = nil
            h.equipped = {}
            h:recalc()
            check("spell cost: items' mana discount and Mana Flow add up, at least 25 % of the table cost",
                withItem == 32 and withBoth == 22 and floor25 == 10 and spells.cost(hu, c40) == 40 and spells.spend(hu, 13) == 3
                and spells.COST[11] == 4 and spells.COST[97] == 55)
        end
        -- item spells (FUN_00529d20): a cast spell power fires on d100 < chance, needs the hero out of recovery, is off with
        -- No Items and starts the hero's spell recovery; Heal Self (spell 0) heals 50 x level
        do
            local spells = require("src.game.spells")
            local function strikeWith(w, chance)
                local hu = w.eco:heroAlive(0)
                hu.recoverUntil = nil
                hu.h.equipped = { [5] = { powers = { { type = "cast spell", data = 0, chance = chance, level = 2 } } } }
                hu.hp = hu.maxHp - 150
                local hp0 = hu.hp
                local saved = math.random
                ---@diagnostic disable-next-line: duplicate-set-field -- a stub, restored below
                math.random = function() return 100 end                -- the d100 roll
                local fired = spells.itemCast(hu)
                math.random = saved
                local gained = hu.hp - hp0
                local again = spells.itemCast(hu)                       -- still recovering
                hu.h.equipped = {}
                return fired, gained, again, hu
            end
            local fired, gained, again, hu = strikeWith(plain, 101)
            check("item spells: a cast spell power heals and starts the recovery", fired and gained == 100 and not again
                and hu.recoverUntil and hu.recoverUntil > plain.time)
            check("item spells: the roll must be below the chance", not (strikeWith(plain, 100)))
            check("item spells: No Items switches them off", not (strikeWith(new({ noItems = true }), 101)))
            local items = require("src.game.items")
            local rngv = 0
            local function rng(n) rngv = (rngv * 31 + 17) % 997 return rngv % n + 1 end
            local ok, boots, packs = true, 0, 0
            for level = 1, 60 do
                local worn, pack = items.computerKit(level, false, rng)
                local worn2, pack2 = items.computerKit(level, true, rng)
                for slot in pairs(worn) do if slot < 1 or slot > 7 or slot == 6 then ok = false end end
                if worn[7] and worn[7].id == 2 then boots = boots + 1 end
                packs = packs + #pack
                if #pack2 ~= 0 or #pack > 3 then ok = false end
            end
            check("computer hero items: slots, boots as the last item, no backpack in an Assassin game", ok and boots > 10
                and packs > 0)
        end
        -- resignation: the command neutralises the side only with the option
        local function neutralised(w, side)
            for _, u in ipairs(w.units) do if u.side == side and u.state ~= "dead" then return false end end
            for _, b in ipairs(w.buildings) do if b.side == side and b.hp > 0 then return false end end
            return true
        end
        local commands = require("src.game.commands")
        local killing, leaving = new({ resignKills = true }), new({ resignKills = false })
        commands.apply(killing, { t = "resign", side = 1 })
        commands.apply(leaving, { t = "resign", side = 1 })
        check("advanced: resignation kills a side", killing.sides[1].resigned and neutralised(killing, 1))
        check("advanced: without the option the side stays", not leaving.sides[1].resigned and not neutralised(leaving, 1))
        -- AI resign: a side with no hero and almost nothing left, while another side has an army
        local function crush(w, side)
            for _, u in ipairs(w.units) do if u.side == side then u.side = 6 end end
            for _, b in ipairs(w.buildings) do if b.side == side then b.side = 6 end end
        end
        local function resigns(adv)
            local w = new(adv)
            w.ai = require("src.game.ai").new(w)
            crush(w, 1)
            local rule = Advanced.shouldResign(w, 1, true)
            for _ = 1, 30 * 6 do w:update(1 / 30) end
            return w.sides[1].resigned == true, rule
        end
        local on, rule = resigns({ aiResign = true })
        check("advanced: a crushed computer side resigns with AI can resign", on and rule)
        check("advanced: and keeps playing without it", resigns({ aiResign = false }) == false)
        local sound = new({ aiResign = true })
        check("advanced: a side with a hero and buildings does not resign", not Advanced.shouldResign(sound, 1, true))
        sound.ai = require("src.game.ai").new(sound)
        crush(sound, 0)
        for _ = 1, 30 * 6 do sound:update(1 / 30) end
        check("advanced: the local side never resigns by itself", not sound.sides[0].resigned)
        -- tournament: every hero is made at the chosen level and is temporary; computer heroes get that level too
        local tw = new({ tournament = true, points = 12 })
        local th = assert(assert(tw.eco:heroAlive(0)).h)
        check("advanced: tournament hero at the chosen level with its points", th.level == 12 and th.tournament
            and th.points.attr == 12 and th.points.skill == 12)
        local ai1 = tw.eco:heroAlive(1)
        check("advanced: tournament computer heroes have that level", ai1 and ai1.h.level == 12 and not ai1.h.tournament)
        local xp0 = th.xp
        check("advanced: a tournament hero earns no experience", require("src.game.battlexp").finish(tw, true, 1) == 0
            and th.xp == xp0)
        -- a human side's hero levels one level at a time in the battle (binary FUN_004d60f0: latch), the rest after it
        do
            local heroMod = require("src.game.hero")
            local lw = new({})
            local hu = assert(lw.eco:heroAlive(0))
            local lh = assert(hu.h)
            local lvl, pa = lh.level, lh.points.attr
            lh.xp = 0
            lh:addXp(heroMod.xpFor(lvl + 3) - lh.xp, true)         -- enough for three levels
            check("level-up: experience alone gives no level to a human side's hero", lh.level == lvl and lh:manualLevels())
            lw:update(1 / 30) lw:update(1 / 30)         -- the first update only starts the hero's clock
            check("level-up: the update makes one level and sets the latch", lh.level == lvl + 1 and lh.latch
                and lh.points.attr == pa + 1)
            lw:update(1 / 30)
            check("level-up: the latch holds the next level back", lh.level == lvl + 1)
            lh:spendAttr("str") lh:spendSkill(lh.skillList[1][1])
            lh:endLevelUp()
            check("level-up: no points left, the latch is cleared", lh.latch == nil)
            lw:update(1 / 30)
            check("level-up: the next level comes", lh.level == lvl + 2 and lh.latch)
            check("level-up: the saved hero keeps the latch", heroMod.new(nil, lh:save()).latch == true)
            lh:endLevelUp()
            check("level-up: points left keep the latch", lh.latch == true)
            local owed = heroMod.new(nil, { level = 5, xp = heroMod.xpFor(11) })
            check("level-up: the end of a battle owes at most four levels", owed:levelsDue() == 4)
            local one = heroMod.new(nil, { level = 5, xp = heroMod.xpFor(6) + 1 })
            one:applyLevels(one:levelsDue())
            check("level-up: Continue gives the counted level and its points", one.level == 6 and one.points.attr == 1
                and one.points.skill == 1)
            check("level-up: a frozen hero owes none", heroMod.new(nil, { level = 5, xp = heroMod.xpFor(11), frozen = true }):levelsDue() == 0)
            local aiw = lw.eco:heroAlive(1)
            check("level-up: a computer hero levels at once", aiw and not aiw.h:manualLevels())
        end
        local nh = new({ tournament = true, points = 12 }, { mods = { noHeroes = true } })
        local nhero = nh.eco:heroAlive(0)
        check("advanced: no tournament in a No Heroes game", not (nhero and nhero.h and nhero.h.tournament))
        do
            -- the hero made on the creation screens: kept as it is, not saved, current for the battle only
            local profile, Hero = require("src.game.profile"), require("src.game.hero")
            local a, k = Advanced.tournamentPoints(12)
            check("advanced: the tournament screens offer the level as attribute and skill points (binary FUN_00552d90)",
                a == 12 and k == 12)
            check("advanced: tournament game rule", Advanced.tournamentGame({ tournament = true }, {})
                and not Advanced.tournamentGame({ tournament = true }, { noHeroes = true })
                and not Advanced.tournamentGame({ tournament = false }, nil))
            local save = require("src.game.classes").newHero("Priest", 5)
            save.level, save.tournament, save.xp, save.points = 12, true, Hero.xpFor(12), { attr = 0, skill = 0 }
            local rec = { id = "tournament", temporary = true, name = "Tmp", race = 5, class = "Priest", portrait = 0, hero = save }
            profile.setTemporary(rec)
            local loaded = profile.load(11)             -- whatever the race of the side
            check("advanced: the temporary hero is the current hero of any side", profile.current() == rec
                and profile.recordFor(11) == rec and loaded and loaded.tournament and loaded.level == 12)
            profile.update(rec)
            check("advanced: the temporary hero is never written", love.filesystem.getInfo("heroes/tournament.lua") == nil)
            local placed = new({ tournament = true, points = 12 }, { heroes = { [0] = save } })
            local ph = assert(assert(placed.eco:heroAlive(0)).h)
            check("advanced: a made tournament hero is used as it is", ph.class == "Priest" and ph.race == 5 and ph.level == 12
                and ph.points.attr == 0)
            profile.setTemporary(nil)
            check("advanced: the temporary hero goes away", profile.temporary() == nil)
        end
        do
            -- No Heroes: the start force is the race's plain general (table of FUN_00445810), builders, no hero
            local economy = require("src.game.economy")
            local gens, heroes, builders = 0, 0, 0
            for _, u in ipairs(nh.units) do
                if u.side == 0 then
                    if u.hero then heroes = heroes + 1 end
                    if u.code == economy.GENERAL[nh.sides[0].race] then gens = gens + 1 end
                    if u.code == economy.BUILDER[nh.sides[0].race] then builders = builders + 1 end
                end
            end
            check("no heroes: the start force is one plain general and the builders, no hero", gens == 1 and heroes == 0
                and builders >= 2 and not nhero)
        end
        -- I am the greatest: computer heroes at level 100 or more, +100 experience for a win
        local gw = new(Advanced.enforce({ greatest = true }))
        local gh = gw.eco:heroAlive(1)
        check("advanced: I am the greatest gives computer heroes level 100", gh and gh.h.level >= 100)
        check("advanced: and is passed to the experience rules", require("src.game.battlexp").summary(gw, true, 1).greatest
            and not require("src.game.battlexp").summary(plain, true, 1).greatest)
        -- AI hero panel settings (aihero.lua, PNL_VIEWHERO): the computer's hero is made with the chosen race, class, level
        do
            local aihero = require("src.game.aihero")
            check("ai hero: level arrows run 4..50 and wrap", aihero.stepLevel(4, -1) == 50 and aihero.stepLevel(50, 1) == 4
                and aihero.stepLevel(2, 1) == 4 and aihero.stepLevel(2, -1) == 4 and aihero.stepLevel(20, 1) == 21)
            check("ai hero: unset settings stay unset, bad ones are dropped", aihero.clean({}) == nil
                and aihero.clean({ race = 99, class = -1 }) == nil and aihero.clean({ class = 3 }).class == 3)
            local f = aihero.fill({ class = 2 }, 5, 10)
            check("ai hero: the panel fills the rest (side race, level near the hero's)", f.class == 2 and f.race == 5
                and f.level >= 4 and f.level <= 15)
            local scn = assert(boot.loadScenario("Bridges"))
            scn.sides[1].aiHero = { race = 5, class = 13, level = 22 }
            local cw = worldMod.new(scn, { player = 0 })
            local ch = cw.eco:heroAlive(1)
            check("ai hero: chosen race, class and level apply to the computer's hero", ch and ch.h.level == 22
                and ch.h.race == 5 and ch.h.class == "Healer" and ch.code == require("src.game.economy").HERO[5])
            local gw2 = worldMod.new(scn, { player = 0, advanced = Advanced.enforce({ greatest = true }) })
            check("ai hero: I am the greatest still raises a chosen level", gw2.eco:heroAlive(1).h.level >= 100)
            local sc2 = assert(boot.loadScenario("Bridges"))
            local hw = worldMod.new(sc2, { player = 0 })
            check("ai hero: no choice keeps the side's race for the hero unit",
                hw.eco:heroAlive(1).code == require("src.game.economy").HERO[hw.sides[1].race])
        end
    end
    -- skirmish setup: the scenario's side / option locks and the produce-heroes flag
    do
        local boot = require("src.game.boot")
        local worldMod = require("src.game.world")
        local eld = assert(boot.loadScenario("Eldritch Tower"))
        check("setup locks: Eldritch Tower locks team and resources of its sides",
            eld.sides[0].teamLocked and eld.sides[0].resourcesLocked and eld.sides[4].teamLocked and not eld.sides[0].aiLocked)
        local dwarf = assert(boot.loadScenario("Dwarven Tunnels"))
        check("setup locks: Dwarven Tunnels locks the computer level of side 2 and hidden map / quests / handicapping",
            dwarf.sides[2].aiLocked and not dwarf.sides[1].aiLocked and dwarf.header.options.hiddenLocked
            and dwarf.header.options.questsLocked and dwarf.header.options.handicapLocked)
        local circles = assert(boot.loadScenario("Circles"))
        check("setup locks: Circles locks Tough Towers on", circles.header.options.modLocks.toughTowers
            and circles.header.options.mods.toughTowers and not circles.header.options.modLocks.noHeroes)
        local plain = worldMod.new(assert(boot.loadScenario("Bridges")), { player = 0 })
        local bridges = assert(boot.loadScenario("Bridges"))
        bridges.header.produceHeroes = false
        local none = worldMod.new(bridges, { player = 0, resurrect = true })
        local function heroes(w)
            local n = 0
            for _, u in ipairs(w.units) do if u.hero and u.side < 6 then n = n + 1 end end
            return n
        end
        check("produce heroes: a scenario with the flag off puts no hero on the map and none can be resurrected",
            heroes(plain) > 0 and heroes(none) == 0 and not none.resurrect and plain.heroesProduced)
        -- a skirmish seat plays the race of its panel whatever the hero's race (FUN_004de740): the hero unit is the hero's
        -- own race (World:heroRaceOf), the profile is asked for the hero whatever the seat's race (World:profileRace)
        local seatRace = plain.sides[0].race
        local other = (seatRace + 5) % 16
        local function fake(heroRace) return setmetatable({ opts = { heroRace = heroRace }, sides = plain.sides, player = 0 },
                                                          getmetatable(plain)) end
        check("skirmish seat race: the hero keeps its own race, the profile lookup ignores the seat's",
            fake(other):heroRaceOf(0) == other and fake(other):profileRace(0) == nil
            and fake(seatRace):heroRaceOf(0) == nil and fake(seatRace):profileRace(0) == nil
            and fake(nil):heroRaceOf(0) == nil and fake(nil):profileRace(0) == seatRace)
        -- resurrection (own opt-in rule) brings the hero back as the chosen avatar, not the race's default unit
        local profile = require("src.game.profile")
        local herocustom = require("src.game.herocustom")
        local rw = worldMod.new(assert(boot.loadScenario("Bridges")), { player = 0, resurrect = true, profile = true })
        local race = rw.sides[0].race
        local avatar = herocustom.AVATARS[race][#herocustom.AVATARS[race]]
        local oldRecordFor = profile.recordFor
        ---@diagnostic disable-next-line: duplicate-set-field -- a stub, restored below
        profile.recordFor = function(r) return { race = r, avatar = avatar, hero = {} } end
        local keep = rw:addBuilding({ code = "BKB0", side = 0, x = 26 * 32, y = 8 * 24 })
        local hero = rw.eco:heroAlive(0)
        if hero then hero:vanish(true) rw.sides[0].heroUnit = nil end
        local list = rw.eco:productionList(keep)
        -- pillaging (building destruction FUN_0052b3e0, "Temporary"): temples and mines turn neutral instead of being destroyed
        local pw = worldMod.new(assert(boot.loadScenario("Celestial Oasis")), { player = 0 })
        local temple
        for _, b in ipairs(pw.buildings) do if b.code == "BTCE" then temple = b break end end
        temple.side = 0
        pw:damageBuilding(temple, 99999, nil)
        local pillaged = temple.pillaged and temple.side == 6 and temple.hp == 1 and not temple.destroyed
        temple.pillaged = pw.time
        pw:update(1 / 30)
        check("pillage: a destroyed temple turns neutral and is back with full hits after the recovery time",
            pillaged and temple.hp == temple.maxHp and not temple.pillaged and temple.side == 6)
        local mw = worldMod.new(assert(boot.loadScenario("Bridges")), { player = 0 })
        local mine
        for _, b in ipairs(mw.buildings) do if b.mine and b.mine.resource == "gold" then mine = b break end end
        mine.side, mine.mine.reserve, mine.mine.produce = 0, 30, 5
        local gold = mw.sides[1].gold
        local raider = { side = 1 }                         -- an attacker of side 1
        mw:damageBuilding(mine, 99999, raider)
        check("pillage: a mine gives 10 x its production (at most what is left) and runs out for good without a rest",
            mw.sides[1].gold == gold + 30 and mine.mine.reserve == 0 and mine.side == 6 and not mine.pillaged and mine.hp == 0)
        -- Ancient Wisps bring 4 crystal with every income (the 1.04 army income 0x005299d0)
        local cw = worldMod.new(assert(boot.loadScenario("Bridges")), { player = 0 })
        local c0 = cw.sides[0].crystal
        cw.eco:income(0)
        local d1 = cw.sides[0].crystal - c0
        cw:addUnit("AEAX", 0, 20, 20)
        c0 = cw.sides[0].crystal
        cw.eco:income(0)
        check("income: an Ancient Wisp adds 4 crystal", cw.sides[0].crystal - c0 == d1 + 4)
        -- a computer side's casters start with 10 more mana when the maximum allows it (army mana setup FUN_00528cd0)
        local caster
        for _, rec in ipairs(require("src.content").unit:all()) do
            local inf = rec._info
            if not caster and not inf.hero and inf.maxMana and (inf.startMana or 0) + 10 <= inf.maxMana then caster = rec.id end
        end
        if caster then
            local hm, cm = cw:addUnit(caster, 0, 22, 20).mana, cw:addUnit(caster, 1, 24, 20).mana
            check("mana: a computer side's caster starts with 10 more mana (" .. caster .. ")",
                cw.humans[0] and not cw.humans[1] and cm == hm + 10)
        else
            check("mana: a unit type with mana exists", false)
        end
        local isHero = rw.eco:isHeroCode(0, list[1])
        profile.recordFor = oldRecordFor
        check("hero resurrection: the keep offers the hero's chosen avatar", list[1] == herocustom.AVATAR_CODES[avatar]
            and isHero)
    end
    -- wall building: the drag rules, the two construction rows, the builder rules and the queued build command
    do
        local walls = require("src.game.walls")
        local always = function() return true end
        check("walls: the wall test knows the pieces and the rampart (BWG/BWN/BWE 0..2, BWRA as in FUN_0052b3e0)",
            walls.isWall("BWG0") and walls.isWall("BWN2")
            and walls.isWall("BWE1") and walls.isWall("BWRA") and not walls.isWall("BWTC") and not walls.isWall("BWG3")
            and not walls.isWall("BKK0"))
        local function codes(d)
            local out = {}
            for i, s in ipairs(d.sections) do out[i] = s.code end
            return table.concat(out, " ")
        end
        local d = walls.start("BWG0", 10, 10, 100, 100)
        check("walls: a lone section keeps the chosen piece", codes(d) == "BWG0")
        walls.add(d, 12, 10, always)
        check("walls: two neighbours are both square pieces", codes(d) == "BWG0 BWG0")
        walls.add(d, 14, 10, always)
        walls.add(d, 16, 10, always)
        check("walls: a horizontal line is 2x1 pieces between square ends", codes(d) == "BWG0 BWG1 BWG1 BWG0")
        check("walls: a cell on the 2-cell grid snaps and a duplicate is refused",
            walls.add(d, 17, 10, always) == false and walls.add(d, 13, 10, always) == false and #d.sections == 4)
        d = walls.start("BWN1", 5, 6, 100, 100)
        walls.add(d, 5, 8, always)
        walls.add(d, 5, 10, always)
        check("walls: a vertical line is 1x2 pieces between square ends", codes(d) == "BWN0 BWN2 BWN0")
        check("walls: odd / even cells follow the first section", walls.add(d, 8, 11, always)
            and d.sections[4].gx == 7 and d.sections[4].gy == 10)
        d = walls.start("BWE0", 4, 4, 100, 100)
        walls.add(d, 6, 4, always)
        walls.add(d, 4, 6, always)
        check("walls: a corner or a branch is a square piece", codes(d) == "BWE0 BWE0 BWE0")
        d = walls.start("BWRA", 4, 4, 100, 100)
        walls.add(d, 6, 4, always)
        walls.add(d, 8, 4, always)
        check("walls: the rampart keeps its code", codes(d) == "BWRA BWRA BWRA")
        d = walls.start("BWG0", 4, 4, 20, 20)
        check("walls: outside the map and illegal cells are refused", walls.add(d, 20, 4, always) == false
            and walls.add(d, -2, 4, always) == false and walls.add(d, 6, 4, function() return false end) == false
            and #d.sections == 1)
        d = walls.start("BWG0", 1, 1, 200, 200)
        check("walls: an odd first cell at the edge refuses cell 0", walls.add(d, 0, 1, always) == false)
        d = walls.start("BWG0", 0, 0, 200, 200)
        for i = 1, 100 do walls.add(d, i * 2, 0, always) end
        check("walls: at most 64 sections", #d.sections == walls.MAX)
        check("walls: the drag list is plain data", walls.list(d)[2].code == "BWG1" and walls.list(d)[2].gx == 2)
        -- construction rows (Building.cfg [CONSTRUCTION] row 0 / row 1) and the builder rules
        local boot = require("src.game.boot")
        local worldMod = require("src.game.world")
        local function newWorld(mods)
            return worldMod.new(assert(boot.loadScenario("Bridges")), { player = 0, mods = mods })
        end
        local w = newWorld(nil)
        local function has(list, code)
            for _, c in ipairs(list) do if c == code then return true end end
            return false
        end
        local walls1 = w.eco:constructionList(0, 1)
        local major = w.eco:constructionList(0, 0)
        check("walls: row 1 is the tower, the wall pieces and the rampart", #walls1 == 5 and has(walls1, "BWRA")
            and (has(walls1, "BWG0") or has(walls1, "BWE0") or has(walls1, "BWN0")))
        check("walls: row 0 has no wall pieces", #major > 0 and not has(major, "BWRA"))
        check("walls: both rows together are what a builder may build",
            #w.eco:constructionList(0) == #major + #walls1)
        local nw = newWorld({ noWalls = true })
        check("walls: No Walls leaves the tower only", #nw.eco:constructionList(0, 1) == 1)
        local nt = newWorld({ noTowers = true })
        check("walls: No Towers leaves the wall pieces", #nt.eco:constructionList(0, 1) == #walls1 - 1)
        local builder, hero
        for _, u in ipairs(w.units) do
            if u.side == 0 and u:alive() then
                if u.hero then hero = hero or u elseif not builder and require("src.game.powerups").buildSkill(u) > 0 then builder = u end
            end
        end
        local function ofType(code) return { code = code } end      -- a stand-in army of the type
        check("walls: heroes and treants cannot build walls", (not hero or not walls.canBuild(hero))
            and not walls.canBuild(ofType("AWJX")) and not walls.canBuild(ofType("AWKX"))
            and walls.canBuild(ofType("AHBX")))
        if builder then
            -- the command: section 0 runs now, the others wait in the queue
            local list = {}
            local piece = has(walls1, "BWG0") and "BWG0" or (has(walls1, "BWE0") and "BWE0" or "BWN0")
            for i = 1, 4 do list[i] = { code = piece, gx = builder.gx + 2 * i, gy = builder.gy + 2 } end
            require("src.game.commands").apply(w, { t = "build", side = 0, id = builder.id, sections = list })
            check("walls: the first section is the builder's task", builder.task and builder.task.kind == "build"
                and builder.task.gx == list[1].gx)
            check("walls: the other sections are queued", builder.queue and #builder.queue == 3
                and builder.queue[3].kind == "build" and builder.queue[3].gx == list[4].gx)
            require("src.game.commands").apply(w, { t = "build", side = 0, id = builder.id,
                                                    sections = { { code = "BKK0", gx = builder.gx, gy = builder.gy } } })
            check("walls: the command only takes wall pieces", builder.task == nil or builder.task.code ~= "BKK0")
        else
            check("walls: a builder to test with", false)
        end
    end
    -- retinue: slots, setup points, recruits, the graveyard, computer armies and the setup of a battle
    do
        local retinue = require("src.game.retinue")
        local armylevel = require("src.game.armylevel")
        local gamedata = require("src.game.gamedata")
        local boot = require("src.game.boot")
        local worldMod = require("src.game.world")
        check("retinue: slots follow the Charisma", retinue.slots(0) == 1 and retinue.slots(3) == 1 and retinue.slots(4) == 2
            and retinue.slots(24) == 7 and retinue.slots(28) == 8 and retinue.slots(60) == 8)
        local pt = assert(gamedata.army("AHKX")).setupPoints
        check("retinue: setup points = type points + the level table", retinue.cost("AHKX", 0) == pt
            and retinue.cost("AHKX", 4) == pt + 1 and retinue.cost("AHKX", 9) == pt + 3 and retinue.cost("AHKX", 19) == pt + 15)
        local g1 = armylevel.gain({ combat = 3, speed = 10, hits = 20, damage = 5 }, 1)
        local g5 = armylevel.gain({ combat = 10, speed = 10, hits = 60, damage = 5 }, 5)
        check("retinue: one level adds 1 hit-table step, damage +2, resistance and armour +1",
            g1.combat == 1 and g1.hits == 5 and g1.damage == 2 and g1.resistance == 1 and g1.armor == 1)
        check("retinue: five levels add combat 5, hits 70 (the range follows the value), damage 11, resistance 6, armour 6",
            g5.combat == 5 and g5.hits == 10 + 10 + 20 + 10 + 20 and g5.damage == 11 and g5.resistance == 6 and g5.armor == 6)
        check("retinue: no damage is learnt without an attack", armylevel.gain({ combat = 3, speed = 5, hits = 20, damage = 0 }, 4).damage == 0)
        check("retinue: the general of a race is rolled from its table", retinue.generalFor(0, 3) == "AHGW"
            and retinue.generalFor(5, 0) == "AOGX" and retinue.generalFor(15, 9) == "AHGB")
        -- recruits: eligibility, replacing, the general
        local codes = { "AHKX", "AHMX", "AHFX", "AHDX", "AHEX", "AHBX", "AAEG", "AHIX" }
        local function cand(code, level, extra)
            local c = { code = code, level = level, xp = 10, combat = 9, defaultData = true }
            for k, v in pairs(extra or {}) do c[k] = v end
            return c
        end
        local function names(list)
            local out = {}
            for _, e in ipairs(list) do out[#out + 1] = e.code .. e.level end
            return table.concat(out, " ")
        end
        local opts = { race = 0, short = false, pitched = false, roll = 3 }
        local list = retinue.recruits({ cand("AHKX", 1), cand("AHMX", 2, { combat = 7 }), cand("AHFX", 2, { mechanical = true }),
                                        cand("AAEY", 4), cand("AHDX", 2, { defaultData = false }), cand("AHEX", 3) }, opts)
        check("retinue: level 2, combat 8, not mechanical, not the Eye, default data", names(list) == "AHEX3 AHGW0")
        check("retinue: the general is level 0 with 1 experience", list[2].general and list[2].xp == 1 and list[2].name == nil)
        check("retinue: a general among the candidates stops the added one",
            names(retinue.recruits({ cand("AHEX", 3, { general = true }) }, opts)) == "AHEX3")
        check("retinue: no general after a short game", names(retinue.recruits({}, { race = 0, short = true, roll = 3 })) == "")
        check("retinue: a short pitched battle still gets one", names(retinue.recruits({}, { race = 0, short = true, pitched = true, roll = 3 })) == "AHGW0")
        local eight = {}
        for i = 1, 8 do eight[i] = cand(codes[i], 2, { general = i == 1 }) end
        local full = retinue.recruits(eight, opts)
        check("retinue: at most eight recruits", #full == 8)
        local strong = {}
        for i = 1, 9 do strong[i] = cand(codes[(i - 1) % 8 + 1], 2, { general = i == 1 }) end
        strong[9].level = 10
        local weakest, weakStrength = nil, 1000
        for i = 1, 8 do
            local s = retinue.stats(codes[i], 2).combat + 10
            if s < weakStrength then weakest, weakStrength = codes[i], s end
        end
        local replaced = retinue.recruits(strong, opts)
        local has10, hasWeak = false, false
        for _, e in ipairs(replaced) do
            if e.level == 10 then has10 = true end
            if e.code == weakest and e.level == 2 then hasWeak = true end
        end
        check("retinue: a full list gives up its weakest entry for a stronger newcomer", #replaced == 8 and has10 and not hasWeak)
        local dup = {}
        for i = 1, 8 do dup[i] = cand(i == 2 and "AHKX" or codes[i], i == 2 and 5 or 2, { general = i == 1 }) end
        dup[9] = cand("AHIX", 2)
        local r = retinue.recruits(dup, opts)
        local ahkx2 = false
        for _, e in ipairs(r) do if e.code == "AHKX" and e.level == 2 then ahkx2 = true end end
        check("retinue: with a type twice in a full list the weaker copy goes", #r == 8 and not ahkx2)
        -- naming sets of the recruits
        check("retinue: naming sets by type and race flags", retinue.nameSetOf("AWGX", 0) == 15 and retinue.nameSetOf("AHFX", 1) == 2
            and retinue.nameSetOf("AAIM", 0) == 1 and retinue.nameSetOf("ABCX", 0x100) == 1 and retinue.nameSetOf("ABCX", 0x38) == 6
            and retinue.nameSetOf("ABCX", 0x2) == 8 and retinue.nameSetOf("ABCX", 0x80) == 12 and retinue.nameSetOf("ABCX", 0x1) == 4
            and retinue.nameSetOf("ABCX", 0x4000) == nil and retinue.nameSetOf("ABCX", 0) == 0)
        check("retinue: typed names keep 19 characters, the original's heroes get a 2",
            retinue.cleanName("Aaaaaaaaaabbbbbbbbbbcccc") == "Aaaaaaaaaabbbbbbbbb" and retinue.cleanName("ROBERT") == "ROBERT2"
            and retinue.cleanName("Rob") == "Rob")
        -- the graveyard
        local rec = { retinue = { { code = "AHKX", level = 2, xp = 12, battles = 3 }, { code = "AHMX", level = 1, xp = 5, battles = 1 },
                                  [5] = { code = "AHDX", level = 3, xp = 30, battles = 0 } } }
        retinue.settle(rec, { brought = { true, true }, alive = { [2] = { level = 2, xp = 20 } }, scenario = "Bridges",
                              fallen = { [1] = "AOMX" } })
        local gy = rec.graveyard
        check("retinue: a fallen member goes to the graveyard with its battles and the place", gy[1] and gy[1].code == "AHKX"
            and gy[1].battles == 4 and gy[1].scenario == "Bridges" and rec.retinue[1] == nil)
        check("retinue: the grave keeps the unit type that killed the member", gy[1].killer == "AOMX")
        check("retinue: survivors keep what they learned and count the battle", rec.retinue[2].level == 2 and rec.retinue[2].xp == 20
            and rec.retinue[2].battles == 2 and rec.retinue[5].battles == 1)
        local rec2 = { retinue = {}, graveyard = {} }
        for i = 1, 10 do rec2.graveyard[i] = { code = "AHBX", level = 0, xp = 0, battles = 1, scenario = "", since = i } end
        rec2.graveyard[1].level, rec2.graveyard[1].since = 9, 1
        rec2.retinue[1] = { code = "AHKX", level = 1, xp = 5, battles = 1 }
        retinue.settle(rec2, { brought = { true }, alive = {}, scenario = "X" })
        check("retinue: a full graveyard gives up the one that has been there longest, the best stays first",
            rec2.graveyard[1].level == 9 and rec2.graveyard[10].code == "AHKX" and rec2.graveyard[10].since == 1)
        -- computer armies
        local first = function() return 1 end
        local out = retinue.aiArmy(0, 5, 2, first)
        check("retinue: a computer side buys its builder first, then the table row", table.concat(out, " ") == "AHBX AAEG AHMX")
        check("retinue: a Knave gets half of the rest", table.concat(retinue.aiArmy(0, 5, 1, first), " ") == "AHBX AAEG")
        check("retinue: one point is the builder only", #retinue.aiArmy(3, 1, 2, first) == 1 and #retinue.aiArmy(3, 0, 2, first) == 0)
        local bad = 0
        for race = 0, 15 do
            for p = 1, 8 do
                for roll = 1, 4 do
                    local army = retinue.aiArmy(race, p == 1 and 1 or p + 1, 2, function() return roll end)
                    for _, code in ipairs(army) do if not gamedata.army(code) then bad = bad + 1 end end
                end
            end
        end
        check("retinue: every unit of the computer table exists", bad == 0)
        check("retinue: campaign difficulty gives 10 or 4 points", retinue.aiExtraPoints(1, 29) == 10 and retinue.aiExtraPoints(1, 30) == 4
            and retinue.aiExtraPoints(1, 75) == 0 and retinue.aiExtraPoints(2, 59) == 10 and retinue.aiExtraPoints(0, 1) == 0)
        local hire, major = retinue.aiMercenaryRoll(1, 10, 24)
        local hire2, major2 = retinue.aiMercenaryRoll(1, 10, 49)
        check("retinue: computer mercenaries by hero level and difficulty", hire and major and hire2 and not major2
            and not retinue.aiMercenaryRoll(1, 10, 50) and not retinue.aiMercenaryRoll(2, 4, 1) and retinue.aiMercenaryRoll(1, 6, 11))
        -- the campaign's extra army points, mercenary selection and difficulty option
        local run = require("src.game.campaignrun")
        local st = { crowns = 45, mercs = { 3, 12 }, save = function() end }
        check("campaign: extra points cost 10 crowns for 4 and 30 for 10", run.buyExtraPoints(st, 1) == 4 and st.crowns == 35
            and run.buyExtraPoints(st, 2) == 10 and st.crowns == 5 and run.buyExtraPoints(st, 1) == 0 and st.crowns == 5
            and run.buyExtraPoints(st, 0) == 0 and not run.extraPointsAvailable(st))
        local taken = run.takeMercenaries(st, { [2] = true })
        local D = require("src.game.campaigndata").load()
        local want = 0
        for _, u in ipairs(D.mercenaries[12].units) do want = want + u.number end
        check("campaign: only the selected mercenary companies come along, the others stay", #taken == want and #st.mercs == 1
            and st.mercs[1] == 3 and #run.takeMercenaries(st, nil) == 0 and #st.mercs == 1)
        check("campaign: computer heroes by difficulty", run.computerHeroLevel(0, 9) == 4 and run.computerHeroLevel(0, 1) == 1
            and run.computerHeroLevel(1, 9) == 9 and run.computerHeroLevel(2, 9) == 13)
        check("campaign: no fog of war on Easy", run.fogMode({ fog = true }, 0) == 3 and run.fogMode({ fog = true }, 1) == 2
            and run.fogMode({ fog = true, hidden = true }, 0) == 4 and run.fogMode({ fog = true, hidden = true }, 2) == 1)
        -- the campaign AI level (FUN_005a1790) and the levels of the computer sides (FUN_005a1880)
        local function hero(wins, games, level, race) return { raceWins = { [race or 3] = wins }, raceGames = { [race or 3] = games }, hero = { level = level } } end
        check("campaign: AI level from victories, games, hero level and difficulty",
            run.aiLevel(hero(0, 0, 1), 3, 1) == 0 and run.aiLevel(hero(5, 6, 1), 3, 1) == 2 and run.aiLevel({}, 3, 1) == 0
            and run.aiLevel(hero(10, 10, 1), 3, 0) == 1 and run.aiLevel(hero(80, 90, 45), 3, 2) == 4
            and run.aiLevel(hero(80, 90, 45), 3, 3) == 5 and run.aiLevel(hero(5, 6, 20), 3, 1) == 3 and run.aiLevel(hero(5, 6, 20), 4, 1) == 0)
        check("campaign: side levels follow the scenario, the map's attributes and the difficulty",
            run.sideLevel(partial({ relativeai = 1 }), 3, 3, 1) == 4 and run.sideLevel(partial({ relativeai = 0 }), 0, 3, 1) == 0
            and run.sideLevel(partial({ relativeai = 0 }), 7, 3, 1) == 7 and run.sideLevel(partial({ ai = 7 }), 3, 3, 1) == 7
            and run.sideLevel(partial({ relativeai = 0 }), 1, 3, 0) == 1 and run.sideLevel(nil, 3, 3, 2) == 4
            and run.sideLevel(partial({ team = 0 }), nil, 3, 2) == 3 and run.sideLevel(partial({ relativeai = -1 }), nil, 3, 2) == 3
            and run.sideLevel(partial({ relativeai = 3 }), nil, 5, 2) == 6)
        check("campaign: difficulty rating of a map",
            run.difficultyRating(partial({ sides = { [0] = { team = 0 } } }), 3) == 2
            and run.difficultyRating(partial({ sides = { [0] = { team = 0 }, { team = 0 }, { team = 0 }, { team = 0 } } }), 3) == 3
            and run.difficultyRating(partial({ sides = { [0] = { team = 1 }, { team = 1 } } }), 4) == 1
            and run.difficultyRating(partial({ sides = { [0] = { team = 0 }, { team = 0, ai = 0 }, { team = 0, relativeai = 1 } } }), 3) == 3 - 1
            and run.difficultyRating(partial({ sides = { [0] = { team = 0 } } }), 0) == 0)
        -- the race list and the picked race of a campaign battle (FUN_005a2fc0 / FUN_00595470 / FUN_005a3390 / FUN_005a1880)
        local hate = require("src.game.campaignhate")
        check("campaign: relations by standing", hate.relation(-5) == "enemy" and hate.relation(-4) == "neutral"
            and hate.relation(4) == "neutral" and hate.relation(5) == "friend" and hate.relation(14) == "friend"
            and hate.relation(15) == "ally" and hate.initial(0, 0) == 20 and hate.initial(0, 2) == -10 and hate.initial(15, 11) == 8)
        check("campaign: diplomatic steps apply twice up to the limit", hate.apply(3, 2, 15, -1000) == 7 and hate.apply(3, 2, 5, 0) == 5
            and hate.apply(9, 4, 14, 0) == 14 and hate.apply(3, 100, 5, 0) == 103 and hate.apply(0, -4, 99, -10) == -8
            and hate.apply(-4, -4, 99, -10) == -10 and hate.apply(-8, -4, 99, -10) == -12 and hate.apply(5, 0, 1, 1) == 5)
        local cstate, profileMod = require("src.game.campaignstate"), require("src.game.profile")
        local realGet = profileMod.get
        ---@diagnostic disable-next-line: duplicate-set-field -- a stub, restored below
        profileMod.get = function() return nil end
        local oldSave = cstate.new("selftest")
        oldSave.diplomacy[5] = 3                                  -- a save from before the table: changes counted from 0
        ---@diagnostic disable-next-line: duplicate-set-field -- a stub, restored below
        profileMod.get = function() return { race = 0 } end
        local newSave = cstate.new("selftest")
        oldSave:seedStandings()
        oldSave:seedStandings()
        profileMod.get = realGet
        check("campaign: standings start as the hero's row, an older save gets it added once", newSave.standingsSeeded
            and newSave:rating(1) == 10 and newSave:relation(0) == "ally" and newSave:relation(2) == "enemy"
            and oldSave.standingsSeeded and oldSave:rating(5) == 2 and oldSave:rating(1) == 10)
        local fakeRec = { race = 3, hero = { level = 1 }, raceWins = { [1] = 10 }, raceGames = { [1] = 10 } }
        local oldRec = run.heroRecord
        ---@diagnostic disable-next-line: duplicate-set-field -- a stub, restored below
        run.heroRecord = function() return fakeRec end
        local relations = { [1] = "ally", [3] = "ally", [6] = "friend", [9] = "ally", [12] = "ally" }
        local raceState = { relation = function(_, r) return relations[r] or "neutral" end, difficulty = 1, bonuses = {} }
        local list = run.battleRaces(raceState)
        check("campaign: the race list is the hero's race first, then the allied races", #list == 4 and list[1] == 3 and list[2] == 1
            and list[3] == 9 and list[4] == 12)
        ---@type boolean?
        local pickedOk = false
        local diffOk = false
        -- in a fixed order (pairs would pick a different map each run), and for the difficulty a map where the hero's
        -- own race is inside the 0..5 scale (at either end both are clamped and the line cannot show the record)
        local actionKeys = {}
        for k in pairs(D.actions) do actionKeys[#actionKeys + 1] = k end
        table.sort(actionKeys, function(a, b) return tostring(a) < tostring(b) end)
        local diffChecked = false
        for _, k in ipairs(actionKeys) do
            local act = D.actions[k]
            local map = act.type == "battle" and act.map and D.maps[act.map]
            if map and map.file and map.file ~= "random" then
                if not pickedOk then
                    local scn, opts = run.setup(raceState, act.map, nil, 1)
                    local own, ownOpts = run.setup(raceState, act.map)
                    pickedOk = scn and scn.sides[0].race == 1 and opts.race == 1 and opts.heroRace == 3
                        and own and own.sides[0].race == 3 and ownOpts.race == 3
                end
                local d3 = not diffChecked and run.mapDifficulty(raceState, act.map, 3)
                if d3 and d3 > 0 and d3 < 5 then
                    diffChecked = true
                    diffOk = run.mapDifficulty(raceState, act.map, 1) > run.mapDifficulty(raceState, act.map, 3)
                end
            end
        end
        run.heroRecord = oldRec
        check("campaign: the picked race is side 0's, the hero keeps his own", pickedOk)
        check("campaign: the difficulty line follows the picked race's record", diffOk)
        local o = run.options(partial({ difficulty = 2 }))
        check("campaign: option defaults", o.difficulty == 2 and o.scrollRate == 1 and o.menuSounds == 1 and run.options(partial({})).difficulty == 1)
        check("retinue: handicap points", retinue.handicap(10, 10) == 0 and retinue.handicap(11, 10) == 1 and retinue.handicap(40, 10) == 41
            and retinue.handicap(45, 10) == 41 + 15)
        -- a battle with armies: the human's choice, the computer's purchase, levels, recruit flags
        local armies = { [0] = { retinue = { { slot = 2, code = "AHKX", level = 3, xp = 40, name = "Rob" } }, army = { "AHMX", "AHMX" } } }
        local w = worldMod.new(assert(boot.loadScenario("Bridges")), { player = 0, armies = armies, startPoints = 5 })
        local mine, others, rob = 0, 0, nil
        for _, u in ipairs(w.units) do
            if u.side == 0 then mine = mine + 1 end
            if u.side == 1 then others = others + 1 end
            if u.retinueIndex == 2 then rob = u end
        end
        check("retinue: the retinue member and the bought troops are placed", rob and rob.name == "Rob" and rob.level == 3 and w.brought[0][2]
            and mine >= 4)
        local base = assert(gamedata.army("AHKX"))
        local plain = w:addUnit("AHKX", 0, 31, 31)
        check("retinue: a retinue member has the stats of its level", rob and plain
            and rob.maxHp - plain.maxHp == armylevel.gain({ combat = base.combat, speed = base.speed, hits = plain.maxHp, damage = base.damage }, 3).hits
            and rob:stats().combat >= plain:stats().combat and rob.hp == rob.maxHp)
        assert(rob)
        check("retinue: setup armies cannot become recruits, later ones can", not rob.canRetinue)
        local made = w:addUnit("AHKX", 0, 30, 30, { level = 4, xp = 40 })
        local cands = made and retinue.collect(w, 0) or {}
        for i = #cands, 1, -1 do if cands[i].level == 0 then table.remove(cands, i) end end
        check("retinue: a unit made in the battle is a candidate", made and made.canRetinue and #cands == 1 and cands[1].code == "AHKX")
        check("retinue: a computer side buys an army", others >= 2)
        assert(made)
        made:addXp(500)
        check("retinue: experience levels add the hits at once", made.level > 4 and made.hp == made.maxHp and made.maxHp > base.hits)
    end
    do      -- hot keys: the network statistics dialog (Ctrl+N)
        local netstats = require("src.ui.netstats")
        local r, g, b = netstats.barColour(netstats.barValue(100, 1000))
        check("netstats: the original's constant 100 % / 1000 ms gives a 40 pixel bar of colour 255,200,0",
            netstats.barValue(100, 1000) == 40 and r == 255 and g == 200 and b == 0)
        check("netstats: a perfect link is a full green bar, a bad one a short dark red bar",
            netstats.barValue(100, 0) == 65 and select(2, netstats.barColour(65)) == 255
            and netstats.barValue(85, 1500) == 5 and select(1, netstats.barColour(5)) == 100)
        local lockstep = require("src.game.lockstep")
        local peer = { stats = function() return 12, 97.5 end }
        local host = lockstep.host(nil, { sides = { 0, 1, 2 }, localSide = 0, peers = { [1] = peer }, names = { [0] = "A", [1] = "B" } })
        local rows = netstats.rows(host, nil)
        check("netstats: the host measures its clients and shows itself as perfect",
            #rows == 3 and rows[1].ping == 0 and rows[2].ping == 12 and rows[2].reliability == 97.5
            and rows[2].name == "B" and rows[3].ping == nil and rows[3].name == "Player 3")
        local client = lockstep.client(nil, { sides = { 0, 1 }, localSide = 1, server = peer, names = {} })
        rows = netstats.rows(client, nil)
        check("netstats: before the host's table arrives a client only knows its own link to the host",
            rows[1].ping == 12 and rows[2].ping == 12)
        -- the host relays every player's figures once a second; a client shows the full table
        local sent = {}
        local function fake(ping) return { stats = function() return ping, 99 end, send = function(_, m) sent[#sent + 1] = m end } end
        local h2 = lockstep.host(nil, { sides = { 0, 1, 2 }, localSide = 0, peers = { [1] = fake(30), [2] = fake(80) }, names = {} })
        local hashBefore = require("src.core.serialize").encode({ h2.tick, h2.sentTurn })
        h2:sendStats()
        check("netstats: the host sends its table to every client and keeps the simulation state untouched",
            #sent == 2 and sent[1].t == "netstats" and sent[1].stats[2][1] == 80 and sent[1].stats[0][2] == 100
            and hashBefore == require("src.core.serialize").encode({ h2.tick, h2.sentTurn }))
        client.netStats = sent[1].stats
        local c3 = lockstep.client(nil, { sides = { 0, 1, 2 }, localSide = 1, server = peer, names = {} })
        c3.netStats = require("src.core.serialize").decode(require("src.core.serialize").encode(sent[1].stats))
        rows = netstats.rows(c3, nil)
        check("netstats: a client shows every player from the host's table",
            rows[1].ping == 0 and rows[2].ping == 30 and rows[3].ping == 80 and rows[3].reliability == 99)
    end
    do      -- formations: the original's slot tables (0x005FBC9C) and their use
        local formation = require("src.game.formation")
        local data = require("src.game.formationdata")
        local complete = true
        for _, kind in ipairs(formation.KINDS) do
            for n = 1, 32 do
                local t = data.slots[kind] and data.slots[kind][n]
                if not t or #t ~= 2 * n then complete = false end
            end
        end
        check("formations: 8 formations with 1..32 slots for every group size", complete and #formation.KINDS == 8)
        local b = data.slots.block[32]
        check("formations: the table is the binary's (Block of 32 starts (1,-5) (-1,-5) (5,-3) (-5,-3))",
            b[1] == 1 and b[2] == -5 and b[3] == -1 and b[4] == -5 and b[5] == 5 and b[6] == -3 and b[7] == -5 and b[8] == -3)
        local c4 = data.slots.circle[4]
        check("formations: the ring of 4 has a centre, one beside and one behind",
            c4[1] == 0 and c4[2] == 0 and c4[3] == 2 and c4[4] == 0 and c4[5] == -2 and c4[6] == 0 and c4[7] == 0 and c4[8] == 2)
        local function off(dir, x, y) local a, b2 = formation.offset(dir, x, y) return a .. "," .. b2 end
        check("formations: the eight directions turn the slot (3,-5) like the formation placement FUN_00530f80",
            off(4, 3, -5) == "3,-5" and off(6, 3, -5) == "-5,-3" and off(0, 3, -5) == "-3,5" and off(2, 3, -5) == "5,3"
            and off(5, 3, -5) == "-4,-2" and off(3, 3, -5) == "2,-4" and off(1, 3, -5) == "4,2" and off(7, 3, -5) == "-2,4")
        check("formations: the facing follows FUN_0040c770 (near keeps it, 2:1 quadrants)",
            formation.directionFor(2, 3, 6) == 6 and formation.directionFor(0, -8, 4) == 0 and formation.directionFor(0, 8, 0) == 4
            and formation.directionFor(8, 0, 0) == 6 and formation.directionFor(-8, 0, 0) == 2 and formation.directionFor(8, 8, 0) == 5
            and formation.directionFor(-8, 8, 0) == 3 and formation.directionFor(-8, -8, 0) == 1 and formation.directionFor(8, -8, 0) == 7
            and formation.directionFor(-8, 3, 0) == 2 and formation.directionFor(2, 8, 0) == 4)
        local function fake(id, range, combat)
            return { id = id, stats = function() return { range = range, combat = combat } end }
        end
        local list = { fake(1, 0, 30), fake(2, 6, 10), fake(3, 0, 20), fake(4, 6, 10), fake(5, 3, 5) }
        local placed = formation.assign("block", list, 50, 50, formation.BOTTOM)
        local ids = {}
        for _, p in ipairs(placed) do ids[#ids + 1] = p.unit.id end
        local t5 = data.slots.block[5]
        check("formations: longest range first, then lowest combat, ties in selection order",
            table.concat(ids, ",") == "2,4,5,3,1" and placed[1].gx == 50 + t5[1] and placed[1].gy == 50 + t5[2]
            and placed[5].gx == 50 + t5[9] and placed[5].gy == 50 + t5[10])
        local many = {}
        for i = 1, 40 do many[i] = fake(i, 0, 1) end
        local spread, seen, dup = formation.assign("block", many, 50, 50, formation.BOTTOM), {}, false
        for _, p in ipairs(spread) do
            local key = p.gx .. "," .. p.gy
            if seen[key] then dup = true end
            seen[key] = true
        end
        check("formations: more than 32 units get a second batch behind the first", #spread == 40 and not dup)
        -- the state is per army: defaults, the leader is the highest damage (first of equal), apply writes all
        local function army(dmg) return { stats = function() return { damage = dmg } end } end
        local group = { army(5), army(9), army(9), army(2) }
        local k0, d0 = formation.state(group[1])
        check("formations: a new army has the Defensive Ring facing TOP", k0 == 2 and d0 == formation.TOP)
        check("formations: the group leader is the first army of the highest damage", formation.leader(group) == group[2])
        group[2].formationType, group[2].formationDir = 5, formation.LEFT
        local lk, ld = formation.state(assert(formation.leader(group)))
        check("formations: the group move reads the leader's state only", lk == 5 and ld == formation.LEFT
            and select(1, formation.state(group[1])) == 2)
        formation.apply(group, 5, formation.RIGHT)
        local ak, ad = formation.state(group[4])
        check("formations: apply gives type and direction to every army", ak == 5 and ad == formation.RIGHT)
    end
    do
        -- building combat: the computer-player level bonus of the building combat value (FUN_0052ae70; real value,
        -- computer sides only)
        local stand = { buildings = {}, sides = {
            [0] = { ai = false, aiLevel = 5 }, [1] = { ai = true, aiLevel = 1 }, [2] = { ai = true, aiLevel = 2 },
            [3] = { ai = true, aiLevel = 3 }, [4] = { ai = true, aiLevel = 4 }, [5] = { ai = true, aiLevel = 5 },
            [6] = { ai = true, aiLevel = 6 } } }   -- a stand-in for the world
        local eco = require("src.game.economy").new(stand)
        local function combat(side)
            local tower = { side = side, type = { combat = 10 } }
            return eco:buildingCombat(tower)
        end
        local neutral = { side = 6, type = { combat = 10, damage = 5, range = 6 } }
        local base, real = eco:buildingStats(neutral)
        check("buildings: computer level bonus Knave -2, Knight 0, Lord +1, Prince +2, Warlord +3, Emperor +5",
            combat(1) == 8 and combat(2) == 10 and combat(3) == 11 and combat(4) == 12 and combat(5) == 13
            and combat(6) == 15)
        check("buildings: a human side gets no bonus, the displayed base value never does",
            combat(0) == 10 and base.combat == 10 and real.combat == 15)
    end
    do
        -- network lobby: map transfer pieces (reordered, with a repeat) and the host's readyToStart
        local mapxfer = require("src.game.mapxfer")
        local bytes = {}
        for i = 1, 9001 do bytes[i] = string.char((i * 7) % 256) end
        local data = table.concat(bytes)
        local pieces = mapxfer.pieces(data, 1)
        local collect, got = mapxfer.collector(), nil
        for k = #pieces, 1, -1 do got = collect(pieces[k]) or got end
        check("lobby: map pieces of any order give the file back, checksum is stable and word wise",
            #pieces == 3 and got == data and collect(pieces[1]) == nil
            and mapxfer.checksum(data) == mapxfer.checksum(got) and mapxfer.checksum("\1\0\0\0\2") == 3)
        local host = require("src.screens.mphost")
        local function lobby(seats, ready, sync)
            local f = setmetatable({ sides = seats, sync = sync }, host)
            ---@diagnostic disable-next-line: duplicate-set-field -- a stub of the lobby screen
            f.humanAt = function(_, i) local sd = seats[i] return sd and sd.human and { ready = sd.human == "ready" } or nil end
            ---@diagnostic disable-next-line: duplicate-set-field -- a stub of the lobby screen
            f.mySeat = function() return 0 end
            return f
        end
        local function seat(kind, team) return { human = (kind == "ready" or kind == "wait") and kind or nil, open = kind == "open",
                                                  closed = kind == "closed", team = team } end
        check("lobby: readyToStart needs every human ready, two played seats and different teams",
            lobby({ [0] = seat("ready", 1), seat("ready", 2) }):readyToStart()
            and not lobby({ [0] = seat("ready", 1), seat("wait", 2) }):readyToStart()
            and not lobby({ [0] = seat("ready", 1), seat("open", 2) }):readyToStart()
            and not lobby({ [0] = seat("ready", 1), seat("closed", 2) }):readyToStart()
            and not lobby({ [0] = seat("ready", 1), seat("ready", 1) }):readyToStart()
            and lobby({ [0] = seat("ready", 0), seat("ready", 0) }):readyToStart()
            and lobby({ [0] = seat("ready", 1), seat("ai", 2) }):readyToStart()
            and not lobby({ [0] = seat("ready", 1), seat("ready", 2) }, nil, { never = true }):readyToStart())
        -- the host removes a player (answer 0x004ed610): his seat is Open again, he is told and cannot act any more; a player picks
        -- the race of his own seat (-1 is Random) unless the scenario locks it or he is ready
        local sent = {}
        local f = setmetatable({ sides = { [0] = { player = 0, team = 1 }, { player = 1, team = 2 }, { raceLocked = true, open = true } },
                                 players = { [0] = { name = "H" }, { name = "P", ready = true, peer = { send = function(_, m) sent[#sent + 1] = m.t end } } },
                                 held = {}, joining = {} }, host)
        ---@diagnostic disable-next-line: duplicate-set-field -- a stub of the lobby screen
        f.broadcastLobby = function() end
        ---@diagnostic disable-next-line: duplicate-set-field -- a stub of the lobby screen
        f.locked = function() return false end
        ---@diagnostic disable-next-line: duplicate-set-field -- a stub of the lobby screen
        f.humanAt = function(self, i) local sd = self.sides[i] return sd and sd.player ~= nil and self.players[sd.player] or nil end
        f.sides[1].race = 3
        f.players[1].peer.slot = 1
        f:handle(f.players[1].peer, { t = "ready", on = false })
        f:handle(f.players[1].peer, { t = "side", side = 1, field = "race", value = 7 })
        local picked = f.sides[1].race
        f:handle(f.players[1].peer, { t = "side", side = 1, field = "race", value = -1 })
        local random = f.sides[1].race == nil
        f.sides[1].raceLocked = true
        f:handle(f.players[1].peer, { t = "side", side = 1, field = "race", value = 4 })
        f.sides[1].raceLocked = nil
        f:boot(1)
        f:handle(f.players[1].peer, { t = "seat", side = 2 })
        check("lobby: a player picks his seat's race (Random = -1, not when locked); the host boots him and the seat is Open",
            picked == 7 and random and f.sides[1].race == nil and f.sides[1].open == true and f.sides[1].player == nil
            and f.players[1].booted ~= nil and sent[#sent] == "booted" and f.sides[2].player == nil)
    end
    require("src.tools.randomtest").run(check)          -- random map pieces and generator
    require("src.tools.fxtest").run(check)              -- presentation effects: decals, particles, lights, text, gamma
    require("src.tools.editortest").run(check)          -- scenario editor: chunk round trips, object / sides / chest dialogs
    require("src.tools.conversiontest").run(check)      -- keep conversion, palace conversions, best conversion square
    require("src.tools.contenttest").run(check)         -- content registry: patch API, removal, hash, dump, rollback
    require("src.tools.queststest").run(check)          -- shrine quests: answer and build kinds, name, naming set remap
    for _, test in ipairs(M.extra or {}) do failures = failures + (test() or 0) end
    log.info("%d failures", failures)
    return failures == 0 and 0 or 1
end

return M
