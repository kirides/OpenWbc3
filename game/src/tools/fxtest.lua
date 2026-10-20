-- Self tests of the presentation effects (decals, particles, floating text, lights, gamma, menu effect): the rules
-- taken from the original, without a window. Called from selftest.lua with its `check`.
local M = {}

---@param check fun(name: string, ok: any) the selftest's check: logs ok / FAIL and counts the failures
function M.run(check)
    local gamma = require("src.ui.gamma")
    local m1, a1 = gamma.ramp(1)
    local m4, a4 = gamma.ramp(4)
    local m0, a0 = gamma.ramp(0)
    check("gamma: level 0 is the identity, 1..3 scale by 0xffff - g * 0x1fff, 4 lifts the blacks by 0x3fff",
        m0 == 1 and a0 == 0 and math.abs(m1 - (0xffff - 0x1fff) / 0xffff) < 1e-9 and a1 == 0
        and m4 == 0.75 and math.abs(a4 - 0x3fff / 0xffff) < 1e-9)

    -- decals
    local decals = require("src.gfx.decals")
    local cells = { [0] = 3 }
    local terr = { w = 8, h = 8,
        inside = function(_, x, y) return x >= 0 and y >= 0 and x < 8 and y < 8 end,
        cell = function(_, x, y)
            local t = (x == 5) and 3 or ((x == 6) and 4 or 0)         -- water at x = 5, a cliff (no move cost) at x = 6
            return t, 0, (x == 6) and 0 or 1
        end }
    ---@cast terr Terrain
    local on = { decals = true, blood = true }
    local d = decals.new(terr, { decals = function() return on.decals end, blood = function() return on.blood end })
    check("decals: gore lives 120 s, 0.8 s on water, none without move cost",
        d:create("goreRed", 1, 1, 0) and d.cells[1 * 8 + 1].expires == 120000
        and d:create("goreRed", 5, 1, 0) and d.cells[1 * 8 + 5].expires == 800
        and not d:create("goreRed", 6, 1, 0))
    check("decals: a lower priority does not replace a decal, an equal or higher one does",
        d:create("scorch", 2, 2, 0) and not d:create("footSmallV", 2, 2, 0) and d.cells[2 * 8 + 2].ty == decals.TYPES.scorch
        and d:create("scorch", 2, 2, 100) and d:create("baseDirt", 2, 2, 100) and d.cells[2 * 8 + 2].expires == nil)
    d:update(1000)
    check("decals: they expire", d.cells[1 * 8 + 5] == nil and d.cells[1 * 8 + 1] ~= nil)
    on.blood = false
    check("decals: no gore with blood off, none at all with decals off",
        not d:create("goreGreen", 3, 3, 0) and d:create("footSmallH", 3, 3, 0))
    on.decals = false
    check("decals: off creates nothing", not d:create("footSmallH", 4, 4, 0))
    local link = {}
    on.decals = true
    d:create("baseStandard", 0, 4, 0, link)
    d:removeLinked(link)
    check("decals: linked decals go with their building", d.cells[4 * 8] == nil)

    -- floating text
    local floattext = require("src.gfx.floattext")
    local ft = floattext.new()
    local u = {}
    local ok1 = ft:add(u, "a", floattext.STANDARD, true, 100, 100, 1000)
    local ok2 = ft:add(u, "b", floattext.BAD, true, 100, 100, 1000)
    local ok3 = ft:add(u, "c", floattext.GOOD, true, 100, 100, 1000)
    check("floating text: at most two per army, the second is delayed 500 ms, 'bad' of an own army is 'good' (font 38)",
        ok1 and ok2 and not ok3 and ft.items[2].start == 1500 and ft.items[2].font == 38)
    local ft2 = floattext.new()
    local army1, army2 = {}, {}                         -- two armies (the list only keys on them)
    ft2:add(army1, "a", floattext.STANDARD, true, 100, 100, 1000)
    ft2:add(army2, "b", floattext.STANDARD, true, 100, 100, 1100)
    check("floating text: a message close after another at the same height is moved 30 px lower and 250 ms later",
        ft2.items[1].y0 == 60 and ft2.items[2].y0 == 90 and ft2.items[2].start == 1350)
    ft:update(1000 + 1000 + 1500)
    check("floating text: lives 1000 + 1500 ms", #ft.items == 1 and ft.items[1].text == "b")

    -- lights
    local lighting = require("src.gfx.lighting")
    local li = lighting.new()
    li:add(1, 1, lighting.RED, lighting.SMALL, lighting.SHORT, 0, 1)
    li:add(1, 1, lighting.RED, lighting.LARGE, lighting.VERYLONG, 0, 1)
    li:add(1, 1, lighting.RED, lighting.LARGE, lighting.VERYLONG, 0, 0)
    check("lighting: level 1 drops the smallest flash and shrinks the rest by one size and two durations, level 0 shows none",
        #li.items == 1 and li.items[1].size == 1 and li.items[1].duration == 0)
    li:update(6 * 50)
    check("lighting: a short flash lasts six steps of 50 ms", #li.items == 0)

    -- particles
    local particles = require("src.gfx.particles")
    local counts = {}
    for level = 0, 3 do
        local pl = particles.new()
        pl:add(0, 0, 0, { size = 20, respawn = 4, level = level })
        counts[level] = pl.bursts[1] and #pl.bursts[1].parts or 0
        if pl.bursts[1] then counts["r" .. level] = pl.bursts[1].respawn end
    end
    check("particles: the level option scales the count (none, half, three quarters, all) and the respawns",
        counts[0] == 0 and counts[1] == 10 and counts[2] == 15 and counts[3] == 20
        and counts.r1 == 0 and counts.r2 == 2 and counts.r3 == 4)
    local pl = particles.new()
    pl:add(0, 0, 0, { size = 4, type = particles.POINT })
    for i = 1, 30 do pl:update(i * 25) end
    check("particles: a burst is over after 42 steps", #pl.bursts == 0)

    -- emitters (binary: building emitters FUN_0040e930, effect codes FUN_0040ebd0, missile codes FUN_0040f620,
    -- the Explode ability FUN_00529a40)
    local emitters = require("src.gfx.emitters")
    local function same(def, size, colors, gravity, dir, ptype, speed, anim, fade)
        return def and def.size == size and def.colors == colors and def.gravity == gravity and def.direction == dir
            and def.type == ptype and def.speed == speed and def.animation == anim and def.fade == fade
    end
    local P = particles
    local function eff(code) return (emitters.effect(code)) end
    local function mis(code) return (emitters.missile(code)) end
    check("emitters: soul sparkle, chaos effect and chaos cast as in the binary",
        same(eff("ESSP"), 4, 0x20, 4, 2, 0, 1, 1, 1) and same(eff("ECHE"), 9, 2, 4, 1, 0, 1, 1, 4)
        and same(eff("ECHC"), 9, 2, 4, 1, 1, 1, 4, 2))
    check("emitters: mana leech has no break in the original and runs into venom touch's block",
        same(eff("EMLE"), 1, 4, 4, 1, 1, 0, 6, 1) and eff("EMLE").every == 1 and eff("ESVT").every == 1)
    check("emitters: the acid breath's EPGA and the good breath's EBLS (own picture EZ21), every fifth frame",
        same(eff("EPGA"), 7, 4, 2, 4, 0, 0, 1, 2) and eff("EPGA").every == 5 and eff("EPGA").py == -40
        and same(eff("EBLS"), 7, 0x20, 1, 2, 4, 1, 5, 2) and select(2, emitters.effect("EBLS")) == "EZ21")
    check("emitters: spell cast effects (poison cast lights green, ice storm sprays huge cyan bursts)",
        eff("EPOC").light and eff("EPOC").light[1] == 3 and same(eff("EIST"), 12, 0x10, 2, 2, 1, 2, 4, 1)
        and eff("EIST").respawn == 4 and same(eff("ESMR"), 5, 1, 4, 2, 3, 1, 10, 2) and eff("ESMR").respawn == 3)
    local function steps(n) return table.concat(emitters.steps(n, 16), ",") end
    check("emitters: an effect fires on its first frame and then every `every` frames (the counter starts at 1000)",
        steps(5) == "1,6,11,16" and steps(100) == "1" and steps(1):gsub(",", "") == "12345678910111213141516"
        and table.concat(emitters.steps(5, 8), ",") == "1,6")
    check("emitters: the titan's balls (15 massive fountain particles, fast, random frame, gradual fade)",
        same(mis("EMTF"), 15, 2, 2, 2, 1, 2, 10, 2) and same(mis("EMTM"), 15, 0x10, 2, 2, 1, 2, 10, 2)
        and mis("EMTF").area == 3 and mis("EMTF").every == 1000)
    local _, sprite = emitters.missile("EMAP")
    local _, axe = emitters.missile("EMS0")
    local _, ice = emitters.missile("EMIS")
    check("emitters: missile codes swap their picture (poison arrow EMA0, Minotaur's axe EMM3, ice shards invisible)",
        sprite == "EMA0" and axe == "EMM3" and ice == "EDUM" and select(2, emitters.missile("EMFP")) == "EMA2")
    check("emitters: fire ball and magic sphere only flash small short lights, lightning medium ones",
        mis("EMF0").size == 0 and mis("EMF0").light[1] == 2 and mis("EMF0").every == 2 and mis("EMM0").light[1] == 4
        and mis("EMM1").light[2] == 1 and mis("EMM1").gy == -2 and mis("EMM2").light[1] == 4)
    local function one() return 1 end
    local function two() return 2 end
    check("emitters: building emitters (plague glow, cave stars with a random colour, furnace smoke or sparks)",
        same(emitters.building("BACP", one), 3, 4, 4, 2, 1, 0, 2, 1) and emitters.building("BACP", one).every == 9
        and emitters.building("BPFC", one).colors == 2 and emitters.building("BPFC", two).colors == 0x20
        and emitters.building("BPIC", one).colors == 0x10 and emitters.building("BKA0", one).type == 1
        and emitters.building("BKA0", two).type == 3 and emitters.building("BKA0", two).gy == 5
        and same(emitters.building("BKV0", one), 3, 1, 4, 2, 3, 0, 10, 2) and emitters.building("BKV0", one).every == 10)
    local pe = particles.new()
    check("emitters: Explode's two bursts and the Minotaur's meal",
        emitters.EXTRA.explode[1].size == 8 and emitters.EXTRA.explode[2].colors == 0x40 and emitters.EXTRA.eat[1].size == 11)
    emitters.emit(pe, "explode", 10, 10, 0, 3)
    emitters.emit(pe, "nonsense", 10, 10, 0, 3)
    check("emitters: a code makes its bursts, an unknown one nothing", #pe.bursts == 2)
    -- the frame-rate throttle (FUN_0048fb80 and its users)
    local frameload = require("src.gfx.frameload")
    frameload.reset()
    for i = 1, 40 do frameload.frame(i * 200) end            -- 5 frames a second
    local slow = frameload.problems
    local pt = particles.new()
    pt:add(0, 0, 0, { size = 8, level = 3 })
    local kept = #pt.bursts
    frameload.reset()
    for i = 1, 40 do frameload.frame(i * 20) end             -- 50 frames a second
    check("frame throttle: a slow game raises the counter to its maximum, a fast one keeps it at 0",
        slow == 20 and frameload.problems == 0 and kept == 0)
    frameload.reset()

    -- idle fidgets (the fidget roll at 0x00539a90 of the 1.04 binary)
    local fid = require("src.gfx.fidget")
    local b = fid.bands(20, 0x0c)
    check("fidget: the ambient animation up to the rate, the turn bands at +2 / +4 / +5 / +6 with the rotation bit",
        b[1] == 20 and b[2] == 22 and b[3] == 24 and b[4] == 25 and b[5] == 26 and fid.bands(20, 0x04)[5] == 20
        and fid.bands(20, 0x08)[1] == 0 and fid.bands(20, 0x08)[5] == 6 and fid.bands(20, 0)[5] == 0)
    check("fidget: a roll picks the band", fid.pick(b, 20) == fid.AMBIENT and fid.pick(b, 21) == fid.TURN_LEFT
        and fid.pick(b, 24) == fid.TURN_RIGHT and fid.pick(b, 25) == fid.WIDE_LEFT and fid.pick(b, 26) == fid.WIDE_RIGHT
        and fid.pick(b, 27) == fid.NONE)
    local function flat(seq)
        local t = {}
        for _, e in ipairs(seq) do t[#t + 1] = ("%d:%d%s%d"):format(e[1], e[2], e[3]:sub(1, 1), e[4]) end
        return table.concat(t, " ")
    end
    check("fidget: narrow turns show stand frame 1 for 100 ms, then the new facing (left is dir + 7)",
        flat(fid.sequence(fid.TURN_LEFT, 2, false, 0)) == "0:1s1 100:1s0 200:1s0"
        and flat(fid.sequence(fid.TURN_RIGHT, 2, false, 0)) == "0:2s1 100:3s0 200:3s0")
    check("fidget: a wide turn goes two steps; the ambient animation plays its frames at 100 ms",
        flat(fid.sequence(fid.WIDE_LEFT, 0, false, 0)) == "0:7s1 100:6s1 200:6s0 300:6s0"
        and flat(fid.sequence(fid.AMBIENT, 3, false, 3)) == "0:3a0 100:3a1 200:3a2 300:3a0"
        and flat(fid.sequence(fid.TURN_RIGHT, 7, true, 0)) == "0:7w1 100:7s1 200:0w1 300:0s0 400:0s0")
    local fl = fid.new()
    local u1, u2 = { id = 1, dir = 0, type = { fidget = 100, flags = 0x04 } }, { id = 2, dir = 0, type = { fidget = 100, flags = 0x04 } }
    for t = 0, 5 do
        fl:update(t * 25, function() return { u1, u2 } end, true, function() return true end, function() return 3 end)
    end
    check("fidget: a pass every fifth tick that ends at the first unit that fidgets", fl.units[u1] and not fl.units[u2]
        and fl:view(u1, 125, true).anim == "ambient")
    fl:update(10 * 25, function() return { u1, u2 } end, true, function() return true end, function() return 3 end)
    check("fidget: a unit in its sequence is skipped, the next one gets its chance", fl.units[u2] ~= nil)
    check("fidget: a unit that is no longer idle loses its view", fl:view(u1, 50, false) == nil)

    -- options: volume levels, scroll rate, music sets, feature ambience
    local go = require("src.core.gameopts")
    check("options: sound effects levels are 0 / 30 / 60 / 90 / 120 of 127, music levels 0 / 32 / 64 / 96 / 128 (clamped)",
        math.abs(go.SFX[5] - 120 / 127 * 100) < 0.1 and math.abs(go.SFX[3] - 60 / 127 * 100) < 0.1
        and math.abs(go.MUSIC[4] - 96 / 127 * 100) < 0.1 and go.MUSIC[5] == 100 and go.volumeLevel("effects") >= 1)
    check("options: scroll is `rate` cells per event, 60 events a second at the edge and 20 for the keys",
        go.SCROLL_EDGE_EVENTS == 60 and go.SCROLL_KEY_EVENTS == 20 and go.scrollRate() >= 1 and go.scrollRate() <= 5)
    local music = require("src.audio.music")
    local sets = music.sets()
    check("music sets: the install's Battlecry3.ini is listed by its title", #sets >= 1 and sets[#sets].title ~= ""
        and music.setFile() ~= "")
    local ambience = require("src.audio.ambience")
    local fea = 0
    for _, path in ipairs(require("src.vfs.vfs").list("%.[Ff][Ee][Aa]$")) do
        if ambience.featureSound(path:match("(%w+)%.%w+$")) then fea = fea + 1 end
    end
    check("feature ambience: no shipped feature type has the ambient flag", fea == 0)

    -- the spell records' effect pictures (read from the cast functions of the 1.04 binary, docs/spells.md) and the effect items
    local content = require("src.content")
    local vfs = require("src.vfs.vfs")
    local bySlot = content.spell.cache.slot
    local function pic(slot) return bySlot[slot] and bySlot[slot].pictures or {} end
    check("spell pictures: heal group EZ11 / EZ11, blessing EBLS, immunity EIMM, venom touch ESVT, Elemental Lore at the base",
        pic(4).cast == "EZ11" and pic(4).target == "EZ11" and pic(2).persistent == "EBLS" and pic(100).persistent == "EIMM"
        and pic(104).persistent == "ESVT" and pic(110).persistent == "EZ65" and pic(110).base and not pic(100).base)
    check("spell pictures: Ring of Ice (84) and Banish (114) call the functions of 48 and 18, the troops' Shield has the base picture EZ54",
        pic(84).cast == "EZ07" and pic(48).cast == "EZ07" and pic(114).target == "EZ37" and pic(18).target == "EZ37"
        and pic(-1).persistent == "EZ54" and pic(-1).base)
    check("spell pictures: the dialog spells (60, 61, 78, 96) have none", next(pic(60)) == nil and next(pic(61)) == nil
        and next(pic(78)) == nil and next(pic(96)) == nil)
    local missing, n = {}, 0
    for slot = -1, 129 do
        local p = bySlot[slot] and bySlot[slot].pictures
        for _, key in ipairs({ "cast", "target", "persistent" }) do
            local code = p and p[key]
            if code then
                n = n + 1
                if not (emitters.EFFECTS[code] or vfs.find(code .. ".ani")) then missing[#missing + 1] = code end
            end
        end
    end
    check("spell pictures: every code is an emitter effect or a picture of the install (" .. n .. " of them; missing: "
        .. table.concat(missing, " ") .. ")", n > 150 and #missing == 0)
    local items = require("src.gfx.effectitems")
    check("effect items: 50 ms a frame, 120 ms for EX01, 43..70 ms for the healing and lightning pictures; the feet-and-behind target codes",
        items.frameMs("EZ34", 1, 1, 0) == 50 and items.frameMs("EX01", 1, 1, 0) == 120 and items.frameMs("EZ11", 3, 4, 100) >= 43
        and items.frameMs("EZ11", 3, 4, 100) <= 70 and items.frameMs("EZ11", 3, 4, 100) == items.frameMs("EZ11", 3, 4, 120)
        and items.AT_BASE.EZ34 and items.AT_BASE.EZ40 and not items.AT_BASE.EZ20)
    -- which armies a cast touched (a world before and after)
    local spellfx = require("src.gfx.spellfx")
    local u1, u2, u3 = { id = 1, gx = 5, gy = 5, hp = 10, fx = {} }, { id = 2, gx = 4, gy = 4, hp = 10, fx = {} },
        { id = 3, gx = 6, gy = 6, hp = 10, fx = {} }
    local fw = { time = 1000, units = { u1, u2, u3 }, buildings = {}, missiles = {} }
    local ctx = { durMs = 30000 }
    local snap = spellfx.begin(fw, u1, {}, ctx)
    u2.hp = 6                                                      -- hurt
    u3.fx.slow = { t1 = 31000 }                                     -- a timed effect added
    local u4 = { id = 4, gx = 7, gy = 7, hp = 5, fx = {} }
    fw.units[4] = u4                                                -- a new army
    local res = spellfx.finish(fw, snap)
    check("cast pictures: the armies hurt, given an effect or made are touched row by row; the effect carries the picture until the cast's end",
        #res.touched == 3 and res.touched[1] == u2 and res.touched[2] == u3 and res.touched[3] == u4
        and #res.persistent == 1 and res.persistent[1].owner == u3 and res.persistent[1].kinds.slow and res.untilMs == 31000)
    snap = spellfx.begin(fw, u1, {}, ctx)
    res = spellfx.finish(fw, snap)
    check("cast pictures: a cast that changed nothing touches nothing and puts its persistent picture on the caster",
        #res.touched == 0 and #res.persistent == 1 and res.persistent[1].owner == u1)
    snap = spellfx.begin(fw, u1, {}, ctx)
    fw.missiles[1] = { shooter = u1, target = u2 }                  -- what missiles.launch keeps of a spell missile
    fw.missiles[2] = { shooter = u3, target = u4 }                  -- somebody else's
    res = spellfx.finish(fw, snap)
    check("cast pictures: the target of a missile the cast fired is touched at the cast (FUN_004ac0e0 case 0x10)",
        #res.touched == 1 and res.touched[1] == u2)

    -- main menu effect
    local menu = require("src.ui.menueffect")
    local me = menu.new()
    for i = 1, 14 do me:add("x", 400, 100, i * 0.01) end
    check("main menu effect: at most twelve at once", #me.items == 12)
    me:update(0.5 + 1.5)
    check("main menu effect: lasts 1.5 s", #me.items == 0)
end

return M
