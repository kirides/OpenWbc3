-- A unit ("army") on the battle map.
--
-- Movement is cell by cell: a step to a neighbouring cell takes
-- STEP_TIME[speed] ms (speed -8 uphill, +8 downhill) and plays part of the
-- walk cycle; the pixel position follows the per-frame move amounts of the
-- unit type so the feet don't slide. The unit claims its destination cell
-- when the step starts.
local content = require("src.content")
local gamedata = require("src.game.gamedata")
local anims = require("src.gfx.anims")
local pathMod = require("src.game.path")
local sprite = require("src.formats.sprite")
local rules = require("src.game.rules")
local sound = require("src.audio.sound")
local gameopts = require("src.core.gameopts")
local status = require("src.game.status")
local attitude = require("src.game.attitude")
local powerups = require("src.game.powerups")
local specials = require("src.game.unitspecials")
local armylevel = require("src.game.armylevel")
local missiles = require("src.game.missiles")

local A = sprite.ANIM
local CW, CH = 32, 24
local DX, DY = pathMod.DX, pathMod.DY

-- Idle units cycle their STAND frames every 100 ms; the six dragons (tag `dragon`) use 160 ms.
local function standFrameTime(code) return gamedata.hasTag(code, "dragon") and 160 or 100 end

-- Experience and levels for plain troops (the original gives every army experience and levels: the troop experience
-- routine FUN_0040da20 and its table at 0x005fbc50, 19 thresholds read from the binary). Levels count from 0 and the
-- control panel shows them as gold / silver medals; the statistic gains of a level (combat, speed, hits, damage,
-- resistance, armour) are the original's troop level-up FUN_0040daa0 (src/game/armylevel.lua).
local MAX_ARMY_LEVEL = 19                                   -- the 19 levels of the table above
local XP_FOR_LEVEL = { 0, 5, 10, 20, 40, 70, 110, 160, 220, 280, 350, 430, 520, 610, 700, 800, 900,
                       1100, 1300, 1500 }                   -- total experience needed at each level

-- The statistics of a unit (Unit:stats / Unit:baseStats) or an armed building (Eco:buildingStats).
---@class UnitStats
---@field combat number
---@field speed number
---@field armor number
---@field damage number
---@field damageType integer        0 piercing, 1 ice, 2 electricity, 3 fire, 4 magic, 5 crushing, 6 slashing
---@field range number
---@field strong integer            the damage class the armour is strong / weak against (-1 none)
---@field weak integer
---@field view number
---@field resistance number?
---@field hot boolean?              Flaming Arrows: the damage is piercing plus half of it as fire (status.lua)

-- An order of the unit's queue (Unit:enqueue): plain data, so savegame.lua can store it (except kind "fn").
---@class UnitOrder
---@field kind "move"|"attack"|"task"|"build"|"taskb"|"convert"|"fn"
---@field x integer?                move
---@field y integer?
---@field pace number?              move / attack: the formation's pace
---@field target (Unit|Building)?   attack
---@field auto boolean?             attack: an attitude's own attack
---@field task UnitTask?            task
---@field code string?              build
---@field gx integer?
---@field gy integer?
---@field what "convert"|"mine"|"garrison"|"visit"|nil taskb
---@field building Building?        taskb
---@field fn fun(u: Unit)?          fn

-- What a unit walks to and then does (Unit:orderTask).
---@class UnitTask
---@field kind "build"|"convert"|"visit"|"garrison"|"mine"
---@field range integer             how close (cells) it has to get
---@field building Building?
---@field code string?              build
---@field gx integer?
---@field gy integer?

-- A unit ("army") on the battle map; heroes are units with progression state `h` (hero.lua). Buildings are not units:
-- they are plain tables of their own class `Building` (economy.lua); both are `Entity`s and an attack target may be either.
---@class Unit: Entity
---@field kind "unit"
---@field world World
---@field set table                 the sprite set (gfx/anims.lua; a unit has one, Unit.new fails without)
---@field type UnitRecord?          the type record (gamedata.army: content `unit` record)
---@field side integer
---@field name string
---@field move integer              movement class (terrain.MOVE: 0 land, 1 fly, 2 sea, 3 float)
---@field anim integer
---@field frame integer
---@field standFrames integer
---@field nextStandFrame number?
---@field hp number
---@field maxHp number
---@field rule table?               Building.cfg [RULES] override of the side's race (rules.override)
---@field state "idle"|"move"|"attack"|"task"|"step"|"fight"|"convert"|"cast"|"stunned"|"hidden"|"dead"
---@field hero boolean              a hero unit
---@field h Hero?                   the hero's progression state
---@field mana number?              troops that cast spells (heroes keep theirs in `h.mana`)
---@field maxMana number?
---@field level integer?            troop level 0..19 (not heroes)
---@field xp number?                troop experience
---@field lvLevel integer?          Unit:levelGain's cache
---@field lvType table?
---@field lvGain table?
---@field morphMod {combat: number?, speed: number?, damage: number?}? Chaos morph
---@field fx table<string, StatusEffect>? status effects by kind (status.lua)
---@field illusion boolean?         an illusion (spells)
---@field cmdIn boolean?            inside a hero's command radius (morale.lua)
---@field armorLoss number?         the acid breath's armour reduction
---@field pace number?              the formation's pace
---@field autoChase boolean?        an attitude's own attack
---@field roaming boolean?          (only ever cleared)
---@field running boolean?          running away (attitude.lua: terror)
---@field target (Unit|Building)?   attack target
---@field goalX integer?            move goal
---@field goalY integer?
---@field path {[1]: integer, [2]: integer}[]? the cells still to walk
---@field repath boolean?
---@field pathGoalX integer?
---@field pathGoalY integer?
---@field blockedSince number?
---@field task UnitTask?
---@field converting {t0: number, t1: number}?
---@field hidden boolean?           inside a construction site, mine or garrison
---@field selected boolean?
---@field remove boolean?           taken off the map at the next update
---@field queue UnitOrder[]?
---@field patrol {points: {[1]: integer, [2]: integer}[], index: integer, heading: boolean?}?
---@field guarding Unit?
---@field animStart number?
---@field animDur number?
---@field animLoop boolean?
---@field step table?               the step in progress (Unit:beginStep)
---@field attack table?             the attack in progress (Unit:beginAttack)
---@field deadSince number?
---@field retinueIndex integer?     the retinue slot it came from
---@field wasHit boolean?           hit since the last attitude evaluation
---@field regenT number?
---@field regenAcc number?
---@field manaT number?
---@field manaAcc number?
---@field merge table?              wisps merging (armyabilities.lua)
---@field summonUntil number?       a summoned creature's end
---@field pendingCast {id: integer, target: any}?
---@field castUntil number?
---@field attSlice integer?         the attitude slice it was last evaluated in (attitude.lua)
---@field nextScan number?
---@field view table?               the idle fidget's picture (gfx/fidget.lua; display only)
---@field garrisoned Building?      the tower it is in
---@field attitude string?          attitude.lua
---@field post {[1]: integer, [2]: integer}? where an attitude returns to (attitude.lua)
---@field att {action: integer, extra: integer, tx: integer?, ty: integer?, target: integer?}? the attitude's action
---@field cmdTimer number?          morale.lua
---@field formationType integer?    formation.lua (nil: the default)
---@field formationDir integer?
---@field ammo integer?             the Troll's sheep / the Catapult's cows (unitspecials.lua)
---@field lastLeech number?         a Black Mage's mana leech pause
---@field recoverUntil number?      no spell before (spells.lua)
---@field nextSpell number?         a computer caster's next try (spells.lua)
---@field aiDrunk boolean?          armyabilities.lua
---@field lairHome Building?        the lair a monster came from (sites.lua)
---@field canRetinue boolean?       made during the battle: may join the retinue afterwards
---@field adopted boolean?          the campaign hero took the place of the scenario's
---@field voiceSet table?           the hero record's voice set (herocustom.lua)
local Unit = {}
Unit.__index = Unit

---@param dx number
---@param dy number
---@return integer? dir 0 = north, clockwise; nil for no offset
local function dirTo(dx, dy)
    -- 0 = north, clockwise; diagonal when neither axis dominates by 2x
    if dx == 0 and dy == 0 then return nil end
    local adx, ady = math.abs(dx), math.abs(dy)
    if adx > 2 * ady then return dx > 0 and 2 or 6 end
    if ady > 2 * adx then return dy > 0 and 4 or 0 end
    if dx > 0 then return dy > 0 and 3 or 1 end
    return dy > 0 and 5 or 7
end
Unit.dirTo = dirTo

-- Makes a unit of type `code` for `side` at the free cell nearest to (gx, gy); nil without sprites or room. `rec` is a
-- scenario army record or the like (name, hits, curHits, level, xp, hero ...).
---@param world World
---@param code string
---@param side integer
---@param gx integer
---@param gy integer
---@param rec table?
---@return Unit?
function Unit.new(world, code, side, gx, gy, rec)
    local t = gamedata.army(code)
    local set = anims.get(code)
    if not set then return nil end
    local fx, fy = world:nearestFree(gx, gy, t and t.moveType or 0)
    if not fx then return nil end
    ---@cast fy -nil
    local hits = (rec and rec.hits and rec.hits > 0 and not rec.useDefault) and rec.hits or (t and t.hits or 50)
    -- Building.cfg [RULES]: this race's version of the unit (see rules.override)
    local rule = world.sides[side] and rules.override(world.sides[side].race, code)
    if rule and rule.hits and not (rec and rec.hits and rec.hits > 0 and not rec.useDefault) then hits = rule.hits end

    ---@type Unit
    local u = setmetatable({
        kind = "unit", world = world, id = world:newId(), code = code, type = t, set = set, side = side,
        name = (rec and rec.name ~= "" and rec.name) or rules.unitName(code, t),
        move = t and t.moveType or 0,
        gx = fx, gy = fy,
        x = fx * CW + 16, y = fy * CH + 12,
        dir = 4, anim = A.STAND, frame = 0, standFrames = set:frames(A.STAND),
        nextStandFrame = world.time + 100,
        hp = hits, maxHp = hits, rule = rule,
        state = "idle",
        hero = (rec and rec.hero) or (rules.armyInfo(code) or {}).hero or false,
    }, Unit)
    if u.hero then
        -- scenario heroes carry a level and experience; computer heroes spend their points
        local lvl = rec and rec.level or 1
        if lvl < 1 or lvl > require("src.game.hero").MAX_LEVEL then lvl = 1 end
        local saved = { level = lvl, xp = rec and rec.xp or 0,
                        points = { attr = require("src.game.hero").ATTR_POINTS * (lvl - 1), skill = lvl - 1 } }
        local sd = world.sides[side]
        if sd and sd.fallenHero and not rec then
            -- a resurrected hero keeps what it had earned
            saved, sd.fallenHero = sd.fallenHero, nil
        end
        local h = u:makeHero(saved)
        if sd and sd.ai then h:autoSpend() end
    end
    if rec and rec.curHits and rec.curHits > 0 and rec.curHits < u.maxHp then u.hp = rec.curHits end
    if not u.hero then
        -- non-hero units that cast spells carry their own mana (Army.cfg MANA column "max:start"); the Library and
        -- Sorcery power-ups add 15 to both, and a computer side's armies start with 10 more when the maximum is at
        -- least start + 10 (the army mana setup FUN_00528cd0, called from the army initialiser FUN_00519ae0; the
        -- computer-player flag DAT_0070d6a4 is set for every non-human side, passive ones and the neutral side too)
        local info = rules.armyInfo(code)
        if info and info.maxMana then
            local bonus = powerups.manaBonus(world.sides[side])
            local start = info.startMana or 0
            u.maxMana = info.maxMana + bonus
            u.mana = start + bonus
            if world.humans and not world.humans[side] and start + 10 <= info.maxMana then u.mana = u.mana + 10 end
        end
        -- scenario armies come with a level and experience; the SCN's level counts from 0
        local lvl = rec and rec.level or 0
        if lvl < 0 then lvl = 0 end
        if lvl > MAX_ARMY_LEVEL then lvl = MAX_ARMY_LEVEL end
        u.level, u.xp = lvl, math.max(0, rec and rec.xp or 0)
        local gain = u:levelGain()
        if gain.hits > 0 then
            local full = u.hp >= u.maxHp
            u.maxHp = u.maxHp + gain.hits
            if full then u.hp = u.maxHp end
        end
    end
    world.occ[world:index(fx, fy)] = u
    return u
end

-- The type record's statistics with the Building.cfg per-race overrides, before the level.
local function rawStats(self)
    local t = self.type or {}

    ---@type UnitStats
    local st = {
        combat = t.combat or 5, speed = t.speed or 12, armor = t.armor or 0,
        damage = t.damage or 5, damageType = t.damageType or 6, range = t.range or 0,
        strong = t.strong or -1, weak = t.weak or -1, view = t.view or 6,
    }
    local rule = self.rule
    if rule then
        st.combat, st.speed = rule.combat or st.combat, rule.speed or st.speed
        st.damage, st.range = rule.damage or st.damage, rule.range or st.range
    end
    return st
end

local NO_GAIN = { combat = 0, speed = 0, hits = 0, damage = 0, resistance = 0, armor = 0 }

-- What the troop's level adds (FUN_0040daa0); heroes have their own progression.
---@return {combat: number, speed: number, hits: number, damage: number, resistance: number, armor: number}
function Unit:levelGain()
    local l = self.level
    if not l or l <= 0 or self.hero then return NO_GAIN end
    if self.lvLevel ~= l or self.lvType ~= self.type then
        local st, t = rawStats(self), self.type or {}
        local rule = self.rule
        self.lvGain = armylevel.gain({ combat = st.combat, speed = st.speed, damage = st.damage,
                                       hits = (rule and rule.hits) or t.hits or 50 }, l)
        self.lvLevel, self.lvType = l, self.type
    end
    return self.lvGain
end

local function typeStats(self)
    local st = rawStats(self)
    local l = self.level
    if l and l > 0 then
        local g = self:levelGain()
        st.combat, st.speed, st.damage, st.armor = st.combat + g.combat, st.speed + g.speed, st.damage + g.damage,
            st.armor + g.armor
    end
    return st
end

-- The statistics before power-ups, spell effects and status effects: what the original's statistic getters return
-- for their base-value option
-- (the stored army record; for a hero its own derived values, a chaos morph is kept). The info area prints the
-- difference to `stats()` as "+n" / "-n".
---@return UnitStats
function Unit:baseStats()
    local st = typeStats(self)
    if self.h then self.h:applyStats(st) end
    local m = self.morphMod
    if m then
        st.combat = math.max(1, math.min(99, st.combat + (m.combat or 0)))
        st.speed = math.max(1, math.min(99, st.speed + (m.speed or 0)))
        if st.damage > 0 then st.damage = math.max(1, math.min(999, st.damage + (m.damage or 0))) end
    end
    st.resistance = st.resistance or ((self.type and self.type.resistance) or 0) + self:levelGain().resistance
    return st
end

-- Resistance, base and real (the resistance getter FUN_00526b70): the type's value (a hero's own, with its items);
-- Black Ward, a resistance spell, the Warding skill of the side's living hero (every unit of the side, not only the
-- hero) count for the real one.
---@return number base, number real
function Unit:resistances()
    local base = self.h and self.h.mod.resistance or ((self.type and self.type.resistance) or 0) + self:levelGain().resistance
    return base, self:resistance()
end

---@return number
function Unit:resistance()
    if self.illusion then return 0 end
    local real = self.h and self.h.mod.resistance or powerups.unitResistance(self) + self:levelGain().resistance
    local fx = self.fx and self.fx.resistance
    if fx then real = real + (fx.value or 0) end
    local skills = require("src.game.heroskills")
    real = real + skills.value(self.world, self.side, skills.ids.Warding)
    if self.fx and self.fx.chaos then       -- under Chaos: never above the base value (FUN_00526b70)
        local base = ((self.type and self.type.resistance) or 0) + self:levelGain().resistance
        real = math.min(real, base)
    end
    return real
end

-- The complete armour (the armour getter 0x005260a0 for all types at once, real values) indexed by the original's
-- damage type numbers: 0 piercing, 1 ice, 2 electricity, 3 fire, 4 magic, 5 crushing, 6 slashing. Armour for the three physical types, the resistance for
-- fire / electricity / ice, magic 0; the resist spells add to their type (25 per success level), a hero's items and
-- skills add to theirs (Armorer piercing, Scales slashing, Thick Hide crushing, the four resistance skills and Elemental
-- Resistance), the Doombat's fire armour and an immolated unit's +15. Returns the strong damage type as well: the type
-- record's, or fire for the Doombat's firebat.
---@return table<integer, number> armour, integer strong
function Unit:completeArmour()
    local st = self:stats(true)
    local res = self:resistance()
    local a = { [0] = st.armor, res, res, res, 0, st.armor, st.armor }
    local strong = self.type and self.type.strong or -1
    local fx = self.fx
    if fx then
        if fx.resfire then a[3] = a[3] + (fx.resfire.value or 0) end
        if fx.resmagic then a[4] = a[4] + (fx.resmagic.value or 0) end
        if fx.fanatic then a[3] = a[3] + 15 end                 -- immolation type 2 (the Fanaticism ability)
    end
    local h = self.h
    if h then
        for t, v in pairs(h.mod.armorSkill) do a[t] = a[t] + v end
        for t, v in pairs(h.mod.resistSkill) do a[t] = a[t] + v end
        local items = h.mod.resist or {}
        a[1] = a[1] + (items.ice or 0)
        a[2] = a[2] + (items.electricity or 0)
        a[3] = a[3] + (items.fire or 0)
        a[4] = a[4] + (items.magic or 0)
    else
        local extra = powerups.fireArmour(self)                  -- Doombat
        if extra > 0 then a[3], strong = a[3] + extra, 3 end
    end
    return a, strong
end

-- `noPace` leaves out the formation pace (the info area shows the unit's own speed).
---@return UnitStats
function Unit:stats(noPace)
    local st = typeStats(self)
    local chaos = self.fx and self.fx.chaos
    if self.fx and not chaos then status.powerDamage(self, st) end   -- Fire Breathing / Ice Floe: the damage getter's best effect
    require("src.game.powerups").applyStats(self, st)
    if self.h then self.h:applyStats(st) end
    if self.morphMod then                       -- Chaos morph spells change the base stats for good
        local m = self.morphMod
        ---@cast m -nil
        st.combat = math.max(1, math.min(99, st.combat + (m.combat or 0)))
        st.speed = math.max(1, math.min(99, st.speed + (m.speed or 0)))
        if st.damage > 0 then st.damage = math.max(1, math.min(999, st.damage + (m.damage or 0))) end
    end
    -- the weather's combat modifier (FUN_0051bd10: day / night / rain / fine per race), at least 1; before the
    -- status effects, which the original subtracts afterwards
    st.combat = math.max(1, st.combat + require("src.game.weather").combatMod(self.world, self.code))
    if self.illusion then                       -- FUN_0043c450: combat 1, damage 1, no armour or resistance, half range
        st.combat, st.damage, st.armor, st.resistance = 1, 1, 0, 0
        st.range = math.floor(st.range / 2)
    end
    if self.cmdIn then                          -- inside the command radius of a hero (game/morale.lua)
        local c, s = require("src.game.morale").bonus(self)
        st.combat, st.speed = st.combat + c, st.speed + s
    end
    if self.fx then require("src.game.status").stats(self, st) end
    -- the acid breath's armour reduction comes last, the armour getter's final step (never below 0)
    if self.armorLoss then st.armor = math.max(0, st.armor - self.armorLoss) end
    if chaos then require("src.game.psych").chaosStats(self, st) end
    if self.pace and not noPace and self.pace < st.speed then st.speed = self.pace end
    return st
end

-- Turns the unit into a hero with progression state (see src/game/hero.lua).
---@param saved table? a Hero:save() table
---@return Hero
function Unit:makeHero(saved)
    self.hero = true
    self.h = require("src.game.hero").new(self, saved)
    return self.h
end

---@return boolean
function Unit:alive() return self.state ~= "dead" and not self.hidden end

-- Orders --------------------------------------------------------------------

---@param tx integer
---@param ty integer
function Unit:orderMove(tx, ty)
    if not self:alive() then return end
    self.autoChase, self.roaming, self.running = false, nil, nil
    self.target = nil
    self.goalX, self.goalY = tx, ty
    self.path = nil
    self.repath = true
    self.blockedSince = nil
    if self.state ~= "step" then self.state = "move" end
end

---@param target Unit|Building
---@param auto boolean? an attitude's own attack
function Unit:orderAttack(target, auto)
    if not self:alive() or target == self then return end
    -- under terror an army cannot attack anything: it runs (not traced in the 1.04 binary yet)
    if self.fx and self.fx.terror then
        require("src.game.attitude").run(self, target)
        return
    end
    self.autoChase = auto or false      -- an attitude's own attack (it returns to its post afterwards)
    self.pace = nil
    self.target = target
    self.path = nil
    self.repath = true
    if self.state ~= "step" then self.state = "attack" end
end

-- Tasks: walk next to something, then act (build, convert, enter a mine).
---@param task UnitTask
function Unit:orderTask(task)
    if not self:alive() then return end
    self.autoChase, self.roaming = false, nil
    self.pace = nil
    self.target, self.goalX = nil, nil
    self.task = task
    self.path = nil
    self.repath = true
    if self.state ~= "step" then self.state = "task" end
end

---@param code string
---@param gx integer
---@param gy integer
function Unit:orderBuild(code, gx, gy)
    self:orderTask({ kind = "build", code = code, gx = gx, gy = gy, range = 1 })
end

-- Conversion range: a hero converts within its command radius (at most 19), anyone else within 4 (FUN_00523af0).
---@return number
function Unit:convertRange()
    if self.h then return math.min(19, self.h.mod.commandRadius) end
    return 4
end

-- What a computer side's conversion uses (the conversion routine FUN_0051cbb0: 3 more than the range of a human side's
-- conversion, so that a converting hero does not get stuck); the conversion list is a circle of this radius round the
-- unit (Eco:conversionList).
---@return number
function Unit:conversionRange()
    local range = self:convertRange()
    if self.world.sides[self.side].ai then range = range + 3 end
    return range
end

-- How close a walk to a building must get before the unit starts converting it: the list is a circle, the walk stops by
-- the Chebyshev distance, whose worst case (a diagonal) is 1.41 times the circle's radius.
---@return integer
function Unit:convertWalkRange()
    return math.max(1, math.floor(self:conversionRange() / 1.5))
end

---@param b Building
function Unit:orderConvert(b)
    self:orderTask({ kind = "convert", building = b, range = self:convertWalkRange() })
end

-- Begin a conversion at the unit's current spot. The time follows the hero's Conversion bonus, a general's
-- Holy Relic / Dryad / Bronze General's golem three-quarter rate and the side's power-ups (binary: conversion time).
---@param t number world time
function Unit:startConversion(t)
    local factor = self.h and self.h.mod.conversion or 1
    local ms = require("src.game.economy").CONVERT_TIME * factor
    if not self.h then
        local side = self.world.sides[self.side]
        local secs = ms / 1000
        local conv = self.type and self.type.behaviour and self.type.behaviour.conversion
        if conv and (not conv.powerup or powerups.has(side, conv.powerup)) then
            secs = math.max(1, math.floor(secs * conv.num / conv.den))
        end
        ms = powerups.conversionSeconds(side, secs) * 1000
    end
    self.converting = { t0 = t, t1 = t + ms }
    self.state = "convert"
    self.world:event("converting", self)
end

-- A queued / inserted convert (the original's deferred/appended convert order): converts whatever is in
-- range where the unit stands when the order runs, so a Shift-queued convert fires at the spot the unit reached.
function Unit:convertHere()
    if #self.world.eco:conversionTargets(self) == 0 then
        self:setIdle(self.world.time)
        return
    end
    self:startConversion(self.world.time)
end

---@param b Building
function Unit:orderVisit(b)
    self:orderTask({ kind = "visit", building = b, range = 2 })
end

---@param b Building
function Unit:orderGarrison(b)
    self:orderTask({ kind = "garrison", building = b, range = 1 })
end

---@param b Building
function Unit:orderEnterMine(b)
    self:orderTask({ kind = "mine", building = b, range = 1 })
end

-- Hides the unit (inside a construction site or mine); permanent removes it.
---@param permanent boolean? remove it for good
function Unit:vanish(permanent)
    local world = self.world
    if world.occ[world:index(self.gx, self.gy)] == self then world.occ[world:index(self.gx, self.gy)] = nil end
    self.hidden = true
    self.selected = false
    self.task, self.target, self.path, self.goalX = nil, nil, nil, nil
    self.state = "hidden"
    if permanent then self.remove = true end
end

---@param gx integer
---@param gy integer
function Unit:reappear(gx, gy)
    local world = self.world
    self.hidden = false
    self.gx, self.gy = gx, gy
    self.x, self.y = gx * CW + 16, gy * CH + 12
    world.occ[world:index(gx, gy)] = self
    self:setIdle(world.time)
end

function Unit:stop()
    self.task = nil
    self.target, self.path, self.goalX = nil, nil, nil
    self.queue, self.patrol, self.guarding, self.roaming = nil, nil, nil, nil
    if self.state ~= "step" and self.state ~= "dead" then self:setIdle(self.world.time) end
end

-- Order queue (shift + order): orders wait in `queue` and start one after the other when the unit has nothing to do.
-- An order is { kind = "move", x, y, pace } | { kind = "attack", target } | { kind = "task", task } |
-- { kind = "build", code, gx, gy } | { kind = "taskb", what = convert|mine|garrison|visit, building } | { kind = "convert" }
-- (the last is the original's deferred convert: a queued convert with no building bound, which converts whatever
-- is in range where the unit stands when the order runs) (all plain data, so savegame.lua can store the queue) |
-- { kind = "fn", fn } (not saved).
---@param order UnitOrder
function Unit:enqueue(order)
    if not self:alive() then return end
    if self.state == "idle" and not (self.queue and #self.queue > 0) and not self.patrol then
        self:runOrder(order)
    else
        self.queue = self.queue or {}
        self.queue[#self.queue + 1] = order
    end
end

---@param o UnitOrder
function Unit:runOrder(o)
    if o.kind == "move" then
        self:orderMove(o.x, o.y)
        self.pace = o.pace
    elseif o.kind == "attack" then
        if o.target and ((o.target.kind == "unit" and o.target:alive()) or (o.target.kind == "building" and o.target.hp > 0)) then
            self:orderAttack(o.target, o.auto)
            self.pace = o.pace
        end
    elseif o.kind == "task" then self:orderTask(o.task)
    elseif o.kind == "build" then self:orderBuild(o.code, o.gx, o.gy)
    elseif o.kind == "taskb" then
        local b = o.building
        ---@cast b -nil
        if o.what == "convert" then self:orderTask({ kind = "convert", building = b, range = self:convertWalkRange() })
        elseif o.what == "mine" then self:orderEnterMine(b)
        elseif o.what == "garrison" then self:orderGarrison(b)
        elseif o.what == "visit" then self:orderVisit(b) end
    elseif o.kind == "convert" then self:convertHere()
    elseif o.kind == "fn" then o.fn(self) end
end

-- The order the unit is carrying out right now, as plain data (the head of the original's order queue). Mirrors
-- savegame.lua saveOrders: task first, then an attack target, then a move goal.
---@return UnitOrder?
function Unit:currentOrder()
    if self.task then return { kind = "task", task = self.task }
    elseif self.target then return { kind = "attack", target = self.target, auto = self.autoChase or nil, pace = self.pace }
    elseif self.goalX then return { kind = "move", x = self.goalX, y = self.goalY, pace = self.pace } end
end

-- Alt + order (the original's insert queue mode, the insert branch of the move / attack orders FUN_0051d6b0 /
-- FUN_0051da60): the new order goes to the
-- head of the queue and starts immediately, the order that was running stays right behind it and resumes when the
-- new one finishes, and the waiting orders keep their place. A conversion in progress is interrupted, not kept
-- (the binary stops a running conversion before an insert; the stop drops a convert order at the head). With nothing
-- running and nothing waiting this is a plain order (the original clears the mode when there is no running order).
---@param order UnitOrder
function Unit:insertOrder(order)
    if not self:alive() then return end
    -- a conversion in progress is interrupted, not kept (the binary stops a running conversion before an insert)
    if self.converting then
        self.converting = nil
        if self.state == "convert" then self:setIdle(self.world.time) end
    end
    local running = self:currentOrder()
    if not running and not (self.queue and #self.queue > 0) and not self.patrol then
        self:runOrder(order)
        return
    end
    -- skip when the new order repeats the one being carried out (the insert branch's already-done check)
    if running and running.kind == order.kind and running.kind ~= "task" then
        local same = running.kind == "move" and running.x == order.x and running.y == order.y
            or (running.kind == "attack" and running.target == order.target)
        if same then return end
    end
    if running then
        self.queue = self.queue or {}
        table.insert(self.queue, 1, running)
    end
    self:runOrder(order)
end

-- A new order without shift replaces the whole queue and patrol (with Alt the queue is kept and resumes afterwards).
---@param keepQueue boolean?
function Unit:clearOrders(keepQueue)
    if not keepQueue then self.queue, self.patrol = nil, nil end
    self.guarding, self.roaming = nil, nil
end

-- Shift+Esc: drops the last queued order; End: all but the running one.
---@return boolean
function Unit:removeLastOrder()
    if self.queue and #self.queue > 0 then table.remove(self.queue) return true end
    if self.patrol then self.patrol = nil return true end
    return false
end

---@return boolean
function Unit:removeQueuedOrders()
    local had = (self.queue and #self.queue > 0) or self.patrol ~= nil
    self.queue, self.patrol = nil, nil
    return had
end

-- Patrol: walk between the points in a loop, fighting what comes near (Shift adds points to the path).
---@param points {[1]: integer, [2]: integer}[]
---@param append boolean? Shift: add the points to the patrol
function Unit:setPatrol(points, append)
    if not self:alive() then return end
    if append and self.patrol then
        for _, p in ipairs(points) do self.patrol.points[#self.patrol.points + 1] = p end
    else
        local pts = { { self.gx, self.gy } }
        for _, p in ipairs(points) do pts[#pts + 1] = p end
        self.patrol = { points = pts, index = 1 }
        self.queue = nil
        self.guarding = nil
    end
    if self.state == "idle" then self:nextPatrolPoint() end
end

function Unit:nextPatrolPoint()
    local pt = self.patrol
    if not pt or #pt.points == 0 then return end
    local cur = pt.points[pt.index]
    if pt.heading and math.max(math.abs(cur[1] - self.gx), math.abs(cur[2] - self.gy)) > 1 then
        self:orderMove(cur[1], cur[2])      -- back to the point it was heading for before a fight
        return
    end
    pt.index = pt.index % #pt.points + 1
    pt.heading = true
    local p = pt.points[pt.index]
    self:orderMove(p[1], p[2])
end

-- Guard: stay near a friendly unit and fight what threatens it.
---@param other Unit
function Unit:setGuard(other)
    if not self:alive() or other == self then return end
    self.queue, self.patrol = nil, nil
    self.guarding = other
end

-- Animation helpers -----------------------------------------------------------

---@param t number world time
function Unit:setIdle(t)
    self.pace = nil
    self.state = "idle"
    self.anim, self.frame = A.STAND, 0
    self.animStart = t
    self.nextStandFrame = t + standFrameTime(self.code)
end

---@param anim integer
---@param t number
---@param duration number ms
---@param loop boolean
function Unit:startAnim(anim, t, duration, loop)
    self.anim = anim
    self.animStart = t
    self.animDur = duration
    self.animLoop = loop
    self.frame = 0
end

-- Geometry --------------------------------------------------------------------

---@param other Unit|Building
---@return number
function Unit:cellDistance(other)
    if other.kind == "building" and other.shape then
        local best = math.huge
        for _, c in ipairs(self.world:shapeCells(other.gx, other.gy, other.shape)) do
            local d = math.max(math.abs(c[1] - self.gx), math.abs(c[2] - self.gy))
            if d < best then best = d end
        end
        return best
    end
    return math.max(math.abs(other.gx - self.gx), math.abs(other.gy - self.gy))
end

---@return number
function Unit:attackRange()
    -- the damage getter: a Troll after a sheep, a Catapult after a cow, a Minotaur after a critter and a daemon after a Soul
    -- walk over and pick the victim up (range 0)
    local tg = self.target
    if tg and specials.meleeOnly(self, tg) then return 1 end
    local r = self:stats().range
    if r <= 1 then return 1 end
    return r
end

-- Stepping --------------------------------------------------------------------

---@param nx integer
---@param ny integer
---@param t number
function Unit:beginStep(nx, ny, t)
    local world = self.world
    local d = dirTo(nx - self.gx, ny - self.gy)
    local t0 = self.type
    local set = self.set
    local maxFrames = math.max(1, set:frames(A.WALK))
    local ft = t0 and t0.fineTune or { 1, 1, 1, 1 }
    local num
    if d % 2 == 1 then
        num = (ft[4] ~= 0) and math.floor(ft[3] * maxFrames / ft[4]) or maxFrames
    else
        num = (ft[2] ~= 0) and math.floor(ft[1] * maxFrames / ft[2]) or maxFrames
    end
    if num <= 0 then num = maxFrames end

    local speed = self:stats().speed
    if self.move ~= 1 and self.move ~= 3 then
        local h0, h1 = world.terrain:heightAt(self.gx, self.gy), world.terrain:heightAt(nx, ny)
        if h1 > h0 then speed = speed - 8 elseif h1 < h0 then speed = speed + 8 end
    end
    speed = math.max(0, math.min(30, speed))
    local dur = gamedata.STEP_TIME[speed]
    if d % 2 == 1 then dur = dur * 1.2 end

    local startFrame = self.anim == A.WALK and ((self.frame + 1) % maxFrames) or math.random(0, maxFrames - 1)
    -- cumulative move amounts over the frames of this step
    local cum, total = { [0] = 0 }, 0
    local amounts = t0 and t0.moveAmount
    for i = 0, num - 1 do
        local a = amounts and amounts[(startFrame + i) % maxFrames] or 1
        total = total + a
        cum[i + 1] = total
    end
    if total == 0 then
        for i = 0, num do cum[i] = i end
        total = num
    end

    world.occ[world:index(self.gx, self.gy)] = nil
    world.occ[world:index(nx, ny)] = self
    self.step = {
        fromX = self.x, fromY = self.y, toX = nx * CW + 16, toY = ny * CH + 12,
        t0 = t, dur = dur, num = num, startFrame = startFrame, maxFrames = maxFrames,
        cum = cum, total = total,
    }
    self.gx, self.gy = nx, ny
    self.dir = d
    self.anim = A.WALK
    self.state = "step"
end

---@param t number
---@return boolean done
function Unit:updateStep(t)
    local s = self.step
    ---@cast s -nil
    local p = (t - s.t0) / s.dur
    if p >= 1 then
        self.x, self.y = s.toX, s.toY
        self.frame = (s.startFrame + s.num - 1) % s.maxFrames
        self.step = nil
        return true
    end
    local fp = p * s.num
    local k = math.floor(fp)
    local frac = fp - k
    local a = (s.cum[k] + (s.cum[k + 1] - s.cum[k]) * frac) / s.total
    self.x = s.fromX + (s.toX - s.fromX) * a
    self.y = s.fromY + (s.toY - s.fromY) * a
    self.frame = (s.startFrame + k) % s.maxFrames
    return false
end

-- Follows self.path toward (goalX, goalY); returns true when the goal is reached
-- or unreachable.
---@param t number
---@param goalX integer
---@param goalY integer
---@param stopDist number?
---@return boolean
function Unit:advance(t, goalX, goalY, stopDist)
    local world = self.world
    if math.max(math.abs(goalX - self.gx), math.abs(goalY - self.gy)) <= (stopDist or 0) then return true end
    if self.repath or not self.path or #self.path == 0 then
        self.path = world:findPath(self, goalX, goalY)
        self.repath = false
        self.pathGoalX, self.pathGoalY = goalX, goalY
        if #self.path == 0 then return true end
    end
    local nxt = self.path[1]
    if world:free(nxt[1], nxt[2], self.move, self) then
        table.remove(self.path, 1)
        self.blockedSince = nil
        self:beginStep(nxt[1], nxt[2], t)
        return false
    end
    -- blocked by another unit: wait a little, then path around it
    local other = world:unitAt(nxt[1], nxt[2])
    self.blockedSince = self.blockedSince or t
    if t - self.blockedSince > 400 or (other and other.state == "idle") then
        self.blockedSince = nil
        self.repath = true
        if other and other.side == self.side and other.state == "idle" and #self.path <= 1 then
            return true   -- destination taken by a friend: good enough
        end
    end
    if self.anim == A.WALK then
        self.anim, self.frame = A.STAND, 0
        self.nextStandFrame = t + standFrameTime(self.code)
    end
    return false
end

-- Combat ------------------------------------------------------------------------

local HIT = { MISS = 0, MARGINAL = 1, GOOD = 2, CRITICAL = 3, DEATHBLOW = 4 }
-- Damage types of the type records: 0 piercing, 1 ice, 2 electricity, 3 fire, 4 magic, 5 crushing, 6 slashing (checked
-- against the data: Frost Dragon 1, Storm Dragon 2, Fire Elemental 3). 1..4 are the elemental ones (resistances from
-- items apply to them). The spells and status effects (spells.lua, status.lua) number them fire 1, ice 2, electricity 3.
-- A critical hit applies the damage type's special attack (see Unit:strike): piercing ignores armour, ice freezes for
-- 8 s (the original's slow-all effect of 6, kind slow), electricity drains mana, fire immolates, magic dispels,
-- crushing stuns, slashing cleaves an area hit around the attacker; the petrify missile EMM5 kills its victims (a
-- survivor is frozen).

local function armorOf(target, dmgType)
    local t = target.type or {}
    if target.kind == "unit" then
        -- the complete armour of that damage type: armour, resistance, skills, items and effects (Unit:completeArmour)
        local a, strong = target:completeArmour()
        return a[dmgType] or 0, strong, t.weak or -1
    end
    return t.armor or 0, t.strong or -1, t.weak or -1
end

local damagetypes = content.damagetype
local function covers(class, dmgType)
    -- 7 all physical (pierce, crush, slash), 8 pierce+slash, 9 the elements, 10 all: the `classes` of the damage type records
    if class == dmgType then return true end
    local dt = damagetypes:bySlot(dmgType)
    if dt then return dt.classes[class] == true end
    return class == 10
end

-- Armour, strong / weak classes, resist spells and the hero's element resistances applied to `dmg` of type `dmgType`.
-- `ignoreArmour` zeroes the armour value (a critical piercing hit: the melee routine FUN_0042ace0 zeroes the armour).
-- `ia` is the attacking hero's Ignore Armor effect: it takes that much off the armour and 5 percent per point off the
-- 50 percent a strong armour absorbs (at most 50; binary FUN_0042ace0).
---@param target Unit|Building
---@param dmg number
---@param dmgType integer
---@param ranged boolean
---@param ignoreArmour boolean?
---@param ia number?
---@return number
local function soften(target, dmg, dmgType, ranged, ignoreArmour, ia)
    local armor, strong, weak = armorOf(target, dmgType)
    if target.kind == "building" and dmgType ~= 4 then armor = armor + 10 end
    if ignoreArmour then armor = 0 end
    ia = ia or 0
    if ia > 0 then armor = math.max(0, armor - ia) end
    if covers(strong, dmgType) then dmg = dmg - math.floor((50 - math.min(50, ia * 5)) * dmg / 100)
    elseif covers(weak, dmgType) then dmg = dmg + math.floor(dmg / 2) end
    if armor >= dmg * 4 then dmg = math.floor(dmg / 5)
    elseif armor >= dmg * 3 then dmg = math.floor(dmg / 4)
    elseif armor >= dmg * 2 then dmg = math.floor(dmg / 3)
    elseif armor >= dmg then dmg = math.floor(dmg / 2)
    else dmg = math.floor(armor / 2) + (dmg - armor) end
    dmg = math.max(1, dmg)
    -- the resist spells and a hero's item resistances are part of the complete armour now; what is left is Resist Missiles
    if target.fx then dmg = status.reduce(target, nil, ranged, dmg) end
    return dmg
end
Unit.soften = soften

-- critters: no assassination of these
local function isCritter(code) return gamedata.hasTag(code, "critter") end
Unit.isCritter = isCritter
-- the fourth letter of the Army.cfg STATUS column marks titans; they gain no experience (the army's titan flag at
-- +0x1cd, set by the army initialiser FUN_00519ae0 and tested by the experience routine FUN_00527100)
local function isTitanUnit(code) return gamedata.hasTag(code, "titan") end
Unit.isTitanUnit = isTitanUnit
Unit.MAX_ARMY_LEVEL = MAX_ARMY_LEVEL
Unit.XP_FOR_LEVEL = XP_FOR_LEVEL   -- 1-based: index level + 1 is the total experience for a level

-- The questions the battle cursor choice (FUN_00420390) and the right-click order chain (0x00421190)
-- ask in the same order, so the cursor and the order agree: both go through these. Ground and air
-- attacks follow the type's attack type (0 none / 1 ground / 2 air / 3 ground and air).
---@return boolean
function Unit:canAttackGround() return (self.type and self.type.attackType or 0) % 2 == 1 end
---@return boolean
function Unit:canAttackAir() return (self.type and self.type.attackType or 0) >= 2 end

-- The garrison test (FUN_0051c240): the army's shape width, its unit value (openwbc3 never stacks
-- units, so it is always 1), the flyer flag, a builder that is not a hero, a critter, an illusion or an Eye.
---@return boolean
function Unit:canGarrison()
    if (self.type and self.type.shape and self.type.shape.w or 1) > 1 then return false end
    if (self.type and self.type.unitValue or 0) > 1 then return false end
    if gamedata.hasTag(self.code, "flyer") then return false end
    if powerups.buildSkill(self) > 0 and not self.hero then return false end
    if isCritter(self.code) or self.illusion or gamedata.hasTag(self.code, "noGarrison") then return false end
    return true
end

-- The mine-work test (FUN_00523e70): the army's building skill; 0 for heroes, wisps, treants and
-- the eagle, 2 for the Dwarf Smith and the Engineer, 1 for any other builder.
---@return integer places it takes (0 = cannot)
function Unit:canWorkInMine()
    if self.hero then return 0 end
    if gamedata.hasTag(self.code, "noMine") then return 0 end
    local skill = self.type and self.type.behaviour and self.type.behaviour.mineSkill
    if skill then return skill end
    if powerups.buildSkill(self) > 0 then return 1 end
    return 0
end

-- The Minotaur status flag: the M of the Army.cfg STATUS column's race letter (the STATUS reader FUN_005856e0).
-- A Minotaur right-clicked on one of its own critters gets the plain attack order (right-click chain 0x00421190)
-- and eats it: the critter's death heals the attacker by 20 hits (army death FUN_005210b0, "Eating.wav").
---@return boolean
function Unit:isMinotaur()
    return require("bit").band(powerups.flags(self.code), 0x80) ~= 0
end

-- Experience for a plain troop (FUN_0040da20): the total is capped at 20000 and the level follows
-- the XP table; returns the number of levels gained.
---@param n number
---@return integer levels gained
function Unit:addXp(n)
    if self.hero or isTitanUnit(self.code) then return 0 end
    self.xp = math.max(0, math.min(20000, (self.xp or 0) + n))
    local level, gained = self.level or 0, 0
    while level < MAX_ARMY_LEVEL and self.xp >= XP_FOR_LEVEL[level + 2] do
        level = level + 1
        gained = gained + 1
    end
    local before = self:levelGain().hits
    self.level = level
    local more = self:levelGain().hits - before
    if more > 0 then              -- a level adds to the hits and the new hits are there at once (FUN_0040daa0)
        self.maxHp = self.maxHp + more
        if self.hp > 0 then self.hp = self.hp + more end
    end
    return gained
end

-- What a hero's melee skills add to the damage of a strike (binary FUN_0042ace0: only the hero attacker reads them,
-- Reave and Thievery are not read there): the slayers and Smite skills against the target kinds (powerups.flags bits:
-- human 0x1, dwarf 0x2, undead 0x4, elves 0x38, minotaur 0x80, orc 0x100, monster 0x800, dragon 0x1000, daemon
-- 0x800000, Ssrathi 0x1000000, good 0x2000000, evil 0x8000000, small 0x20000000) and Demolition against buildings. The
-- sum is added to the base damage after the power-up factors and before the hit type's multiplier.
local HERO_MELEE = {
    { 35, 0x1 }, { 36, 0x4 }, { 37, 0x1000 }, { 38, 0x800000 }, { 39, 0x2 }, { 40, 0x38 }, { 41, 0x100 },
    { 43, 0x2000000 }, { 44, 0x8000000 }, { 47, 0x1000000 }, { 48, 0x800 }, { 49, 0x80 }, { 50, 0x20000000 },
}
local function heroMeleeBonus(att, target)
    local h = att.h
    if not h then return 0 end
    if target.kind ~= "unit" then return h:effect(46) end
    local f, n, band = powerups.flags(target.code), 0, require("bit").band
    for _, s in ipairs(HERO_MELEE) do
        if band(f, s[2]) ~= 0 then n = n + h:effect(s[1]) end
    end
    return n
end

Unit.heroMeleeBonus = heroMeleeBonus

-- The attacker's innate poison / disease (the type record's psych effect, type 5 poison / 6 disease): the Zombie and
-- the Chameleon carry one in their type record, and Rabies gives the Barbarian's Wolf Rider a disease of strength 5
-- (the Rabies power-up FUN_00438ca0). A diseased attacker spreads its disease too (the hit resolution 0x0051abe0).
local function psychOf(att)
    local p = att.type and att.type.psych
    if p and (p.type == 5 or p.type == 6) then return p.type, p.strength end
    local with = att.type and att.type.behaviour and att.type.behaviour.psychWith
    if with then
        local side = att.world.sides[att.side]
        if side and powerups.has(side, with.powerup) then return with.type, with.strength end
    end
    if att.fx and att.fx.disease then return 6, 5 end
    return nil
end

-- The special attacks of the acid, evil and good dragon breath (the second switch of Hit, binary FUN_005427e0, on the picture's
-- special attack set by FUN_0053f180: EMF3 reduces armour by 2, EMF4 drains 10 experience, EMF5 crystallizes). They are sent to armies
-- only, with no resistance roll, and the first two only to one that is still alive after the damage (FUN_00527ff0 / FUN_00527ed0 return
-- at 0 hits); `atk` is the missile record's `attack`, `crystal` whether the hit takes the army (decided before the damage).
--   reduce armour (message 0x224, FUN_00527ff0): +2 to the army's armour reduction (+0x20c), which the armour getter (0x005260a0) subtracts
--       from the base armour at its very end (at least 0), for good, stacking, saved with the army (Game.txt 863, picture EZ15);
--   drain experience (0x223, FUN_00527ed0): a troop's experience falls by 10, at least 0, and a hero's too (the original only on the
--       machine of its owner; the levels stay, no new level comes before the experience is earned again) (Game.txt 864 with the amount, EZ15);
--   crystallize (0x214, FUN_004a9d90 -> FUN_00528190): the army is killed at once without a corpse (FUN_0051a130, then
--       the death FUN_005210b0 with the shooter as killer), the shooter's side gets 100 crystal (the value in the binary and in the text of Game.txt 1148, shown
--       over a shooting army), blue particles and Crystallize.wav at the army.
---@param shooter Unit|Building
---@param victim Unit
---@param atk table the missile record's `attack`
---@param crystal boolean?
function Unit.breathSpecial(shooter, victim, atk, crystal)
    local world = shooter.world
    if crystal then
        if victim:alive() then return end
        victim.remove = true
        local side = world.sides[shooter.side]
        if side then
            local before = side.crystal or 0
            side.crystal = math.min(world.eco and world.eco:cap(shooter.side) or 99999, before + 100)
            if side.crystal > before then world:battleStats():resource(shooter.side, "crystal", side.crystal - before, "obtained") end
        end
        world:event("crystallize", victim, shooter)
        if shooter.kind == "unit" then world:event("tinymsg", shooter, 1148, 1) end
    elseif atk.kind == "reduceArmour" and victim:alive() then
        victim.armorLoss = (victim.armorLoss or 0) + atk.amount
        world:event("tinymsg", victim, 863, 2)
        world:event("critfx", victim, 863, shooter, true)
    elseif atk.kind == "drainXp" and victim:alive() then
        if victim.h then victim.h.xp = math.max(0, victim.h.xp - atk.amount)
        elseif victim.xp then victim.xp = math.max(0, victim.xp - atk.amount) end
        world:event("tinymsg", victim, 864, 2, atk.amount)
        world:event("critfx", victim, 864, shooter, true)
    end
end

---@param target Unit|Building
---@param missile table? the missile that hit (missiles.lua)
---@return integer hit, number damage
function Unit:strike(target, missile)
    local world = self.world
    local st = self:stats()
    -- a building defends with its real combat: type record + computer-player level + garrison (the building's combat
    -- value; not traced in the 1.04 binary yet)
    local combatB
    if target.kind == "unit" then combatB = target:stats().combat
    elseif target.type and target.type.combat and world.eco then combatB = world.eco:buildingCombat(target)
    else combatB = (target.type and target.type.combat) or 5 end
    local combatA = math.max(1, st.combat)
    local base = math.floor(100 * combatA / math.max(1, combatA + combatB))
    local deathblow = math.max(1, math.floor(base / 12))
    local ranged = self:attackRange() > 1
    -- Weaponmaster adds its effect to a hero's critical chance in melee (binary FUN_0042ace0)
    local critical = math.max(2, math.floor(base / 6)) + (self.h and self.h.mod.critical or 0)
        + ((self.h and not ranged) and self.h:effect(33) or 0)
    local roll = math.random(1, 100)
    local mcode = ranged and powerups.shotCode(self) or nil
    local petrify = mcode == "EMM5"        -- the basilisk's / Titan Orc's petrifying missile
    local dmg = st.damage
    -- the pick-up fights (a Troll and a sheep ...) strike with damage 100; a thrown sheep / cow does three times the damage
    dmg = specials.pickupDamage(self, target) or dmg
    if missile and missile.damageMul then dmg = dmg * missile.damageMul end
    -- a splashing missile hits the cells round its landing with 3/4, the second ring with 3/4 of that (Splash)
    for _ = 1, missile and missile.rings or 0 do dmg = math.floor(dmg * 3 / 4) end
    local ia = 0
    if not ranged then
        dmg = dmg * powerups.meleeFactor(self, target)      -- Paladin, Fallen Knight, Cowards ...
        dmg = dmg + heroMeleeBonus(self, target)            -- slayers, Smite, Demolition
        ia = self.h and self.h:effect(42) or 0               -- Ignore Armor
    end
    local hit
    if missile then
        -- a missile does a normal hit: the missile impact (binary FUN_005427e0) works out its damage with hit type 2
        -- (normal hit) and the melee combat table (FUN_0042ace0) is only called for range 0 / 1 attackers (FUN_00536e30);
        -- the shooter's skill decides whether the missile flies true instead (missiles.lua)
        hit = HIT.GOOD
    elseif roll <= deathblow then
        hit, dmg = HIT.DEATHBLOW, dmg * 4
        -- the attacker shouts its "Deathblow" line (FUN_0042ace0 asks the unit voice FUN_0050be80 for it, melee against armies)
        if not ranged and target.kind == "unit" then world:event("deathblow", self) end
    elseif roll <= critical then hit, dmg = HIT.CRITICAL, dmg * 2
    elseif roll <= base then hit = HIT.GOOD
    elseif roll <= base * 2 then hit, dmg = HIT.MARGINAL, math.floor(dmg / 2)
    else hit, dmg = HIT.MISS, 1 end

    -- a critical hit (deathblow or critical) triggers the damage type's special attack: melee in FUN_0042ace0,
    -- a missile on its own 4 percent roll made when it was launched (the fight activation FUN_00523150)
    local crit, cleave
    if missile then crit = missile.crit
    else crit = (hit == HIT.CRITICAL or hit == HIT.DEATHBLOW) end

    if hit ~= HIT.MISS then
        -- assassination (FUN_0042ace0): the same roll at or below the attacker's chance kills outright
        local assassin = (not ranged and target.kind == "unit") and powerups.assassin(self) or 0
        if assassin > 0 and target.h then assassin = math.max(1, assassin - math.floor(target.h.level / 2)) end
        if assassin > 0 and not isCritter(target.code) and roll <= assassin then
            dmg = 5000
            world:event("assassinate", target, self)            -- FUN_004a9e90: the picture over the victim, a line over the killer
        else
            local raw = dmg   -- the hit's damage before armour, hit-type multiplier included
            -- the missile impact (binary FUN_005427e0) skips the armour altogether when the shooter is a titan (the
            -- army's titan flag at +0x1cd) or when the missile carries the ignore-armour
            -- special attack (a piercing missile's critical) and the victim is an army
            if missile and (isTitanUnit(self.code)
                or (target.kind == "unit" and crit and st.damageType == 0 and not st.hot and not petrify)) then
                dmg = raw
            elseif st.hot then      -- Flaming Arrows: the arrow's damage as piercing plus half of it as fire
                dmg = soften(target, dmg, 0, ranged) + soften(target, math.floor(dmg / 2), 3, ranged)
            else
                -- a critical piercing melee hit ignores armour (the melee routine FUN_0042ace0 zeroes the armour)
                dmg = soften(target, dmg, st.damageType, ranged,
                    crit and not ranged and st.damageType == 0, ia)
            end
            -- a critical slashing hit's cleave: min(50, damage / 2) (a missile's min(50, damage / 2 + 1)) good-hit
            -- slashing damage, damage before armour (melee FUN_0042ace0 / the hit resolution 0x0051abe0)
            if crit and st.damageType == 6 then cleave = math.min(50, math.floor(raw / 2) + (ranged and 1 or 0)) end
            -- the good / evil dragon breath does double damage to its opposite (FUN_005427e0, armies only)
            if missile and missile.dbl and target.kind == "unit"
                and require("bit").band(powerups.flags(target.code), missile.dbl == "good" and 0x2000000 or 0x8000000) ~= 0 then
                dmg = dmg * 2
            end
            -- the height percentage of the missile impact: the missile's start height against the victim's cell (missiles.lua)
            if missile then dmg = math.floor(dmg * missiles.heightPercent(world, missile, target) / 100) end
            -- piercing missiles against missile-resistant targets do a sixteenth of their damage, at least 1 (2 for the
            -- hot-and-pointy ones); units by their code, buildings by the missile picture (the building's missile test
            -- FUN_0052e790)
            if ranged and (st.hot or st.damageType == 0) and powerups.missileResistant(target, self, mcode) then
                dmg = math.max(st.hot and 2 or 1, math.floor(dmg / 16))
            end
        end
        local vamp = powerups.vampirism(self)
        if vamp > 0 then self.hp = math.min(self.maxHp, self.hp + vamp) end
        if self.h and self.h.mod.vampirism > 0 then
            self.hp = math.min(self.maxHp, self.hp + self.h.mod.vampirism)
        end
        if self.fx then
            if self.fx.vampirism then self.hp = math.min(self.maxHp, self.hp + self.fx.vampirism.value) end
            if self.fx.venom and target.kind == "unit" then
                -- Venom Touch: a poison attack of strength 10, chance max(1, 50 - 5 x (resistance - 10)) percent
                local res = target:resistance()
                if math.random(100) <= math.max(1, 50 - (res - 10) * 5) then status.poison(target) end
            end
            status.remove(self, "invis")
        end
    end
    if target.kind == "unit" then
        -- the attacker's innate poison / disease spreads to what it hits (the hit resolution 0x0051abe0)
        local ptype, strength = psychOf(self)
        if ptype == 6 then strength = strength + require("src.game.heroskills").plaguePiles(world) end
        if ptype then
            local res = target:resistance()
            if math.random(100) <= math.max(1, 50 - (res - strength) * 5) then
                if ptype == 5 then status.poison(target) else status.disease(target) end
            end
        end
        -- the damage type's critical-hit special attack (FUN_0042ace0 for melee, the fight activation FUN_00523150
        -- for a missile that rolled its crit): ice freezes for 8 s, electricity drains 40 mana, fire immolates,
        -- magic dispels, crushing stuns for 5 s
        -- (the "tinymsg" events are the floating "Critical: ..." lines over the victim, Game.txt 1113.., and "critfx" the picture
        -- and sound that go with them: display only, see gfx/battlefx.lua)
        local function critical(key)
            world:event("tinymsg", target, key, 0)
            world:event("critfx", target, key, self, missile ~= nil)
        end
        if crit then
            if st.damageType == 1 then
                status.freeze(target)
                critical(1116)
            elseif st.damageType == 2 then
                if target.h or (target.mana or 0) > 0 then critical(1118) end
                status.drainMana(target, 40)
            elseif st.damageType == 3 or st.hot then
                if status.immolate(target, 0) then critical(1117) end
            elseif st.damageType == 4 then
                status.dispel(target)
            elseif st.damageType == 5 then
                status.add(target, "stun", 5000)
                critical(1115)
            elseif st.damageType == 0 and not st.hot then
                critical(1113)
            end
        end
        -- the crystallizing breath: the hit that kills an army takes it (binary Hit, case 5 of the special attack, sent before the
        -- damage; skipped for an army under a Life Ward, the power 0x3e of the spell effect list)
        local atk = missile and missile.attack
        local crystal = atk and atk.kind == "crystallize" and target:alive() and not (target.fx and target.fx.lifeward)
            and target.hp - dmg <= 0
        target:takeDamage(dmg, self)
        if atk then Unit.breathSpecial(self, target, atk, crystal) end
        -- the cleave lands as an area hit: that damage as good-hit slashing, armour included, on every enemy army
        -- within 2 cells of the attacker and no further (the cleave routine FUN_005278a0 sends a radius 2 spell message
        -- centred on the inflictor; the host's spell resolution FUN_004aa840 gathers enemy armies only, alive, excluding
        -- the attacker, and applies the damage result FUN_0042bbf0 per victim; its movement-type filter lets every army
        -- through, so every army within the radius is hit)
        if cleave then
            -- the floating line is the hit army's (FUN_005278a0 runs on it), the slash picture and sound are the attacker's
            world:event("tinymsg", target, 1114, 0)
            world:event("critfx", target, 1114, self, missile ~= nil)
            for _, o in ipairs(world.units) do
                local dx, dy = o.gx - self.gx, o.gy - self.gy
                if o ~= self and o:alive() and world:enemies(self.side, o.side)
                    and dx * dx + dy * dy <= 4 then
                    o:takeDamage(soften(o, cleave, 6, false), self)
                end
            end
        end
        -- the basilisk's / Titan Orc's petrify missile (EMM5, the petrify special attack the fight activation
        -- FUN_00523150 gives them): a victim the hit kills is gone and the inflictor's side gets 50 stone (the petrify
        -- message handler FUN_004a9c90 adds it); one that survives the hit is frozen instead
        if missile and petrify then
            if target.hp <= 0 then
                world:event("tinymsg", self, 1147, 1)           -- FUN_004a9c90: "Petrify" over the shooter
                local side = world.sides[self.side]
                if side then side.stone = (side.stone or 0) + 50 end
            else
                status.freeze(target)
            end
        end
    elseif not (gamedata.hasTag(target.code, "flag") and require("src.game.victory").get(world.victoryRule, "flagGame")) then     -- flags cannot be hurt
        target.hp = target.hp - dmg
        if target.side ~= self.side then world:event("attacked", target, self, dmg) end
        if target.hp <= 0 then
            target.hp = 0
            if world:canPillage(target) then
                world:pillage(target, self.side)
            else
                target.destroyed = true
                target.razedBy = self.side
                if target.shape then world:blockShape(target.gx, target.gy, target.shape, false) end
                world:award(self, target)
            end
        end
    end
    return hit, dmg
end

-- What a missile of an army does where it lands (the missile impact FUN_005427e0): nothing when the shooter has died on the
-- way, else a poison arrow's poison and then the strike; the victim may have fallen to another missile of the same frame.
missiles.handlers.unit = function(world, m, victim)
    local me = m.shooter
    if not (me and me:alive()) then return end
    if victim.kind == "unit" then
        if not victim:alive() then return end
        -- a poison / fire-poison arrow poisons what it hits, before the damage (the missile impact FUN_005427e0)
        local strength = powerups.poisonArrow(m.code, me.type and me.type.damage or 0)
        if strength > 0 and math.random(100) <= math.max(1, 50 - (victim:resistance() - strength) * 5) then
            status.poison(victim)
        end
    elseif victim.hp <= 0 then
        return
    end
    me:strike(victim, m)
end

-- Attack<idx><skin>.wav: idx from the unit type's combat sound (1-based),
-- the target's skin digit only for melee slash/pierce/crush.
-- (the impact sounds by missile picture: the setting `missile.sounds`)

---@param target Unit|Building
---@param ranged boolean
function Unit:attackSound(target, ranged)
    -- the "combat sounds" option (the attack sound FUN_0050d300 returns at once while it is off)
    if not require("src.core.gameopts").on("combatsounds") then return end
    local raw = self.type and self.type.combatSound or 0
    local idx = math.max(0, raw - 1)
    local skin = 0
    if not ranged and idx <= 2 then
        if target.kind == "unit" then skin = target.type and target.type.skin or 0
        else skin = 3 end
        skin = math.max(0, math.min(5, skin))
    end
    sound.playAt("Assets/SoundFX.xcr", ("Attack%d%d.wav"):format(idx, skin), self.gx, self.gy)
end

---@param code string? the missile picture
---@param target Unit|Building
function Unit.missileImpactSound(code, target)
    -- same option for the impact sounds (the missile plays one only when asked to and the option is on)
    if not require("src.core.gameopts").on("combatsounds") then return end
    local m = code and content.setting:value("missile.sounds")[code]
    if not m then return end
    local n = target.kind == "unit" and m[1] or m[2]
    sound.playAt("Assets/SoundFX.xcr", ("Missile%d.wav"):format(n), target.gx, target.gy, { volume = 0.8 })
end

local lastScream = 0

---@param dmg number
---@param attacker (Unit|Building)?
function Unit:takeDamage(dmg, attacker)
    if not self:alive() then return end
    if attacker and attacker.side ~= self.side then self.world:event("attacked", self, attacker, dmg) end
    if self.world.sides[self.side] and self.world.sides[self.side].ai then
        require("src.game.armyabilities").onHit(self)       -- computer dwarves start drinking when hit
    end
    self.hp = self.hp - dmg
    if self.hp <= 0 and self.fx and self.fx.lifeward then
        self.fx.lifeward = nil
        self.hp = math.max(1, self.maxHp * 0.3)
    end
    if self.hp <= 0 then
        self:die(self.world.time, attacker)
        return
    end
    -- a hit unit does not fight back at once: the damage intake (0x00522af0) only sets the has-been-hit flag and the hit
    -- list entry (attitude.lua), the
    -- unit reacts at its next attitude evaluation
    self.wasHit = true
    -- the hit handling adds the hit list entry for every hit message; a hit without an inflictor (burning, spells nobody gets the
    -- credit for) is sent with the victim as its own inflictor (0x00522af0), so "under attack" sees it as well. Poison
    -- is not such a hit (it takes the hit points off directly, status.lua).
    attitude.addHit(self.world, attacker or self, self)
end

---@param t number
---@param killer (Unit|Building)?
function Unit:die(t, killer)
    local world = self.world
    self.hp = 0
    self.state = "dead"
    self.target, self.path = nil, nil
    if self.step then
        self.x, self.y = self.step.toX, self.step.toY
        self.step = nil
    end
    if world.occ[world:index(self.gx, self.gy)] == self then world.occ[world:index(self.gx, self.gy)] = nil end
    if self.set:has(A.DIE) then
        local n = self.set:frames(A.DIE)
        self:startAnim(A.DIE, t, n * 100, false)
    else
        self.anim = A.STAND
    end
    self.deadSince = t
    if self.retinueIndex then
        -- the retinue removal (FUN_00520e60): a retinue member is marked fallen and remembers the unit type that killed
        -- it (the attacker's global type index; -1 for a building or when nothing struck it)
        local fallen = world.fallen[self.side] or {}
        world.fallen[self.side] = fallen
        fallen[self.retinueIndex] = (killer and killer.kind == "unit" and killer.code) or ""
    end
    local scream = self.type and self.type.deathScream or 0
    local now = love.timer.getTime()
    if scream > 0 and now - lastScream > 0.75 then
        lastScream = now
        sound.playAt("Assets/SoundFX.xcr", ("Death%d.wav"):format(scream), self.gx, self.gy)
    end
    if self.selected then self.selected = false end
    if killer then
        world:event("kill", killer, self)
        world:award(killer, self)
        require("src.game.spells").onKill(killer, self)
        -- a Minotaur eats a critter, a daemon a Soul, the Troll and the Catapult collect their ammunition
        specials.onCritterKilled(world, self, killer)
    end
    specials.onDeath(world, self, killer)
    if self.h then
        -- a slain hero falls back to the start of its level
        local saved = self.h:save()
        saved.xp = require("src.game.hero").xpFor(saved.level)
        local sd = world.sides[self.side]
        if sd then sd.fallenHero = saved end
        world:event("herodied", self)
    end
end

-- Whether this unit's attack type reaches `o` (flyers need AIR, everything else GROUND). Types without an
-- attack type (0) are not restricted, as before.
---@param o Unit|Building
---@return boolean
function Unit:canReach(o)
    if o.kind ~= "unit" then return true end
    if (self.type and self.type.attackType or 0) == 0 then return true end
    if o.move == 1 then return self:canAttackAir() end
    return self:canAttackGround()
end

---@return boolean
function Unit:targetValid()
    local tg = self.target
    if not tg then return false end
    if tg.kind == "unit" then return tg:alive() and self:canReach(tg) end
    return tg.hp and tg.hp > 0
end

---@param t number
function Unit:beginAttack(t)
    local tg = self.target
    ---@cast tg -nil
    local d = dirTo(tg.x - self.x, tg.y - self.y)
    if d then self.dir = d end
    local set = self.set
    local frames = set:frames(A.FIGHT)
    local period = 1500
    if self.hero then period = 1000 end
    if self.h then
        period = period * (100 - math.max(-50, math.min(60, self.h.mod.attackSpeed))) / 100
    else
        -- troops: max(500, 1500 - 10 x the side's morale), the morale being its hero's (FUN_00537060)
        local hero = self.world.eco:heroAlive(self.side)
        local morale = hero and hero.h and hero.h:getMorale() or powerups.moraleBonus(self.world.sides[self.side])   -- FUN_0040dc80
        period = math.max(500, 1500 - 10 * morale)
    end
    if self.fx and (self.fx.fear or self.fx.awe or self.fx.terror) then period = period * 2.5 end   -- fight speed -3/5
    if frames <= 0 then
        frames = 1
    end
    local act = set.info[A.FIGHT] and set.info[A.FIGHT].effectActivation or 0
    if act <= 0 or act >= frames then act = math.max(1, math.floor(frames / 2)) end
    self.attack = { t0 = t, period = period, frames = frames, activation = act, struck = false }
    self.anim = A.FIGHT
    self.frame = 0
    self.state = "fight"
end

---@param t number
---@return boolean done
function Unit:updateAttack(t)
    local a = self.attack
    ---@cast a -nil
    local p = (t - a.t0) / a.period
    if p >= 1 then
        self.attack = nil
        self.frame = 0
        return true
    end
    self.frame = math.min(a.frames - 1, math.floor(p * a.frames))
    if not a.struck and self.frame >= a.activation then
        a.struck = true
        -- Firebombs and Spores explode on contact: the fight activation kills them (their Death does the damage)
        if specials.explodesOnContact(self) then
            self:die(t, nil)
            return false
        end
        local tg = self.target
        if tg and self:targetValid() and self:cellDistance(tg) <= self:attackRange() + 1 then
            if self:attackRange() > 1 then
                -- a missile flies the original's steps and hits what it meets (missiles.lua); the attack's d100 against the
                -- shooter's chance decides whether it flies true or lands to the side of the target
                local world = self.world
                local info = rules.armyInfo(self.code)
                local mcode = powerups.missileCode(self, info and info.missile)
                -- the Troll throws a sheep, the Catapult a cow, when it has one and shoots a crushing missile
                local st = self:stats()
                local thrown, factor = specials.throwAmmo(self, st.damageType)
                if thrown then mcode = thrown end
                local roll = math.random(100)
                -- the special attack: FUN_00523150 rolls dice FUN_00458e70(1,100,0) < 5, and a second time when that
                -- fails for damage type 11 (Flaming Arrows' fire-and-piercing, the damage getter 0x00526310)
                local crit = math.random(100) <= 4
                if not crit and st.hot then crit = math.random(100) <= 4 end
                missiles.launch(world, {
                    code = mcode, kind = "unit", shooter = self, side = self.side, target = tg,
                    roll = roll, dmgMul = factor, crit = crit,
                })
                self:attackSound(tg, true)
            else
                self:attackSound(tg, false)
                if self.h then require("src.game.spells").itemCast(self) end     -- the army strike 0x0051ab00
                self:strike(tg)
            end
        end
    end
    return false
end

---@param t number
function Unit:updateTask(t)
    local task = self.task
    ---@cast task -nil
    local world = self.world
    local eco = world.eco
    local b = task.building
    if b and (b.hp <= 0) then
        self.task = nil
        self:setIdle(t)
        return
    end
    local dist
    if b then dist = self:cellDistance(b)
    else
        local tx, ty = task.gx, task.gy         -- a task without a building has a place (build)
        ---@cast tx -nil
        ---@cast ty -nil
        dist = math.max(math.abs(tx - self.gx), math.abs(ty - self.gy))
    end
    -- for a construction site, being next to any footprint cell is enough
    if task.kind == "build" then
        local bt = gamedata.building(task.code)
        if bt then
            dist = math.huge
            for _, c in ipairs(world:shapeCells(task.gx, task.gy, bt.shape)) do
                dist = math.min(dist, math.max(math.abs(c[1] - self.gx), math.abs(c[2] - self.gy)))
            end
        end
    end
    if dist <= task.range then
        self.task = nil
        self.path = nil
        if task.kind == "build" then
            local ok, why, short = eco:startConstruction(self, task.code, task.gx, task.gy, t)
            if not ok then
                world:event("cantbuild", self, why, short)
                self:setIdle(t)
            end
        elseif task.kind == "mine" then
            ---@cast b -nil
            if not eco:enterMine(self, b) then self:setIdle(t) end
        elseif task.kind == "visit" then
            world:event("visit", self, b)
            self:setIdle(t)
        elseif task.kind == "garrison" then
            ---@cast b -nil
            if not eco:enterGarrison(self, b) then self:setIdle(t) end
        elseif task.kind == "convert" then
            self:startConversion(t)
        end
        if self.state == "task" then self:setIdle(t) end
        return
    end
    local gx, gy = task.gx, task.gy
    if b then gx, gy = b.gx, b.gy end
    ---@cast gx -nil
    ---@cast gy -nil
    if self:advance(t, gx, gy, task.range) and self.state ~= "step" then
        -- unreachable
        if self.task == task and dist > task.range + 2 then
            self.task = nil
            self:setIdle(t)
        end
    end
end

-- Looks for an enemy within `radius` cells (default: view range, 4..10).
---@param radius number?
---@return Unit?
function Unit:scanForEnemies(radius)
    local world = self.world
    local range = radius or math.max(4, math.min(10, self:stats().view))
    local best, bestD
    for _, o in ipairs(world.units) do
        if o ~= self and o:alive() and world:enemies(self.side, o.side) and self:canReach(o)
            and not (o.fx and o.fx.invis and (world.sides[self.side].seeInvisible or 0) <= world.time) then
            local d = math.max(math.abs(o.gx - self.gx), math.abs(o.gy - self.gy))
            if d <= range and (not bestD or d < bestD) then best, bestD = o, d end
        end
    end
    return best
end

-- Hit point regeneration of ordinary units (the original's regeneration interval and tick, 1.04 binary FUN_0051b460 /
-- FUN_0051b820): one hit point per 10 s, 250 ms shorter for every troop level, divided by the
-- percentage 100 / 150 / 200 ... of the Healing power-ups (PRG0, PRG1 ...) plus the Regeneration skill of the side's living
-- hero (20 per level, items counting: hero skill level / effect FUN_00556b50 / FUN_00556ea0, for every army of the side),
-- Trolls four times as fast, Undead twice as fast but not at all in daylight. A unit inside a tower (`inTower`, set by
-- Eco:healGarrison for the garrison; the original's in-tower test, the same call) has the interval halved. The spell
-- effect and item bonus the function adds for a hero belong to hero.lua, which regenerates the heroes. Poison / disease
-- stop it (a poisoned unit loses hits instead: status.lua).
---@param t number
---@param inTower boolean?
function Unit:regenerate(t, inTower)
    local last = self.regenT or t
    self.regenT = t
    if self.hp >= self.maxHp or self.hp <= 0 then self.regenAcc = nil return end
    if self.fx and (self.fx.poison or self.fx.disease) then return end
    local powerups = require("src.game.powerups")
    local undead = gamedata.hasTag(self.code, "undead")
    if undead and not self.world.night then return end
    local side = self.world.sides[self.side]
    local skills = require("src.game.heroskills")
    local pct = powerups.regenPercent(side, "PRG0") + skills.value(self.world, self.side, skills.ids.Regeneration)
    local per = math.max(1000, 10000 - (self.level or 0) * 250) * 100 / pct
    local mult = self.type and self.type.behaviour and self.type.behaviour.regenMultiplier
    if mult then per = per / mult end
    if undead then per = per / 2 end
    if inTower then per = per / 2 end
    self.regenAcc = (self.regenAcc or 0) + (t - last) / per
    if self.regenAcc >= 1 then
        local n = math.floor(self.regenAcc)
        self.regenAcc = self.regenAcc - n
        self.hp = math.min(self.maxHp, self.hp + n)
    end
end

-- Mana regeneration for non-hero spellcasters (the mana regeneration interval FUN_0051b580): one point every
-- 3000 ms (Daemons 6000), minus 100 ms (Daemons 200) for every troop level, divided by the Summon Mana power-up.
-- Mana Freeze stops it for every side.
---@param t number
function Unit:regenMana(t)
    if not self.maxMana or self.maxMana <= 0 then return end
    if self.mana >= self.maxMana then self.manaAcc = nil return end
    local last = self.manaT or t
    self.manaT = t
    if self.world.manaFreeze and self.world.manaFreeze.t1 > t then return end
    local daemon = gamedata.hasTag(self.code, "daemonClass")
    local base = (daemon and 6000 or 3000) - (self.level or 0) * (daemon and 200 or 100)
    local per = math.max(500, base) * 100 / powerups.regenPercent(self.world.sides[self.side], "PMR0")
    self.manaAcc = (self.manaAcc or 0) + (t - last) / per
    if self.manaAcc >= 1 then
        local n = math.floor(self.manaAcc)
        self.manaAcc = self.manaAcc - n
        self.mana = math.min(self.maxMana, self.mana + n)
    end
end

-- Main update -------------------------------------------------------------------

---@param t number world time
function Unit:update(t)
    if self.state == "dead" then
        if self.anim == A.DIE then
            local n = self.set:frames(A.DIE)
            self.frame = math.min(n - 1, math.floor((t - self.animStart) / 100))
        end
        if t - self.deadSince > 20000 then self.remove = true end
        return
    end

    if self.state == "hidden" then return end
    -- idle stand animation: while no other animation plays, the STAND frames step
    -- one at a time every 100 ms (160 ms for dragons)
    if self.anim == A.STAND and self.standFrames > 1 then
        if t >= (self.nextStandFrame or 0) then
            self.frame = (self.frame + 1) % self.standFrames
            self.nextStandFrame = t + standFrameTime(self.code)
        end
    end
    if self.merge then require("src.game.armyabilities").updateMerge(self, t) end
    if self.state == "hidden" then return end
    if self.h then self.h:tick(t) else self:regenerate(t); self:regenMana(t) end
    if self.summonUntil and t >= self.summonUntil then
        self.summonUntil = nil
        self:die(t, nil)
        self.deadSince = t - 19000      -- summoned creatures vanish quickly
        return
    end
    if self.fx and status.update(self, t) and self.state ~= "step" then
        if self.state ~= "idle" and self.state ~= "stunned" then self:stop() end
        self.state = "stunned"
        return
    elseif self.state == "stunned" then
        self:setIdle(t)
    end
    if self.pendingCast and self.state ~= "step" then
        local pc = self.pendingCast
        ---@cast pc -nil
        self.pendingCast = nil
        require("src.game.spells").perform(self, pc.id, pc.target)
    end
    if self.state == "cast" then
        if t >= self.castUntil then self:setIdle(t) end
        return
    end

    if self.state == "step" then
        if not self:updateStep(t) then return end
        -- step finished: continue with the current order
        if self.task then self.state = "task"
        elseif self.target then self.state = "attack"
        elseif self.goalX then self.state = "move"
        else self:setIdle(t) end
    end

    if self.state == "fight" then
        if not self:updateAttack(t) then return end
        self.state = self.target and "attack" or "idle"
        if self.state == "idle" then self:setIdle(t) end
    end

    -- the attitude rules look at the unit once per slice of its side (attitude.lua, M.update), whatever it is doing
    -- (here for walking and attacking units; idle ones below)
    if (self.state == "move" or self.state == "attack") and attitude.due(self) then
        self.attSlice = self.world.attSide[self.side]
        if attitude.think(self, t) then return end
    end

    if self.state == "move" then
        if self.patrol and t >= (self.nextScan or 0) then
            self.nextScan = t + 500
            local e = self:scanForEnemies()
            if e then self:orderAttack(e) return end
        end
        if self:advance(t, self.goalX, self.goalY, 0) then
            self.goalX, self.goalY = nil, nil
            self.path = nil
            if self.state ~= "step" then self:setIdle(t) end
        end
        return
    end

    if self.state == "task" then
        self:updateTask(t)
        return
    end

    if self.state == "convert" then
        local c = self.converting
        ---@cast c -nil
        local targets = self.world.eco:conversionTargets(self)
        if #targets == 0 then
            self.converting = nil
            self:setIdle(t)
        elseif t >= c.t1 then
            for _, b in ipairs(targets) do self.world.eco:setOwner(b, self.side) end
            self.world:event("conversiondone", self)
            self.converting = nil
            self:setIdle(t)
        else
            if self.set:has(A.CONVERT) then
                local n = self.set:frames(A.CONVERT)
                self.anim = A.CONVERT
                self.frame = math.floor((t - c.t0) / 100) % n
            end
        end
        return
    end

    if self.state == "attack" then
        if not self:targetValid() then
            self.target = nil
            self:setIdle(t)
            return
        end
        local tg = self.target
        ---@cast tg -nil
        local dist = self:cellDistance(tg)
        if dist <= self:attackRange() then
            self.path = nil
            self:beginAttack(t)
            return
        end
        -- chase: re-plan when the target moved away from the planned goal
        ---@diagnostic disable-next-line: need-check-nil -- pathGoalY is set together with pathGoalX (Unit:advance)
        if self.pathGoalX and (math.abs(self.pathGoalX - tg.gx) > 1 or math.abs(self.pathGoalY - tg.gy) > 1) then
            self.repath = true
        end
        self:advance(t, tg.gx, tg.gy, self:attackRange())
        return
    end

    -- idle: queued orders first, then patrol / guard duty
    if self.state == "idle" then
        if self.queue and #self.queue > 0 then
            self:runOrder(table.remove(self.queue, 1))
            return
        end
        if self.patrol then
            local e = self:scanForEnemies()
            if e then self:orderAttack(e) else self:nextPatrolPoint() end
            return
        end
    end

    -- idle: the attitude rules once per slice of the side, then fidget
    if self.state == "idle" and attitude.due(self) then
        self.attSlice = self.world.attSide[self.side]
        if attitude.think(self, t) then return end
    end
    -- (the idle fidgets - the ambient animation and the turns on the spot - are a thing of the display layer in the original, and
    -- here: gfx/fidget.lua; the simulation's units only stand)
end

-- Drawing -------------------------------------------------------------------------

-- The status icon beside an affected unit: a 20x20 cell of the ECM0 set, blitted after the
-- sprite at the unit's effect anchor, moved up and left by ICON_OFFSET_X / ICON_OFFSET_Y = 30 / 20
-- and drawn only while the army is alive. The first effect that matches wins, in the order
-- disease, poison, immunity, command radius, chaos, fear, terror, awe. Cell 0 marks an army
-- standing inside a hero's command radius (game/morale.lua; only for the local player's armies,
-- the army draw 0x00538660); cell 7 is the immunity to psych effects after resisting one (psych.lua) as well as
-- the Immunity spell. The cells, the order and the offsets were read off the original game on screen.
local STATUS_ICONS = { { "disease", 5 }, { "poison", 6 }, { "psychimmune", 7 }, { "immunity", 7 }, { "command", 0 },
                       { "chaos", 3 }, { "fear", 1 }, { "terror", 2 }, { "awe", 4 } }
local ICON_OFFSET_X, ICON_OFFSET_Y = 30, 20

---@param colorOf fun(side: integer): any the side's colour for the sprite
function Unit:draw(colorOf)
    local team = colorOf(self.side)
    local anim = self.anim
    if not self.set:has(anim) then anim = A.STAND end
    local x, y = math.floor(self.x + 0.5), math.floor(self.y + 0.5)
    local frame = self.frame
    -- the idle fidget (gfx/fidget.lua: the ambient animation or a turn on the spot) changes only the picture: the simulation's
    -- animation state and facing are the same on every peer
    local dir = self.dir
    local view = self.view
    if view and self.state == "idle" then
        dir = view.dir or dir
        if view.anim then anim, frame = view.anim, view.frame end
    end
    self.set:draw(anim, dir, frame, x, y, team)
    local fx = self.fx
    if self.state ~= "dead" and (fx or self.cmdIn) then
        local cell
        local command = self.cmdIn and self.side == self.world.player
        for _, p in ipairs(STATUS_ICONS) do
            if p[1] == "command" and command or fx and fx[p[1]] then
                cell = p[2]
                break
            end
        end
        local set = cell and anims.get("ECM0")
        if set then
            local ex, ey = self.set:effectCentre()
            set:draw(0, 0, cell, x - ex - ICON_OFFSET_X, y - ey - ICON_OFFSET_Y)
        end
    end
end

return Unit
