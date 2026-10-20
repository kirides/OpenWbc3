-- Economy and production: resources, mines, conversion, production queues,
-- construction, army limit and the standard victory rule.
--
-- Rules follow the original game:
--  * every 4 s each mine gives 2*produce + workers of its resource
--    (elves count half their workers); the reserve shrinks by the same amount
--  * resource caps by best keep level: 1000, 1500, 2000, 2500, 3000
--  * production cost is paid when an item starts; build time = .ARM seconds
--  * army limit = sum of building limits + keep amount + 2 (hero morale)
--  * a side is defeated when it has no units and no "stop defeat" buildings
local content = require("src.content")
local gamedata = require("src.game.gamedata")
local rules = require("src.game.rules")
local log = require("src.core.log")

local M = {}

-- The resources (`resource` records) and the economy numbers (`eco.*` settings, content/base/rules.lua).
M.RESOURCES = content.resource:ids()
local RES_LETTER = {}
local function setting(id) return content.setting:value(id) end
local START_AMOUNT, MINE_PRODUCE, MINE_RESERVE, KEEP_AMOUNT, INCOME_TIME, HORDE_AMOUNT, INCOME_AMOUNT
local ATTACK_INTERVAL
-- the numbers are read again whenever the registry has been (re)built, so a mod's patch of a setting reaches them
content.onReady(function()
    M.RESOURCES = content.resource:ids()
    RES_LETTER = {}
    for _, r in ipairs(content.resource:all()) do RES_LETTER[r.letter] = r.id end
    START_AMOUNT = setting("eco.startAmount")
    MINE_PRODUCE = setting("eco.mineProduce")
    MINE_RESERVE = setting("eco.mineReserve")
    KEEP_AMOUNT = setting("eco.keepAmount")
    INCOME_TIME = setting("eco.incomeTime")
    HORDE_AMOUNT = setting("eco.hordeAmount")
    INCOME_AMOUNT = setting("eco.incomeAmount")       -- Income / Hard Labor power-ups, per mine
    ATTACK_INTERVAL = setting("eco.attackInterval")
    M.CONVERT_TIME = setting("eco.convertTime")
    M.CONVERT_RANGE = setting("eco.convertRange")
    M.GIFT_AMOUNTS = setting("eco.giftAmounts")
    M.GIFT_RESOURCES = setting("eco.giftResources")
            end)

-- Hero ("general") and builder unit per race (the `units` of the race records, indexed by race number). `GENERAL` is the
-- plain general per race that a No Heroes game starts with (instead of the hero): the table read by the start units
-- in the 1.04 binary (FUN_00445810, table at 0x0060B5D8, one id per race).
M.HERO = content.race:view("units.hero")
M.GENERAL = content.race:view("units.general")
M.BUILDER = content.race:view("units.builder")

---@param code string
---@return boolean
function M.isMine(code) return code:sub(2, 2) == "R" end
---@param code string
---@return boolean
function M.isKeep(code) return code:sub(2, 2) == "K" end
-- What a hero may convert (the building conversion test FUN_0052da90 of the 1.04 binary):
-- the second letter of the code, uppercased, must be K (keep), A (power-up altar), P (production
-- point), R (resource point) or T (temple). Everything else is not convertible - lairs (the BL..
-- nests and the BS.. ones too), shops, shrines, walls. The flag (code BMFL) is the function's one exception: it
-- accepts it first, before any other test and whatever the victory rule (Eco:canBeConverted).
---@param code string
---@return boolean
function M.convertible(code)
    local c = code:sub(2, 2)
    return c == "K" or c == "A" or c == "P" or c == "R" or c == "T"
end

local function levelDigit(code)
    return tonumber(code:sub(4, 4)) or 0
end

-- A mine's state (Eco:initBuilding).
---@class Mine
---@field resource string           "gold" | "metal" | "crystal" | "stone"
---@field produce integer
---@field reserve integer
---@field workers integer

-- What a building is producing now (Eco:updateBuilding).
---@class Production
---@field code string
---@field t0 number
---@field t1 number
---@field cost table<string, integer>
---@field name string
---@field full boolean?             stuck at the army limit ("too many men" said once)

-- A building on the battle map (World:addBuilding; production, mines, repairs, garrisons here). A plain table, not a
-- unit: `kind` tells the two apart where either can come (attack targets, picking).
---@class Building: Entity
---@field kind "building"
---@field type BuildingRecord?      the type record (gamedata.building: content `building` record), nil for an unknown code
---@field side integer
---@field name string
---@field hp number
---@field maxHp number
---@field shape Shape?
---@field towerLevel integer?       a race tower scaled to the heroes' level (advanced.scaledTower): that level ...
---@field towerKind string?         ... and "start" | "scenario"
---@field complete boolean          finished (not a construction site)
---@field queue string[]            production queue (codes)
---@field current Production?
---@field waiting boolean?          the head of the queue cannot be afforded
---@field continuous boolean?       continuous army production
---@field mine Mine?
---@field site {t0: number, t1: number, builder: Unit?, p: number?}? construction in progress
---@field repair {t0: number, t1: number, total: number, done: number, speed: integer, pct: number?}?
---@field convert {t0: number, t1: number, range: number, hp: number}? a keep's conversion
---@field rally {[1]: integer, [2]: integer}? rally point (cell)
---@field garrison Unit[]?
---@field attitude string?          what the units it produces start with
---@field target (Unit|Building)?   a tower's target (attitude.towerThink)
---@field targetSide integer?
---@field nextShot number?
---@field pillaged number?          pillaged until (world time)
---@field destroyed boolean?
---@field razedBy integer?          the side that destroyed it
---@field rubbleSince number?
---@field wreck boolean?            leaves a wreck for a while
---@field expireAt number?          spell buildings (walls, portals) fade at this time
---@field seen table<integer, boolean>? sides whose simulation fog has seen it (fog.lua)
---@field attSlice integer?         attitude.lua
---@field pathDanger integer?       airegion.lua
---@field morphMod table?
---@field quest ShrineQuest?        a shrine's quest (quests.lua)
---@field lair LairState?           a lair's breeding (sites.lua)
---@field shop Shop?                a shop's stock and hatred (sites.lua)
---@field flagNumber integer?       Capture the Flag
---@field fireSound any             the battle screen's fire loop (display only)

-- A side (world.sides[i]: 0..5 the players, 6 neutral). Resources are fields named after the resource ids.
---@class Side
---@field index integer
---@field passive boolean?          a Passive side (level 0): its computer only runs its attitude pass (ai.lua)
---@field noRetinue boolean?        the map says "no retinue"
---@field used boolean              takes part in the battle
---@field race integer
---@field color integer
---@field team integer              0 = no team
---@field startX integer            start cell, -1 none
---@field startY integer
---@field resourceLevel integer?    the scenario's start resources
---@field aiLevel integer           0 passive .. 7 rampant
---@field aiFile string?
---@field aiHero table?             race / class / level of the computer's hero (aihero.lua)
---@field ai boolean                played by the computer
---@field gold number
---@field metal number
---@field crystal number
---@field stone number
---@field built table
---@field defeated boolean?
---@field resigned boolean?
---@field fallenHero table?         the saved state of its slain hero (Hero:save)
---@field heroUnit Unit?            Eco:heroAlive's cache
---@field visionBonus number?       campaign bonus / spells: more sight
---@field trueSight any
---@field ironman boolean?
---@field producedTitan boolean?
---@field powerups table?           bought power-ups (powerups.lua)
---@field powerBonus table?
---@field spellBonus table?
---@field knightsQuest table?
---@field quest SideQuest?          a hero's shrine quest (quests.lua)
---@field questsCompleted integer?
---@field charm number?             side timers of spells (world time they run out) and their values
---@field charmValue number?
---@field cheapSkills number?
---@field cheapPct number?
---@field command number?
---@field commandPct number?
---@field concentration number?
---@field concentrationPct number?
---@field corruption number?
---@field corruptionPct number?
---@field dig number?
---@field digPct number?
---@field empower number?
---@field empowerPct number?
---@field enervate number?
---@field enervatePct number?
---@field extend number?
---@field manaflow number?
---@field poisonGate number?
---@field seeInvisible number?
---@field training number?
---@field trainingXp number?
---@field aiMorphAt table<string, number>? morph target code -> world time of the AI's last morph (armyabilities.lua)
---@field sacrificeAt number?

-- The economy of a battle: resources, production, construction, conversion and the victory check.
---@class Eco
---@field world World
---@field nextIncome number
---@field nextVictory number
local Eco = {}
Eco.__index = Eco

---@param world World
---@return Eco
function M.new(world)
    ---@type Eco
    local self = setmetatable({ world = world, nextIncome = INCOME_TIME, nextVictory = 3000 }, Eco)
    for i = 0, 6 do
        local side = world.sides[i]
        local lvl = side.resourceLevel
        local amount = START_AMOUNT[lvl]
        side.gold = amount or 100
        side.metal = amount or 50
        side.crystal = amount or 50
        side.stone = amount or 50
        side.built = {}
    end
    for _, b in ipairs(world.buildings) do self:initBuilding(b) end
    return self
end

---@param b Building
function Eco:initBuilding(b)
    b.complete = b.complete ~= false
    b.queue = b.queue or {}
    if M.isMine(b.code) then
        local lvl = math.min(2, levelDigit(b.code))
        b.mine = {
            resource = RES_LETTER[b.code:sub(3, 3)] or "gold",
            produce = MINE_PRODUCE[lvl], reserve = MINE_RESERVE[lvl], workers = 0,
        }
    end
end

-- Resources --------------------------------------------------------------------

---@param sideIndex integer
---@return integer
function Eco:cap(sideIndex)
    local best = 0
    for _, b in ipairs(self.world.buildings) do
        if b.side == sideIndex and b.hp > 0 and b.complete and M.isKeep(b.code) then
            best = math.max(best, levelDigit(b.code))
        end
    end
    return 1000 + 500 * best
end

-- Price after the hero's Merchant skill.
---@param sideIndex integer
---@param amount number?
---@return number
function Eco:price(sideIndex, amount)
    local hero = self:heroAlive(sideIndex)
    local f = hero and hero.h and hero.h.mod.merchant or 1
    local sd = self.world.sides[sideIndex]
    if sd.charm and sd.charm > self.world.time then   -- Charm: Merchant +2 x success level on the hero
        f = 100 / (100 + (hero and hero.h and hero.h.mod.discount or 0) + (sd.charmValue or 2))
    end
    return f == 1 and (amount or 0) or math.floor((amount or 0) * f + 0.5)
end

---@param sideIndex integer
---@param cost table<string, number> resource -> amount
---@return boolean, string? short
function Eco:canAfford(sideIndex, cost)
    local s = self.world.sides[sideIndex]
    for _, r in ipairs(M.RESOURCES) do
        if self:price(sideIndex, cost[r]) > s[r] then return false, r end
    end
    return true
end

-- The resource a side lacks for `cost`, checked in the order the original does when a builder reaches its building
-- place (crystal, metal, gold, stone; the 1.04 binary's FUN_00524450), or nil.
---@param sideIndex integer
---@param cost table<string, number>
---@return string?
function Eco:shortOf(sideIndex, cost)
    local s = self.world.sides[sideIndex]
    for _, r in ipairs({ "crystal", "metal", "gold", "stone" }) do
        if self:price(sideIndex, cost[r]) > s[r] then return r end
    end
end

---@param sideIndex integer
---@param cost table<string, number>
---@param sign integer? -1 (default) pay, 1 refund
function Eco:pay(sideIndex, cost, sign)
    local s = self.world.sides[sideIndex]
    sign = sign or -1
    local cap = self:cap(sideIndex)
    local stats = self.world:battleStats()
    for _, r in ipairs(M.RESOURCES) do
        local amount = sign * self:price(sideIndex, cost[r])
        s[r] = math.max(0, math.min(cap, s[r] + amount))
        stats:resource(sideIndex, r, -amount, "spent")
    end
end

-- Cost and time of a production / construction item.
---@param code string a unit, power-up or building code
---@param sideIndex integer?
---@return {kind: string, cost: table<string, number>, time: number, name: string}?
function Eco:itemInfo(code, sideIndex)
    local kind = code:sub(1, 1)
    if kind == "A" then
        local t = gamedata.army(code)
        if not t then return nil end
        local cost = t.cost
        local sd = sideIndex and self.world.sides[sideIndex]
        if sd and self:isHeroCode(sideIndex, code) then
            -- resurrecting a hero costs more the higher its level
            local level = sd.fallenHero and sd.fallenHero.level or 1
            cost = { gold = 100 + 50 * level, metal = 0, crystal = 0, stone = 0 }
        end
        local time = math.max(1, t.buildTime)
        if sd then cost, time = self:applyRule(sd.race, code, cost, time) end
        if sd and not self:isHeroCode(sideIndex, code) then cost, time = require("src.game.powerups").unitCost(sd, code, cost, time) end
        return { kind = "unit", cost = cost, time = time * 1000, name = rules.unitName(code, t) }
    elseif kind == "P" or kind == "R" then
        local pu = require("src.game.powerups")
        local cost, time = pu.baseCost(code)
        if not cost or not pu.exists(code) then return nil end
        local sd = sideIndex and self.world.sides[sideIndex]
        if sd then cost, time = self:applyRule(sd.race, code, cost, time) end
        if sd and sd.cheapSkills and sd.cheapSkills > self.world.time then   -- Comprehension
            for k, v in pairs(cost) do cost[k] = math.floor(v * (100 - (sd.cheapPct or 0)) / 100) end
        end
        -- the rune skills (applied last, 10 % per level of the matching hero skill, at least 1 of each resource)
        local skill = pu.runeSkill(code)
        local hero = skill and sd and self:heroAlive(sideIndex)
        local lvl = hero and hero.h and hero.h.skill[skill] or 0
        if lvl > 0 then
            local pct = math.max(0, 100 - 10 * lvl)
            for k, v in pairs(cost) do if v ~= 0 then cost[k] = math.max(1, math.floor(v * pct / 100)) end end
        end
        -- Fame makes the foreign mercenaries cheaper by 25 / 33 / 50 % (FUN_0040b6b0: applied to every resource that is not 0)
        local fame = pu.isOneShot(code) and code:sub(1, 3) == "POM" and sd and pu.level(sd, "PFM0") or 0
        local off = ({ 25, 33, 50 })[fame]
        if off then
            for k, v in pairs(cost) do if v ~= 0 then cost[k] = math.floor((100 - off) * v / 100) end end
        end
        return { kind = "powerup", cost = cost, time = time * 1000, name = pu.name(code) }
    elseif kind == "B" then
        local t = gamedata.building(code)
        if not t then return nil end
        local info = rules.building(code)
        local sd = sideIndex and self.world.sides[sideIndex]
        local cost, time = t.cost, math.max(1, t.buildTime)
        if sd then cost, time = self:applyRule(sd.race, code, cost, time) end
        local speedUp = sd and sd.dig and sd.dig > self.world.time and (100 - (sd.digPct or 50)) / 100 or 1
        -- Engineering: 25 % faster building
        if sd and require("src.game.powerups").has(sd, "PENG") then time = time - math.floor(25 * time / 100) end
        return { kind = "building", cost = cost, time = time * 1000 * speedUp,
                 name = (info and info.name ~= "" and info.name) or t.name or code }
    end
    return nil
end

-- Per-race cost / time overrides of Building.cfg [RULES] (the rule lookup FUN_00587aa0 of the 1.04 binary).
---@generic C, T
---@param race integer
---@param code string
---@param cost C
---@param time T
---@return C|table<string, number> cost, T|number time
function Eco:applyRule(race, code, cost, time)
    local o = rules.override(race, code)
    if not o then return cost, time end
    cost = cost or {}
    local c = {}
    for _, r in ipairs(M.RESOURCES) do c[r] = o[r] or cost[r] or 0 end
    return c, o.time or time
end

-- Requirement check: A*** codes always count; buildings must exist, finished,
-- owned; a level-n building satisfies levels 0..n. A bought power-up or rune counts as well (the power-up routine
-- FUN_00436500 passes a permanent power-up to the dependency counter FUN_0040b350, which is how "E AEMX : RCIE" is met).
---@param sideIndex integer
---@param code string
---@return boolean
function Eco:hasBuilt(sideIndex, code)
    if code:sub(1, 1) == "A" then return true end
    if require("src.game.powerups").has(self.world.sides[sideIndex], code) then return true end
    local stem, need = code:sub(1, 3), tonumber(code:sub(4, 4))
    for _, b in ipairs(self.world.buildings) do
        if b.side == sideIndex and b.hp > 0 and b.complete then
            if b.code == code then return true end
            if need and b.code:sub(1, 3) == stem and (tonumber(b.code:sub(4, 4)) or -1) >= need then return true end
        end
    end
    return false
end

---@param sideIndex integer
---@param code string
---@return boolean, string? missing
function Eco:requirementsMet(sideIndex, code)
    local race = self.world.sides[sideIndex].race
    for _, r in ipairs(rules.requirements(race, code)) do
        if not self:hasBuilt(sideIndex, r) then return false, r end
    end
    return true
end

-- The buildings and armies of the side's race whose requirements are met (and, for an armies, a building that
-- produces it stands): FUN_00519560 / FUN_00519630 of the 1.04 binary, whose "became
-- available" step makes the announcer say "new armies / buildings available". Returns two sets keyed by code.
---@param sideIndex integer
---@return table<string, boolean> buildings, table<string, boolean> armies
function Eco:available(sideIndex)
    local race = self.world.sides[sideIndex].race
    local set = rules.raceSets(race)
    local buildings, armies = {}, {}
    for _, code in ipairs(set.buildings) do
        if self:requirementsMet(sideIndex, code) then buildings[code] = true end
    end
    local builders = {}
    for _, bcode in ipairs(set.buildings) do
        if self:hasBuilt(sideIndex, bcode) then
            for _, item in ipairs(rules.produces(race, bcode)) do builders[item.id] = true end
        end
    end
    for _, code in ipairs(set.armies) do
        if builders[code] and self:requirementsMet(sideIndex, code) then armies[code] = true end
    end
    return buildings, armies
end

-- The hero unit codes of a side: the race's default and, for the player, the selected hero's avatar (World:heroCode).
---@param sideIndex integer? (nil: false)
---@param code string
---@return boolean
function Eco:isHeroCode(sideIndex, code)
    local sd = self.world.sides[sideIndex]
    if sd == nil then return false end
    ---@cast sideIndex -nil
    return M.HERO[sd.race] == code or self.world:heroCode(sideIndex) == code
end

---@param sideIndex integer? (nil: none)
---@return Unit?
function Eco:heroAlive(sideIndex)
    local sd = self.world.sides[sideIndex]
    local cached = sd and sd.heroUnit
    -- a hero hidden inside a garrison is still alive (`alive()` is false for hidden units)
    local function living(u) return u:alive() or (u.garrisoned and u.state ~= "dead" and not u.remove) end
    if cached and cached.hero and cached.side == sideIndex and living(cached) then return cached end
    for _, u in ipairs(self.world.units) do
        if u.side == sideIndex and u.hero and living(u) then
            if sd then sd.heroUnit = u end
            return u
        end
    end
end

-- The troop-XP lords: the skill and what it gives experience to (initial experience, FUN_00557d90). `flags` are the
-- target's powerups.flags bits, `codes` the unit types the skill names.
local XP_LORDS = {
    { id = 87, flags = 0x2 },                                       -- Brewmaster: dwarves
    { id = 98, codes = { "AGSL" } },                                -- Slimemaster: Slime
    { id = 100, codes = { "AARI" } },                               -- Griffonmaster: Griffon
    { id = 90, codes = { "ADOX" } },                                -- Runic Lore
    { id = 93, codes = { "AUIX" } },                                -- Memories: Skeleton
    { id = 85, codes = { "AUCX" } },                                -- Undead Legion
    { id = 83, codes = { "ABIX", "ABCX", "ABEX" } },                -- Barbarian King
    { id = 84, flags = 0x800 },                                     -- Taming: monsters
    { id = 86, codes = { "AKJX" } },                                -- Guildmaster: Assassin
    { id = 88, codes = { "AHFX", "AHDX", "AHEX" } },                -- Knight Protector: the knights
    { id = 89, codes = { "AWJX", "AWKX" } },                        -- Guardian Oak: Treants
    { id = 91, codes = { "AAEF", "AAEE", "AAEW", "AAEA" } },        -- Elemental Lore: the elementals
    { id = 92, codes = { "AHGR", "AHGW", "AHGB" } },                -- Mage King: the mages
    { id = 94, flags = 0x800000 },                                  -- Gate: daemons
    { id = 96, flags = 0x1000 },                                    -- Dragonmaster: dragons
    { id = 97, codes = { "AGSP", "AGGZ", "AGFL", "AAEY" } },        -- All-Seeing Eye
    { id = 99, codes = { "AAIX", "AAJX", "AAGX" } },                -- Golem Master
}
for _, l in ipairs(XP_LORDS) do
    if l.codes then
        local set = {}
        for _, c in ipairs(l.codes) do set[c] = true end
        l.set = set
    end
end

-- Initial experience of a produced army (the 1.04 binary's FUN_00557d90; the call that makes a unit passes
-- training and lords, FUN_004a49e0 / FUN_0043bfb0's caller). With the side's hero alive: `training` gives the hero's
-- Intelligence / 2 plus the Telepathy training power, `lords` the troop-XP lord skills above
-- (their effect when the unit is of the type the skill names); `gate` (the Golem spell, FUN_005756b0) adds 20 per
-- level of the Gate power-up, hero or not. `code` is the produced unit's type.
---@param sideIndex integer
---@param code string?
---@param opts {training: boolean?, lords: boolean?, gate: boolean?}?
---@return number
function Eco:initialXp(sideIndex, code, opts)
    opts = opts or {}
    local xp = 0
    local hero = self:heroAlive(sideIndex)
    local sd = self.world.sides[sideIndex]
    if hero then
        if opts.training ~= false then
            xp = math.floor((hero.h and hero.h.attr.int or 0) / 2)
            if sd and sd.training and sd.training > self.world.time then xp = xp + (sd.trainingXp or 0) end
        end
        if opts.lords ~= false and code then
            local powerups = require("src.game.powerups")
            local HS = require("src.game.heroskills")
            local f = powerups.flags(code)
            local bit = require("bit")
            for _, l in ipairs(XP_LORDS) do
                if (l.set and l.set[code]) or (l.flags and bit.band(f, l.flags) ~= 0) then
                    xp = xp + HS.value(self.world, sideIndex, l.id)
                end
            end
        end
    end
    if opts.gate and sd then xp = xp + 20 * require("src.game.powerups").level(sd, "PGAX") end
    return xp
end

-- The rune skills raise the hits of the units they name by effect percent of the unit's hits, for as long as the
-- side's hero lives when the unit is produced (binary FUN_0043bfb0): Life Rune the Unicorn, Death Rune the Assassin,
-- Sky Rune every flier, Forest Rune the Treants, Arcane Rune the Dark / Wood / High Elf mages (AENX, AWNX, AKNX).
local RUNE_UNITS = {
    { id = 61, codes = { AEDX = true } },
    { id = 64, codes = { AKJX = true } },
    { id = 63, flags = 0x200000 },
    { id = 62, codes = { AWJX = true, AWKX = true } },
    { id = 65, codes = { AENX = true, AWNX = true, AKNX = true } },
}

---@param sideIndex integer
---@param code string
---@param hits number
---@return number
function Eco:runeHits(sideIndex, code, hits)
    local bonus = 0
    if not self:heroAlive(sideIndex) then return 0 end
    local f = require("src.game.powerups").flags(code)
    local HS = require("src.game.heroskills")
    for _, r in ipairs(RUNE_UNITS) do
        if (r.codes and r.codes[code]) or (r.flags and require("bit").band(f, r.flags) ~= 0) then
            -- each rune works on the hits so far (integer division by 100)
            bonus = bonus + math.floor((hits + bonus) * HS.value(self.world, sideIndex, r.id) / 100)
        end
    end
    return bonus
end

-- Units / buildings the game mods take away (the level check FUN_0040c990 of the 1.04 binary).
-- (the tags `dragon` and `noFliers`, content/base/tags.lua)

-- The level check (FUN_0040c990): may a slot with required level `level` (a digit, or H hero, T tower, W wall, L titan as in
-- Building.cfg) be offered at the scenario's tech level and game mods? `id` is what the mods are tested against: the
-- building being constructed, but for a production list the producing building (that is what the original passes:
-- the production buttons FUN_004cff30 hand it the building's own code). Tech level 0 offers nothing at all.
---@param sideIndex integer
---@param id string
---@param level string
---@return boolean
function Eco:levelOk(sideIndex, id, level)
    local world = self.world
    local tech, mods = world.techLevel, world.mods
    if tech == 0 then return false end
    local n = tonumber(level)
    if n == 0 then return not (mods.noDragons and gamedata.hasTag(id, "dragon")) end
    if level == "H" then return self:heroAlive(sideIndex) ~= nil end
    if level == "T" then return not mods.noTowers end
    if level == "W" then return not mods.noWalls end
    if level == "L" then return not mods.noLords and not world.sides[sideIndex].producedTitan end
    if mods.noFliers and gamedata.hasTag(id, "noFliers") then return false end
    if mods.noDragons and gamedata.hasTag(id, "dragon") then return false end
    return n ~= nil and tech > n
end

-- Whether a slot entry (level prefix + code) is offered; `producer` is the building whose list it is.
---@param sideIndex integer
---@param entry {id: string, level: string}
---@param producer string?
---@return boolean
function Eco:slotLegal(sideIndex, entry, producer)
    if not self:levelOk(sideIndex, producer or entry.id, entry.level) then return false end
    local k = entry.id:sub(1, 1)
    if k == "P" or k == "R" then return require("src.game.powerups").exists(entry.id) end
    return k == "A" or k == "B"
end

-- Army limit -------------------------------------------------------------------

-- Keep level of a side: 0 without a keep, otherwise 1 + the keep's upgrade digit (the keep-level routine FUN_005325d0).
---@param sideIndex integer
---@return integer
function Eco:keepLevel(sideIndex)
    local level = 0
    for _, b in ipairs(self.world.buildings) do
        if b.side == sideIndex and b.hp > 0 and b.complete and M.isKeep(b.code) then
            level = math.max(level, levelDigit(b.code) + 1)
        end
    end
    return level
end

---@param sideIndex integer
---@return number current, number max
function Eco:armyLimit(sideIndex)
    local sum, keepLevel = 0, nil
    for _, b in ipairs(self.world.buildings) do
        if b.side == sideIndex and b.hp > 0 and b.complete then
            local info = rules.building(b.code)
            if info then sum = sum + info.armyLimit end
            if M.isKeep(b.code) then keepLevel = math.max(keepLevel or 0, levelDigit(b.code) + 1) end
        end
    end
    local hero = self:heroAlive(sideIndex)
    -- the hero adds half of its morale (the hero's army limit addition)
    local command = hero and (hero.h and math.floor(hero.h:getMorale() / 2) or 2) or 0
    -- a living Knight Lord adds 2, a Warlord 1 (the hero's army limit addition FUN_005269a0)
    if hero then command = command + require("src.game.unitspecials").armyLimitBonus(self.world, sideIndex) end
    local max = sum + command + KEEP_AMOUNT[keepLevel or 0] - 2
    local side = self.world.sides[sideIndex]
    -- Horde and Supply power-ups
    local pu = require("src.game.powerups")
    max = max + HORDE_AMOUNT[pu.level(side, "PHD0")] + HORDE_AMOUNT[pu.level(side, "PSY0")]
    if side.ai then max = max + 2 * (side.aiLevel or 2) end
    local cur = 0
    for _, u in ipairs(self.world.units) do
        if u.side == sideIndex and u:alive() and not u.hero then
            cur = cur + math.max(1, u.type and u.type.unitValue or 1)
        end
    end
    return cur, math.min(250, max)
end

-- The army-limit check (binary FUN_005776c0, checked in the 1.04 binary): whether
-- one more army of type `code` (nothing: a unit value of 1, the Call the Dead check) fits under the side's army limit, i.e.
-- not (limit maximum < current + the type's unit value). Only the first army counts, however many a spell then makes. When it
-- does not fit and the side is the local player's, the announcer says "too many men" at once (the forced system speech resets
-- the "limit changed" memory first), raised as the "toomanymen" event with `forced`. Used by every summon spell and by the
-- summoning buttons of the troops. The neutral side is not checked: the limit arrays of the original for it are not known.
---@param sideIndex integer
---@param code string?
---@return boolean
function Eco:roomFor(sideIndex, code)
    if sideIndex >= 6 then return true end
    local value = 1
    if code then
        local t = gamedata.army(code)
        if not t then return false end
        value = t.unitValue or 0
    end
    local cur, max = self:armyLimit(sideIndex)
    if max < cur + value then
        self.world:event("toomanymen", sideIndex, true)
        return false
    end
    return true
end

-- Production -------------------------------------------------------------------

---@param b Building
---@return string[]
function Eco:productionList(b)
    local side = self.world.sides[b.side]
    if not side or b.side == 6 then return {} end
    local out = {}
    -- a keep brings a fallen hero back
    -- (openwbc3's own opt-in rule; the hero comes back as the player's chosen avatar, not the race's default unit)
    if self.world.resurrect and M.isKeep(b.code) and not self:heroAlive(b.side) and M.HERO[side.race] then
        out[1] = self.world:heroCode(b.side)
    end
    for _, entry in ipairs(rules.produces(side.race, b.code)) do
        if self:slotLegal(b.side, entry, b.code) then out[#out + 1] = entry.id end
    end
    return out
end

-- The buildings a builder of this side may construct (the builder's build actions 0x00525a70: major buildings and walls
-- through the level check FUN_0040c990).
-- `row` picks the list of the Build button (0, the major buildings) or of the Build Wall button
-- (1, the tower, the three wall pieces and the rampart); without it both rows (what a builder may build).
---@param sideIndex integer
---@param row integer?
---@return string[]
function Eco:constructionList(sideIndex, row)
    local out = {}
    for _, e in ipairs(rules.buildList(self.world.sides[sideIndex].race)) do
        if (row == nil or e.row == row) and e.id:sub(1, 1) == "B" and not M.isMine(e.id)
            and self:levelOk(sideIndex, e.id, e.level) then
            out[#out + 1] = e.id
        end
    end
    return out
end

---@param b Building
---@param code string
---@param count integer?
function Eco:enqueue(b, code, count)
    if require("src.game.victory").get(self.world.victoryRule, "pitched") or b.convert then return end     -- a converting keep produces nothing
    if require("src.game.powerups").isPowerup(code) then
        -- a power-up is bought once: not when owned, researched or already queued here (the research and mercenary
        -- ones are never owned, they can be queued again and again)
        local pu = require("src.game.powerups")
        if not pu.offered(self.world.sides[b.side], code) then return end
        if not pu.isOneShot(code) then
            if b.current and b.current.code == code then return end
            for _, q in ipairs(b.queue) do if q == code then return end end
        end
        count = 1
    end
    for _ = 1, count or 1 do
        if #b.queue < 20 then b.queue[#b.queue + 1] = code end
    end
end

-- Stopping production (FUN_0052d7e0 of the 1.04 binary): the whole queue goes and the running item's cost comes back.
---@param b Building
function Eco:stopProduction(b)
    if b.current then self:pay(b.side, b.current.cost, 1) end
    b.current, b.waiting, b.queue = nil, nil, {}
end

---@param b Building
function Eco:cancel(b)
    if b.convert then self:stopKeepConversion(b) end        -- the Stop button (0x004d0aa0) stops a conversion too
    if b.current then
        self:pay(b.side, b.current.cost, 1)
        b.current = nil
    elseif #b.queue > 0 then
        table.remove(b.queue)
    end
end

-- Spawn point below the building's footprint, then the nearest free cell.
---@param b Building
---@param code string
---@return Unit?
function Eco:spawnNear(b, code)
    local world = self.world
    local shape = b.shape or { w = 1, h = 1 }
    local gx = b.gx
    local gy = b.gy + math.max(1, shape.h)
    local u = world:addUnit(code, b.side, gx, gy)
    if u then
        local xp = self:initialXp(b.side, code)
        if xp > 0 then u:addXp(xp) end
        local more = u.hero and 0 or self:runeHits(b.side, code, u.maxHp)
        if more > 0 then u.maxHp, u.hp = u.maxHp + more, u.hp + more end
        u.attitude = b.attitude
    end
    if u and b.rally then u:orderMove(b.rally[1], b.rally[2]) end
    return u
end

-- Resource gifts (diplomacy dialog, Alt+D; the send routine FUN_00559690, amounts at 0x00614e68):
-- 50 to 500 of one resource to any other side still in the game. The giver pays the amount; the receiver gains it
-- up to the keep cap.

---@param from integer
---@param to integer
---@param resource string
---@param amount number
---@return boolean
function Eco:gift(from, to, resource, amount)
    local world = self.world
    local a, b = world.sides[from], world.sides[to]
    if not a or not b or from == to or to > 5 or not b.used or b.defeated or a.defeated then return false end
    if not resource or not amount or amount <= 0 or a[resource] < amount then return false end
    a[resource] = a[resource] - amount
    b[resource] = math.min(math.max(b[resource], self:cap(to)), b[resource] + amount)
    return true
end

-- Trade (market): `amount` of one resource becomes rate % of it in another (FUN_00573750 / FUN_005735e0 of
-- the original's market dialog): limited by what the side has and by what the keep cap leaves room for.
---@param sideIndex integer
---@param from integer index of M.GIFT_RESOURCES
---@param to integer
---@param amount number
---@param rate number percent
---@return boolean
function Eco:trade(sideIndex, from, to, amount, rate)
    local s = self.world.sides[sideIndex]
    local src, dst = M.GIFT_RESOURCES[from], M.GIFT_RESOURCES[to]
    if not s or not src or not dst or src == dst or amount <= 0 or rate <= 0 then return false end
    amount = math.min(amount, s[src])
    local gained = math.floor(amount * rate / 100)
    local room = self:cap(sideIndex) - s[dst]
    if gained > room then
        gained = math.max(0, room)
        amount = math.floor(100 * gained / rate)
    end
    if amount <= 0 then return false end
    s[src] = s[src] - amount
    s[dst] = s[dst] + gained
    return true
end

-- Repairs. Verified against the 1.04 binary (cost FUN_0056cb60, start FUN_0052eb10, progress FUN_0052ebc0, Repair
-- button FUN_004d2300): slow repair costs missing% * build cost / 200 per resource (at least 5 of each resource
-- the building costs) and takes 90 s, fast costs twice as much and takes 45 s; hits come back in proportion to the
-- elapsed time and the cost is paid up front. Orcs cannot repair. The Masonry power-up halves the cost.
M.ORC = 5
M.REPAIR_SECONDS = setting("eco.repairSeconds")

---@param b Building
---@return boolean
function Eco:canRepair(b)
    return b.complete and b.hp > 0 and b.hp < b.maxHp and not b.pillaged and b.side ~= 6
        and self.world.sides[b.side].race ~= M.ORC
end

-- Cost of repairing the whole damage: slow, fast (resource tables).
---@param b Building
---@return table<string, number> slow, table<string, number> fast
function Eco:repairCost(b)
    local t = gamedata.building(b.code)
    local base = t and t.cost or {}
    local pct = 100 - math.floor(math.floor(b.hp) * 100 / b.maxHp)
    local slow, fast = {}, {}
    for _, r in ipairs(M.RESOURCES) do
        local c = base[r] or 0
        local v = math.floor(pct * c / 200)
        if c > 0 then v = math.max(5, v) end
        slow[r], fast[r] = v, v * 2
    end
    if require("src.game.powerups").has(self.world.sides[b.side], "PMAS") then
        -- Masonry halves the repair costs
        for _, r in ipairs(M.RESOURCES) do slow[r], fast[r] = math.floor(slow[r] / 2), math.floor(fast[r] / 2) end
    end
    return slow, fast
end

-- Starts a repair (0 slow, 1 fast); returns false when it is not possible.
---@param b Building
---@param speed integer 0 slow, 1 fast
---@return boolean
function Eco:repair(b, speed)
    if b.repair or not self:canRepair(b) then return false end
    speed = speed == 1 and 1 or 0
    local cost = select(speed + 1, self:repairCost(b))
    local side = self.world.sides[b.side]
    for _, r in ipairs(M.RESOURCES) do
        if cost[r] > side[r] then return false end
    end
    for _, r in ipairs(M.RESOURCES) do
        side[r] = side[r] - cost[r]
        self.world:battleStats():resource(b.side, r, cost[r], "spent")
    end
    local t = self.world.time
    b.repair = { t0 = t, t1 = t + M.REPAIR_SECONDS[speed] * 1000, total = math.ceil(b.maxHp - b.hp), done = 0,
                 speed = speed }
    return true
end

---@param b Building
---@param t number
function Eco:updateRepair(b, t)
    local r = b.repair
    ---@cast r -nil
    if b.hp >= b.maxHp then b.repair = nil return end
    local pct = math.min(100, math.floor(100 * (t - r.t0) / (r.t1 - r.t0)))
    local hits = math.floor(pct * r.total / 100)
    b.hp = math.min(b.maxHp, b.hp + hits - r.done)
    r.done, r.pct = hits, pct
    if pct >= 100 or b.hp >= b.maxHp then b.repair = nil end
end

---@param b Building
---@param t number
function Eco:updateBuilding(b, t)
    if b.hp <= 0 then b.repair, b.convert = nil, nil return end
    local world = self.world
    if b.repair then self:updateRepair(b, t) end
    if b.convert then self:updateKeepConversion(b, t) end
    if not b.complete then
        local s = b.site
        ---@cast s -nil
        local p = (t - s.t0) / (s.t1 - s.t0)
        -- Like the original: hp grows with construction progress, damage taken meanwhile sticks
        -- (also through completion, the building is not healed to full when it finishes).
        local last = s.p or math.min(1, b.hp / b.maxHp)
        local np = math.min(1, p)
        b.hp = math.min(b.maxHp, b.hp + b.maxHp * math.max(0, np - last))
        s.p = np
        if p >= 1 then
            b.complete = true
            b.site = nil
            if s.builder then
                local u = s.builder
                ---@cast u -nil
                local fx, fy = world:nearestFree(b.gx, b.gy + math.max(1, (b.shape and b.shape.h or 1)), u.move, 8)
                ---@cast fy -nil
                if fx then u:reappear(fx, fy) end
            end
            world:event("built", b, s.builder)
        end
        return
    end
    if b.current then
        if t >= b.current.t1 then
            local code = b.current.code
            if code:sub(1, 1) == "A" then
                local cur, max = self:armyLimit(b.side)
                local t0 = gamedata.army(code)
                if cur + math.max(1, t0 and t0.unitValue or 1) > max then       -- wait for room
                    -- the first time it is stuck the side hears "too many men" (not traced in the 1.04 binary yet)
                    if not b.current.full then
                        b.current.full = true
                        world:event("toomanymen", b.side)
                    end
                    return
                end
                local u = self:spawnNear(b, code)
                -- a resurrected player hero speaks with its voice set again (the start hero gets this in World)
                if u and u.hero and b.side == world.player and world.opts.profile then world:applyProfileHero(u) end
                if u then world:event("produced", u) end
                -- continuous army production (the building tick at 0x0052cb04: a finished production goes
                -- back to the rear of the queue; the original skips titans (codes _T_X - here the
                -- Army.cfg STATUS titan flag) and the hero general, and re-adds only while the
                -- army's own requirements are still met, FUN_0040b580 - openwbc3 checks the building's list)
                if b.continuous then
                    local titan = gamedata.hasTag(code, "titan")
                    if not self:isHeroCode(b.side, code) and not titan then
                        for _, c in ipairs(self:productionList(b)) do
                            if c == code then b.queue[#b.queue + 1] = code break end
                        end
                    end
                end
            elseif code:sub(1, 1) == "B" then
                self:upgradeBuilding(b, code)
            elseif require("src.game.powerups").isPowerup(code) then
                require("src.game.powerups").grant(world, b.side, code, b)
            end
            b.current = nil
        end
        return
    end
    local code = b.queue[1]
    if code then
        local info = self:itemInfo(code, b.side)
        if not info then
            table.remove(b.queue, 1)
            return
        end
        if self:canAfford(b.side, info.cost) then
            table.remove(b.queue, 1)
            self:pay(b.side, info.cost)
            b.current = { code = code, t0 = t, t1 = t + info.time, cost = info.cost, name = info.name }
            b.waiting = nil
        else
            -- the original freezes the queue when the head cannot be afforded (the production start
            -- FUN_0052e1d0 sets the running id to -1, waiting); the order stays
            -- queued and the panel shows an animated selection ring in the first slot instead of an icon
            b.waiting = true
        end
    end
end

---@param b Building
---@param code string
function Eco:upgradeBuilding(b, code)
    local t = gamedata.building(code)
    b.code = code
    b.type = t or b.type
    b.set = require("src.gfx.anims").get(code) or b.set
    b.maxHp = b.maxHp + 100
    b.hp = b.hp + 100
    b.name = (rules.building(code) and rules.building(code).name) or b.name
    self.world:event("upgraded", b)
end

-- Construction -------------------------------------------------------------------

-- Placement: clicked cell is the top row of the centred footprint; all cells
-- level, dry, passable and free.
---@param code string
---@param gx integer
---@param gy integer
---@param sideIndex integer?
---@param useFog boolean?
---@return boolean
function Eco:canPlace(code, gx, gy, sideIndex, useFog)
    local world = self.world
    local t = gamedata.building(code)
    if not t then return false end
    local terrain = world.terrain
    local h0
    for _, c in ipairs(world:shapeCells(gx, gy, t.shape)) do
        local x, y = c[1], c[2]
        if not world:free(x, y, 0) then return false end
        local ter, hgt = terrain:cell(x, y)
        if ter == 3 or ter == 5 or ter == 6 or ter == 7 or ter == 9 then return false end
        h0 = h0 or hgt
        if hgt ~= h0 then return false end
        if useFog and world.fog and sideIndex == world.player and not world.fog:isExplored(x, y) then return false end
    end
    return true
end

-- Starts a construction site; the builder disappears inside until it is done.
---@param builder Unit
---@param code string
---@param gx integer
---@param gy integer
---@param t number
---@return boolean ok, string? why, string? short
function Eco:startConstruction(builder, code, gx, gy, t)
    local world = self.world
    if require("src.game.victory").get(world.victoryRule, "pitched") then return false, "place" end
    if not M.isMine(code) then
        local allowed = false
        for _, c in ipairs(self:constructionList(builder.side)) do allowed = allowed or c == code end
        if not allowed then return false, "place" end
    end
    local info = self:itemInfo(code, builder.side)
    if not info then return false end
    if not self:canPlace(code, gx, gy, builder.side) then return false, "place" end
    if not self:canAfford(builder.side, info.cost) then
        return false, "cost", self:shortOf(builder.side, info.cost)
    end
    self:pay(builder.side, info.cost)
    local b = world:addBuilding({ code = code, side = builder.side, x = gx * 32 + 16, y = gy * 24 + 12, anim = 0, dir = 0,
                                  frame = 0 })
    b.complete = false
    -- Engineering: new structures get 25 % more hits
    -- Engineer: the building gets the skill's effect in extra hits first (building creation, binary FUN_0043bd50), then Engineering
    -- adds a quarter
    b.maxHp = b.maxHp + require("src.game.heroskills").value(world, builder.side, require("src.game.heroskills").ids.Engineer)
    if require("src.game.powerups").has(world.sides[builder.side], "PENG") then b.maxHp = math.floor(b.maxHp * 5 / 4) end
    b.hp = 1
    -- the builder's build skill speeds construction up or down (the cost routine FUN_0040b6b0: time -= ((skill-10)*time)/10,
    -- the skill from the type's BUILDING power; the Zombie Feast's +4 is not part of it, the original reads the record)
    local powerups = require("src.game.powerups")
    local time = info.time or 0
    local skill = powerups.rawBuildSkill(builder)
    if skill > 0 then
        local d = (skill - 10) * time
        time = time - (d >= 0 and math.floor(d / 10) or math.ceil(d / 10))
    end
    -- Construction: a Chameleon's own building actions take half the time (the builder's build actions 0x00525a70)
    if builder.code == "ALBX" and powerups.has(world.sides[builder.side], "PCON") then time = math.floor(time / 2) end
    b.site = { t0 = t, t1 = t + time, builder = builder }
    self:initBuilding(b)
    b.complete = false
    builder:vanish()
    return true
end

-- Garrisons ----------------------------------------------------------------------
-- Garrisonable buildings (Building.cfg garrison column: the towers) hold 4 units,
-- heroes counting like any other (the garrison test FUN_0052db10 and entry FUN_0052db50). Units inside heal at twice
-- their normal rate (Eco:healGarrison). The garrison changes the tower's statistics as in the building's damage 0x0052e9e0,
-- combat FUN_0052ae70 and speed FUN_0052b0c0: see Eco:garrisonBonus.

---@param b Building
---@return integer
function Eco:garrisonCap(b)
    if not b.complete or b.hp <= 0 or b.pillaged then return 0 end
    local info = rules.building(b.code)
    return (info and (info.garrison or 0) > 0) and 4 or 0
end

-- Statistic bonuses a garrison gives its building (the building's damage 0x0052e9e0, combat FUN_0052ae70, speed FUN_0052b0c0):
-- hero: damage +20, range +2, combat +6, speed +2; archer (missile unit): damage +10 (advanced unit +20), range +1;
-- other unit: combat +3 (advanced +6; +4 / +7 for computer players), speed +1 (advanced +2).
---@param b Building
---@return number damage, number range, number combat, number speed
function Eco:garrisonBonus(b)
    local dmg, range, combat, speed = 0, 0, 0, 0
    local powerups = require("src.game.powerups")
    local bit = require("bit")
    for _, u in ipairs(b.garrison or {}) do
        local f = powerups.flags(u.code)
        local advanced = bit.band(f, 0x8000) ~= 0
        if u.hero then
            dmg, range, combat, speed = dmg + 20, range + 2, combat + 6, speed + 2
        elseif bit.band(f, 0x40000) ~= 0 then
            dmg, range = dmg + (advanced and 20 or 10), range + 1
        else
            local ai = self.world.sides[u.side].ai
            combat = combat + (advanced and (ai and 7 or 6) or (ai and 4 or 3))
            speed = speed + (advanced and 2 or 1)
        end
    end
    return dmg, range, combat, speed
end

-- Combat bonus of a computer player's buildings by AI level (the building's combat value, binary
-- FUN_0052ae70 asked for the real value, checked: Knave -2, Lord +1, Prince +2, Warlord +3, Emperor +5; Passive, Knight,
-- Rampant and anything else 0). Only for computer sides, only in the real value; the base value and a
-- human's buildings never get it. The army's combat value (FUN_0051bd10) has no such bonus.
local AI_BUILDING_COMBAT = { [1] = -2, [3] = 1, [4] = 2, [5] = 3, [6] = 5 }

---@param side integer
---@return number
function Eco:aiBuildingCombat(side)
    local s = self.world.sides[side]
    return s and s.ai and AI_BUILDING_COMBAT[s.aiLevel or 0] or 0
end

-- The combat a building fights with, as an attacker (tower shots, FUN_0052d2f0) and as a target (FUN_0042ace0 melee
-- resolution): the real combat value (FUN_0052ae70) = type record + computer-player level + garrison.
---@param b Building
---@return number
function Eco:buildingCombat(b)
    local _, _, gCombat = self:garrisonBonus(b)
    return ((b.type and b.type.combat) or 8) + self:aiBuildingCombat(b.side) + gCombat
end

-- The statistics of an armed building for the info area: `base` (type record, the getters asked for the base value) and `real`
-- (with the garrison and, for combat, the computer-player level: FUN_0052ae70 / FUN_0052b0c0 /
-- 0x0052e9e0; the info area shows both through the stat formatter FUN_004ddeb0). The garrison's damage type is that
-- of its missile unit with the highest base combat.
---@param b Building
---@return table base, table real
function Eco:buildingStats(b)
    local bt = b.type or {}
    local dmg, range, combat, speed = self:garrisonBonus(b)
    combat = combat + self:aiBuildingCombat(b.side)
    local base = { combat = bt.combat or 8, speed = bt.speed or 0, damage = bt.damage or 0, range = bt.range or 0,
                   damageType = bt.damageType or 0 }
    local real = { combat = base.combat + combat, speed = base.speed + speed, damage = base.damage + dmg,
                   range = base.range + range, damageType = base.damageType }
    local best, bestCombat
    for _, u in ipairs(b.garrison or {}) do
        if require("bit").band(require("src.game.powerups").flags(u.code), 0x40000) ~= 0 then
            local c = u:baseStats().combat
            if not bestCombat or c > bestCombat then best, bestCombat = u, c end
        end
    end
    if best then
        local st = best:stats()
        real.damageType = st.hot and 3 or st.damageType
    end
    return base, real
end

-- The original's interval between tower shots (ms) by building speed, capped at 16 (table at 0x006114bc, read by
-- FUN_0052b150).

---@param b Building
---@return integer
function Eco:garrisoned(b) return b.garrison and #b.garrison or 0 end

---@param u Unit
---@param b Building
---@return boolean
function Eco:canGarrison(u, b)
    return b.kind == "building" and b.side == u.side and self:garrisonCap(b) > self:garrisoned(b)
        and u:canGarrison()
end

---@param u Unit
---@param b Building
---@return boolean
function Eco:enterGarrison(u, b)
    if not self:canGarrison(u, b) then return false end
    b.garrison = b.garrison or {}
    b.garrison[#b.garrison + 1] = u
    u.garrisoned = b
    u:vanish()
    self.world:event("garrison", u, b)
    return true
end

-- Lets the garrison out below the building (all of it, or just `unit`).
---@param b Building
---@param unit Unit? only this one
function Eco:unload(b, unit)
    local list = b.garrison
    if not list or #list == 0 then return end
    local world = self.world
    local shape = b.shape or { w = 1, h = 1 }
    for i = #list, 1, -1 do
        local u = list[i]
        if not unit or unit == u then
            table.remove(list, i)
            u.garrisoned = nil
            if u.state ~= "dead" then
                local x, y = world:nearestFree(b.gx, b.gy + math.max(1, shape.h), u.move, 8)
                if x then
                    ---@cast y -nil
                    u:reappear(x, y)
                    if b.rally then u:orderMove(b.rally[1], b.rally[2]) end
                end
            end
        end
    end
end

-- The garrison regenerates as it does outside, with the interval halved (the regeneration tick, 1.04 binary FUN_0051b820 reads
-- the in-tower flag +0x1c5 and shifts the interval of FUN_0051b460 right by one): the same rate for a
-- troop - level, Healing power-ups, the hero's Regeneration skill, Troll, undead by night, not while poisoned or diseased -
-- and the hero's own rate, twice as fast. The units are hidden in there, so their update does not run; this calls it.
---@param b Building
---@param t number
function Eco:healGarrison(b, t)
    local list = b.garrison
    if not list or #list == 0 then return end
    for _, u in ipairs(list) do
        if u.h then
            u.h:tick(t, true)
        elseif u.state ~= "dead" then
            u:regenerate(t, true)
        end
    end
end

-- Mines --------------------------------------------------------------------------

---@param u Unit
---@param b Building
---@return boolean
function Eco:enterMine(u, b)
    if not b.mine or b.side ~= u.side or b.hp <= 0 then return false end
    -- the mine-work check FUN_00523e70: only a builder works a mine, and the Dwarf Smith / Engineer take two of the eight places
    local value = u:canWorkInMine()
    if value == 0 or b.mine.workers >= 8 then return false end
    b.mine.workers = math.min(8, b.mine.workers + value)
    u:vanish(true)
    return true
end

---@param t number
function Eco:income(t)
    local world = self.world
    local gain = {}
    for i = 0, 6 do gain[i] = { gold = 0, metal = 0, crystal = 0, stone = 0 } end
    for _, b in ipairs(world.buildings) do
        local m = b.mine
        if m and b.hp > 0 and b.side ~= 6 and b.complete and not b.pillaged then
            local side = world.sides[b.side]
            local workers = m.workers
            local race = content.race:bySlot(side.race)
            if race and race.flags and race.flags.halvesMineWorkers then workers = math.floor(workers / 2) end
            local inc
            if m.reserve <= 0 then inc = 2 else inc = 2 * m.produce + workers end
            if m.reserve > 0 then
                local pu = require("src.game.powerups")
                inc = inc + INCOME_AMOUNT[pu.level(side, "PIB0")] + INCOME_AMOUNT[pu.level(side, "PHL0")]
            end
            gain[b.side][m.resource] = gain[b.side][m.resource] + inc
            if m.reserve > 0 and world.sides[b.side][m.resource] < self:cap(b.side) then
                m.reserve = math.max(0, m.reserve - inc)
            end
        end
    end
    -- Every Ancient Wisp brings 4 crystal and every Leprechaun 2 gold with each income, whatever the multiplier (the
    -- army income routine 0x005299d0, army vtable slot +0x34 called from FUN_00531f10); wisps and leprechauns do not
    -- work in mines (the mine-work check FUN_00523e70 gives 0).
    for _, u in ipairs(world.units) do
        if (u.code == "AEAX" or u.code == "AFNX") and u.side < 6 and (u:alive() or (u.garrisoned and u.state ~= "dead")) then
            local r, n = "gold", 2
            if u.code == "AEAX" then r, n = "crystal", 4 end
            gain[u.side][r] = gain[u.side][r] + n
        end
    end
    local skills = require("src.game.heroskills")
    local ids = skills.ids
    for i = 0, 5 do
        local s = world.sides[i]
        if s.used and not s.defeated then
            -- Wealth / Quarrying / Smelting / Gemcutting: the hero's side gains that much more with every income
            -- (the side income FUN_00531f10; the effect is read through the side's skill level FUN_00556b50, so only
            -- while the hero lives)
            gain[i].gold = gain[i].gold + skills.value(world, i, ids.Wealth)
            gain[i].stone = gain[i].stone + skills.value(world, i, ids.Quarrying)
            gain[i].metal = gain[i].metal + skills.value(world, i, ids.Smelting)
            gain[i].crystal = gain[i].crystal + skills.value(world, i, ids.Gemcutting)
            local cap = self:cap(i)
            for _, r in ipairs(M.RESOURCES) do
                local before = s[r]
                s[r] = math.min(cap, s[r] + gain[i][r])
                world:battleStats():resource(i, r, s[r] - before, "obtained")
            end
        end
    end
end

-- Conversion -----------------------------------------------------------------------

---@param u Unit
function Eco:canConvert(u)
    return u.hero or (rules.armyInfo(u.code) or {}).general
end

-- Whether a building can be taken over at all: the conversion test FUN_0052da90 (code letters, finished, not
-- pillaged, no garrison).
---@param b Building
---@return boolean
function Eco:canBeConverted(b)
    if b.hp <= 0 then return false end
    -- the flag BMFL is always convertible: FUN_0052da90 returns at once for it, before its finished / hit point /
    -- pillage / garrison tests and in any game, not only Capture the Flag (a destroyed flag is not on the map)
    if gamedata.hasTag(b.code, "flag") then return true end
    return b.complete and M.convertible(b.code) and not b.pillaged
        -- a garrison that already holds units can't be converted (FUN_0052da90:
        -- garrisonable, FUN_0052db10, and a garrison count above 0)
        and not (self:garrisonCap(b) > 0 and self:garrisoned(b) > 0)
end

-- Whose buildings a converter of `side` may take (the side test of the conversion list,
-- binary FUN_005489e0): not its own, the neutral side's always, an enemy's, and an ally's only when the converter is
-- not a computer side (the alliance matrix test `!alliance || !isAI`).
---@param side integer
---@param b Building
---@return boolean
function Eco:convertibleBy(side, b)
    if b.side == side then return false end
    if b.side == 6 then return true end
    local world = self.world
    if world:enemies(side, b.side) then return true end
    return not world.sides[side].ai
end

-- Buildings a converting unit takes over: the original asks the conversion list (binary FUN_005489e0) for the unit's own
-- cell and range both when the conversion starts (the army's conversion FUN_0051cbb0; none: "nothing here to convert")
-- and when it ends (the order's removal, FUN_00520c90 -> the circle conversion FUN_00532640), so the list is the circle of
-- `conversionList` (nearest point of the footprint within the range, at most 8, rows from the bottom up). `minesOnly`
-- (the conversion spell, FUN_005758b0) keeps the resource producers.
---@param u Unit
---@param range number?
---@param minesOnly boolean?
---@return Building[]
function Eco:conversionTargets(u, range, minesOnly)
    return self:conversionList(u.side, u.gx, u.gy, range or u:conversionRange(), minesOnly)
end

-- Keep conversion (binary FUN_0052f9b0): a keep takes over every convertible building of
-- the other sides in a circle around it (28 cells and 150 s, a computer side's 32 cells and 120 s), the list being
-- fixed when the conversion ends (FUN_00532640).
M.KEEP_CONVERT = setting("eco.keepConvert")
M.CONVERSION_LIST_MAX = setting("eco.conversionListMax")          -- 8: what FUN_00532640 asks for

-- The conversion list (binary FUN_005489e0; keeps, armies and the conversion spell alike): the convertible buildings of
-- other sides whose nearest point is within `range` of (px, py) - Euclidean, from the point of the footprint closest to
-- it - at most 8, taken row by row from the bottom of the circle upwards and from left to right within a row (the
-- display item rows).
---@param side integer
---@param px integer
---@param py integer
---@param range number
---@param minesOnly boolean?
---@return Building[]
function Eco:conversionList(side, px, py, range, minesOnly)
    local found = {}
    for k, b in ipairs(self.world.buildings) do
        if b.side ~= side and b.shape and self:convertibleBy(side, b) and self:canBeConverted(b)
            and (not minesOnly or b.mine)
            and b.gy >= py - range - 16 and b.gy <= py + range and b.gx >= px - range - 8 and b.gx <= px + range + 8 then
            local w, h = b.shape.w, b.shape.h
            local ex, ey
            if b.gx < px then ex = math.min(px, b.gx + math.floor(w / 2)) else ex = math.max(px, b.gx - math.floor(w / 2)) end
            if b.gy < py then ey = math.min(py, b.gy + h) else ey = b.gy end
            if (px - ex) ^ 2 + (py - ey) ^ 2 <= range * range then found[#found + 1] = { b = b, k = k } end
        end
    end
    table.sort(found, function(a, c)
        if a.b.gy ~= c.b.gy then return a.b.gy > c.b.gy end
        if a.b.gx ~= c.b.gx then return a.b.gx < c.b.gx end
        return a.k < c.k
    end)
    local out = {}
    for i = 1, math.min(#found, M.CONVERSION_LIST_MAX) do out[i] = found[i].b end
    return out
end

-- The Convert button of an own keep (and the computer's keep conversions, FUN_004fbb90). Fails when the keep is not
-- finished, is producing (FUN_0052e750: the button is greyed out then) or is converting already; with nothing to
-- convert in range the owner is told ("nothing here to convert").
---@param b Building
---@return boolean
function Eco:startKeepConversion(b)
    if not (M.isKeep(b.code) and b.complete and b.hp > 0 and b.side < 6 and not b.convert and not b.pillaged) then
        return false
    end
    if b.current or b.waiting or #b.queue > 0 then return false end
    local world = self.world
    local k = M.KEEP_CONVERT
    local ai = world.sides[b.side].ai
    local range, seconds = ai and k.aiRange or k.range, ai and k.aiSeconds or k.seconds
    if #self:conversionList(b.side, b.gx, b.gy, range) == 0 then
        world:event("noconversions", b)
        return false
    end
    local t = world.time
    b.convert = { t0 = t, t1 = t + seconds * 1000, range = range, hp = b.hp }
    world:event("keepconverting", b)
    return true
end

---@param b Building
function Eco:stopKeepConversion(b)
    b.convert = nil
end

-- A keep's conversion runs on: damage stops it (the building's hit reaction FUN_0052b180), at the end every
-- building in the circle changes sides.
---@param b Building
---@param t number
function Eco:updateKeepConversion(b, t)
    local c = b.convert
    ---@cast c -nil
    if b.hp < c.hp then
        b.convert = nil
        return
    end
    c.hp = b.hp
    if t < c.t1 then return end
    b.convert = nil
    local list = self:conversionList(b.side, b.gx, b.gy, c.range)
    for _, o in ipairs(list) do self:setOwner(o, b.side) end
    self.world:event("keepconverted", b, #list)
end

-- Progress of a keep's own conversion in percent (FUN_0052fc00: 1..100, 0 when it is not converting).
---@param b Building
---@return integer
function Eco:keepConversionPercent(b)
    local c = b.convert
    if not c then return 0 end
    local p = math.floor(100 * (self.world.time - c.t0) / math.max(1, c.t1 - c.t0))
    return math.max(1, math.min(100, p))
end

---@param b Building
---@param sideIndex integer
function Eco:setOwner(b, sideIndex)
    self:unload(b)
    local old = b.side
    b.side = sideIndex
    b.queue = {}
    b.current = nil
    b.rally = nil
    b.continuous = nil
    b.convert = nil                 -- the owner-change message FUN_004a6cc0 cancels the building's own conversion
    if b.mine then b.mine.workers = 0 end
    self.world:event("converted", b, nil, old)
end

-- Victory ---------------------------------------------------------------------------

-- Whether side i is still in the game under a victory rule (what keeps a side alive differs per rule).
---@param i integer
---@param rule string|integer|nil
---@return boolean
function Eco:sideAlive(i, rule)
    local world = self.world
    local s = world.sides[i]
    if s.resigned then return false end
    -- the countdown modes defeat nobody until the clock has run out; razefest / slugfest are decided at the end
    local Victory = require("src.game.victory")
    if world.victoryEnd and Victory.timed(rule) and (Victory.get(rule, "decidedAtEnd") or not Victory.timerDone(world)) then
        return true
    end
    return Victory.sideAlive(world, i, rule)
end

-- A side gives up: it counts as defeated at the next victory check. Its armies and buildings turn neutral
-- (binary FUN_00534340: every army changes owner, every standing building changes owner,
-- destroyed ones are removed); this is what both a resigning player (option "Resignation kills a side") and a
-- resigning computer side (option "AI can resign") do.
---@param i integer
function Eco:resign(i)
    local s = self.world.sides[i]
    if not (s and s.used) or s.resigned then return end
    s.resigned = true
    self:neutralize(i)
end

---@param i integer
function Eco:neutralize(i)
    local world = self.world
    for _, u in ipairs(world.units) do
        if u.side == i and u.state ~= "dead" then
            u:stop()
            u.side = 6
        end
    end
    for _, b in ipairs(world.buildings) do
        if b.side == i and b.hp > 0 then
            self:unload(b)
            b.side = 6
            b.queue, b.current, b.rally, b.continuous = {}, nil, nil, nil
            if b.mine then b.mine.workers = 0 end
        end
    end
end

function Eco:checkVictory()
    local world = self.world
    if world.events and world.events:pendingSpawns() and world.time < 60000 then return end
    local function defeat(i)
        local s = world.sides[i]
        s.defeated = true
        for _, b in ipairs(world.buildings) do
            if b.side == i then
                if b.type and b.type.damage and b.type.damage > 0 and not M.isMine(b.code) then
                    b.hp = 0
                    b.destroyed = true
                else
                    b.side = 6
                end
            end
        end
        world:event("defeated", i)
    end
    for i = 0, 5 do
        local s = world.sides[i]
        if s.used and not s.defeated and not self:sideAlive(i, world.victoryRule or "standard") then defeat(i) end
    end
    -- the modes with their own winner: the others are defeated
    local Victory = require("src.game.victory")
    local won = Victory.winners(world)
    if won then
        local keep = {}
        for _, i in ipairs(won) do keep[i] = true end
        for i = 0, 5 do
            local s = world.sides[i]
            if s.used and not s.defeated and not keep[i] then defeat(i) end
        end
        world.winners = won
    end
    -- a finished countdown disappears (razefest / slugfest keep it only while the game is extended)
    if world.clock and world.victoryEnd and world.time >= world.victoryEnd
        and not Victory.get(world.victoryRule, "decidedAtEnd") then
        world.clock = nil
    end
    -- winner: all remaining undefeated sides are allied with each other
    local remaining = {}
    for i = 0, 5 do
        local s = world.sides[i]
        if s.used and not s.defeated then remaining[#remaining + 1] = i end
    end
    local over = true
    for a = 1, #remaining do
        for b = a + 1, #remaining do
            if world:enemies(remaining[a], remaining[b]) then over = false end
        end
    end
    -- scenarios with a scripted victory end through their events (unless the player is out)
    if over and world.scriptedVictory and not (world.sides[world.player] or {}).defeated then over = false end
    if over and not world.over then
        world.over = { winners = remaining }
        world:event("gameover", remaining)
    end
end

-- Towers and other armed buildings. The target is chosen by the tower's own threat search once per attitude slice of its side
-- (attitude.towerThink = the building's threat search FUN_0052d0d0: best-threat scan FUN_005334f0, priority, the fog of a
-- human side, the box threat centre +- range) and kept in `b.target` (the building's target FUN_0052a410, which the threat
-- priority of an enemy tower reads). The shooting is the finished building's update (1.04 binary: the code at 0x0052c4d0 - 0x0052c5b0, which
-- Ghidra has no function for, calls the building's shot FUN_0052d600 and reads +0x7c damage, +0x130 attacking, +0x140 next
-- time, +0x148 interval): with a target, a shot when the clock reaches the next attack time (`b.nextShot`, 0 = first shot
-- at once), the next time being the previous one plus the interval of the real speed (FUN_0052b0c0, table read by
-- FUN_0052b150), or now plus the interval for
-- the first shot. A target that is dead or has changed sides meanwhile (the lookup by id and side fails) costs its shot, a
-- building that produces resources and has been pillaged or is down is no target (the attack decision FUN_0052d2f0).
-- Neutral towers shoot as well (the threat search of the neutral side, except in the tutorial).
---@param b Building
---@param t number
function Eco:buildingAttack(b, t)
    local bt = b.type
    if not bt or b.hp <= 0 then b.target = nil return end
    if (bt.damage or 0) <= 0 then return end
    local world = self.world
    require("src.game.attitude").towerThink(world, b)
    if not b.complete or b.pillaged then return end
    local best = b.target
    if not best then return end
    b.targetSide = b.targetSide or best.side
    if b.nextShot and t < b.nextShot then return end
    local gDmg, gRange, gCombat, gSpeed = self:garrisonBonus(b)
    local interval = ATTACK_INTERVAL[math.min(16, math.max(0, (bt.speed or 0) + gSpeed))]
    b.nextShot = (b.nextShot or t) + interval
    if best.kind == "unit" and not best:alive() or best.kind == "building" and (best.hp <= 0 or best.mine and best.pillaged)
        or best.side ~= b.targetSide then
        return
    end
    local info = rules.building(b.code)
    local missile = info and info.missile
    local missiles = require("src.game.missiles")
    local aiCombat = self:aiBuildingCombat(b.side)
    -- a tower rolls a d100 for every missile against FUN_0052d9b0's chance; a miss lands beside the target (missiles.lua). The
    -- shot's numbers are taken now and kept with the missile (the handler below), as the original sets the damage of
    -- the missile when it makes it.
    missiles.launch(world, {
        code = missile, kind = "tower", shooter = b, side = b.side, target = best,
        crit = false,      -- the tower shot FUN_0052d2f0 rolls no special attack (the army's 4 % is FUN_00523150's)
        -- its one special: the Crystal Tower's missile carries the special attack 5 (+0x67c = 5, +0x67d = 100), crystallize
        p = { combat = (bt.combat or 8) + gCombat + aiCombat, damage = bt.damage + gDmg, dtype = bt.damageType or 0,
              range = bt.range, base = bt.damage, crystal = gamedata.hasTag(b.code, "crystalTower") or nil },
    })
end

local CRYSTALLIZE = { kind = "crystallize", amount = 100 }

-- A tower's missile lands (the missile impact FUN_005427e0): the same damage resolution as the units', with the tower as the
-- attacker; nothing when the tower has fallen meanwhile.
require("src.game.missiles").handlers.tower = function(world, m, victim)
    local b = m.shooter
    if not (b and b.hp > 0) then return end
    local Unit = require("src.game.unit")
    local powerups = require("src.game.powerups")
    local status = require("src.game.status")
    local p = m.p
    if victim.kind == "unit" then
        if not victim:alive() then return end
        -- a poison arrow poisons what it hits (the missile impact FUN_005427e0)
        local strength = powerups.poisonArrow(m.code, p.base or 0)
        if strength > 0 and math.random(100) <= math.max(1, 50 - (victim:resistance() - strength) * 5) then
            status.poison(victim)
        end
    elseif victim.hp <= 0 then
        return
    end
    local fake = setmetatable({ world = world, side = b.side, type = b.type, code = b.code, gx = b.gx, gy = b.gy },
        { __index = Unit })
    function fake:stats()
        return { combat = p.combat, speed = 0, armor = 0, damage = p.damage, damageType = p.dtype, range = p.range,
                 strong = -1, weak = -1, view = 10 }
    end
    -- the Crystal Tower: an army its shot kills is crystallized (impact FUN_005427e0 case 5, the same as the good breath's:
    -- Unit.breathSpecial; no line over a tower)
    if p.crystal then m.attack = CRYSTALLIZE end
    Unit.strike(fake, victim, m)
    if victim.target == fake then victim.target = b end
end

---@param t number world time
function Eco:update(t)
    for _, b in ipairs(self.world.buildings) do
        self:updateBuilding(b, t)
        self:healGarrison(b, t)
        self:buildingAttack(b, t)
    end
    if t >= self.nextIncome then
        self.nextIncome = self.nextIncome + INCOME_TIME
        self:income(t)
    end
    if t >= self.nextVictory then
        self.nextVictory = t + 3000
        self:checkVictory()
    end
end

return M
