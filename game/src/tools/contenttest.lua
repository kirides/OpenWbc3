-- Headless checks of the content registry (docs/data-driven/01-content-registry.md 1.8): patch operators, keyed lists,
-- removal cascade, phases, provenance, hash stability, dump round trip, rollback. `run(check)` is called from
-- selftest.lua. The tests use their own registries (`registry.new()`), never the game's.
local registry = require("src.content.registry")
local patch = require("src.content.patch")
local hashlib = require("src.content.hash")
local dump = require("src.content.dump")

local M = {}

-- A small registry with a "thing" kind that references a "part" kind.
---@return ContentRegistry
local function sample()
    local R = registry.new()
    R.defineKind({ name = "part", sortBy = "sort" })
    R.defineKind({
        name = "thing", derived = { "partRef" },
        refs = { { field = "parts", target = "part", mode = "list" },
                 { field = "main", target = "part", mode = "id", hard = true },
                 { field = "by.*", target = "part", mode = "list" },
                 { field = "stock", target = "part", mode = "keys" } },
        validate = function(rec) if rec.cost and rec.cost < 0 then return "negative cost" end end,
        derive = function(rec, kind) rec.partRef = rec.main and kind._R.part[rec.main] end,
    })
    R.begin()
    R.setLayer("base")
    for i, id in ipairs({ "A", "B", "C", "D" }) do R.part:add({ id = id, sort = 10 - i, weight = i }) end
    R.thing:add({ id = "T1", cost = 5, main = "A", parts = { { id = "A", level = 1 }, { id = "B", level = 2 }, { id = "C", level = 3 } },
                  tags = { "x", "y", "z" }, stats = { hp = 10, armour = { base = 1, step = 2 } },
                  by = { human = { { id = "A" }, { id = "D" } } }, stock = { A = 1, D = 2 } })
    return R
end

-- True when `fn` raises an error (one matching `pattern` when given); the error as the second value.
---@param fn function
---@param pattern string?
---@return boolean
---@return any err
local function throws(fn, pattern)
    local ok, err = pcall(fn)
    if ok then return false end
    return pattern == nil or tostring(err):find(pattern) ~= nil, err
end

---@param check fun(name: string, ok: any) the selftest's check: logs ok / FAIL and counts the failures
function M.run(check)
    -- records, aliases, ordering ----------------------------------------------------------------------------------
    do
        local R = sample()
        check("content: records are plain tables found by id", R.part["A"] and R.part:get("B").weight == 2 and R.part:has("C"))
        check("content: all() is in insertion order, ids() matches",
            #R.part:all() == 4 and R.part:all()[1].id == "A" and table.concat(R.part:ids(), "") == "ABCD")
        check("content: require reports the missing id and who needed it",
            throws(function() R.part:require("Q", "thing T1") end, "part 'Q' is not defined %(needed by thing T1%)"))
        check("content: adding an existing id is an error that names the origin",
            throws(function() R.part:add({ id = "A" }) end, "already exists %(base%)"))
        check("content: a record needs a string id", throws(function() R.part:add({}) end, "has no id"))
        R.part:alias("Alpha", "A")
        check("content: an alias is a second key for the same record", R.part["Alpha"] == R.part["A"] and #R.part:all() == 4)
        local n = 0
        for _, rec in R.part:each(function(r) return r.weight % 2 == 0 end) do n = n + rec.weight end
        check("content: each(pred) visits the matching records in order", n == 6)
        check("content: kind names must not collide with the API", throws(function() R.defineKind({ name = "patch" }) end)
            or throws(function() R.defineKind({ name = "begin" }) end, "collides"))
    end

    do
        -- registries are independent: the kind methods of one do not touch the state of another
        local A, B = sample(), sample()
        A.finalise()
        local ok = throws(function() B.part:add({ id = "Z" }) end) == false
        B.setLayer("mod:other")
        A.setLayer("mod:first")
        check("content: two registries do not share state", ok and A.layer() == "mod:first" and B.layer() == "mod:other"
            and A.frozen() and not B.frozen() and A.part["A"] ~= B.part["A"])
    end

    -- patch semantics ---------------------------------------------------------------------------------------------
    do
        local R = sample()
        R.thing:patch("T1", { cost = 7, stats = { hp = 20, armour = { step = 3 } } })
        local t = R.thing["T1"]
        check("content: patch replaces scalars and merges maps field by field",
            t.cost == 7 and t.stats.hp == 20 and t.stats.armour.step == 3 and t.stats.armour.base == 1)
        R.thing:patch("T1", { tags = { "q" } })
        check("content: a plain array in a patch replaces the whole array", #t.tags == 1 and t.tags[1] == "q")
        R.thing:patch("T1", { tags = { append = { "r", "s" } } })
        R.thing:patch("T1", { tags = { prepend = { "p" } } })
        check("content: append / prepend", table.concat(t.tags, "") == "pqrs")
        R.thing:patch("T1", { tags = { remove = { "q", "s" } } })
        check("content: remove drops listed values", table.concat(t.tags, "") == "pr")
        R.thing:patch("T1", { tags = { insertAfter = { match = "p", value = "m" } } })
        R.thing:patch("T1", { tags = { insertBefore = { match = "p", value = "o" } } })
        check("content: insertAfter / insertBefore are relative to a match", table.concat(t.tags, "") == "opmr")
        R.thing:patch("T1", { tags = { replace = { "z" } } })
        check("content: replace swaps the list", #t.tags == 1 and t.tags[1] == "z")
        R.thing:patch("T1", { parts = { remove = { "B" }, append = { { id = "D", level = 4 } } } })
        local ids = {}
        for _, p in ipairs(t.parts) do ids[#ids + 1] = p.id end
        check("content: keyed lists are addressed by element id, several operators in one patch",
            table.concat(ids, "") == "ACD" and t.parts[3].level == 4)
        R.thing:patch("T1", { parts = { insertAfter = { match = "A", value = { id = "B", level = 9 } } } })
        check("content: insertAfter with a keyed record", t.parts[2].id == "B" and t.parts[2].level == 9)
        check("content: an unmatched insert is an error naming the path",
            throws(function() R.thing:patch("T1", { parts = { insertAfter = { match = "Q", value = "x" } } }) end, "no element matches"))
        R.thing:patch("T1", { cost = R.REMOVE, stats = { hp = function(old) return old * 2 end } })
        check("content: REMOVE deletes a field, a function value computes from the old one", t.cost == nil and t.stats.hp == 40)
        local hook = function() return 1 end
        R.thing:patch("T1", { hook = R.value(hook) })
        check("content: value() assigns a function literally", t.hook == hook)
        R.thing:patch("T1", function(rec) rec.touched = true end)
        check("content: a function patch mutates in place", t.touched == true)
        check("content: a patch cannot change the id", throws(function() R.thing:patch("T1", { id = "T2" }) end, "cannot change the id"))
        check("content: patching an unknown id is an error", throws(function() R.thing:patch("nope", {}) end, "not defined"))
        check("content: a list operator on a map is an error",
            throws(function() R.thing:patch("T1", { stats = { append = { 1 } } }) end, "not a list"))
        local c = R.part:patch(function(r) return r.weight > 2 end, { heavy = true })
        check("content: patch(pred) visits every matching record", c == 2 and R.part["C"].heavy and R.part["D"].heavy and not R.part["A"].heavy)
        local copy = R.clone(t)
        copy.stats.hp = 1
        check("content: patch tables are copied in, clone() is deep", t.stats.hp == 40)
        local list = { "a", "b", "c" }
        patch.append(list, "d")
        patch.insertBefore(list, "a", "0")
        check("content: the list helpers work on plain arrays", table.concat(list, "") == "0abcd" and patch.removeWhere(list, function(v) return v > "b" end) == 2)
    end

    -- phases, removal, finalise -----------------------------------------------------------------------------------
    do
        local R = sample()
        R.phase("patch")
        check("content: phases only move forward", throws(function() R.phase("define") end, "cannot go back"))
        R.part:remove("B")
        check("content: remove drops the record", R.part["B"] == nil and #R.part:all() == 3)
        R.part:remove("A")
        R.part:remove("D")
        local rep = R.finalise()
        local t = R.thing["T1"]
        check("content: removal cascades into keyed lists, id maps and keyed-by-id tables",
            #t.parts == 1 and t.parts[1].id == "C" and #t.by.human == 0 and t.stock.A == nil and t.stock.D == nil)
        local hard
        for _, e in ipairs(rep.errors) do if e.msg:find("main refers to part 'A', which was removed") then hard = true end end
        check("content: a hard reference to a removed id is an error naming the referrer", hard == true)
        local warned = 0
        for _, w in ipairs(rep.warnings) do if w.msg:find("loses") then warned = warned + 1 end end
        check("content: each dropped list entry is a warning", warned >= 4)
        check("content: derived fields are computed at finalise and the registry is frozen", t.partRef == nil and R.frozen())
        check("content: writing after finalise is an error", throws(function() R.part:add({ id = "Z" }) end, "frozen"))
    end
    do
        local R = sample()
        R.thing:add({ id = "T2", cost = -3, main = "A", parts = {}, by = {}, stock = {} })
        R.thing:add({ id = "T3", main = "ghost", parts = { { id = "C" }, { id = "nope" } }, by = {}, stock = {} })
        R.part:patch("A", { sort = 100 })
        local rep = R.finalise()
        local neg, ghost = false, false
        for _, e in ipairs(rep.errors) do
            if e.msg:find("T2") and e.msg:find("negative cost") then neg = true end
            if e.msg:find("T3") and e.msg:find("unknown part 'ghost'") then ghost = true end
        end
        check("content: validators run per record, dangling references are errors in the base layer", neg and ghost)
        check("content: sortBy stable-sorts a kind at finalise (nil sort last)", table.concat(R.part:ids(), "") == "DCBA")
        check("content: derive sees the final records", R.thing["T1"].partRef == R.part["A"])
    end

    -- provenance --------------------------------------------------------------------------------------------------
    do
        local R = sample()
        R.setLayer("mod:orcs")
        R.thing:add({ id = "T9", main = "A", parts = {}, by = {}, stock = {} })
        R.thing:patch("T1", { cost = 1 })
        local where = R.where("thing", "T9")
        check("content: records remember layer, file and line", where:find("^mod:orcs ") and where:find("contenttest.lua:%d+"))
        check("content: the patch trail names the layer", R.where("thing", "T1"):find("patched by mod:orcs"))
        local ok, err = pcall(function() R.part:add({ id = "A" }) end)
        check("content: an error from mod code points at the mod's line", not ok and tostring(err):find("contenttest.lua:%d+"))
        R.setLayer("mod:orcs")
        R.thing:add({ id = "T8", main = "ghost", parts = {}, by = {}, stock = {} })
        local rep = R.finalise()
        local named
        for _, e in ipairs(rep.errors) do if e.msg:find("T8") and e.msg:find("mod:orcs") then named = true end end
        check("content: finalise errors name the mod and the line of the record", named)
    end

    -- hash --------------------------------------------------------------------------------------------------------
    do
        local function build(reverseKeys)
            local R = sample()
            if reverseKeys then
                R.thing:patch("T1", function(rec)
                    local copy = {}
                    local keys = {}
                    for k in pairs(rec) do keys[#keys + 1] = k end
                    table.sort(keys, function(a, b) return a > b end)
                    for _, k in ipairs(keys) do copy[k] = rec[k] end
                    for k in pairs(rec) do rec[k] = nil end
                    for _, k in ipairs(keys) do rec[k] = copy[k] end
                end)
            end
            R.finalise()
            return R
        end
        local a, b = build(false), build(true)
        check("content: the hash is stable for the same content", a.hash() == build(false).hash() and #a.hash() == 32)
        check("content: the hash ignores key order", a.hash() == b.hash())
        local c = sample()
        c.part:patch("A", { weight = 99 })
        c.finalise()
        check("content: changing one value changes the hash", c.hash() ~= a.hash())
        local d = sample()
        d.part:remove("D")
        d.finalise()
        check("content: removing a record changes the hash", d.hash() ~= a.hash())
        check("content: provenance and derived fields are not hashed",
            (function()
                local e = sample()
                e.setLayer("mod:x")
                e.part:patch("A", { weight = 1 })      -- same value as before: only the trail differs
                e.finalise()
                return e.hash() == a.hash()
            end)())
        check("content: verify() detects a mutation behind the API's back",
            (function()
                local e = sample()
                e.finalise()
                e.hash()
                local before = e.verify()
                local recA = e.part["A"] --[[@as table]]
                recA.weight = 123
                return before and not e.verify()
            end)())
        local function plusOne() return 1 end
        local function plusTwo() return 2 end
        local function factory(kind) return function() return kind end end
        check("content: functions hash by their source lines and plain upvalues",
            hashlib.canonical({ f = plusOne }) ~= hashlib.canonical({ f = plusTwo })
            and hashlib.canonical({ f = plusOne }) == hashlib.canonical({ f = plusOne })
            and hashlib.canonical({ f = factory("a") }) ~= hashlib.canonical({ f = factory("b") })
            and hashlib.canonical({ f = factory("a") }) == hashlib.canonical({ f = factory("a") })
            and hashlib.canonical({ n = 0.1 }) == hashlib.canonical({ n = 0.1 }))
        check("content: numbers serialise exactly", hashlib.number(3) == "3" and hashlib.number(0.1) == "0.10000000000000001")
    end

    -- dump round trip ---------------------------------------------------------------------------------------------
    do
        local R = sample()
        R.finalise()
        local text = R.dump("thing")
        local chunk = loadstring(text)
        local back = chunk and chunk()
        local function same(a, b)
            if type(a) ~= type(b) then return false end
            if type(a) ~= "table" then return a == b end
            for k, v in pairs(a) do
                if type(k) == "string" and k:sub(1, 1) ~= "_" and k ~= "partRef" and not same(v, b[k]) then return false end
                if type(k) == "number" and not same(v, b[k]) then return false end
            end
            for k in pairs(b) do if a[k] == nil then return false end end
            return true
        end
        local rec = back and back[1]
        local expect = R.clone(R.thing["T1"])
        expect.partRef = nil
        check("content: a dump loads back into equal records", rec ~= nil and same(expect, rec) and #back == 1)
        check("content: the dump is readable sorted Lua with the install header",
            text:find("^%-%- openwbc3 content dump") and text:find("armour = {") and text:find("hp = 10") and not text:find("partRef"))
        check("content: dumping is deterministic", R.dump("thing") == text and dump.value({ b = 1, a = { 1, 2 } }) == "{\n    a = { 1, 2 },\n    b = 1,\n}")
    end

    -- rollback of a failing layer ---------------------------------------------------------------------------------
    do
        local R = sample()
        local before = hashlib.registry(R.kinds(), R.sources)
        local snap = R.snapshot()
        R.setLayer("mod:bad")
        R.part:add({ id = "Z", weight = 1 })
        R.part:patch("A", { weight = 50 })
        R.thing:remove("T1")
        R.restore(snap)
        check("content: a snapshot restores the registry exactly (hash equal)",
            hashlib.registry(R.kinds(), R.sources) == before and R.part["Z"] == nil and R.part["A"].weight == 1 and R.thing["T1"] ~= nil)
        check("content: restored records keep one identity per id", R.part["A"] == R.part:all()[1] and R.thing["T1"] == R.thing:all()[1])
    end

    -- the game's own registry --------------------------------------------------------------------------------------
    do
        local content = require("src.content")
        local loader = require("src.content.loader")
        local rep = loader.setup()
        check("content: the game registry builds without errors", #rep.errors == 0)
        check("content: the kinds of the engine exist and unplanned ones do not",
            content.hasKind("unit") and content.hasKind("spell") and content.hasKind("setting") and content.hasKind("lair")
            and content.hasKind("aiprofile") and not content.hasKind("text"))
        check("content: the game registry is frozen and has a hash", content.frozen() and #content.hash() == 32 and content.verify())
        check("content: order of kinds is fixed", content.kinds()[1].name == "setting")

        -- the typed Army.cfg / Building.cfg fields of the original data
        local rules, gamedata = require("src.game.rules"), require("src.game.gamedata")
        check("content: the install's units, buildings and power-ups are records (counts)",
            content.race:count() == 16 and content.unit:count() > 150 and content.building:count() > 200 and content.powerup:count() > 200)
        local rawStatus, unknown = 0, 0
        for _, u in ipairs(content.unit:all()) do
            if u.rawStatus then rawStatus = rawStatus + 1 end
            if not u.missingStats and u.id ~= u.fileId and u.fileId then unknown = unknown + 1 end
        end
        check("content: every Army.cfg status string is rebuilt exactly from the typed fields", rawStatus == 0)
        check("content: a peasant is a medium good land infantry unit of the Knights",
            content.unit["AHBX"].size == "medium" and content.unit["AHBX"].alignment == "good"
            and content.unit["AHBX"].moveClass == "land" and content.unit["AHBX"].infantry and content.unit["AHBX"].races.human
            and content.unit["AHBX"].legacyStatus == "MGH-LI--")
        check("content: gamedata and rules read the records", gamedata.army("AHBX") == content.unit["AHBX"]
            and gamedata.building("BKK0") == content.building["BKK0"] and rules.armyInfo("ahbx").status == "MGH-LI--"
            and rules.buildList(0)[1].id == "BKK0" and rules.produces(0, "BKK0")[1].id ~= nil)
        check("content: the race letter and number lookups agree", content.race:bySlot(5).id == "orc"
            and content.race:byLetter("O").slot == 5 and rules.RACE_LETTER[11] == "V")
        check("content: requirements, priority and per-race overrides sit on the record",
            #rules.requirements(0, "AHMX") > 0 and rules.priority(0, "AHMX") == 50 and rules.override(10, "PIB0") ~= nil
            and content.powerup["PIB0"].byRace.darkdwarf.gold == 200)

        -- a mod patches the registry; the engine's accessors see it, a failing mod is dropped without a trace
        -- Rebuilds the registry with these mods (manifest-less definitions) and returns the report.
        ---@param mods table[]?
        local function rebuild(mods)
            loader.mods = mods
            return loader.setup(true)
        end
        local base = content.hash()
        local rep2 = rebuild({
            { id = "tweaks",
              define = function(c)
                  local clone = c.clone(c.unit["AHAX"] or c.unit["AHBX"])
                  clone.id, clone.label = "tweaks:footman", "Footman"
                  clone.cost.gold = 77
                  c.unit:add(clone)
              end,
              patch = function(c)
                  c.unit:patch("AHBX", { hits = 99 })
                  c.building:patch(function(b) return b.produces ~= nil end, function(b)
                      for _, list in c.pairs(b.produces) do c.removeWhere(list, "PAC0") end
                  end)
                  c.building:patch("BKK0", { produces = { human = { append = { { id = "tweaks:footman", level = "0" } } } } })
              end } })
        check("content: a mod's patch is seen through gamedata", gamedata.army("AHBX").hits == 99 and rep2.errors[1] == nil)
        check("content: a mod unit is a record the editor lists and the rules know",
            gamedata.army("tweaks:footman").cost.gold == 77 and rules.armyInfo("tweaks:footman").name == "Footman"
            and (function() for _, e in ipairs(rules.armyList()) do if e.code == "tweaks:footman" then return true end end end)())
        check("content: keyed list operators reach the production lists",
            rules.produces(0, "BKK0")[#rules.produces(0, "BKK0")].id == "tweaks:footman"
            and (function() for _, b in ipairs(content.building:all()) do
                for _, list in pairs(b.produces or {}) do for _, e in ipairs(list) do if e.id == "PAC0" then return false end end end
            end return true end)())
        check("content: a mod changes the hash and the hash is stable", content.hash() ~= base and content.verify())
        local rep3 = rebuild({
            { id = "good", patch = function(c) c.unit:patch("AHBX", { hits = 55 }) end },
            { id = "bad", define = function(c) c.unit:patch("AHBX", { hits = 1 }) end,
              patch = function(c) error("boom") end },
        })
        local named
        for _, e in ipairs(rep3.errors) do if e.layer == "mod:bad" and e.text:find("boom") then named = true end end
        check("content: a failing mod is dropped as a whole and named in the report; the other mod still applies",
            named and gamedata.army("AHBX").hits == 55)
        -- tags: the data form of the engine's code sets; a mod gives a tag and the rules follow
        check("content: tags come from lists and from typed fields",
            gamedata.hasTag("AADR", "dragon") and gamedata.hasTag("ACSH", "critter") and gamedata.hasTag("AUIX", "undead")
            and gamedata.hasTag("AVBX", "daemonClass") and gamedata.hasTag("ATHX", "titan") and gamedata.hasTag("BTCE", "temple")
            and gamedata.hasTag("AADR", "flyer") and not gamedata.hasTag("AHBX", "critter") and not gamedata.hasTag("XXXX", "critter"))
        local unitMod = require("src.game.unit")
        local before = unitMod.isCritter("AHBX")
        local rep5 = rebuild({ { id = "wild",
            patch = function(c) c.unit:patch("AHBX", { tags = { append = { "critter" } } }) end },
            { id = "typo", patch = function(c) c.unit:patch("AHBX", { tags = { append = { "crittr" } } }) end } })
        local typo
        for _, e in ipairs(rep5.errors) do if e.msg:find("unknown tag 'crittr'") then typo = true end end
        check("content: a mod's tag changes what the rules see; an unknown tag is an error naming the mod",
            before == false and unitMod.isCritter("AHBX") == true and typo == true)
        rebuild({})

        -- items: the catalogue is records, the meaning of a power type is a record too
        local items = require("src.game.items")
        check("content: the item catalogue is in the registry with numeric ids, classes and tiers",
            #items.all() > 150 and items.get(1).id == 1 and type(items.get(1).name) == "string" and items.SLOTS[5] == "Ring"
            and items.slotCount(5) == 2 and items.slotCount(0) == 1 and content.setting:value("item.tiers").artifact == 4)
        rebuild({ { id = "gems",
            define = function(c)
                c.itempower:add({ id = "luck", stat = "morale", sign = 1, text = "0455" })
                c.item:add({ id = "gems:ring", name = "Ring of Luck", desc = "", row = 5, col = 0, slot = 5, value = 10, rarity = 0,
                             tier = 1, tierName = "minor", powers = { { type = "luck", data = 4 }, { type = "combat", data = 2 } } })
            end } })
        local ring = items.get("gems:ring")
        local b = items.bonuses({ [5] = ring --[[@as ItemRecord]] })
        check("content: a mod item with a string id and its own power type feeds the hero's item bonuses",
            ring ~= nil and b.morale == 4 and b.combat == 2 and #items.all() == content.item:count())
        rebuild({})

        -- spells: records with an effect function or a recipe; a mod adds a sphere with two spells, retunes one, removes one
        local fx = require("src.game.fx")
        local spells = require("src.game.spells")
        check("content: the spells are records (130 hero spells, the troops' own, 13 spheres) and the engine reads them",
            content.spell:count() == 140 and content.sphere:count() == 13 and spells.COST[4] == 15 and spells.SPHERES == 13
            and spells.targetKind(11) == "ground" and spells.defs[0].ai == "heal" and spells.SPHERE_NAMES[7] == "Runes"
            and type(content.spell["healing.0"].effect) == "table" and type(content.spell["healing.5"].effect) == "function")
        local rep6 = rebuild({ { id = "chrono",
            define = function(c)
                c.sphere:add({ id = "chrono:chronomancy", slot = 13, skill = 150, name = "Chronomancy", researchName = "Chronomancy Spell",
                               colour = { 1, 1, 1 }, icon = 12 })
                c.spell:add({ id = "chrono:haste", slot = 130, sphere = "chrono:chronomancy", index = 0, cost = 5, ai = "buff", name = "Hasten",
                              effect = { { status = { id = "speed", who = "self", seconds = { duration = "normal" },
                                                      value = { base = 2, perLevel = 1 } } } } })
                c.spell:add({ id = "chrono:rewind", slot = 131, sphere = "chrono:chronomancy", index = 1, cost = 9, name = "Rewind",
                              effect = function(ctx) fx.heal(ctx, ctx.u, 77) end })
            end,
            patch = function(c)
                c.spell:patch("healing.4", { cost = 7 })
                c.spell:remove("healing.9")
            end } })
        local w6 = require("src.game.world").new(assert(require("src.game.boot").loadScenario("Bridges")), { player = 0 })
        local hero6 = assert(w6.eco:heroAlive(0))
        hero6.h.skill[150] = 12
        hero6.h:recalc()
        hero6.h.mana, hero6.h.nextBonus = 100, 1000
        hero6.hp = hero6.maxHp - 200
        local hp0 = hero6.hp
        math.randomseed(1)      -- a cast rolls its chance: the outcome must not depend on what ran before
        local ok1 = spells.perform(hero6, 130, nil)
        hero6.recoverUntil = nil
        local ok2 = spells.perform(hero6, 131, nil)
        check("content: a mod sphere with a recipe spell and a function spell: known by its casting skill, cast, paid in mana",
            #rep6.errors == 0 and spells.SPHERES == 14 and hero6.h.spells[130] and hero6.h.spells[131] and ok1 and ok2
            and hero6.fx and hero6.fx.speed and hero6.hp == hp0 + 77 and hero6.h.mana == 100 - 5 - 9
            and spells.name(130) == "Hasten" and spells.cost(hero6, 131) == 9)
        check("content: a mod retunes a spell's cost and removes one: heroes lose it from the book",
            spells.COST[4] == 7 and content.spell["healing.9"] == nil and not hero6.h.spells[9])
        local rep7 = rebuild({ { id = "broken", define = function(c)
            c.spell:add({ id = "broken:x", slot = 140, sphere = "healing", index = 0, effect = { { frobnicate = {} } } })
        end } })
        local brokenMsg
        for _, e in ipairs(rep7.errors) do if e.text:find("no known action") then brokenMsg = true end end
        check("content: a recipe with an unknown step is an error naming the spell", brokenMsg == true)
        rebuild({})

        -- statuses, damage types, missiles: records the unit rules read
        local statusMod = require("src.game.status")
        local healthy = { fx = {} }                     -- a unit stand-in: canInfect reads only its effects
        ---@cast healthy Unit
        check("content: the statuses, damage types and missiles of the original are records",
            content.status:count() >= 25 and content.status["poison"].negative and content.damagetype["fire"].spellSlot == 1
            and content.missile["EMM1"].lightning ~= nil and content.missile["EMA0"].piercing == true and statusMod.canInfect(healthy))
        rebuild({ { id = "bleed",
            define = function(c)
                c.status:add({ id = "bleed", negative = true, tick = { every = 500, fn = function(u) u:takeDamage(3, nil) end } })
                c.status:add({ id = "shield", resist = { type = 3, pct = 50 } })
                c.missile:add({ id = "XMA0", flags = 0x82, piercing = true })
            end,
            patch = function(c) c.damagetype:patch("magic", { classes = { [7] = true } }) end } })
        do
            local w = require("src.game.world").new(assert(require("src.game.boot").loadScenario("Bridges")), { player = 0 })
            local u = assert(w:addUnit("AHBX", 1, 20, 20))
            u.maxHp, u.hp = 1000, 1000
            statusMod.add(u, "bleed", 4000)
            for t = 0, 2000, 100 do statusMod.update(u, w.time + t) end
            local bled = u.hp < 1000 and (1000 - u.hp) % 3 == 0
            statusMod.clear(u, true)
            statusMod.add(u, "shield", 4000, 50)
            check("content: a mod status ticks, is cleared as a negative effect, and a resist record reduces that damage type",
                bled and u.fx == nil or (bled and not (u.fx and u.fx.bleed)))
            local struck = { kind = "building", world = w }  -- a building stand-in: only its kind and world are read
            ---@cast struck Building
            check("content: a mod status with a resist record cuts the damage of its type; a mod missile and damage class are seen",
                statusMod.reduce(u, 3, false, 100) == 50 and statusMod.reduce(u, 1, false, 100) == 100
                and require("src.game.missiles").flagsOf("XMA0") == 0x82 and require("src.game.powerups").missileResistant(
                    struck, nil, "XMA0") == true)
        end
        rebuild({})

        -- settings and resources: engine modules read them when they load (a mod's values apply from the next start)
        check("content: the resources are records; the economy reads its numbers from settings",
            #content.resource:all() == 4 and content.resource["crystal"].letter == "C" and table.concat(content.resource:ids(), ",") == "gold,metal,crystal,stone"
            and require("src.game.economy").CONVERT_TIME == 39000 and content.setting:value("unit.stepTime")[0] == 1200)
        rebuild({ { id = "slowtime", patch = function(c)
            c.setting:patch("eco.convertTime", { value = 99000 })
            c.setting:patch("hero.maxLevel", { value = 50 })
        end } })
        local economy, heroMod = require("src.game.economy"), require("src.game.hero")
        check("content: a mod patches a rule number and the engine modules that keep it in a local see it at once",
            economy.CONVERT_TIME == 99000 and heroMod.MAX_LEVEL == 50)
        rebuild({})
        check("content: and when the mod is gone the numbers are the original's again",
            economy.CONVERT_TIME == 39000 and heroMod.MAX_LEVEL == 999)

        -- the example mods of docs/modding/examples load from their folders, in the sandbox, and do what they say
        do
            local mods, config = require("src.content.mods"), require("src.core.config")
            local examples = config.sourceDir() .. "/../docs/modding/examples"
            local function withMods(names, fn)
                local args = {}
                for _, n in ipairs(names) do args[#args + 1] = "--mod" args[#args + 1] = examples .. "/" .. n end
                mods.configure(args)
                loader.mods = nil
                local rep = loader.setup(true)
                local ok, err = pcall(fn, rep)
                mods.configure({ "--no-mods" })
                loader.mods = {}
                loader.setup(true)
                if not ok then error(err, 0) end
            end
            withMods({ "balance-patch" }, function(rep)
                check("mods: the balance patch example loads from its folder and patches units, a computed field and a setting",
                    #rep.errors == 0 and content.unit["AHBX"].hits == 40 and content.unit["AHFX"].cost.gold == 120
                    and content.unit["AHFX"].cost.metal ~= nil and content.unit["AWGX"].behaviour.conversion == nil
                    and content.unit["ADIX"].hits == (require("src.formats.types").parseArmy(
                        require("src.import.wbc3.cfg").lookup("ADIX", ".arm") --[[@as string]]).hits + 2)
                    and content.setting:value("eco.mineProduce")[0] == 2 and #mods.loaded() == 1)
                local info = mods.describe(content)
                check("mods: the loaded mods are described with a hash of their files for saves and the lobby",
                    info.mods[1].id == "balance_patch" and #info.mods[1].hash == 32 and #info.hash == 32 and info.version == mods.ENGINE_VERSION)
            end)
            local without = content.hash()
            withMods({ "new-spell", "new-unit", "new-race" }, function(rep)
                local spells = require("src.game.spells")
                check("mods: the spell, unit and race examples load together without errors",
                    #rep.errors == 0 and content.spell["new_spell:hasten"] ~= nil and content.unit["new_unit:gilded"] ~= nil
                    and content.race["new_race:goblins"] ~= nil and #mods.loaded() == 3)
                check("mods: the new unit has its alias for scenarios and sits in the stables' production list, the race is playable",
                    content.unit["MGLD"] == content.unit["new_unit:gilded"] and require("src.game.gamedata").army("MGLD").hits > 100
                    and #content.race:playable() == 17 and require("src.game.rules").produces(16, "BPSB")[1] ~= nil
                    and (function() for _, e in ipairs(require("src.game.rules").produces(0, "BPSB")) do if e.id == "new_unit:gilded" then return true end end end)())
                check("mods: the new sphere is there for the engine", spells.SPHERES == 14 and spells.COST[130] == 6 and spells.name(131) == "Mend Time")
            end)
            check("mods: after the mods the content is the original again", content.hash() == without)
        end

        -- mod folders in the save directory: order, dependencies, conflicts, manifests, the sandbox and its budget
        do
            local mods = require("src.content.mods")
            local created = {}
            mods.root = "__mods_test"                     -- a folder of its own: the player's mods are not touched
            local without = content.hash()                -- the original content (the checks run without mods)
            local function writeFile(path, text)
                love.filesystem.createDirectory(path:match("^(.*)/[^/]+$"))
                love.filesystem.write(path, text)
                created[#created + 1] = path
            end
            local function mod(folder, manifest, files)
                writeFile(mods.root .. "/" .. folder .. "/mod.lua", "return " .. manifest)
                for rel, text in pairs(files or {}) do writeFile(mods.root .. "/" .. folder .. "/" .. rel, text) end
            end
            local function cleanup()
                for i = #created, 1, -1 do
                    love.filesystem.remove(created[i])
                    local dir = created[i]:match("^(.*)/[^/]+$")
                    while dir and #love.filesystem.getDirectoryItems(dir) == 0 do
                        love.filesystem.remove(dir)
                        dir = dir:match("^(.*)/[^/]+$")
                    end
                end
                love.filesystem.remove(mods.root .. "/enabled.lua")
                love.filesystem.remove(mods.root)
                mods.root = "mods"
            end
            local function load(enabled, args)
                mods.saveEnabled(enabled)
                mods.configure(args or {})
                loader.mods = nil
                return loader.setup(true)
            end
            local ok, err = pcall(function()
                mod("__t_a", [[{ id = "t_a", version = "1.0", depends = { "t_b >= 1.2" }, after = { "t_c" } }]],
                    { ["data/a.lua"] = 'content.setting:add{ id = "t_a.order", value = "a" }' })
                mod("__t_b", [[{ id = "t_b", version = "1.5" }]], { ["data/b.lua"] = 'content.setting:add{ id = "t_b.order", value = "b" }' })
                mod("__t_c", [[{ id = "t_c", version = "0.1", conflicts = { "t_x" } }]], { ["data/c.lua"] = 'content.setting:add{ id = "t_c.order", value = "c" }' })
                mod("__t_x", [[{ id = "t_x", version = "1" }]], { ["data/x.lua"] = 'content.setting:add{ id = "t_x.order", value = "x" }' })
                mod("__t_old", [[{ id = "t_old", depends = { "t_b >= 2.0" } }]], { ["data/o.lua"] = 'content.setting:add{ id = "t_old.order", value = "o" }' })
                mod("__t_bad id", [[{ id = "Bad-ID" }]])
                load({ "t_a", "t_b", "t_c", "t_x", "t_old" })
                local order = {}
                for _, m in ipairs(mods.loaded()) do order[#order + 1] = m.id end
                local errs = table.concat(mods.errors(), " | ")
                check("mod folders: dependencies load first, ties follow the player's list, a conflict drops the later mod",
                    table.concat(order, ",") == "t_b,t_c,t_a" and errs:find("t_x' left out: it conflicts with 't_c'", 1, true))
                check("mod folders: an unsatisfied version requirement and a bad manifest are reported, never loaded",
                    errs:find("t_old' left out: needs 't_b >= 2.0'", 1, true) and content.setting["t_old.order"] == nil
                    and content.setting["t_a.order"] ~= nil and content.setting["t_x.order"] == nil)
                check("mod folders: the mod set is part of the registry hash", content.hash() ~= without)
                local plain = load({}, { "--no-mods" })
                check("mod folders: --no-mods loads nothing", content.setting["t_b.order"] == nil and #mods.loaded() == 0 and content.hash() == without)

                -- the sandbox
                local function broken(code)
                    mod("__t_s", [[{ id = "t_s" }]], { ["data/s.lua"] = code })
                    local rep = load({ "t_s" })
                    local msg
                    for _, e in ipairs(rep.errors) do if e.layer == "mod:t_s" then msg = e.msg end end
                    return msg
                end
                local function refused(code, what)
                    local msg = broken(code)
                    check("sandbox: " .. what .. " is refused and the mod is dropped as a whole", msg ~= nil and content.setting["t_s.flag"] == nil)
                end
                refused('content.setting:add{ id = "t_s.flag", value = 1 } io.open("x")', "io")
                refused('content.setting:add{ id = "t_s.flag", value = 1 } os.execute("x")', "os")
                refused('content.setting:add{ id = "t_s.flag", value = 1 } require("src.game.world")', "require")
                refused('content.setting:add{ id = "t_s.flag", value = 1 } love.filesystem.write("x", "y")', "love")
                refused('content.setting:add{ id = "t_s.flag", value = 1 } local f = ffi.new("int")', "ffi")
                refused('content.setting:add{ id = "t_s.flag", value = 1 } debug.sethook()', "debug")
                refused('content.setting:add{ id = "t_s.flag", value = 1 } loadstring("x = 1")()', "loadstring")
                refused('content.setting:add{ id = "t_s.flag", value = 1 } _G.x = 1', "_G")
                refused('content.setting:add{ id = "t_s.flag", value = 1 } getmetatable("").__index.x = 1', "getmetatable")
                refused('content.setting:add{ id = "t_s.flag", value = math.random(100) }', "math.random while loading")
                refused('content.setting:add{ id = "t_s.flag", value = 1 } content.begin()', "the registry's lifecycle")
                local t0 = os.clock()
                local msg = broken('while true do end')
                check("sandbox: an endless loop is stopped by the instruction budget", msg ~= nil and msg:find("ran longer") and os.clock() - t0 < 10)
                check("sandbox: a syntax error names the file of the mod", (broken("content.setting:add{ id = ")) and true)
                mod("__t_s", [[{ id = "t_s" }]], { ["data/s.lua"] = 'string.upper = nil math.floor = nil content.setting:add{ id = "t_s.flag", value = math.max(1, 2) }' })
                load({ "t_s" })
                check("sandbox: a mod changes copies of the libraries, not the engine's", string.upper("a") == "A" and math.floor(1.5) == 1
                    and content.setting["t_s.flag"].value == 2)
                mod("__t_s", [[{ id = "t_s" }]], { ["data/s.lua"] = 'content.setting:add{ id = "t_s.flag", value = 1, hook = function() return math.random(10) end }\ninclude("lib/more.lua")',
                                                    ["lib/more.lua"] = 'content.setting:add{ id = "t_s.more", value = mod.id }' })
                load({ "t_s" })
                check("sandbox: include runs another file of the mod in its environment; math.random works in the functions it stores",
                    content.setting["t_s.more"] and content.setting["t_s.more"].value == "t_s"
                    and content.setting["t_s.flag"].hook() >= 1)
                -- slots: a mod record asks for the next free number and keeps it, a number is never given twice
                local function raceMod(folder, id, letter)
                    mod(folder, "{ id = \"" .. id .. "\" }", { ["data/r.lua"] = "local r = content.clone(content.race[\"orc\"]) r.id, r.slot, r.letter = \""
                        .. id .. ":race\", \"auto\", \"" .. letter .. "\" content.race:add(r)" })
                end
                raceMod("__t_r1", "t_r1", "Y")
                raceMod("__t_r2", "t_r2", "X")
                raceMod("__t_r3", "t_r3", "W")
                load({ "t_r1" })
                local first = content.race["t_r1:race"] and content.race["t_r1:race"].slot
                load({ "t_r1", "t_r2" })
                local both = content.race["t_r1:race"].slot .. "," .. content.race["t_r2:race"].slot
                load({ "t_r2" })
                local alone = content.race["t_r2:race"].slot
                load({ "t_r3" })
                local third = content.race["t_r3:race"].slot
                check("slots: the first mod race gets 16, the second 17, each keeps its number, a later one never reuses 16",
                    first == 16 and both == "16,17" and alone == 17 and third == 18)
                mod("__t_sp", [[{ id = "t_sp" }]], { ["data/s.lua"] = 'content.sphere:add{ id = "t_sp:s", slot = "auto", skill = 160, name = "T", researchName = "T Spell", colour = { 1, 1, 1 }, icon = 12 }\n'
                    .. 'content.spell:add{ id = "t_sp:one", sphere = "t_sp:s", index = 3, cost = 1, effect = function(c) end }' })
                load({ "t_sp" })
                check("slots: a spell without a slot takes its sphere's slot times ten plus its index", content.sphere["t_sp:s"].slot == 13
                    and content.spell["t_sp:one"].slot == 133 and content.spell:bySlot(133) == content.spell["t_sp:one"])
                mod("__t_s", [[{ id = "t_s", scope = "cosmetic" }]], { ["data/s.lua"] = 'content.setting:add{ id = "t_s.flag", value = 1 }' })
                load({ "t_s" })
                check("mod folders: a cosmetic mod must not carry data files", content.setting["t_s.flag"] == nil)
            end)
            cleanup()
            mods.configure({ "--no-mods" })
            loader.mods = {}
            loader.setup(true)
            if not ok then error(err, 0) end
        end

        -- assets: a mod's own PNG sprite set (generated here, no original art), its override/ folder and the placeholder
        do
            local mods = require("src.content.mods")
            local assets, anims, vfs = require("src.assets"), require("src.gfx.anims"), require("src.vfs.vfs")
            local created = {}
            mods.root = "__mods_test"
            local without = content.hash()
            local function writeFile(path, data)
                love.filesystem.createDirectory(path:match("^(.*)/[^/]+$"))
                love.filesystem.write(path, data)
                created[#created + 1] = path
            end
            local function png(w, h, shade)
                local img = love.image.newImageData(w, h)
                for y = 0, h - 1 do
                    for x = 0, w - 1 do img:setPixel(x, y, shade, 0.5, 0.2, 1) end
                end
                return img:encode("png"):getString()
            end
            local root = mods.root .. "/__t_art"
            local ok, err = pcall(function()
                writeFile(root .. "/mod.lua", "return { id = 't_art', version = '1.0' }")
                writeFile(root .. "/data/u.lua", [[
                    for _, def in ipairs({ { "png", "MTAP", asset.sprite("gfx/knight") }, { "gone", "MTAG", asset.sprite("gfx/nothere") },
                                           { "orig", "MTAO", "AHBX" }, { "none", "MTAN", nil } }) do
                        local u = content.clone(content.unit["AHFX"])
                        u.id, u.sprite = "t_art:" .. def[1], def[3]
                        content.unit:add(u)
                        content.unit:alias(def[2], u.id)
                    end ]])
                writeFile(root .. "/gfx/knight/anim.lua", "return { size = { w = 16, h = 20 }, origin = { 8, 18 }, dirs = 5, "
                    .. "frames = { stand = 1, walk = 2 }, selection = { 8, 18, 9 } }")
                writeFile(root .. "/gfx/knight/stand.png", png(16, 5 * 20, 0.9))
                writeFile(root .. "/gfx/knight/walk.png", png(32, 5 * 20, 0.3))
                writeFile(root .. "/override/Zz_override.txt", "from the mod")
                mods.saveEnabled({ "t_art" })
                mods.configure({})
                loader.mods = nil
                local rep = loader.setup(true)
                check("assets: a mod with art loads without errors and its folder is mounted", #rep.errors == 0 and #assets.mounts() == 1)
                local set = anims.get("MTAP") --[[@as PngSet?]]
                -- the decoded sheet of an animation the mod has (a missing one fails the check with an error)
                ---@param s PngSet
                ---@param anim integer
                ---@return love.ImageData
                local function sheet(s, anim) return s:data(anim) --[[@as love.ImageData]] end
                check("assets: a unit with a PNG sprite set gets it: sizes, origin, frames from anim.lua, sheets expanded to eight directions",
                    set and set.code == "t_art:png" and set:frames(0) == 1 and set:frames(1) == 2 and not set:has(2)
                    and set:has(0) and set:has(1) and set:pickRect(0) == 8 and select(3, set:pickRect(0)) == 16
                    and sheet(set, 1):getWidth() == 32 and sheet(set, 1):getHeight() == 8 * 20)
                ---@cast set -nil
                local si = set.info[0]
                check("assets: anim.lua's selection fills the .ani record's selOriginX / selOriginY / selSize read by the battle screen",
                    si.selOriginX == 8 and si.selOriginY == 18 and si.selSize == 9)
                local r, g = sheet(set, 0):getPixel(3, 7 * 20 + 4)          -- direction 7 is the mirror of direction 1
                check("assets: a five direction sheet is mirrored for the west half", math.abs(r - 0.9) < 0.02 and math.abs(g - 0.5) < 0.02)
                local orig = anims.get("MTAO")
                check("assets: a unit whose sprite names an install set uses it", orig and orig.code == "AHBX" and orig:has(0))
                local placeholder = require("src.gfx.pngset").placeholder()
                check("assets: a missing PNG folder and a record without a sprite get the placeholder, and still can be spawned",
                    anims.get("MTAG") == placeholder and anims.get("MTAN") == placeholder and placeholder:has(0)
                    and anims.get("QQQQ") == nil)
                check("assets: override/ replaces an entry of the install for every lookup",
                    vfs.find("Zz_override.txt") == "from the mod" and vfs.exists("zz_override.txt") and vfs.find("Zz_missing.txt") == nil)
            end)
            mods.configure({ "--no-mods" })
            loader.mods = {}
            loader.setup(true)
            for i = #created, 1, -1 do
                love.filesystem.remove(created[i])
                local dir = created[i]:match("^(.*)/[^/]+$")
                while dir and #love.filesystem.getDirectoryItems(dir) == 0 do
                    love.filesystem.remove(dir)
                    dir = dir:match("^(.*)/[^/]+$")
                end
            end
            love.filesystem.remove(mods.root .. "/enabled.lua")
            love.filesystem.remove(mods.root)
            mods.root = "mods"
            check("assets: without the mod there is no mount and no override", #assets.mounts() == 0 and vfs.find("Zz_override.txt") == nil
                and anims.get("MTAP") == nil and content.hash() == without)
            if not ok then error(err, 0) end
        end

        -- saves and the lobby compare the content: the same mods and files, or a clear refusal
        do
            local mods = require("src.content.mods")
            local mine = mods.describe(content)
            local savegame = require("src.game.savegame")
            local ok1 = mods.compare(mine, content)
            local ok2, why = mods.compare({ hash = "0", version = "x", mods = { { id = "orc_tweaks", version = "1.2", scope = "gameplay" } } }, content)
            local ok3, why3 = mods.compare(nil, content)
            ---@cast why string
            check("content check: the same description matches, another mod set is named in the message",
                ok1 == true and ok2 == false and why:find("orc_tweaks 1.2", 1, true) and why:find("no mods", 1, true) and ok3 == false)
            check("saves: a save of the loaded content fits, one of another mod set does not, an old one fits when no mods are loaded",
                savegame.fits({ content = mine }) == true and savegame.fits({ content = { hash = "1", mods = { { id = "x", version = "2", scope = "gameplay" } } } }) == false
                and savegame.fits({}) == true)
            local sent = {}
            local fake = { count = function() return 0 end, usedSides = function() return 2 end, busy = function() return false end }
            require("src.screens.mphost").join(fake, { send = function(_, m) sent[#sent + 1] = m end },
                { version = require("src.game.net").VERSION, content = { hash = "1", version = "x", mods = { { id = "x", version = "2", scope = "gameplay" } } } })
            check("lobby: a client with other content is refused with the difference named",
                sent[1] and sent[1].t == "refused" and sent[1].reason:find("Different content", 1, true) and sent[1].reason:find("x 2", 1, true))
        end

        -- a 17th race: every loop and lookup of the engine must cope with it, a computer side of that race plays a battle
        local rep4 = rebuild({
            { id = "goblins",
              define = function(c)
                  local race = c.clone(c.race["orc"])
                  race.id, race.slot, race.letter, race.name, race.plural, race.nameLine = "goblins:goblin", 16, "Z", "Goblin", "Goblins", nil
                  race.word = "goblin"
                  c.race:add(race)
              end,
              patch = function(c)
                  c.unit:patch(function(u) return u.races.orc end, function(u) u.races["goblins:goblin"] = true end)
                  c.building:patch(function(b) return b.races.orc end, function(b) b.races["goblins:goblin"] = true end)
                  c.building:patch(function(b) return b.produces and b.produces.orc end, function(b)
                      b.produces["goblins:goblin"] = c.clone(b.produces.orc)
                  end)
              end } })
        local rules = require("src.game.rules")
        check("content: a mod race gets slot 16 and the engine's lookups find it",
            #rep4.errors == 0 and content.race:bySlot(16).id == "goblins:goblin" and rules.RACE_LETTER[16] == "Z"
            and require("src.game.economy").HERO[16] == "AOHX" and #content.race:playable() == 17
            and rules.buildList(16)[1].id == rules.buildList(5)[1].id and #rules.produces(16, rules.buildList(16)[1].id) > 0
            and #rules.raceSets(16).buildings > 0 and require("src.game.classes").raceSlots()[17] == 16)
        do
            local boot, worldMod = require("src.game.boot"), require("src.game.world")
            local scn = assert(boot.loadScenario("Bridges"))
            scn.sides[1].race = 16
            local w = worldMod.new(scn, { player = 0 })
            w.ai = require("src.game.ai").new(w)
            for _ = 1, 30 * 40 do w:update(1 / 30) end
            local mine = 0
            for _, u in ipairs(w.units) do if u.side == 1 and u:alive() then mine = mine + 1 end end
            check("content: a computer side of a mod race plays a battle", mine > 0 and w.sides[1].race == 16)
        end
        -- a mod adds a lair: the record names the breed, the building that has it gets the production list, a missing building is an error
        do
            local repL = rebuild({ { id = "nest",
                define = function(c)
                    local b = c.clone(c.building["BLBM"])
                    b.id = "nest:den"
                    c.building:add(b)
                    c.lair:add{ id = "nest:den", min = 60000, max = 90000, boss = { unit = "AUAX", level = 5 },
                                spawns = { { troops = 2, troop = "AOSX", level = 1, leaders = 1, leader = "AOKX", leaderLevel = 3 } } }
                end } })
            local ids = {}
            for _, e in ipairs(require("src.game.rules").produces(0, "nest:den")) do ids[e.id] = true end
            check("content: a mod lair is a record, its breed is the building's production list",
                #repL.errors == 0 and content.lair["nest:den"].spawns[1].leader == "AOKX" and ids["AOSX"] and ids["AOKX"] and not ids["AUIX"]
                and require("src.game.sites").isLair("nest:den") and content.lair["BLBM"].spawns[3].leader == "AUKX")
            local repM = rebuild({ { id = "nest", define = function(c)
                c.lair:add{ id = "nest:none", min = 1, max = 2, boss = { unit = "AUAX", level = 1 }, spawns = { { troops = 1, troop = "AUAX", level = 1 } } }
            end } })
            check("content: a lair without a building is reported", #repM.errors == 1 and repM.errors[1].text:find("no building of that code", 1, true))
        end
        -- a mod adds an attitude: a rule set the interface lists, units can take, and that is checked
        do
            local attitude = require("src.game.attitude")
            local repA = rebuild({ { id = "stance", define = function(c)
                c.attitude:add{ id = "stance:brave", order = 50, title = "Brave", desc = "Fights everything.", icon = 3, size = 10, rules = {
                    { priority = 100, name = "", overrides = false, conds = { { code = 0, unit = 0, area = false, result = true, extra = { 0, 0, 0 } } },
                      action = { code = 5, unit = 0, area = false, extra = { 0, 0, 0 } } } } }
            end } })
            local list = attitude.list()
            check("content: a mod attitude is listed after the nine built-in ones and has its name, description and icon",
                #repA.errors == 0 and list[10] == "stance:brave" and list[4] == "standard" and attitude.name("stance:brave") == "Brave"
                and attitude.description("stance:brave") == "Fights everything." and attitude.icon("stance:brave") == 3
                and attitude.def["stance:brave"].custom and attitude.def["stance:brave"].ai.size == 10)
            local repB = rebuild({ { id = "stance", define = function(c)
                c.attitude:add{ id = "stance:bad", order = 50, title = "Bad", icon = 3, rules = { { priority = 1, conds = { { code = 99 } },
                    action = { code = 5 } } } }
            end } })
            check("content: an attitude rule with an unknown condition code is an error", #repB.errors == 1 and repB.errors[1].text:find("no known code", 1, true))
        end
        -- the computer player's levels are records: a patch changes what the AI code reads, a level without the field gets the code's default
        do
            local profile = require("src.game.aiprofile")
            local orig = profile.get(6, "incomeCap", 35)
            local repP = rebuild({ { id = "easy", patch = function(c) c.aiprofile:patch("emperor", { incomeCap = 5, rates = { army = 1 } }) end } })
            check("content: a patched AI level changes the numbers the AI code reads",
                #repP.errors == 0 and orig == -1 and profile.get(6, "incomeCap", 35) == 5 and profile.rate(6, "army", 60) == 1
                and profile.rate(6, "builder", 60) == 150 and profile.get(7, "incomeCap", 35) == 35 and profile.get(0, "humanBias", 9) == 0)
        end
        rebuild({})
        check("content: without mods the registry is the original again", content.hash() == base and gamedata.army("AHBX").hits ~= 99)
    end
    return 0
end

return M
