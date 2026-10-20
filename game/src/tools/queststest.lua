-- Headless checks of the shrine quests the shipped data never uses (kind 4 "provide an answer", kind 8 "build a
-- building type"), of the quest giver's name and of the naming set remap for languages other than English:
-- `run(check)` is called from selftest.lua. The quest records are made up here (the install has none of these).
local M = {}

-- A battle screen stand-in for savegame.snapshot / apply, which read only the world, the scenario path and the camera.
---@param t table
---@return BattleScreen
local function asBattle(t) return t --[[@as BattleScreen]] end

---@param check fun(name: string, ok: any) the selftest's check: logs ok / FAIL and counts the failures
function M.run(check)
    local boot = require("src.game.boot")
    local worldMod = require("src.game.world")
    local quests = require("src.game.quests")
    local rules = require("src.game.rules")
    local savegame, serialize = require("src.game.savegame"), require("src.core.serialize")

    -- the original's table (u16 at 0x608618): Evil / Barbarian -> GenericEvil, Draconic stays, the rest Standard
    local expected = { [0] = 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 14, 0 }
    local same, mapped = true, true
    for i = 0, 15 do
        same = same and quests.nameSetIndex(i, "English") == i
        mapped = mapped and quests.nameSetIndex(i, "German") == expected[i]
    end
    check("naming sets: English uses the asked set", same)
    check("naming sets: every other language goes through the original's remap table", mapped
        and quests.nameSetIndex(7, "French") == 0 and quests.nameSetIndex(13, "Russian") == 1)

    local w = worldMod.new(assert(boot.loadScenario("Bridges")), { player = 0 })
    local hero = w.eco:heroAlive(0)
    if not hero then return end
    ---@return Building
    local function shrine(gx, gy)
        local b = w:addBuilding({ code = "BMSH", side = 6, x = gx * 32 + 16, y = gy * 24 + 12 })
        return b
    end
    -- the hero's arrival picks the quest (the "visit" event), the dialog's page only reads it
    ---@param b Building
    local function visit(b)
        quests.offer(w, hero, b)
        return quests.visit(w, hero, b)
    end
    local list = quests.list("BMSH")
    local saved = { ids = list.ids, count = list.count }
    local function only(def)
        def.prefix, def.id = "BMSH", 99
        def.name, def.newq, def.cont, def.cmpl, def.inst, def.rept = "Title", "Hello ~NAME~", "", "Done ~NAME~", "", ""
        def.time, def.idle, def.naming, def.pic = 600, 30, 0, nil
        list[99], list.ids, list.count = def, { 99 }, 1
    end
    local free = { gold = 0, metal = 0, crystal = 0, stone = 0 }

    -- kind 4: always legal, an answer box instead of Accept, the answer ignores case, the reward comes with it
    local b4 = shrine(20, 40)
    only({ req = { kind = 4, n = 1, answer = "Sirian" }, reward = { res = { gold = 123 } } })
    local gold = w.sides[0].gold
    local info = visit(b4)
    check("quest kind 4: the dialog asks for an answer and has the complete text ready",
        info and info.mode == "answer" and info.done == "Done " .. b4.quest.name and info.text == "Hello " .. b4.quest.name)
    local def = quests.def(b4)
    check("quest kind 4: the answer is compared without regard to case",
        quests.rightAnswer(def, "sIrIaN") and not quests.rightAnswer(def, "Sirians") and not quests.rightAnswer(def, ""))
    check("quest kind 4: nothing happens before an answer", quests.complete(w, hero, b4) == nil and w.sides[0].gold == gold)
    local lines = quests.complete(w, hero, b4, true)
    check("quest kind 4: a right answer pays the reward and sends the shrine to rest",
        lines and w.sides[0].gold == gold + 123 and b4.quest.state == "recovery" and w.sides[0].quest == nil)

    -- the quest giver's name is drawn once per quest: the same in the text and for the character reward
    local b5 = shrine(24, 40)
    only({ req = { kind = 0, n = 1, res = "gold", amount = 999999 }, reward = { char = { code = "AHFX", xp = 0 } } })
    visit(b5)
    local name = b5.quest.name
    local again = visit(b5)
    ---@cast again -nil
    check("quest name: drawn when the shrine picks the quest and kept", name ~= nil and name ~= ""
        and again.text:find(name, 1, true) and b5.quest.name == name)
    quests.accept(w, hero, b5)
    check("quest name: the side's quest carries it", w.sides[0].quest.name == name)
    local snap = savegame.snapshot(asBattle({ world = w, scnPath = "Bridges", camX = 0, camY = 0, zoom = 1 }))
    local round = serialize.decode(serialize.encode(snap))
    local w2 = worldMod.new(assert(boot.loadScenario("Bridges")), { player = 0, restore = round, advanced = round.opts.advanced })
    savegame.apply(asBattle({ world = w2 }), round)
    local b6
    for _, b in ipairs(w2.buildings) do if b.code == "BMSH" and b.quest and b.quest.name == name then b6 = b end end
    check("quest name: a saved game keeps it, on the shrine and on the side", b6 ~= nil and w2.sides[0].quest
        and w2.sides[0].quest.name == name)
    w.sides[0].quest = nil

    -- kind 8: counts finished buildings of the type, never a temple, only what the race can build
    local race = w.sides[0].race or 0
    local code
    for _, e in ipairs(rules.buildList(race)) do
        if e.id:sub(1, 1) == "B" and quests.buildable(race, e.id) then code = e.id break end
    end
    local b8 = shrine(28, 40)
    only({ req = { kind = 8, n = 1, code = code }, reward = { res = { gold = 5 } } })
    local i8 = visit(b8)
    check("quest kind 8: offered for a building the race can build", code ~= nil and i8 and i8.mode == "new")
    quests.accept(w, hero, b8)
    local d8 = quests.def(b8) --[[@as QuestDef]]
    local c8 = visit(b8)
    check("quest kind 8: the dialog shows the count line", c8 and c8.mode == "continue" and c8.hint == "Progress: 0 of 1"
        or (c8 and c8.hint and c8.hint:find("0") ~= nil))
    check("quest kind 8: not met before one is built", not quests.met(w, 0, d8))
    quests.onEvent(w, "built", { side = 1, code = code })
    quests.onEvent(w, "built", { side = 0, code = "BXXX" })
    check("quest kind 8: other sides' and other types' buildings do not count", not quests.met(w, 0, d8))
    quests.onEvent(w, "built", { side = 0, code = code })
    check("quest kind 8: finishing one meets it", quests.met(w, 0, d8))
    check("quest kind 8: and the reward comes with the visit", quests.complete(w, hero, b8) ~= nil)
    local bt = shrine(32, 40)
    only({ req = { kind = 8, n = 1, code = "BTCE" }, reward = { res = { gold = 5 } } })
    local _, why = visit(bt)
    check("quest kind 8: a temple cannot be built, so the shrine has nothing to offer", why == "none")

    -- a power-up reward the side already owns makes the quest illegal
    local bp = shrine(36, 40)
    only({ req = { kind = 0, n = 1, res = "gold", amount = 1 }, reward = { powerup = "PRG0" } })
    w.sides[0].powerups = w.sides[0].powerups or {}
    w.sides[0].powerups.PRG0 = true
    local _, why2 = visit(bp)
    check("quest: a power-up the side owns is not offered as a reward", why2 == "none")
    w.sides[0].powerups.PRG0 = nil

    -- the commands: a hero far from the shrine does nothing, one beside it accepts, and a resource quest it can pay
    -- is finished at once; the typed answer of a kind 4 quest is checked again by the command
    local commands = require("src.game.commands")
    local bc = shrine(hero.gx + 1, hero.gy + 1)
    only({ req = { kind = 0, n = 1, res = "gold", amount = 10 }, reward = { res = { metal = 77 } } })
    w.sides[0].gold = 5
    visit(bc)
    local far = shrine(hero.gx + 30, hero.gy)
    local function cmd(op, b, answer)
        commands.apply(w, { t = "quest", side = 0, op = op, bid = b.id, hero = hero.id, answer = answer })
    end
    only({ req = { kind = 0, n = 1, res = "gold", amount = 10 }, reward = { res = { metal = 77 } } })
    visit(far)
    cmd("accept", far)
    check("quest command: a hero away from the shrine cannot accept", w.sides[0].quest == nil)
    cmd("accept", bc)
    check("quest command: accept gives the side the quest", w.sides[0].quest and w.sides[0].quest.srcId == bc.id)
    local metal = w.sides[0].metal
    cmd("complete", bc)
    check("quest command: complete needs the requirement", w.sides[0].quest ~= nil and w.sides[0].metal == metal)
    w.sides[0].gold = 50
    cmd("complete", bc)
    check("quest command: complete pays the reward and rests the shrine",
        w.sides[0].quest == nil and w.sides[0].metal == metal + 77 and w.sides[0].gold == 40 and bc.quest.state == "recovery")
    local b9 = shrine(hero.gx + 1, hero.gy - 2)
    only({ req = { kind = 0, n = 1, res = "gold", amount = 10 }, reward = { res = { metal = 1 } } })
    visit(b9)
    cmd("accept", b9)
    check("quest command: a resource quest already payable is finished on accept",
        w.sides[0].quest == nil and b9.quest.state == "recovery" and w.sides[0].gold == 30)
    local b10 = shrine(hero.gx - 2, hero.gy - 1)
    only({ req = { kind = 4, n = 1, answer = "Sirian" }, reward = { res = { metal = 3 } } })
    visit(b10)
    metal = w.sides[0].metal
    cmd("complete", b10, "wrong")
    check("quest command: a wrong answer pays nothing", b10.quest.state == "held" and w.sides[0].metal == metal)
    cmd("complete", b10, "SIRIAN")
    check("quest command: a right answer pays", b10.quest.state == "recovery" and w.sides[0].metal == metal + 3)

    local bv = shrine(hero.gx - 2, hero.gy + 3)
    only({ req = { kind = 0, n = 1, res = "gold", amount = 10 }, reward = { res = { metal = 1 } } })
    w:event("visit", hero, bv)
    check("quest: the visit event (every peer runs it) picks the shrine's quest", bv.quest.state == "held" and bv.quest.name ~= nil)

    -- two peers that run the same visit and commands (the random stream reseeded per tick, as in a network game)
    -- end with the same shrine quest, giver and side quest
    list[99], list.ids, list.count = nil, saved.ids, saved.count
    local function peer()
        local pw = worldMod.new(assert(boot.loadScenario("Bridges")), { player = 0 })
        local ph = assert(pw.eco:heroAlive(0))
        local sb = pw:addBuilding({ code = "BMSH", side = 6, x = ph.gx * 32 + 48, y = ph.gy * 24 + 36 })
        math.randomseed(4242)
        pw:event("visit", ph, sb)
        math.randomseed(4243)
        commands.apply(pw, { t = "quest", side = 0, op = "accept", bid = sb.id, hero = ph.id })
        return sb.quest.id, sb.quest.name, pw.sides[0].quest and pw.sides[0].quest.id
    end
    local qa, na, sa = peer()
    local qb, nb, sb2 = peer()
    check("quest command: two peers pick the same quest, giver and side quest",
        qa ~= nil and qa == qb and na == nb and sa == sb2)
    list[99], list.ids, list.count = nil, saved.ids, saved.count
    free = nil
end

return M
