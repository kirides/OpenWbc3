-- Self tests of the scenario editor's data side (the dialogs of src/screens/editorobject.lua, editorsides.lua and
-- editoritems.lua): every shipped scenario's army, building, chest, side, AI and header chunk must be written back byte for byte
-- from its parsed fields; what the dialogs change is saved and read back; the saved scenario loads in a battle.
-- Called from tools/selftest.lua (`require("src.tools.editortest").run(check)`).
local M = {}

---@param check fun(name: string, ok: any) the selftest's check: logs ok / FAIL and counts the failures
function M.run(check)
    local scn = require("src.formats.scn")
    local scnwrite = require("src.formats.scnwrite")
    local fs = require("src.core.fs")
    local config = require("src.core.config")
    local lib = require("src.game.editorlib")
    local rules = require("src.game.rules")
    local boot = require("src.game.boot")
    local items = require("src.game.items")

    -- 1. the chunk writers reproduce every shipped chunk; the type indices of Army.cfg / Building.cfg are the SCN's type indices
    do
        local counts, bad, badIndex = 0, {}, 0
        local function chk(kind, a, b)
            counts = counts + 1
            if a ~= b then bad[kind] = (bad[kind] or 0) + 1 end
        end
        for _, dir in ipairs({ "Scenario", "CampaignScenario", "Tutorial" }) do
            for _, name in ipairs(fs.list(config.gamedir .. "/" .. dir, "%.scn$")) do
                local s = scn.parse(fs.read(config.gamedir .. "/" .. dir .. "/" .. name) --[[@as string]])
                if s then
                    for _, a in ipairs(s.armies) do
                        chk("army", scnwrite.chunk.army(a), a.raw)
                        local info = rules.armyInfo(a.code)
                        if not info or info.index ~= a.globalIndex then badIndex = badIndex + 1 end
                    end
                    for _, b in ipairs(s.buildings) do
                        chk("building", scnwrite.chunk.building(b), b.raw)
                        local info = rules.building(b.code)
                        if not info or info.index ~= b.globalIndex then badIndex = badIndex + 1 end
                    end
                    for _, it in ipairs(s.items) do chk("item", scnwrite.chunk.item(it), it.raw) end
                    chk("header", scnwrite.chunk.header(s), s.header.raw)
                    chk("sides", scnwrite.chunk.sides(s), s.rawSides)
                    chk("ai", scnwrite.chunk.ai(s), s.rawAI)
                end
            end
        end
        local why = {}
        for k, v in pairs(bad) do why[#why + 1] = k .. "=" .. v end
        check(("scenario chunk round trip (%d chunks)%s"):format(counts, #why > 0 and (": " .. table.concat(why, ",")) or ""),
            counts > 5000 and #why == 0)
        -- the 33 left are placeholders: the tower variants of Forest Lakes (the game re-picks the race's tower type) and a unit of
        -- C_KorDwarf made against another table
        check("scenario type indices match Army.cfg / Building.cfg (" .. badIndex .. " off)", badIndex <= 40)
    end

    -- 2. objects: defaults of a placed army / building, the owner rules, the Done of the dialog
    local sc = assert(boot.loadScenario("Bridges"))
    local before = #sc.items
    local plain
    for _, e in ipairs(rules.armyList()) do
        if not e.hero and not require("src.game.unit").isCritter(e.code) and require("src.game.gamedata").army(e.code) then
            plain = e.code
            break
        end
    end
    local goose = lib.add(sc, "armies", "ACGO", 10, 10, 0)
    local grunt = lib.add(sc, "armies", plain, 11, 10, 1)
    local hall = lib.add(sc, "buildings", (rules.buildList(0)[1] or {}).id, 14, 14, 0)
    check("editor object: a critter is neutral, an army starts with its type's statistics",
        goose.side == 6 and goose.owner == 6 and grunt.useDefault and grunt.behaviour == 2 and grunt.alive
        and grunt.curHits == grunt.hits and grunt.hits > 0 and grunt.globalIndex == rules.armyInfo(grunt.code).index)
    check("editor object: owner cycle", lib.nextOwner("armies", goose) == 6 and lib.nextOwner("armies", grunt) == 2
        and lib.nextOwner("buildings", hall) == 1)
    lib.applyArmy(grunt, "Bob", "boss1", "4")
    lib.applyBuilding(hall, "Fort", "")
    check("editor object: Done stores name, tag, level and the experience of the level",
        grunt.name == "Bob" and grunt.tag == "boss1" and grunt.character and grunt.level == 3 and grunt.xp == 20
        and hall.name == "Fort" and hall.character)
    lib.applyArmy(grunt, "", "", "0")
    check("editor object: level 0 is clamped, no name is no character", grunt.level == 0 and not grunt.character)
    lib.applyArmy(grunt, "Bob", "boss1", "4")
    grunt.behaviour, grunt.script = 4, "ambush"
    grunt.combat, grunt.useDefault = 99, false
    lib.setOwner("armies", grunt, 1)

    -- 3. sides, options, mods, AI file
    sc.header.options.techLevel, sc.header.options.techLocked = 3, true
    sc.header.options.armySetupPoints, sc.header.options.pointsLocked = 33, true
    sc.header.options.hiddenLocked, sc.header.options.handicapping = true, true
    sc.header.options.mods.noDragons, sc.header.options.modLocks.toughTowers = true, true
    sc.sides[1].raceLocked, sc.sides[1].mustBeHuman, sc.sides[1].team, sc.sides[1].resources = true, true, 4, 3
    sc.sides[2].used, sc.sides[2].mustBeOn = true, true
    sc.ai[2].file = "G_Reckless.ai"
    local five = lib.newScenario("S", 64, "")
    local rule1 = lib.canSwitchSide(five, 2, true) and not lib.canSwitchSide(five, 3, true) and not lib.canSwitchSide(five, 1, false)
    five.sides[2].used = true
    local rule2 = lib.canSwitchSide(five, 3, true) and lib.canSwitchSide(five, 2, false) and not lib.canSwitchSide(five, 0, false)
    five.sides[3].used = true
    check("editor sides: a side switches on after the lower ones and off before the higher ones",
        rule1 and rule2 and not lib.canSwitchSide(five, 2, false) and not lib.canSwitchSide(five, 5, true))

    -- 4. chests
    -- a scenario chest holds numbered items (an i16 in the file): the base items, never a mod item's "modid:name"
    local function itemNo(i) return items.all()[i].id --[[@as integer]] end
    local rnd = assert(lib.placeChest(sc, 20, 20, "random"))
    local ok2, why2 = lib.placeChest(sc, 20, 20, "random")
    local it = assert(lib.placeChest(sc, 22, 20, "item", itemNo(3)))
    lib.placeChest(sc, 22, 20, "item", itemNo(4))
    lib.placeChest(sc, 22, 20, "item", itemNo(5))
    lib.placeChest(sc, 22, 20, "item", itemNo(6))
    local full, whyFull = lib.placeChest(sc, 22, 20, "item", itemNo(7))
    local res = assert(lib.placeChest(sc, 24, 20, "resource", 4))
    local rc, whyRes = lib.placeChest(sc, 24, 20, "item", itemNo(3))
    check("editor chests: a random item goes on a free cell only, four items at most, a resource chest holds nothing else",
        rnd and not ok2 and why2 == "noresource" and it.chest.count == 4 and not full and whyFull == "full"
        and res.chest.resource and res.dir == 3 and res.chest.items[1].data == 17 and not rc and whyRes == "resource")
    lib.removeChestItem(it, 2)
    check("editor chests: removing an item moves the rest up, the last one stays",
        it.chest.count == 3 and it.chest.items[2].index == items.all()[5].id and not lib.removeChestItem(rnd, 1))

    -- 4b. moving a chest (right click on an empty cell / dragging)
    local mv = assert(lib.placeChest(sc, 26, 20, "item", itemNo(3)))
    local movedOk = lib.moveChest(sc, mv, 27, 21)
    local blocked = lib.moveChest(sc, mv, 24, 20)           -- the resource chest is there
    check("editor chests: a chest moves to a free cell, not onto another chest",
        movedOk and not blocked and lib.chestAt(sc, 27, 21) == mv and not lib.chestAt(sc, 26, 20)
        and mv.chest.x == 27 and mv.chest.y == 21 and mv.chest.items[1].x == 27 and mv.chest.items[1].y == 21)
    for i, c in ipairs(sc.items) do if c == mv then table.remove(sc.items, i) break end end

    -- 4c. a mod item ("modid:name") has no item number for the file: refused on a free cell and in a chest that is there,
    -- and the writer stops with an error that names it (not a bare type error from the i16)
    local itemsBefore = #sc.items
    ---@type any
    local modItem = "t_mod:sword"
    local m1, whyM1 = lib.placeChest(sc, 30, 20, "item", modItem)
    local m2, whyM2 = lib.placeChest(sc, 22, 20, "item", modItem)
    local bad = lib.newChest(31, 20, "item", 1)
    bad.chest.items[1].index = modItem
    local wrote, werr = pcall(scnwrite.chunk.item, bad)
    check("editor chests: a mod item is refused for a chest (the scenario holds item numbers), the writer names it",
        not m1 and whyM1 == "moditem" and not m2 and whyM2 == "moditem" and #sc.items == itemsBefore and it.chest.count == 3
        and not lib.chestItemId("t_mod:sword") and lib.chestItemId(itemNo(3)) and not wrote
        and tostring(werr):find("t_mod:sword", 1, true) ~= nil)

    -- 5. save and read back
    local data = scnwrite.write(sc)
    local back = assert(scn.parse(data))
    ---@generic T
    ---@param list T[]
    ---@param pred fun(o: T): any
    ---@return T?
    local function find(list, pred) for _, o in ipairs(list) do if pred(o) then return o end end end
    local a = find(back.armies, function(o) return o.name == "Bob" end)
    local b = find(back.buildings, function(o) return o.name == "Fort" end)
    check("editor object: saved army", a and a.code == grunt.code and a.tag == "boss1" and a.level == 3 and a.xp == 20
        and a.side == 1 and a.owner == 1 and a.character and a.behaviour == 4 and a.script == "ambush" and a.combat == 99
        and not a.useDefault and a.globalIndex == grunt.globalIndex)
    check("editor object: saved building", b and b.side == 0 and b.character and b.globalIndex == hall.globalIndex
        and b.useDefault and b.curHits == hall.curHits)
    local o = back.header.options
    check("editor options: saved", o.techLevel == 3 and o.techLocked and o.armySetupPoints == 33 and o.pointsLocked
        and o.hiddenLocked and o.handicapping and o.mods.noDragons and not o.mods.noFliers and o.modLocks.toughTowers
        and not o.modLocks.noDragons)
    check("editor sides: saved", back.sides[1].raceLocked and back.sides[1].mustBeHuman and back.sides[1].team == 4
        and back.sides[1].resources == 3 and back.sides[2].used and back.sides[2].mustBeOn and back.ai[2].file == "G_Reckless.ai"
        and back.sides[2].aiFile == "G_Reckless.ai" and back.ai[0].file == (sc.ai[0].file))
    local nr, ni, nres = 0, 0, 0
    for _, c in ipairs(back.items) do
        if c.chest.resource then nres = nres + 1 elseif c.chest.count == 3 then ni = ni + 1 elseif c.chest.items[1].index == -2 then nr = nr + 1 end
    end
    check("editor chests: saved", nres == 1 and ni == 1 and nr == before + 1 and #back.items == #sc.items)
    check("editor: the saved scenario is byte for byte stable", scnwrite.write(back) == data)

    -- 6. the saved scenario in a battle
    local w = require("src.game.world").new(back, { player = 0 })
    local bob
    for _, u in ipairs(w.units) do if u.name == "Bob" then bob = u end end
    local nchest = #w.chests
    check("editor battle: the army keeps its owner, name and level", bob and bob.side == 1 and bob.level == 3 and bob.xp == 20)
    local fort
    for _, bl in ipairs(w.buildings) do if bl.name == "Fort" then fort = bl end end
    check("editor battle: the building keeps its name and owner", fort and fort.side == 0)
    local gold0 = w.sides[0].crystal or 0
    local resChest
    for _, c in ipairs(w.chests) do if c.resource then resChest = c end end
    local itemChest
    for _, c in ipairs(w.chests) do if c.items and #c.items == 3 then itemChest = c end end
    check("editor battle: the chests are on the map (one chest of 3 items, a resource chest, the random one)",
        resChest and resChest.resource == "crystal" and itemChest and nchest == before + 1 + 1 + 1)
    local picker = { gx = 24, gy = 20, side = 0 }       -- a hero stand-in: collectItems reads its cell and side
    ---@cast picker Unit
    w:collectItems(picker)
    check("editor battle: a resource chest gives 500 to the hero's side",
        (w.sides[0].crystal or 0) == gold0 + 500 and #w.chests == nchest - 1)
    check("editor battle: the side's AI script comes with the scenario", w.sides[2].aiFile == "G_Reckless.ai")

    -- 6b. the random map of the editor (Ctrl+R): tiles and features only, six sides on without starts, standard victory event
    do
        local rs = lib.randomScenario("Rnd", 64, "d", 1234)
        local rb = assert(scn.parse(scnwrite.write(rs)))
        local nused, nstart = 0, 0
        for i = 0, 5 do
            if rb.sides[i].used then nused = nused + 1 end
            if rb.sides[i].startX >= 0 then nstart = nstart + 1 end
        end
        check("editor random map: a 64 map with no objects, six sides on, no starts, the victory event",
            rb.width == 64 and #rb.tiles + 1 > 0 and nused == 6 and nstart == 0 and #rb.buildings == 0 and #rb.armies == 0
            and #rb.items == 0 and #lib.userEvents(rb) == 0 and rb.events[1] and rb.events[1].cond.condition == 10)
        local w = require("src.game.world").new(rb, { player = 0 })
        check("editor random map: the saved map loads in a battle", w.w == 64 and w.h == 64)
        local r2 = lib.randomScenario("Rnd", 64, "d", 1234)
        check("editor random map: the same seed gives the same map", scnwrite.write(r2) == scnwrite.write(rs))
        local r3 = lib.randomScenario("Rnd", 96, "d", 77)
        check("editor random map: sizes outside the original's four work too", r3.width == 96 and r3.tilesW == 10)
    end

    -- 7. a new scenario
    local ns = lib.newScenario("T", 64, "")
    local nb = assert(scn.parse(scnwrite.write(ns)))
    check("editor: a new scenario has the original's defaults", nb.header.options.hiddenMap and nb.header.options.quests
        and nb.header.options.techLevel == 5 and nb.header.options.fog == 1 and nb.ai[0].file == "" and nb.ai[0].race == -1
        and not nb.sides[0].raceLocked and #nb.items == 0)
end

return M
