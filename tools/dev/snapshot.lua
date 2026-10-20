-- Golden-master snapshot of the rule data through the engine's own accessors (docs/data-driven/07-verification-legal.md
-- 7.1): units, buildings, build lists, production, requirements, overrides, power-up costs / pictures / bonuses. It uses
-- only the facade API, so the same script runs at the baseline commit and at the working tree and the outputs can be
-- diffed (tools/dev/golden.ps1). The output is derived from the install: it goes to the user directory, never committed.
--   pwsh tools/dev/love.ps1 -- --selftest --lua tools/dev/snapshot.lua <out.txt>
local out = {}
local outPath = ...
-- the text form of a value: sorted keys, the array part ends at the first hole (a copy of the registry's dump, so that the baseline commit
-- and the working tree are compared with the same serialiser)
local function keyLess(a, b)
    local ta, tb = type(a), type(b)
    if ta ~= tb then return ta == "number" or (tb ~= "number" and ta < tb) end
    if ta == "number" or ta == "string" then return a < b end
    return tostring(a) < tostring(b)
end
---@param v number
---@return string
local function num(v)
    if v ~= v then return "nan" end
    if v == math.floor(v) and math.abs(v) < 2 ^ 52 then return ("%d"):format(v) end
    return ("%.17g"):format(v)
end
---@param v any
---@param indent string
---@param out string[] the pieces, appended to
local function text(v, indent, out)
    local t = type(v)
    if t == "number" then out[#out + 1] = num(v)
    elseif t == "string" then out[#out + 1] = (("%q"):format(v):gsub("\\\n", "\\n"))
    elseif t == "boolean" then out[#out + 1] = tostring(v)
    elseif t == "table" then
        local n = 0
        while v[n + 1] ~= nil do n = n + 1 end
        local keys = {}
        for k in pairs(v) do
            if not (type(k) == "number" and k >= 1 and k <= n and k == math.floor(k)) then keys[#keys + 1] = k end
        end
        table.sort(keys, keyLess)
        if n == 0 and #keys == 0 then out[#out + 1] = "{}" return end
        out[#out + 1] = "{\n"
        for i = 1, n do
            out[#out + 1] = indent .. "    "
            text(v[i], indent .. "    ", out)
            out[#out + 1] = ",\n"
        end
        for _, k in ipairs(keys) do
            out[#out + 1] = indent .. "    [" .. (type(k) == "string" and ("%q"):format(k) or num(k)) .. "] = "
            text(v[k], indent .. "    ", out)
            out[#out + 1] = ",\n"
        end
        out[#out + 1] = indent .. "}"
    else
        out[#out + 1] = "nil"
    end
end
local dump = { value = function(v) local out = {} text(v, "", out) return table.concat(out) end }
local rules = require("src.game.rules")
local gd = require("src.game.gamedata")
local pu = require("src.game.powerups")

-- One line of the snapshot: section|key|value as text.
---@param section string
---@param key any
---@param value any
local function put(section, key, value) out[#out + 1] = section .. "|" .. tostring(key) .. "|" .. dump.value(value) end

local ARM = { "useDefault", "moveType", "name", "sideReq", "buildTime", "combat", "speed", "resistance", "hits", "view",
              "armor", "strong", "weak", "damage", "damageType", "range", "shape", "psych", "cost", "powers", "unitValue",
              "setupPoints", "fidget", "moveSound", "combatSound", "ambient", "moveAmount", "bones", "attitude", "fineTune",
              "attackType", "shadow", "flags", "speech", "skin", "deathScream" }
local BUI = { "useDefault", "name", "buildTime", "cost", "combat", "speed", "resistance", "hits", "view", "armor", "strong",
              "weak", "damage", "damageType", "range", "shape", "sideReq", "fire", "rubbleType", "attackType", "base" }
-- The fields `names` of a record, as a new table.
---@param names string[]
---@return table
local function pick(rec, names)
    local t = {}
    for _, n in ipairs(names) do t[n] = rec[n] end
    return t
end

local armies, buildings = {}, {}
for _, e in ipairs(rules.armyList()) do armies[#armies + 1] = e.code end
for _, e in ipairs(rules.buildingList()) do buildings[#buildings + 1] = e.code end
table.sort(armies) table.sort(buildings)
for _, c in ipairs(armies) do
    put("army", c, pick(gd.army(c), ARM))
    local info = rules.armyInfo(c) --[[@as table]]   -- every code of armyList has its info
    local copy = {}
    for k, v in pairs(info) do if k ~= "cache" then copy[k] = v end end
    put("armyInfo", c, copy)
end
for _, c in ipairs(buildings) do
    put("building", c, pick(gd.building(c), BUI))
    put("buildingInfo", c, rules.building(c))
end
put("armyList", "all", rules.armyList())
put("buildingList", "all", rules.buildingList())

local powerups = {}
for _, p in ipairs(pu.codesForTest and pu.codesForTest() or {}) do powerups[#powerups + 1] = p end
local okpd, pd = pcall(require, "src.game.powerupdata")
if okpd and pd.cost and next(pd.cost) then
    for c in pairs(pd.cost) do powerups[#powerups + 1] = c end
else
    for _, p in ipairs(require("src.content").powerup:all()) do powerups[#powerups + 1] = p.id end
end
table.sort(powerups)

local things = {}
for _, c in ipairs(armies) do things[#things + 1] = c end
for _, c in ipairs(buildings) do things[#things + 1] = c end
for _, c in ipairs(powerups) do things[#things + 1] = c end

-- A build / production list cut down to code, level and row.
---@return table[]
local function codes(list)
    local t = {}
    for i, e in ipairs(list) do t[i] = { code = e.code or e.id, level = e.level, row = e.row } end
    return t
end

for race = 0, 15 do
    put("buildList", race, codes(rules.buildList(race)))
    local sets = rules.raceSets(race)
    for _, key in ipairs({ "buildings", "armies" }) do    -- a code Army.cfg lists twice appears once (the registry keeps one record)
        local seen, list = {}, {}
        for _, c in ipairs(sets[key]) do if not seen[c] then seen[c] = true list[#list + 1] = c end end
        sets[key] = list
    end
    put("raceSets", race, sets)
    local force = rules.startingForce(race)
    put("startingForce", race, force)
    for _, b in ipairs(buildings) do put("produces", race .. b, codes(rules.produces(race, b))) end
    for _, c in ipairs(things) do
        local req = rules.requirements(race, c)
        if #req > 0 then put("requires", race .. c, req) end
        local o = rules.override(race, c)
        if o then put("override", race .. c, o) end
    end
end
put("raceVariant", "x", (function()
    local t = {}
    for race = 0, 15 do for _, c in ipairs({ "BWTC", "BWG0", "BWN1", "BWE2", "BWTP", "AHBX" }) do t[#t + 1] = gd.raceVariant(c, race) end end
    return t
end)())

-- the race tables: role units, hero creation data, customisation lists, retinue, conversation tests
do
    local economy, classes = require("src.game.economy"), require("src.game.classes")
    local herocustom, retinue = require("src.game.herocustom"), require("src.game.retinue")
    local conversation = require("src.game.conversation")
    for race = 0, 15 do
        put("race", race, { hero = economy.HERO[race], general = economy.GENERAL[race], builder = economy.BUILDER[race],
                            plural = gd.RACES[race], picture = pu.PICTURE[race], portraits = herocustom.PORTRAITS[race],
                            voices = herocustom.VOICES[race], voicesAlt = herocustom.VOICES_ALT[race],
                            avatars = herocustom.AVATARS[race], names = classes.RACE_NAMES[race] })
        for _, c in ipairs(classes.list and classes.list() or classes.CLASSES) do
            put("hero", race .. c[1], { attr = classes.baseAttr(race, c[1]), skills = classes.skillList(race, c[1]) })
        end
        local gens = {}
        for roll = 0, 9 do gens[#gens + 1] = retinue.generalFor(race, roll) end
        put("retinueGeneral", race, gens)
        for points = 1, 30 do
            put("retinueAI", race .. ":" .. points, retinue.aiArmy(race, points, 2, function(n) return (points % n) + 1 end))
        end
        local words = {}
        for _, w in ipairs({ "knight", "dwarf", "undead", "barbarian", "minotaur", "orc", "highelf", "woodelf", "darkelf", "fey",
                             "darkdwarf", "daemon", "empire", "ssrathi", "swarm", "plaguelord", "good", "evil", "mortal", "immortal" }) do
            words[#words + 1] = conversation.test(w, { race = race, class = "Paladin" }) and 1 or 0
        end
        put("conversation", race, words)
    end
    local towers = {}
    for _, c in ipairs(buildings) do towers[#towers + 1] = gd.isRaceTower(c) and 1 or 0 end
    put("isRaceTower", "all", towers)
end

-- attitudes: the list, each one's rule set, names and icons
do
    local attitude, strings = require("src.game.attitude"), require("src.game.strings")
    local names = {}
    for _, a in ipairs(attitude.list()) do
        local def = attitude.def[a]
        local ai = def.ai
        put("attitude", a, { name = attitude.name(a), desc = attitude.description(a), icon = attitude.icon(a), designated = def.designated,
                             spells = def.spells, custom = def.custom or false, hitRules = def.hitRules or false, size = ai.size,
                             rules = ai.rules, idle = ai.idle })
        names[#names + 1] = a
    end
    put("attitudeList", "all", names)
end

-- items: the catalogue, bonuses, description lines, slot names, random picks
do
    local items = require("src.game.items")
    if items.load then items.load() end
    local list = items.all and items.all() or items.list
    put("itemCount", "all", #list)
    for _, it in ipairs(list) do
        local copy = {}
        for k, v in pairs(it) do copy[k] = v end
        put("item", it.id, copy)
        put("itemBonus", it.id, items.bonuses({ [1] = it }, 1))
        put("itemBonusAll", it.id, items.bonuses({ [1] = it }))
        put("itemLines", it.id, items.powerLines(it))
    end
    local slots = {}
    for row = 0, 11 do slots[#slots + 1] = tostring(items.SLOTS[row]) end
    put("itemSlots", "all", slots)
    local seed = 1
    local function rng() seed = (seed * 1103515245 + 12345) % 2147483648 return seed / 2147483648 end
    local picks = {}
    for tier = 1, 3 do for _ = 1, 20 do local it = items.random(tier, rng) picks[#picks + 1] = it and it.id or 0 end end
    put("itemRandom", "all", picks)
    local irng = function(n) seed = (seed * 1103515245 + 12345) % 2147483648 return 1 + seed % n end
    for level = 1, 40, 3 do
        local worn, pack = items.computerKit(level, false, irng)
        local w, p = {}, {}
        for slot, it in pairs(worn) do w[#w + 1] = slot .. "=" .. it.id end
        table.sort(w)
        for _, it in ipairs(pack) do p[#p + 1] = it.id end
        put("itemKit", level, { w, p })
    end
end

-- abilities: the buttons every unit type offers to each of a few races (ids sorted: the order of the buttons is not compared),
-- the building abilities of every building type for every race
do
    local boot, worldMod = require("src.game.boot"), require("src.game.world")
    local armyab = require("src.game.armyabilities")
    local buildab = require("src.game.buildingabilities")
    math.randomseed(5)
    local w = worldMod.new(assert(boot.loadScenario("Bridges")), { player = 0 })
    local hero = assert(w.eco:heroAlive(0))
    local sd = w.sides[0]
    sd.gold, sd.metal, sd.crystal, sd.stone = 5000, 5000, 5000, 5000
    local units = {}
    for i, code in ipairs(armies) do
        local x, y = w:nearestFree(hero.gx + (i % 20) - 10, hero.gy + 4 + math.floor(i / 20), 0, 8)
        local u = x and w:addUnit(code, 0, x, y --[[@as integer]])
        if u then u.mana = 500 units[#units + 1] = u end
    end
    for _, race in ipairs({ 0, 1, 2, 3, 4, 8, 11 }) do
        sd.race = race
        sd.powerups = {}
        for _, u in ipairs(units) do
            local row = {}
            for _, b in ipairs(armyab.buttons(w, 0, { u }, 0)) do row[#row + 1] = b.id .. (b.disabled and "!" or "") .. ":" .. b.icon .. ":" .. tostring(b.tip) end
            table.sort(row)
            put("buttons", race .. u.code, row)
        end
    end
    sd.powerups = {}
    for _, p in ipairs(powerups) do sd.powerups[p] = true end
    for _, race in ipairs({ 0, 2, 12 }) do
        sd.race = race
        for _, u in ipairs(units) do
            local row = {}
            for _, b in ipairs(armyab.buttons(w, 0, { u }, 0)) do row[#row + 1] = b.id .. (b.disabled and "!" or "") .. ":" .. b.icon end
            table.sort(row)
            put("buttonsPU", race .. u.code, row)
        end
    end
    local list = {}
    for _, a in ipairs(buildab.list) do
        local copy = {}
        for k, v in pairs(a) do if k ~= "kind" and k ~= "buildingRace" then copy[k] = v end end
        list[#list + 1] = copy
    end
    table.sort(list, function(a, b) return a.id < b.id end)
    put("buildingAbilities", "list", list)
    local function pickFields(map, names)
        local out = {}
        for id, rec in pairs(map) do
            local t = {}
            for _, n in ipairs(names) do t[n] = rec[n] end
            out[id] = t
        end
        return out
    end
    put("morphs", "all", { pickFields(armyab.MORPHS, { "from", "to", "res", "amount", "need", "icon", "name", "req" }),
                           pickFields(armyab.ABILITIES, { "id", "mana", "icon", "name", "spell", "power" }) })
end

-- heroes: skill effects and help lines, racial lords, experience, conversion times, classes
do
    local HS, hero, classes = require("src.game.heroskills"), require("src.game.hero"), require("src.game.classes")
    local fx = {}
    for id = 1, 106 do
        for lvl = 0, 10 do fx[#fx + 1] = HS.effect(id, lvl) end
        fx[#fx + 1] = tostring(HS.help(id, 3))
    end
    put("skillEffects", "all", fx)
    local ids = {}
    for name in pairs({ Ferocity = 1, Leech = 1, Contamination = 1, Gate = 1, Thievery = 1, Diplomacy = 1, Potionmaster = 1, Assassin = 1 }) do
        ids[#ids + 1] = name .. "=" .. tostring(HS.ids[name])
    end
    table.sort(ids)
    put("skillIds", "some", ids)
    local lords = {}
    for race = 0, 15 do lords[#lords + 1] = HS.lordOf(race) end
    put("lords", "all", lords)
    local xp = {}
    for level = 1, 120 do xp[#xp + 1] = hero.xpFor(level) end
    put("heroXp", "all", xp)
    local conv = {}
    for rating = 0, 110 do conv[#conv + 1] = hero.conversionTime(rating) end
    put("heroConv", "all", conv)
    put("classes", "all", { classes.list and classes.list() or classes.CLASSES, classes.BROAD, classes.of(1), classes.of(4), classes.data("Healer"), classes.newHero("Druid", 7) })
    put("heroConsts", "all", { hero.MAX_LEVEL, hero.ATTR_POINTS, hero.SKILL_POINTS, hero.PACK_SIZE, hero.BASE_ATTR, hero.START_POTIONS,
                               hero.MAX_POTIONS, hero.SLOT_LAYOUT, hero.potionHeal(3), hero.potionMana(3) })
end

-- victory conditions: an all-computer battle under every rule, then the clock of the timed ones forced to run out and the sides 1..4
-- wiped out (their armies killed, their buildings razed); the special rules are also decided by their own measure
if not os.getenv("WBC3_SNAP_QUICK") then       -- the battles take minutes: golden.ps1 -Quick leaves them out
    local boot, worldMod = require("src.game.boot"), require("src.game.world")
    local victory = require("src.game.victory")
    local RULES = { "standard", "raze all", "kill all", "assassins", "razefest", "slugfest", "fortress", "king of the castle",
                    "rich get richer", "against the horde", "battle of titans", "pitched battle", "capture the flag" }
    -- One minute of an all-computer battle under `rule`, then `finish(w)` and 40 seconds more; puts the outcome.
    ---@param rule string
    ---@param label string
    ---@param finish fun(w: World)
    local function run(rule, label, finish)
        math.randomseed(77)
        local w = worldMod.new(assert(boot.loadScenario("Bridges")), { player = 99, victory = rule })
        w.ai = require("src.game.ai").new(w)
        for _ = 1, 30 * 60 do w:update(1 / 30) end
        local before = victory.totals(w)
        if w.victoryEnd then w.victoryEnd = w.time + 1000 end
        finish(w)
        for _ = 1, 30 * 40 do w:update(1 / 30) end
        local def, totals = {}, {}
        for i = 0, 5 do def[#def + 1] = tostring(w.sides[i].defeated) end
        for i, n in pairs(victory.totals(w) or {}) do totals[#totals + 1] = i .. "=" .. n end
        table.sort(totals)
        local first = {}
        for i, n in pairs(before or {}) do first[#first + 1] = i .. "=" .. n end
        table.sort(first)
        put("victory", rule .. " / " .. label, { rule = w.victoryRule, over = w.over and table.concat(w.over.winners, ",") or "no",
                               winners = w.winners and table.concat(w.winners, ",") or "none", defeated = def, totals = totals,
                               before = first, clock = w.clock ~= nil, flags = w.flagCount, tech = w.techLevel, hash = w:hash(),
                               number = victory.number(rule), timed = victory.timed(rule), name = victory.NAMES[victory.number(rule)] })
    end
    ---@param w World
    local function wipe(w)
        for _, u in ipairs(w.units) do if u.side >= 1 and u.side <= 4 then u:takeDamage(1e7, nil) end end
        for _, b in ipairs(w.buildings) do if b.side >= 1 and b.side <= 4 then b.hp = 0 b.destroyed = true end end
    end
    for _, rule in ipairs(RULES) do
        run(rule, "idle", function() end)
        run(rule, "wipe", wipe)
    end
    run("king of the castle", "keep", function(w) w.eco.keepLevel = function(_, i) return i == 2 and 5 or 0 end end)
    run("rich get richer", "rich", function(w) local s = w.sides[3] s.gold, s.metal, s.crystal, s.stone = 2600, 2600, 2600, 2600 end)
    run("capture the flag", "flags", function(w) for _, b in ipairs(w.buildings) do if b.flagNumber then b.side = 1 end end end)
    run("razefest", "count", function(w) w.events.stats.razed["2:*"] = 99 end)
    run("slugfest", "count", function(w) w.events.stats.kills["4:*"] = 999 end)
    put("victoryRule", "x", { victory.rule(4), victory.rule("kill armies"), victory.rule("nonsense") or "nil", victory.rule("razefest") })
end

-- power-ups: cost / time, picture index, army bonuses of every single power-up on every army type
for _, p in ipairs(powerups) do
    if pu.baseCost then
        local c, t = pu.baseCost(p)
        ---@cast c -nil
        put("powerCost", p, { c.gold, c.metal, c.crystal, c.stone, t })
    else
        put("powerCost", p, pu.cost[p])
    end
    local row = {}
    for _, letter in ipairs({ "H", "D", "U", "B", "M", "O", "E", "W", "K", "F", "A", "V", "P", "L", "R", "G" }) do
        local pi = pu.pictureIndex(letter, p) row[#row + 1] = tostring(pi)
    end
    put("powerPicture", p, row)
    for _, a in ipairs(armies) do
        local side = { powerups = { [p] = true } }
        local b = pu.bonus(side, a)
        if b then put("powerBonus", p .. a, b) end
    end
end

table.sort(out)
local f = assert(io.open(outPath, "wb"))
f:write(table.concat(out, "\n"), "\n")
f:close()
print("snapshot lines " .. #out)
