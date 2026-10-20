-- Battle world: terrain, sides and all placed objects, simulated on a game
-- clock in milliseconds.
local ffi = require("ffi")
local bit = require("bit")
local terrainMod = require("src.game.terrain")
local gamedata = require("src.game.gamedata")
local anims = require("src.gfx.anims")
local pathMod = require("src.game.path")
local Unit = require("src.game.unit")
local powerups = require("src.game.powerups")
local log = require("src.core.log")

local CW, CH = terrainMod.CELL_W, terrainMod.CELL_H
local ATTR_POINTS_PER_LEVEL = require("src.game.hero").ATTR_POINTS

local M = {}

-- What every object placed on the battle map has: units (unit.lua), buildings (economy.lua), features and chests.
---@class Entity
---@field kind "unit"|"building"|"feature"|"chest"
---@field id integer                world-unique (World:newId); commands and saved games refer to objects by it
---@field code string               the four-letter type code (for a chest the picture's)
---@field set table?                the sprite set (gfx/anims.lua)
---@field x number                  pixel position (the centre of the cell for units)
---@field y number
---@field gx integer                cell position
---@field gy integer
---@field dir integer               facing, 0 = north, clockwise
---@field anim integer?             the animation (formats/sprite.lua ANIM)
---@field frame integer?
---@field phase integer?            random animation offset of buildings and features (display only)

-- A building's or feature's footprint: `w` x `h` cells, bit x of exclusion row y set = cell (x, y) not occupied.
---@class Shape
---@field w integer
---@field h integer
---@field ex table<integer, integer>?
---@field exclusion table<integer, integer>?

-- A map feature (tree, rock ...): blocks its shape's cells unless it can be walked over.
---@class Feature: Entity
---@field kind "feature"
---@field shape Shape?
---@field walkOver boolean?

-- An item (or a resource chest of a scenario) lying on the ground.
---@class Chest: Entity
---@field kind "chest"
---@field item table?               the item record (items.lua)
---@field resource string?          a resource chest: what it holds ...
---@field amount integer?           ... and how much
---@field ignoreFor Unit?           a thrown-away item is not picked up by its owner before it has moved off
---@field dropped boolean?          dropped by a slain lair boss
---@field refused boolean?          a full pack has been reported once

-- A short-lived picture of the battle view (rings, bolts, sprites of spells and events); display only.
---@class WorldEffect
---@field kind string               "ring" | "bolt" | "sprite" ...
---@field t0 number                 start (world time, ms)
---@field dur number                length (ms)
---@field [string] any

-- The battle world: terrain, sides and every object on the map, simulated on a game clock in milliseconds.
-- Fields after `setupDone` are set by other modules (weather, attitude, victory, ai, spells, the battle screen ...).
---@class World
---@field scn table                 the scenario (formats/scn.lua)
---@field time number               the game clock (ms)
---@field speed number              game speed factor
---@field terrain Terrain
---@field w integer                 map size in cells
---@field h integer
---@field occ table<integer, Unit>  cell index -> unit standing / moving there
---@field static ffi.cdata*         uint8_t[w * h]: 1 = a building / feature blocks the cell
---@field units Unit[]
---@field buildings Building[]
---@field features Feature[]
---@field chests Chest[]            items lying on the ground
---@field opts table                the options the world was made with (M.new)
---@field heroesProduced boolean    the scenario header's "produce heroes" flag
---@field resurrect boolean         the skirmish option: a fallen hero can be brought back (openwbc3's own)
---@field techLevel integer         0..5
---@field mods table<string, boolean> game mods (noHeroes, toughTowers, noDragons ...)
---@field advanced AdvancedOptions  the advanced options (advanced.lua)
---@field missiles Missile[]        missiles in flight (missiles.lua)
---@field nextId integer
---@field finder Finder             path finder (path.lua)
---@field messages {text: string, untilT: number}[]
---@field sides table<integer, Side> 0..5 the players, 6 neutral
---@field player integer            the local side
---@field humans table<integer, boolean> the sides played by humans
---@field armies table<integer, {retinue: table[]?, army: (string|table)[]?}> what each human side brought
---@field brought table<integer, table<integer, boolean>> side -> retinue slots that came into this battle
---@field fallen table<integer, table<integer, string>> side -> retinue slot -> code of the killer ("" none)
---@field victoryRule string|integer|nil the victory rule (victory.lua)
---@field listeners fun(kind: string, a: any, b: any, c: any, d: any)[]
---@field eco Eco
---@field events Events             the scenario's triggers (events.lua)
---@field scriptedVictory boolean?  the scenario's events end the battle
---@field setupDone boolean?        set when the start of the battle is done
---@field towerLevel integer?       World:towerHeroLevel's cached result
---@field mercsTaken table<any, boolean>? mercenary companies the computer sides have hired
---@field nextMorale number?        next time of the psych / morale update
---@field blockRev integer?         bumped whenever cells are blocked / freed (airegion.lua)
---@field stats BattleStats?        World:battleStats
---@field effects WorldEffect[]?
---@field ai AI?                    the computer players (ai.lua), set by the battle screen
---@field fog Fog?                  the local player's fog (the battle screen)
---@field sight table<integer, Fog>? the simulation's fog of every human side (fog.lua)
---@field selected table<integer, integer[]>? side -> ids of its selected units (the "select" command)
---@field night boolean             weather (weather.lua)
---@field raining boolean
---@field lightning boolean
---@field rainTarget number
---@field rainDrops number
---@field rainBase number
---@field rainEnding boolean
---@field rainFrame integer
---@field shift {to: string, t0: number, t1: number, per: number}? a running day / night change
---@field weatherAt number          next weather decision
---@field randomWeather boolean
---@field victoryEnd number?        end of a timed victory mode's countdown (victory.lua)
---@field clock {total: number, t0: number}? the countdown shown
---@field winners integer[]?        the sides a victory mode declared winners
---@field over {winners: integer[]}? set when the battle is over
---@field flagCount integer?        Capture the Flag (content/base/victory.lua)
---@field hitList table[]?          the attitude hit list (attitude.lua)
---@field hitProcessed number?
---@field attNext number?           the attitude slices (attitude.lua)
---@field attSlice integer?
---@field attSide table<integer, integer>?
---@field attAi integer?
---@field attConvert table?
---@field attConvertT number?
---@field abilityAt table<any, number>? building abilities' next use (buildingabilities.lua)
---@field aiAbilityAt table<integer, number>?
---@field manaFreeze {t1: number, side: integer}? Freeze Magic
---@field pileCache {t: number, n: integer}? heroskills.lua caches
---@field virulenceCache {t: number, v: number}?
---@field missileCells table?       missiles.lua's cell map
---@field retinueSettled boolean?   the battle screen: the retinue's end of battle is done
---@field xpAwarded boolean?        the battle screen: the end-of-battle experience is given
local World = {}
World.__index = World

M.NEUTRAL = 6

-- How long the wreck of a destroyed building stays on the map before it is gone. The original keeps the
-- dead display item (flagged for removal) and drops it in the rubble cleanup (FUN_004adc80); the length of the
-- stay is openwbc3's own choice, as is the fade-out over the last quarter of it.
M.RUBBLE_MS = 25000

-- Whether a destroyed building has wreck art at all: its own construction stage or abandoned-mine frame,
-- or the stage of the base code for the upgrade levels, which ship no construction sheet of their own.
---@param b Building
---@return boolean
function M.wreckArt(b)
    local A = require("src.formats.sprite").ANIM
    local set = b.set
    if set and (set:has(A.SPECIAL) or set:has(A.DIE)) then return true end
    local base = anims.get((b.code or ""):sub(1, 3) .. "0")
    return base ~= nil and base:has(A.SPECIAL)
end

---@param code string
---@param btype table? the type record
---@return string
function M.buildingName(code, btype)
    local info = require("src.game.rules").building(code)
    if info and info.name ~= "" then return info.name end
    if btype and btype.name ~= "" then return btype.name end
    return code
end

---@param scn table
---@param opts? table
---@return World
function M.new(scn, opts)
    opts = opts or {}

    ---@type World
    local self = setmetatable({}, World)
    self.scn = scn
    self.time = 0
    self.speed = 1
    self.terrain = terrainMod.new(scn)
    self.w, self.h = self.terrain.w, self.terrain.h
    self.occ = {}          -- cell index -> unit standing/moving there
    self.static = ffi.new("uint8_t[?]", self.w * self.h)   -- 1 = building/feature blocks the cell
    self.units, self.buildings, self.features = {}, {}, {}
    self.chests = {}       -- items lying on the ground
    self.opts = opts
    -- hero resurrection is a skirmish option; a slain hero stays dead otherwise (never in campaigns)
    -- the hero production (FUN_0043b550) puts no hero on the map when the scenario header's "produce heroes"
    -- flag is off (a map made for a scripted start); a hero could not come back either
    self.heroesProduced = not (scn.header and scn.header.produceHeroes == false)
    self.resurrect = opts.resurrect == true and not opts.campaign and self.heroesProduced
    -- tech level (FUN_0040c740: the scenario option, 0..5) and game mods: what may be built / produced
    local so = scn.header and scn.header.options or {}
    self.techLevel = math.max(0, math.min(5, opts.techLevel or so.techLevel or 5))
    self.mods = opts.mods or so.mods or {}
    -- the advanced options (src/game/advanced.lua): the same table on every peer of a network game
    self.advanced = require("src.game.advanced").normalize(opts.advanced)
    self.missiles = {}
    self.nextId = 1
    self.finder = pathMod.new(self.w, self.h)
    self.messages = {}

    -- sides
    self.sides = {}
    for i = 0, 6 do
        local s = scn.sides and scn.sides[i] or { used = i == M.NEUTRAL, color = 6, team = 0 }
        local side = {
            index = i, passive = s.passive, noRetinue = s.noRetinue,
            used = s.used or i == M.NEUTRAL,
            race = s.race or 0,
            color = (i == M.NEUTRAL) and 6 or (s.color or i),
            team = s.team or 0,
            startX = s.startX or -1, startY = s.startY or -1,
            resourceLevel = s.resources,
            aiLevel = s.passive and 0 or s.aiLevel or 2,
            aiFile = s.aiFile,
            aiHero = require("src.game.aihero").clean(s.aiHero),   -- race / class / level chosen for the computer's hero
            -- every non-human side is a computer side, a Passive one (level 0) too: the computer flag DAT_0070d6a4 is
            -- set by human / computer alone (FUN_004494e0, FUN_004de740) and FUN_00504a30 gives every computer side its
            -- AI object, whose turn (FUN_004fa120) runs the side's attitude pass FUN_00532530 and returns at level 0
            ai = not (opts.humans and opts.humans[i] or (not opts.humans and i == (opts.player or 0)))
                and i ~= M.NEUTRAL,
        }
        -- (the resources and `built` come from Eco.new below)
        ---@cast side Side
        self.sides[i] = side
    end
    self.player = opts.player or 0
    self.humans = opts.humans or { [self.player] = true }
    -- what every human side brings (retinue members and bought troops, the same on every peer of a network game); a
    -- single player game passes the local choice as opts.retinue / opts.army
    self.armies = opts.armies or ((opts.retinue or opts.army) and { [self.player] = { retinue = opts.retinue, army = opts.army } }) or {}
    self.brought = {}        -- side -> set of the retinue slots that came into this battle
    self.fallen = {}         -- side -> retinue slot -> unit type that struck the last blow ("" a building or nothing)
    require("src.game.weather").init(self, opts)          -- night / rain / storm state and the weather timer
    -- victory rule: the one chosen / given, else the map header's (a campaign battle always names its own)
    local Victory = require("src.game.victory")
    self.victoryRule = Victory.rule(opts.victory)
    if not self.victoryRule and opts.victory == nil and not opts.campaign and not opts.tutorial then
        self.victoryRule = Victory.rule(so.victory)
    end
    self.victoryRule = self.victoryRule or (opts.victory ~= nil and opts.victory or nil)
    -- a pitched battle is played at tech level 0 (the victory condition callback 0x004dfec0 of the game setup)
    if Victory.get(self.victoryRule, "pitched") then self.techLevel = 0 end

    for _, f in ipairs(scn.features) do self:addFeature(f) end
    local restore = opts.restore       -- a saved game fills in buildings, units and items itself
    for _, b in ipairs(restore and {} or scn.buildings) do
        local owner = b.side
        if owner == M.NEUTRAL or (self.sides[owner] and self.sides[owner].used) then self:addBuilding(b) end
    end
    for _, a in ipairs(restore and {} or scn.armies) do
        local owner = a.side
        if owner == M.NEUTRAL or (self.sides[owner] and self.sides[owner].used) then
            self:addUnit(a.code, owner, math.floor(a.x / CW), math.floor(a.y / CH), a)
        end
    end
    self.listeners = {}
    if opts.campaign and opts.profile and not opts.restore then self:adoptCampaignHero() end
    local items = require("src.game.items")
    for _, c in ipairs(restore and {} or scn.items or {}) do
        require("src.game.chests").place(self, c)
    end
    self.eco = require("src.game.economy").new(self)
    self.events = require("src.game.events").new(self, scn.events)
    -- header "standard victory" off: the scenario's events end the battle (the event check FUN_00516230 tests the
    -- victory event only when the flag is set); the player's own defeat still does
    if scn.header and scn.header.standardVictory == false and not opts.campaign then self.scriptedVictory = true end
    if opts.startForces ~= false and not restore then self:spawnStartingForces() end
    if not restore then Victory.setup(self) end
    if not restore then self:applyCampaignExtras() end
    log.info("world: %dx%d, %d units, %d buildings, %d features", self.w, self.h, #self.units, #self.buildings,
        #self.features)
    self.setupDone = true      -- from now on a new unit may become a retinue recruit (the army's may-join flag)
    return self
end

-- Whether a building of `shape` fits with its anchor at (gx, gy).
---@param shape Shape
---@return boolean
function World:fits(gx, gy, shape)
    for _, c in ipairs(self:shapeCells(gx, gy, shape)) do
        if not self:free(c[1], c[2], 0) then return false end
    end
    return true
end

-- Skirmish start (original rules): each side gets its hero, two builders and its army: what a human brought from the
-- army setup (retinue members, regular troops), what a computer side buys with the army setup points (addArmies); no keep.
function World:spawnStartingForces()
    local rules = require("src.game.rules")
    local economy = require("src.game.economy")
    local profile = require("src.game.profile")
    -- the player's hero comes from the saved profile; computer heroes start at its level
    local saved
    local me = self.sides[self.player]
    if self.opts.profile and me and me.used then saved = profile.load(self:profileRace(self.player)) end
    local heroes = self.opts.heroes           -- network games: the hero of every human side
    local aiLevel = saved and saved.level or 1
    if heroes then aiLevel = 1 end
    -- advanced options: Tournament mode (every hero starts at the same level; not in a No Heroes game, the campaign or a
    -- tutorial) and I am the greatest (computer heroes are at least level 100, FUN_0042a0d0)
    local adv = self.advanced
    local tournament = adv.tournament and not self.mods.noHeroes and not self.opts.campaign and not self.opts.tutorial
    local function tournamentHero(from, race)
        if from and from.tournament then return from end         -- made on the hero creation screens (screens/heroselect.lua)
        -- without one (headless tests, the developer start) the temporary hero is of the class it would have played
        local base = require("src.game.classes").newHero(from and from.class or "Warrior", race)
        local attr, skill = require("src.game.advanced").tournamentPoints(adv.points)
        base.level, base.tournament = adv.points, true
        base.points = { attr = ATTR_POINTS_PER_LEVEL * attr, skill = skill }
        return base
    end
    -- a campaign scenario places its own armies: the sides that have some get no start force (only the
    -- player's hero, if the scenario has none), otherwise units would be there that the scenario adds later
    local placed = {}
    if self.opts.campaign then
        for _, u in ipairs(self.units) do placed[u.side] = true end
        for _, b in ipairs(self.buildings) do placed[b.side] = true end
    end
    for i = 0, 5 do
        local side = self.sides[i]
        local keepAsIs = placed[i] and not (i == self.player and not self.eco:heroAlive(i))
        -- the tutorial gives the player a lone dwarf warrior (the scenario adds the rest by events)
        if self.opts.tutorial and i ~= self.player then keepAsIs = true end
        if side.used and side.startX >= 0 and not keepAsIs then
            local sx, sy = side.startX, side.startY
            local race = side.race
            local hero
            if self.mods.noHeroes then
                -- No Heroes: the start force is the race's plain general (an army type of its own, no hero system and
                -- no voice set) and the two builders; `FUN_00445810` in the 1.04 binary
                if self.heroesProduced then self:addUnit(economy.GENERAL[race] or economy.HERO[race], i, sx, sy) end
            else
                hero = self.heroesProduced and self:addUnit(self:heroCode(i), i, sx, sy) or nil
            end
            if hero then
                if heroes and heroes[i] then
                    hero:makeHero(tournament and tournamentHero(heroes[i], race) or heroes[i])
                elseif i == self.player and self.opts.tutorial then
                    hero:makeHero(require("src.game.classes").newHero("Warrior", 1))
                    hero.name = "Sirian"
                elseif i == self.player then
                    hero:makeHero(tournament and tournamentHero(saved, race) or saved)
                    self:applyProfileHero(hero)
                else
                    -- own: the original gives computer heroes a random class; here it follows from the side and race so
                    -- that every peer of a network game builds the same hero
                    -- the race, class and level the host chose on the AI hero panel (FUN_0042a0d0) win
                    -- over those rules; an unset level is made as before
                    local classes = require("src.game.classes")
                    local chosen = side.ai and side.aiHero or {}
                    local heroRace = chosen.race or race
                    local cls = chosen.class and classes.list()[chosen.class + 1][1]
                              or classes.list()[(i * 7 + race * 5) % #classes.list() + 1][1]
                    local base = classes.newHero(cls, heroRace)
                    local lvl = require("src.game.victory").get(self.victoryRule, "computerHeroLevel") or aiLevel   -- text 197.2: level 50
                    if tournament then lvl = adv.points end                                -- FUN_0042a0d0
                    if chosen.level then lvl = chosen.level end
                    if adv.greatest then lvl = math.max(lvl, 100) end                      -- FUN_0042a0d0
                    base.level = lvl
                    base.points = { attr = ATTR_POINTS_PER_LEVEL * (lvl - 1), skill = lvl - 1 }
                    local h = hero:makeHero(base)
                    h:autoSpend()
                    self:giveComputerItems(h)
                end
            end
            if self.opts.tutorial then
                -- hero only
            elseif not placed[i] then
                local builder = economy.BUILDER[race] or "AHBX"
                self:addUnit(builder, i, sx, sy + 1)
                self:addUnit(builder, i, sx + 1, sy + 1)
            end
        end
    end
    if not self.opts.tutorial then self:addArmies() end
end

-- The random backpack and worn items of a computer hero (FUN_0042a0d0; Items.computerKit): no backpack
-- items in an Assassin victory game. The stats are worked out again and the start mana is a tenth of the new maximum.
---@param h Hero
function World:giveComputerItems(h)
    local worn, pack = require("src.game.items").computerKit(h.level, require("src.game.victory").get(self.victoryRule, "noComputerPack"))
    for slot, it in pairs(worn) do h.equipped[slot] = it end
    for _, it in ipairs(pack) do
        if #h.pack < require("src.game.hero").PACK_SIZE then h.pack[#h.pack + 1] = it end
    end
    h:recalc()
    h.mana = math.floor(h.mod.mana / 10)
end

-- Where an army of the setup is put (FUN_004402d0): the start location of the side, off by up to 5 cells either way, and at
-- least 5 cells from the map's edge; the nearest free cell then. Falls back to `near` (a unit) when the side has no start.
---@param side integer
---@param near Unit? where to go when the side has no start
---@return integer? gx, integer? gy
function World:armyPlace(side, near)
    local sd = self.sides[side]
    local gx, gy = sd.startX, sd.startY
    if gx < 0 and near then gx, gy = near.gx, near.gy end
    if gx < 0 then return nil end
    gx = math.max(5, math.min(self.w - 5, gx + math.random(1, 10) - 5))
    gy = math.max(5, math.min(self.h - 5, gy + math.random(1, 10) - 5))
    return self:nearestFree(gx, gy, 0, 12)
end

-- Puts one unit of a side's setup army on the map (retinue members keep their slot).
---@param side integer
---@param code string
---@param rec table? name, level, xp
---@param slot integer? the retinue slot
---@return Unit?
function World:addSetupUnit(side, code, rec, slot)
    local gx, gy = self:armyPlace(side, self.units[1])
    if not gx then return nil end
    ---@cast gy -nil
    local u = self:addUnit(code, side, gx, gy, rec)
    if u and slot then
        u.retinueIndex = slot
        self.brought[side] = self.brought[side] or {}
        self.brought[side][slot] = true
    end
    return u
end

-- The armies of the sides at the start (FUN_004406b0): a human's retinue members and regular troops, a computer
-- side's purchase. A human side without a choice gets the computer's purchase only when the game has no army setup
-- points of its own (no `startPoints`: test runs, `--scenario`).
function World:addArmies()
    for i = 0, 5 do
        local sd = self.sides[i]
        if sd.used and sd.startX >= 0 then
            local choice = self.armies[i]
            if choice then
                for _, r in ipairs(choice.retinue or {}) do
                    self:addSetupUnit(i, r.code, { name = r.name, level = r.level, xp = r.xp }, r.slot)
                end
                for _, a in ipairs(choice.army or {}) do
                    if type(a) == "string" then self:addSetupUnit(i, a, nil)
                    else self:addSetupUnit(i, a.code, { name = a.name, level = a.level, xp = a.xp }) end
                end
            elseif sd.ai or (not self.humans[i] and i ~= self.player) or self.opts.startPoints == nil then
                self:buyComputerArmy(i)
            end
        end
    end
end

-- A computer side buys its army (FUN_00445200): the army setup points of the game; in a campaign the difficulty adds
-- points and may hire a mercenary company (not for Passive and Rampant sides, not where the map says "no retinue").
---@param i integer the side
function World:buyComputerArmy(i)
    local sd = self.sides[i]
    local retinue = require("src.game.retinue")
    local points = self.opts.startPoints or 5
    if sd.noRetinue or points <= 0 then return end
    if self.opts.campaign and sd.aiLevel ~= 0 and sd.aiLevel ~= 7 and not sd.passive and i < M.NEUTRAL then
        local difficulty = self.opts.difficulty or 1
        points = points + retinue.aiExtraPoints(difficulty, math.random(1, 100))
        local hire, major = retinue.aiMercenaryRoll(difficulty, self.opts.heroLevel or 1, math.random(1, 100))
        if hire then
            local mercs = require("src.game.campaigndata").load().mercenaries
            local taken = self.mercsTaken or {}
            self.mercsTaken = taken
            local merc = retinue.pickMercenary(mercs, sd.race, major, function(n) return math.random(1, n) end, taken)
            if merc then
                taken[merc.id] = true
                for _, u in ipairs(merc.units) do
                    for _ = 1, u.number do
                        self:addSetupUnit(i, u.code, { name = u.name, level = math.max(0, (u.level or 1) - 1),
                                                       xp = retinue.xpFor(math.max(0, (u.level or 1) - 1)) })
                    end
                end
            end
        end
    end
    for _, code in ipairs(retinue.aiArmy(sd.race, points, sd.aiLevel, function(n) return math.random(1, n) end)) do
        self:addSetupUnit(i, code, nil)
    end
end

-- Campaign battles: bonuses for the player, named heroes for the other sides.
function World:applyCampaignExtras()
    local opts = self.opts
    local hero = self.eco:heroAlive(self.player)
    if hero and hero.h and opts.bonuses then
        local bonus = {}
        for _, b in ipairs(opts.bonuses) do
            if b.type == "vision" then self.sides[self.player].visionBonus = (self.sides[self.player].visionBonus or 0) + b.data
            elseif b.type ~= "none" then bonus[b.type] = (bonus[b.type] or 0) + b.data end
        end
        hero.h.bonus = bonus
        hero.h:recalc()
    end
    local Hero = require("src.game.hero")
    for _, sh in ipairs(opts.sideHeroes or {}) do
        for _, u in ipairs(self.units) do
            if u.side == sh.side and u.hero then
                local lvl = math.max(1, math.min(Hero.MAX_LEVEL, sh.level or 1))
                local h = Hero.new(u, { level = lvl, points = { attr = ATTR_POINTS_PER_LEVEL * (lvl - 1), skill = lvl - 1, spell = lvl } })
                u.h = h
                h:autoSpend()
                self:giveComputerItems(h)
                if sh.name and sh.name ~= "" then u.name = sh.name end
                break
            end
        end
    end
end

-- The race to ask the profile for when it looks up the hero of side `sideIndex` (profile.load / recordFor): the side's own,
-- except in a skirmish, where the player picks the race of his seat and the hero keeps his (nil: whatever race; opts.heroRace
-- is the single player's hero race, network games have opts.net).
---@param sideIndex integer
---@return integer?
function World:profileRace(sideIndex)
    if self.opts.net or self.opts.heroRace then return nil end
    return self.sides[sideIndex].race
end

-- The race of a human side's hero when it differs from the side's (skirmish and network games: the seat's race is the
-- panel's, the hero's is his own; the 1.04 start copy FUN_004de740 takes the side's race from the panel alone). Every peer
-- knows it from the start message, so the hero unit is the same everywhere. The original builds the hero from the hero's own
-- record (the hero production FUN_0043b550, the record's avatar), the army from the side's race.
---@param sideIndex integer
---@return integer?
function World:heroRaceOf(sideIndex)
    local h = self.opts.heroes and self.opts.heroes[sideIndex]
    local race = h and not h.tournament and h.race
    if not h and sideIndex == self.player then race = self.opts.heroRace end
    if type(race) == "number" and race ~= self.sides[sideIndex].race then return race end
end

-- The unit code of a side's hero. The player's hero is the avatar of the selected hero record (the hero production
-- FUN_0043b550 uses the avatar as the hero's unit); everyone else, and a resurrected hero without a record, uses the
-- race's default.
-- Used for the start hero and for resurrection (the keep's hero button, economy.lua).
---@param sideIndex integer
---@return string
function World:heroCode(sideIndex)
    local sd = self.sides[sideIndex]
    -- a computer side's hero may be of another race than the side (the AI hero panel): the unit is that race's hero
    local code = require("src.game.economy").HERO[sd.ai and sd.aiHero and sd.aiHero.race or self:heroRaceOf(sideIndex) or sd.race]
        or "AHHX"
    if sideIndex == self.player and self.opts.profile and not self.opts.tutorial then
        local rec = require("src.game.profile").recordFor(self:profileRace(sideIndex))
        -- a Tournament hero of another race than its side keeps the side's hero unit (own: every peer must build the same
        -- unit types, and only the local player knows the avatar)
        if rec and rec.temporary and rec.race ~= sd.race then rec = nil end
        local avatar = rec and require("src.game.herocustom").AVATAR_CODES[rec.avatar or -1]
        if avatar and require("src.gfx.anims").get(avatar) then code = avatar end
    end
    return code
end

-- What the selected hero record adds to the player's hero unit in battle: its voice set (the hero speaks with it, the
-- sound cache FUN_00511c10 builds the file names from the battle hero's voice set) and Ironman mode (the experience
-- routine FUN_00527100: experience counts twice).
-- Own: the double experience is not applied in network games, the peers would disagree about the level.
---@param u Unit
function World:applyProfileHero(u)
    local rec = require("src.game.profile").recordFor(self:profileRace(u.side))
    if not rec then return end
    if rec.voice then u.voiceSet = require("src.game.herocustom").voiceSpec(rec.voice) end
    if rec.mode == 1 and u.h and not self.opts.net and not u.h.tournament then
        u.h.ironman = true
        self.sides[u.side].ironman = true       -- kept for the end-of-battle experience of a hero that fell
    end
end

-- Campaign: your persistent hero takes the place of the scenario's hero of the player.
function World:adoptCampaignHero()
    local profile = require("src.game.profile")
    local economy = require("src.game.economy")
    local me = self.sides[self.player]
    local saved = me and profile.load(me.race)
    if not saved then return end
    for _, u in ipairs(self.units) do
        if u.side == self.player and u.hero and not u.adopted then
            local code = economy.HERO[me.race]
            if u.code ~= code then
                local gx, gy = u.gx, u.gy
                u:vanish(true)
                local nu = self:addUnit(code, self.player, gx, gy)
                if nu then
                    nu:makeHero(saved)
                    nu.adopted = true
                    self:applyProfileHero(nu)
                end
            else
                u:makeHero(saved)
                u.adopted = true
                self:applyProfileHero(u)
            end
            return
        end
    end
end

-- Items on the ground -------------------------------------------------------

---@param gx integer
---@param gy integer
---@param item table? the item record (nothing happens without one)
---@param dir integer?
---@param thrownBy Unit? its owner threw it away
---@param victimDrop boolean? dropped by a slain lair boss
---@return Chest?
function World:dropItem(gx, gy, item, dir, thrownBy, victimDrop)
    if not item then return nil end
    local c = {
        kind = "chest", id = self:newId(), item = item, set = anims.get("IMAP"),
        gx = gx, gy = gy, x = gx * CW + 16, y = gy * CH + 12, dir = math.max(0, math.min(4, dir or 4)),
        ignoreFor = thrownBy,      -- a thrown-away item isn't picked up again until its owner has moved off
    }
    c.dropped = victimDrop
    self.chests[#self.chests + 1] = c
    self:event("itemdropped", c)
    return c
end

-- A chest of a scenario that holds resources (ITMH, src/game/chests.lua): 500 of `kind`, taken when a hero comes next to it.
---@param gx integer
---@param gy integer
---@param kind string the resource
---@param dir integer?
---@return Chest
function World:dropResource(gx, gy, kind, dir)
    local c = {
        kind = "chest", id = self:newId(), resource = kind, amount = 500, set = anims.get("IMAP"),
        gx = gx, gy = gy, x = gx * CW + 16, y = gy * CH + 12, dir = math.max(0, math.min(4, dir or 0)),
    }
    self.chests[#self.chests + 1] = c
    return c
end

-- A hero standing next to a chest takes the item if it has room.
---@param unit Unit a hero
function World:collectItems(unit)
    for i = #self.chests, 1, -1 do
        local c = self.chests[i]
        local near = math.max(math.abs(c.gx - unit.gx), math.abs(c.gy - unit.gy)) <= 1
        if c.ignoreFor == unit and not near then c.ignoreFor = nil end
        if near and c.resource then
            -- a resource chest goes to the hero's side (the chest check FUN_0053a1a0 adds it with FUN_0043e9b0)
            table.remove(self.chests, i)
            local side = self.sides[unit.side]
            if side then side[c.resource] = (side[c.resource] or 0) + c.amount end
            self:event("resourcefound", unit, c.resource, c.amount)
        elseif near and c.ignoreFor ~= unit then
            local ok, where = unit.h:give(c.item)
            if ok then
                table.remove(self.chests, i)
                self:event("itemfound", unit, c.item, where)
            elseif not c.refused then
                c.refused = true
                self:event("packfull", unit, c.item)
            end
        end
    end
end

-- Experience for a kill and the treasure of slain lair bosses. In the original the killer and the side's
-- hero both get the full experience, wherever the hero is (the army death FUN_005210b0); there is no sharing radius.
local LAIR_BOSS = require("src.game.sites").LAIR_BOSS   -- the name that marks the boss a lair leaves behind

---@param killer Unit|Building
---@param victim Unit|Building
function World:award(killer, victim)
    if killer.side == victim.side or killer.side == M.NEUTRAL then return end
    if victim.side ~= M.NEUTRAL and not self:enemies(killer.side, victim.side) then return end
    local hero = require("src.game.hero")
    local value = hero.xpValue(victim)
    -- killing a critter gives nobody experience (FUN_005210b0 skips the whole branch)
    if victim.kind == "unit" and Unit.isCritter(victim.code) then value = 0 end
    -- Mind Leech (FUN_005210b0 with the energy-drain test FUN_00526fe0): a troop with the effect gains the experience
    -- of the army it kills, on top of the normal kill experience and even for a critter
    if killer.kind == "unit" and not killer.h and killer.fx and killer.fx.drain and victim.kind == "unit" then
        killer:addXp(victim.xp or 0)
    end
    if value > 0 then
        -- the killer itself: plain troops gain the experience too (FUN_005210b0)
        if killer.kind == "unit" and not killer.h and killer:alive() then
            local extra = victim.kind == "unit" and powerups.crusadeXp(self.sides[killer.side]) or 0
            extra = extra + powerups.questKillXp(killer, victim)           -- Knight's Quest
            local gained = killer:addXp(value + extra)
            if gained > 0 then
                -- a troop that gained a level heals up to 100 hits (the experience routine FUN_00527100)
                if killer.hp < killer.maxHp then
                    killer.hp = killer.hp + math.min(100, killer.maxHp - killer.hp)
                end
                self:event("gainedlevel", killer, gained)
            end
        end
        for _, u in ipairs(self.units) do
            if u.h and u.side == killer.side and u:alive() then
                if u == killer then u.h.kills = u.h.kills + 1 end
                -- Crusade: the killer (not the side's other hero) gets one more experience point per level for an army
                local extra = (u == killer and victim.kind == "unit") and powerups.crusadeXp(self.sides[killer.side]) or 0
                local levels = u.h:addXp(value + extra)
                if levels > 0 then
                    if self.sides[u.side].ai then u.h:autoSpend() end
                    self:event("levelup", u, levels)
                end
            end
        end
    end
    -- only a lair boss leaves an item (a random minor/lesser one); heroes drop theirs in the original
    if victim.kind == "unit" and victim.name == LAIR_BOSS then
        self:dropItem(victim.gx, victim.gy, require("src.game.items").random(2), nil, nil, true)
    end
end

-- Damage from a spell to a building (same consequences as a melee strike).
---@param b Building
---@param dmg number
---@param attacker (Unit|Building)?
function World:damageBuilding(b, dmg, attacker)
    if b.hp <= 0 or (require("src.game.gamedata").hasTag(b.code, "flag") and require("src.game.victory").get(self.victoryRule, "flagGame")) then return end
    if attacker and attacker.side ~= b.side then self:event("attacked", b, attacker, dmg) end
    b.hp = b.hp - dmg
    -- a lair breeds when it is hit, a shop's hatred of the attacker goes up (the lair hit FUN_00404b10 and the
    -- shop hatred FUN_00408360, both called from the building's damage intake FUN_0052bd10)
    require("src.game.sites").damage(self, b, attacker and attacker.side)
    if b.hp <= 0 then
        b.hp = 0
        if self:canPillage(b) then
            self:pillage(b, attacker and attacker.side)
        else
            b.destroyed = true
            b.razedBy = attacker and attacker.side or nil
            if b.shape then self:blockShape(b.gx, b.gy, b.shape, false) end
            if attacker then self:award(attacker, b) end
        end
    end
end

-- Moves a unit to a free cell at once (blink, home portal).
---@param u Unit
---@param gx integer
---@param gy integer
function World:teleport(u, gx, gy)
    if self.occ[self:index(u.gx, u.gy)] == u then self.occ[self:index(u.gx, u.gy)] = nil end
    u.step = nil
    u.gx, u.gy = gx, gy
    u.x, u.y = gx * CW + 16, gy * CH + 12
    u.path, u.goalX, u.target = nil, nil, nil
    self.occ[self:index(gx, gy)] = u
end

-- A checksum of the simulation state (to detect that network players are out of sync).
---@return integer
function World:hash()
    local h = 17
    local function mix(n) h = (h * 31 + math.floor(n)) % 2147483647 end
    mix(self.time)
    mix(self.night and 1 or 0) mix(self.raining and 1 or 0) mix(self.lightning and 1 or 0)
    mix(self.rainDrops or 0) mix(self.rainEnding and 1 or 0)
    for _, u in ipairs(self.units) do
        mix(u.id) mix(u.gx) mix(u.gy) mix(u.hp * 4) mix(u.side)
        if u.armorLoss then mix(u.armorLoss) end
    end
    for _, b in ipairs(self.buildings) do
        mix(b.id) mix(b.hp) mix(b.side)
        if b.quest and b.quest.state == "held" then mix(b.quest.id) end        -- a shrine's picked quest
    end
    for _, m in ipairs(self.missiles) do mix(m.frame) mix(m.maxSteps) mix(m.gx1) mix(m.gy1) end
    for i = 0, 6 do
        local s = self.sides[i]
        mix(s.gold) mix(s.metal) mix(s.crystal) mix(s.stone)
        if s.quest then mix(s.quest.id) mix(s.quest.count) end
    end
    return h
end

---@return integer
function World:newId()
    local id = self.nextId
    self.nextId = id + 1
    return id
end

---@param gx integer
---@param gy integer
---@return integer
function World:index(gx, gy) return gy * self.w + gx end

---@param a integer side
---@param b integer side
---@return boolean
function World:enemies(a, b)
    if a == b then return false end
    if a == M.NEUTRAL or b == M.NEUTRAL then return false end
    local sa, sb = self.sides[a], self.sides[b]
    if sa.team ~= 0 and sa.team == sb.team then return false end
    return true
end

-- Features ------------------------------------------------------------------

---@param rec table the scenario's feature record (code, x, y, anim, dir, frame)
---@return Feature
function World:addFeature(rec)
    local set = anims.get(rec.code)
    local f = {
        kind = "feature", id = self:newId(), code = rec.code, set = set,
        x = rec.x, y = rec.y, gx = math.floor(rec.x / CW), gy = math.floor(rec.y / CH),
        anim = math.max(0, math.min(8, rec.anim or 0)), dir = rec.dir or 0, frame = rec.frame or 0,
        phase = math.random(0, 1000),
    }
    local ftype = require("src.vfs.vfs").find(rec.code .. ".fea")
    if ftype and #ftype >= 61 then
        -- the .fea record: id, name (20 bytes), the shape at 24, the walk-over flag at 58
        local w, h = ftype:byte(25), ftype:byte(26)
        f.walkOver = ftype:byte(59) ~= 0
        f.shape = { w = w, h = h, ex = {} }
        for row = 0, 15 do
            local lo, hi = ftype:byte(27 + row * 2, 28 + row * 2)
            f.shape.ex[row] = lo + hi * 256
        end
        if not f.walkOver then self:blockShape(f.gx, f.gy, f.shape, true) end
    end
    self.features[#self.features + 1] = f
    return f
end

-- Takes a feature (tree, rock ...) off the map and frees the cells it blocked.
---@param f Feature
---@return boolean
function World:removeFeature(f)
    for i, o in ipairs(self.features) do
        if o == f then
            if f.shape and not f.walkOver then self:blockShape(f.gx, f.gy, f.shape, false) end
            table.remove(self.features, i)
            return true
        end
    end
    return false
end

-- Marks the cells of a shape anchored like buildings: x from gx-(w-1)/2, y from gy..gy+h-1;
-- bit x of exclusion row y set = cell not occupied.
---@param gx integer
---@param gy integer
---@param shape Shape
---@return {[1]: integer, [2]: integer}[]
function World:shapeCells(gx, gy, shape)
    local cells = {}
    local w, h = math.max(1, shape.w), math.max(1, shape.h)
    local x0 = gx - math.floor((w - 1) / 2)
    local ex = shape.ex or shape.exclusion or {}
    for y = 0, h - 1 do
        for x = 0, w - 1 do
            local row = ex[y] or 0
            if bit.band(row, bit.lshift(1, x)) == 0 then
                cells[#cells + 1] = { x0 + x, gy + y }
            end
        end
    end
    return cells
end

---@param gx integer
---@param gy integer
---@param shape Shape
---@param on boolean
function World:blockShape(gx, gy, shape, on)
    self.blockRev = (self.blockRev or 0) + 1       -- the computer's region map (airegion.lua) rebuilds when this changes
    for _, c in ipairs(self:shapeCells(gx, gy, shape)) do
        if self.terrain:inside(c[1], c[2]) then
            self.static[self:index(c[1], c[2])] = on and 1 or 0
        end
    end
end

-- Buildings -----------------------------------------------------------------

-- The highest hero level of the human sides, the number the building placement FUN_004a50f0 / FUN_00418700 scale a
-- tower with (max of the
-- side panel's level and the hero's own; the tournament level when Tournament mode is on). Known at the start of the
-- battle: the saved hero of this side or what the network start message brought, the same on every peer. 0 for a
-- campaign / tutorial game (the original does it in game types 0 and 1 only) and when no hero is known (headless tests).
---@return integer
function World:towerHeroLevel()
    if self.towerLevel then return self.towerLevel end
    local best = 0
    local adv = self.advanced
    if not self.opts.campaign and not self.opts.tutorial then
        if adv.tournament and not self.mods.noHeroes then
            best = adv.points
        else
            local profile = require("src.game.profile")
            for i = 0, 5 do
                local side = self.sides[i]
                if side.used and self.humans[i] then
                    local h = self.opts.heroes and self.opts.heroes[i]
                    if not h and i == self.player and self.opts.profile then h = profile.load(self:profileRace(i)) or { level = 1 } end
                    best = math.max(best, h and h.level or 0)
                end
            end
        end
    end
    self.towerLevel = best
    return best
end

---@param rec table the scenario's building record (code, side, x, y, anim, dir, frame, name, curHits ...)
---@return Building
function World:addBuilding(rec)
    -- the original re-picks the tower and wall type of the owning side's race (FUN_004a50f0), so the ones
    -- a scenario ships are only placeholders; its current hits belong to the old type and are dropped
    local code = gamedata.raceVariant(rec.code, self.sides[rec.side] and self.sides[rec.side].race)
    local btype = self.mods.toughTowers and gamedata.toughBuilding(code) or gamedata.building(code)
    -- the advanced option of the same name comes on top of the game mod (both change the record the building is made from);
    -- a tower the scenario names (a character) keeps its own stats and gets neither this nor the hero-level scaling
    local advanced = require("src.game.advanced")
    local plain = btype and gamedata.isRaceTower(code) and not rec.character
    local tough = plain and self.advanced.toughTowers
    if tough then btype = advanced.toughTower(btype --[[@as BuildingRecord]]) end      -- plain: there is a record
    -- hero-level scaling (advanced.scaledTower) happens when the map is set up, not to a tower built or conjured later;
    -- a saved game hands back the level (0 = none) the tower was made with
    local level = 0
    if plain then level = rec.towerLevel or (not self.setupDone and self:towerHeroLevel()) or 0 end
    local kind = rec.starting and "start" or "scenario"
    local scaledUp = level > 0
    if scaledUp then btype = advanced.scaledTower(btype --[[@as BuildingRecord]], level, kind) end   -- level > 0: plain
    local hits = (btype and btype.hits > 0) and btype.hits or 500
    local keepHits = not tough and not scaledUp and code == rec.code and rec.curHits and rec.curHits > 0
    local b = {
        kind = "building", id = self:newId(), code = code, type = btype, set = anims.get(code),
        side = rec.side, x = rec.x, y = rec.y, gx = math.floor(rec.x / CW), gy = math.floor(rec.y / CH),
        anim = math.max(0, math.min(8, rec.anim or 0)), dir = rec.dir or 0, frame = rec.frame or 0,
        hp = keepHits and rec.curHits or hits, maxHp = hits,
        name = (rec.name and rec.name ~= "") and rec.name or M.buildingName(code, btype),
        phase = math.random(0, 1000),
        towerLevel = scaledUp and level or nil, towerKind = scaledUp and kind or nil,
    }
    if btype then
        b.shape = btype.shape
        self:blockShape(b.gx, b.gy, btype.shape, true)
    end
    self.buildings[#self.buildings + 1] = b
    require("src.game.sites").initBuilding(self, b)
    return b
end

-- Units ---------------------------------------------------------------------

---@param code string
---@param side integer
---@param gx integer
---@param gy integer
---@param rec table? see Unit.new
---@return Unit?
function World:addUnit(code, side, gx, gy, rec)
    local u = Unit.new(self, code, side, gx, gy, rec)
    if not u then return nil end
    self.units[#self.units + 1] = u
    -- armies made during the battle may be offered as recruits afterwards (a may-join flag); the ones of the setup
    -- (scenario armies, the retinue, bought troops) may not
    if self.setupDone then u.canRetinue = true end
    -- a titan after the first two minutes closes the titan slot for its side (the army initialiser FUN_00519ae0 sets the
    -- side's titan-produced flag)
    if self.time > 120000 and code:sub(2, 2) == "T" and code:sub(4, 4) == "X" and self.sides[side] then
        self.sides[side].producedTitan = true
        self:event("titan", u)      -- the announcer's "enemy / allied titan" (FUN_00519ae0, system speech 26 / 27)
    end
    return u
end

---@return Unit?
function World:unitAt(gx, gy)
    return self.occ[self:index(gx, gy)]
end

---@param gx integer
---@param gy integer
---@param move integer movement class (terrain.MOVE)
---@param ignore Unit? a unit that does not count
---@return boolean
function World:free(gx, gy, move, ignore)
    if not self.terrain:passable(gx, gy, move) then return false end
    local i = self:index(gx, gy)
    if move ~= 1 and self.static[i] ~= 0 then return false end
    local o = self.occ[i]
    return o == nil or o == ignore
end

-- Closest free cell to (gx, gy) by spiral search.
---@param gx integer
---@param gy integer
---@param move integer
---@param maxR integer? default 12
---@return integer? gx nil when no cell within maxR is free (then gy is nil too)
---@return integer? gy
function World:nearestFree(gx, gy, move, maxR)
    if self:free(gx, gy, move) then return gx, gy end
    for r = 1, maxR or 12 do
        for dy = -r, r do
            for dx = -r, r do
                if math.max(math.abs(dx), math.abs(dy)) == r and self:free(gx + dx, gy + dy, move) then
                    return gx + dx, gy + dy
                end
            end
        end
    end
    return nil
end

---@param u Unit
---@param tx integer
---@param ty integer
---@return {[1]: integer, [2]: integer}[] path, boolean reached
function World:findPath(u, tx, ty)
    local move = u.move
    local terrain, static, occ, w = self.terrain, self.static, self.occ, self.w
    local function passable(x, y)
        if not terrain:passable(x, y, move) then return false end
        if move ~= 1 and static[y * w + x] ~= 0 then return false end
        return true
    end
    local function cost(x, y)
        local o = occ[y * w + x]
        if o and o ~= u then return o.state == "idle" and 4 or 1 end
        return 0
    end
    return self.finder:find(u.gx, u.gy, tx, ty, passable, 6000, cost)
end

-- Entities touching a world point (for picking). A unit is picked when the point is
-- inside the box its current frames are drawn in, like the original's picking
-- rectangle (the army rectangle routine 0x00539ce0); this is what lets a cursor on a
-- flyer's floating body hit it rather than only the ground beneath it. Among the units
-- that contain the point the nearest centre wins; if none does, fall back to the old
-- proximity test so a click just off a small unit still selects it.
---@param wx number
---@param wy number
---@return (Unit|Building)?
function World:pick(wx, wy)
    local best, bestD
    for _, u in ipairs(self.units) do
        if u:alive() then
            local ox, oy, w, h = u.set:pickRect(u.anim)
            local d
            if ox then
                local left, top = u.x - ox, u.y - oy
                if wx >= left and wx < left + w and wy >= top and wy < top + h then
                    local cx, cy = left + w / 2, top + h / 2
                    d = (cx - wx) * (cx - wx) + (cy - wy) * (cy - wy)
                end
            else
                local dx, dy = u.x - wx, (u.y - 12) - wy
                if dx * dx + dy * dy < 26 * 26 then d = dx * dx + dy * dy end
            end
            if d and (not bestD or d < bestD) then best, bestD = u, d end
        end
    end
    if best then return best end
    local gx, gy = math.floor(wx / CW), math.floor(wy / CH)
    for _, b in ipairs(self.buildings) do
        if b.hp > 0 and b.shape then
            for _, c in ipairs(self:shapeCells(b.gx, b.gy, b.shape)) do
                if c[1] == gx and c[2] == gy then return b end
            end
        end
    end
    return nil
end

-- The four temples (FUN_0052fc50): like the resource producers they are never destroyed for good.
---@param code string
---@return boolean
function M.isTemple(code)
    return require("src.game.gamedata").hasTag(code, "temple")
end

-- Buildings that are pillaged instead of destroyed (FUN_0052f980: a temple or a resource
-- producer, i.e. the mines here).
---@param b Building
---@return boolean
function World:canPillage(b)
    return b.mine ~= nil or M.isTemple(b.code)
end

-- What a building that cannot be destroyed does when its hit points run out (the building death FUN_0052b3e0,
-- "Temporary"): it turns neutral and loses what it was producing. A mine gives the attacker (else its owner) 10
-- times its production of each resource, at most what is left, and loses twice that from its reserve; it works again
-- after 4 minutes when anything is left, else it is out of commission for good. A temple is back with
-- full hit points after 2 minutes, still neutral (a hero can convert it again). The original
-- pays the loot to the owner when no attacker is known (fire, a spell); `attackerSide` nil does that here.
M.PILLAGE_MS, M.TEMPLE_PILLAGE_MS = 240000, 120000
---@param b Building
---@param attackerSide integer?
function World:pillage(b, attackerSide)
    local m = b.mine
    local owner = b.side
    local left = true
    if m then
        local loot = math.min(m.reserve, m.produce * 10)
        m.reserve = math.max(0, m.reserve - 2 * loot)
        m.workers = 0
        local s = self.sides[attackerSide or owner]
        if s and s[m.resource] and (attackerSide or owner) < M.NEUTRAL then s[m.resource] = s[m.resource] + loot end
        left = m.reserve > 0
    end
    b.side = M.NEUTRAL
    b.queue, b.current, b.waiting, b.continuous = {}, nil, nil, nil
    if left then
        b.hp = 1
        b.pillaged = self.time + (m and M.PILLAGE_MS or M.TEMPLE_PILLAGE_MS)
    else
        b.hp = 0
    end
    self:event("pillaged", b, attackerSide)
end

-- Game events ("produced", "built", "converted", "defeated", "gameover", ...)
-- are forwarded to listeners (screen: sounds and messages; AI).
---@param kind string
function World:event(kind, a, b, c, d)
    require("src.game.quests").onEvent(self, kind, a, b, c)
    if self.events then self.events:note(kind, a, b) end
    self:battleStats():note(kind, a, b, c)
    for _, fn in ipairs(self.listeners) do fn(kind, a, b, c, d) end
end

-- Name shown for a side: its hero's name, else its race.
---@param i integer
---@return string
function World:sideName(i)
    local hero = self.eco:heroAlive(i)
    if hero and hero.name and hero.name ~= "" then return hero.name end
    return require("src.game.classes").RACE_NAMES[self.sides[i].race] or "?"
end

---@return BattleStats
function World:battleStats()
    if not self.stats then self.stats = require("src.game.battlestats").new() end
    return self.stats
end

---@param fn fun(kind: string, a: any, b: any, c: any, d: any)
function World:listen(fn)
    self.listeners[#self.listeners + 1] = fn
end

---@param text string
---@param seconds number?
function World:message(text, seconds)
    self.messages[#self.messages + 1] = { text = text, untilT = love.timer.getTime() + (seconds or 4) }
end

---@param dt number seconds
function World:update(dt)
    local ms = dt * 1000 * self.speed
    self.time = self.time + ms
    local t = self.time
    self.terrain:update(t)
    for i = #self.units, 1, -1 do
        local u = self.units[i]
        u:update(t)
        if u.remove then
            table.remove(self.units, i)
        end
    end
    require("src.game.missiles").update(self, t)
    self.eco:update(t)
    if t >= (self.nextMorale or 0) then            -- the psych auras and the hero's command radius bonus, once a second
        self.nextMorale = t + 1000
        require("src.game.psych").update(self)
        require("src.game.morale").update(self)
    end
    require("src.game.weather").update(self)
    if self.effects then
        for i = #self.effects, 1, -1 do
            local e = self.effects[i]
            if t - e.t0 >= e.dur then table.remove(self.effects, i) end
        end
    end
    for i = #self.buildings, 1, -1 do
        local b = self.buildings[i]
        if b.pillaged and t >= b.pillaged then
            b.pillaged = nil
            if not b.mine or b.mine.reserve > 0 then b.hp = b.maxHp end
        end
        if b.expireAt and t >= b.expireAt and b.hp > 0 then   -- spell buildings (walls, portals) fade
            b.hp = 0
            b.destroyed = true
            if b.shape then self:blockShape(b.gx, b.gy, b.shape, false) end
            if b.code == "BMEG" then require("src.game.unitspecials").hatchEggs(self, b) end   -- Spider Eggs hatch
        end
        if b.hp <= 0 and not b.rubbleSince and not self:canPillage(b) then
            b.rubbleSince = t
            -- the type's rubble type says what a destroyed building leaves behind: 1..3 a wreck that stays for a
            -- while, 0 nothing at all (walls, temples and flags fall to pieces at once)
            b.wreck = (b.type and b.type.rubbleType or 1) > 0 and M.wreckArt(b) or nil
            if b.shape then self:blockShape(b.gx, b.gy, b.shape, false) end
            self.eco:unload(b)
            -- a destroyed lair leaves its boss behind, a destroyed shop raises the hatred again
            require("src.game.sites").destroyed(self, b, b.razedBy)
            self:event("destroyed", b)
        end
        if b.rubbleSince and (not b.wreck or t - b.rubbleSince >= M.RUBBLE_MS) then
            table.remove(self.buildings, i)
        end
    end
    require("src.game.sites").update(self, t)
    self.events:update(t)
    require("src.game.attitude").update(self, t)      -- AI tick FUN_00429ec0: which sides' units check their attitude
    if self.ai then self.ai:update(t) end
end

return M
