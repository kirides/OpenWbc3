-- Hero progression: attributes, skills, experience levels and equipment.
--
-- Numbers are the original game's wherever they could be verified (docs/hero.md lists them and their
-- sources: the game binary's hero stat, bonus, skill effect and experience functions, and its kill, potion and
-- regeneration routines). What is not original is labelled "own": how computer heroes level and
-- spend their points (a human side's hero levels one level at a time in the battle and the rest after it, as the original).
--
-- Skills: a hero has up to ten skills from its race and class (classes.skillList); each level gives one
-- skill point, a skill can be raised once the hero level reaches its availability. The magic spheres are
-- skills too (ids 10..22): the casting skill of a sphere is its level, spells are not learned one by one.
-- The effect of a skill level is `heroskills.effect` (the binary's table); where each one is used is in docs/hero.md.
local content = require("src.content")
local items = require("src.game.items")
local classes = require("src.game.classes")
local HS = require("src.game.heroskills")

local M = { SHORTCUTS = 8 }       -- eight spell shortcut slots (FUN_004258a0 / FUN_004258f0)

-- progression numbers: the `hero.*` settings (content/base/hero.lua), read again whenever the registry has been (re)built
local function setting(id) return content.setting:value(id) end
local XP_TABLE, CONV_TIME, B
content.onReady(function()
    M.MAX_LEVEL = setting("hero.maxLevel")          -- the level cap (FUN_00455b40)
    M.ATTR_POINTS = setting("hero.attrPoints")      -- attribute points per level (the original gives 1 stat and 1 skill point)
    M.SKILL_POINTS = setting("hero.skillPoints")    -- skill points per level
    M.PACK_SIZE = setting("hero.packSize")          -- a hero holds 11 items = 7 worn + 4 backpack
    M.BASE_ATTR = setting("hero.baseAttr")          -- plus the race and class modifiers (classes.lua)
        M.START_POTIONS = setting("hero.startPotions")
    M.MAX_POTIONS = setting("hero.maxPotions")
    XP_TABLE = setting("hero.xpTable")
    CONV_TIME = setting("hero.convTime")
    B = setting("hero.bonus")
end)

M.ATTRS = {
    { key = "str", name = "Strength" },
    { key = "dex", name = "Dexterity" },
    { key = "int", name = "Intelligence" },
    { key = "cha", name = "Charisma" },
}

-- Casting skill spheres: "+1 casting skill" per level
M.SKILL_EFFECT = {}
for id = 10, 22 do M.SKILL_EFFECT[id] = "+1 casting skill" end

-- Name of a skill (Game.txt 760 + id - 1).
---@param id integer
---@return string
function M.skillName(id)
    return require("src.game.strings").get("Game.txt", ("%04d"):format(759 + id)) or ("Skill " .. id)
end

-- The skill's help line at a level (the skill help FUN_00556fc0 of the binary; at level 0 what the first level gives).
---@param id integer
---@param level integer?
---@return string
function M.skillDesc(id, level)
    local e = M.SKILL_EFFECT[id]
    if e then return e .. " per level" end
    return HS.help(id, math.max(1, level or 1)) or ""
end

-- Which classes' items a worn slot takes (item class = Items.bmp row: 0 sword, 1 staff, 2 armour, 3 necklace,
-- 4 shield, 5 ring, 6 crown, 7 helm, 8 banner, 9 boots, 10 charm). Seven worn slots (the items dialog's slot rule;
-- not traced in the 1.04 binary yet).
M.SLOT_LAYOUT = setting("hero.slotLayout")

-- The worn slot of the weapon (worn item 3 of the hero record) and the damage type codes of the type records its powers set.
M.WEAPON_SLOT = 3
local DAMAGE_TYPE = { piercing = 0, ice = 1, electricity = 2, fire = 3, magic = 4, crushing = 5, slashing = 6 }

-- Total experience needed to reach `level` (the original's table for levels 1-51, then 4000 more per level).
---@param level integer
---@return number
function M.xpFor(level)
    if level <= 1 then return 0 end
    local v = XP_TABLE[math.min(level - 1, 50)]
    if level > 51 then v = v + (level - 51) * 4000 end
    return v
end

-- Potions: every hero starts a battle with four of each (the hero stat builder FUN_0054fd50; at most 9). A health
-- potion heals 50 + 10 x keep level, a mana potion restores 10 + 5 x keep level (FUN_00561d80 / FUN_00561c30).
function M.potionHeal(keepLevel) return 50 + 10 * (keepLevel or 0) end
function M.potionMana(keepLevel) return 10 + 5 * (keepLevel or 0) end

-- Conversion time in seconds by conversion rating (FUN_0040ad40; a hero's rating is 8 + level / 2).
---@param rating integer
---@return number seconds
function M.conversionTime(rating)
    return CONV_TIME[math.max(6, math.min(99, rating))]
end

-- The original's attribute bonuses (FUN_0054a6a0 / the formula switch FUN_0054a720, total = base + attribute part).

-- The ability table Hero:recalc derives from attributes, skills, items and power-ups.
---@class HeroMod
---@field combat number
---@field hits number
---@field damage number
---@field damageType integer?
---@field speed number
---@field armor number
---@field armorSkill table<integer, number> extra armour by damage type
---@field resistSkill table<integer, number>
---@field resistance number
---@field command number
---@field commandRadius number
---@field morale number
---@field attackSpeed number
---@field vampirism number
---@field critical number
---@field resist table<string, number>? item resistances (fire, ice, electricity, magic)
---@field assassin number
---@field regen number              life points per second
---@field conversion number         conversion time factor
---@field discount number
---@field manaDiscount number?
---@field merchant number           price factor
---@field mana number               maximum mana
---@field manaRegen number
---@field manaRegenPct number
---@field ritual number

-- A hero's progression state: attributes, skills, experience, items. Belongs to a hero unit (`unit.h`) or stands alone
-- (a profile's hero, unit nil).
---@class Hero
---@field unit Unit?
---@field level integer
---@field xp number
---@field attr table<string, integer> str, dex, int, cha
---@field skill table<integer, integer> skill id -> level
---@field class string
---@field race integer
---@field skillList table[]         classes.skillList: { id, availability, start level }
---@field points {attr: integer, skill: integer}
---@field equipped table<integer, table> worn slot -> item
---@field pack table[]              backpack items
---@field spells table<integer, boolean> castable spell ids
---@field spellCount integer
---@field mod HeroMod
---@field itemSkills table<integer, integer>?
---@field frozen boolean            no more experience
---@field tournament boolean?       a temporary hero of the Tournament mode
---@field shortcuts integer[]       F1..F8: spell id or -1
---@field kills integer
---@field latch boolean?            a level-up whose points are not spent yet
---@field potions {health: integer, mana: integer}
---@field mana number?
---@field bonus table<string, number>? campaign bonuses (Global.bon)
---@field itemsOff number?          Disjunction: the items count for nothing until then
---@field itemMult {t1: number, value: number}?
---@field ironman boolean?          Ironman mode: experience counts twice
---@field nextBonus number?         spells.lua
---@field manaLeech number?
---@field manaLeechAmount number?
---@field lastT number?
---@field scan number?
local Hero = {}
Hero.__index = Hero

-- `unit` is the battle unit the hero state belongs to (may be nil for a
-- stand-alone profile). `saved` is a table from Hero:save().
---@param unit Unit?
---@param saved table?
---@return Hero
function M.new(unit, saved)
    saved = saved or {}

    ---@type Hero
    local h = setmetatable({
        unit = unit,
        level = math.max(1, math.min(M.MAX_LEVEL, saved.level or 1)),
        xp = saved.xp or 0,
        attr = {}, skill = {}, class = saved.class or "Warrior",
        points = { attr = saved.points and saved.points.attr or 0, skill = saved.points and saved.points.skill or 0 },
        equipped = {}, pack = {}, spells = {}, spellCount = 0,
        mod = {},
        frozen = saved.frozen or false,        -- "Freeze your hero's level": no more experience (a hero record flag)
        tournament = saved.tournament or nil,  -- a temporary hero of the advanced Tournament mode
        shortcuts = {},                        -- F1..F8: spell id or -1 (also kept in the hero record, FUN_004258a0)
        kills = 0,
        latch = saved.latch or nil,            -- a level-up of this battle whose points are not spent yet (see checkLevel)
        -- potions are battle state, never kept in the hero profile: a new battle always starts with four of each
        potions = { health = M.START_POTIONS, mana = M.START_POTIONS },
    }, Hero)
    for i = 1, M.SHORTCUTS do h.shortcuts[i] = saved.shortcuts and saved.shortcuts[i] or -1 end
    for k, v in pairs(M.BASE_ATTR) do h.attr[k] = saved.attr and saved.attr[k] or v end
    h.race = saved.race or unit and unit.world and unit.world.sides[unit.side].race or 0
    h.skillList = classes.skillList(h.race, h.class)
    M.loadSkills(h, saved)
    if saved.equipped then
        local slots = {}
        for slot in pairs(saved.equipped) do slots[#slots + 1] = slot end
        table.sort(slots)
        for _, slot in ipairs(slots) do
            local it = items.get(saved.equipped[slot])
            if it then
                local sl = M.SLOT_LAYOUT[slot]
                if sl and sl.classes[it.slot] and not h.equipped[slot] then h.equipped[slot] = it
                else
                    local free = h:freeSlot(it)
                    if free then h.equipped[free] = it elseif #h.pack < M.PACK_SIZE then h.pack[#h.pack + 1] = it end
                end
            end
        end
    end
    if saved.pack then
        for _, id in ipairs(saved.pack) do
            local it = items.get(id)
            if it and #h.pack < M.PACK_SIZE then h.pack[#h.pack + 1] = it end
        end
    end
    if not saved.drained then h.xp = math.max(h.xp, M.xpFor(h.level)) end     -- a drained hero keeps its low experience
    h:recalc()
    -- Potionmaster: that many mana potions more at the start of a battle (hero stats set-up, FUN_0054fd50 of the binary;
    -- no alive check at that point)
    h.potions.mana = M.START_POTIONS + h:effect(95)
    -- a battle starts with a tenth of the maximum mana (FUN_0054fd50)
    h.mana = saved.mana and math.min(saved.mana, h.mod.mana) or math.floor(h.mod.mana / 10)
    return h
end

-- Skill levels from a saved hero: { [skillId] = level }. Heroes saved with the earlier openwbc3 skill set (named keys,
-- learned spells, spell points) are converted; what has no place in the hero's skill list becomes skill points.
local OLD_SKILL = { combat = 1, toughness = 2, regen = 3, speed = 4, lore = 5, energy = 6, leader = 8, merchant = 9,
                    armor = 23, resist = 24, morale = 3, conversion = 6 }
---@param h Hero
---@param saved table
function M.loadSkills(h, saved)
    local inList = {}
    for _, e in ipairs(h.skillList) do inList[e[1]] = e end
    local lost = (saved.points and saved.points.spell) or 0
    for _, e in ipairs(h.skillList) do h.skill[e[1]] = e[3] end
    for k, v in pairs(saved.skill or {}) do
        if type(k) == "number" then
            if inList[k] then h.skill[k] = v end
        else
            local id = OLD_SKILL[k]
            if id and inList[id] then h.skill[id] = h.skill[id] + v else lost = lost + v end
        end
    end
    local known = {}
    for _, id in ipairs(saved.spells or {}) do known[math.floor(id / 10)] = (known[math.floor(id / 10)] or 0) + 1 end
    for sph, n in pairs(known) do
        local sphere = content.sphere:bySlot(sph)
        local skill = sphere and sphere.skill
        if skill and inList[skill] then h.skill[skill] = math.max(h.skill[skill], n) else lost = lost + n end
    end
    h.points.skill = h.points.skill + lost
end

-- Spell hot keys, as the binary's shortcut setter / lookup (FUN_004258a0 / FUN_004258f0): a spell sits on at most one
-- of the eight keys, assigning it elsewhere frees the old key. Not simulation state (never hashed), set from the book.
---@param slot integer 1..8
---@param spell integer spell id or -1
function Hero:setShortcut(slot, spell)
    for i = 1, M.SHORTCUTS do
        if self.shortcuts[i] == spell then self.shortcuts[i] = -1 end
    end
    self.shortcuts[slot] = spell
end

---@param spell integer
---@return integer?
function Hero:shortcutOf(spell)
    for i = 1, M.SHORTCUTS do
        if self.shortcuts[i] == spell then return i end
    end
end

---@return table
function Hero:save()
    local s = { class = self.class, race = self.race, frozen = self.frozen or nil, tournament = self.tournament, level = self.level, xp = self.xp, attr = {}, skill = {},
        drained = self.xp < M.xpFor(self.level) or nil,       -- the evil breath took experience below the level's start
        latch = self.latch or nil,       -- battle state: kept by a saved game, dropped by profile.save
        points = { attr = self.points.attr, skill = self.points.skill }, equipped = {}, pack = {},
        mana = math.floor(self.mana or 0), shortcuts = { unpack(self.shortcuts) } }
    for k, v in pairs(self.attr) do s.attr[k] = v end
    for k, v in pairs(self.skill) do s.skill[k] = v end
    for slot, it in pairs(self.equipped) do s.equipped[slot] = it.id end
    for i, it in ipairs(self.pack) do s.pack[i] = it.id end
    return s
end

-- Derived values ----------------------------------------------------------------

-- Recomputes the ability table `mod` and updates the unit's life points.
-- The binary's skill lookup (FUN_00556ab0 / FUN_00556b50) for the hero itself: the levels it has learnt plus what
-- its worn items add.
---@param id integer skill id
---@return integer
function Hero:lvl(id)
    return (self.skill[id] or 0) + (self.itemSkills and self.itemSkills[id] or 0)
end

-- The skill effect (FUN_00556ea0) of the hero's level of a skill, 0 without it.
---@param id integer skill id
---@return number
function Hero:effect(id)
    local n = self:lvl(id)
    return n > 0 and HS.effect(id, n) or 0
end

-- Casting levels the side's Spell / Arcane Research (and Learn Spell) added to a sphere for this battle: the original adds
-- the side's per-sphere spell bonus to the hero's casting skill when it rebuilds its statistics (binary FUN_0054fd50).
---@param sphere integer
---@return integer
function Hero:sphereBonus(sphere)
    local world = self.unit and self.unit.world
    return require("src.game.powerups").spellBonus(world and world.sides[self.unit.side], sphere)
end

function Hero:recalc()
    local a, lvl = self.attr, self.level
    local b = items.bonuses(self.equipped, M.WEAPON_SLOT)
    local world = self.unit and self.unit.world
    if world and world.advanced and world.advanced.noItems then
        -- advanced option No Items: the item power sums return 0, the item skills and the item stats are not added
        -- (binary FUN_0040c380, FUN_0040c500, FUN_00556ab0, FUN_0054fd50 all test the flag at 0x749c68)
        b = items.bonuses({}, M.WEAPON_SLOT)
    elseif self.itemsOff and self.unit and self.unit.world.time < self.itemsOff then
        b = items.bonuses({}, M.WEAPON_SLOT)              -- Disjunction
    elseif self.itemMult and self.unit and self.unit.world.time < self.itemMult.t1 then
        for k, v in pairs(b) do if type(v) == "number" then b[k] = v * self.itemMult.value end end
    end
    self.itemSkills = b.skills
    local sk = setmetatable({}, { __index = function(_, id) return self:lvl(id) end })
    local E = function(id) return self:effect(id) end
    local m = self.mod
    local cl = classes.data(self.class)
    m.combat = B.combat(a) + E(1) + b.combat
    m.hits = cl.life + (lvl - 1) * cl.perLevel + B.life(a) + E(2)
    -- 10 + (10 + Str) + items + Mighty Blow (10 + bonus formula 1 in the hero stat builder FUN_0054fd50; the army damage
    -- getter 0x00526310 adds items and Mighty Blow)
    m.damage = 20 + a.str + b.damage + E(34)
    m.damageType = b.damageType and DAMAGE_TYPE[b.damageType]       -- the weapon's element or edge replaces the type record's
    m.speed = B.speed(a) + E(4) + b.speed
    -- armour: class base, Dexterity, Invulnerability and items for every physical type; Armorer (piercing), Scales
    -- (slashing) and Thick Hide (crushing) and the resistance skills add per type (Unit:completeArmour)
    m.armor = cl.armor + B.armor(a) + E(31) + b.armor
    m.armorSkill = { [0] = E(23), [5] = E(32), [6] = E(30) }
    local elemental = E(26)
    m.resistSkill = { [1] = E(28) + elemental, [2] = E(29) + elemental, [3] = E(27) + elemental, [4] = E(25) }
    -- power-ups the original reads in its hero functions (powerups.lua): Black Ward, Dark Lord, Courage / Order of the Lion /
    -- Warmth, Healing, Summon Mana, Meditation, Holy Relic
    local pu = require("src.game.powerups")
    local sd = self.unit and self.unit.world and self.unit.world.sides[self.unit.side]
    local puRes = sd and pu.resistanceBonus(sd) or 0
    local puCommand = sd and pu.commandBonus(sd) or 0
    local puMorale = sd and pu.moraleBonus(sd) or 0
    local puHeal = sd and pu.regenPercent(sd, "PRG0") or 100
    local puMana = sd and pu.regenPercent(sd, "PMR0") or 100
    local puCast = sd and pu.castingBonus(sd) or 0
    m.resistance = B.resistance(a) + b.resistance + puRes           -- Warding is side-wide: Unit:resistance
    m.command = b.command
    -- 5 + Cha + items (the base is not traced in the 1.04 binary yet); Leadership is morale
    m.commandRadius = 5 + a.cha + m.command + puCommand
    local lord = HS.lordOf(sd and sd.race)
    -- Leadership and the racial lord skill of the side's race (hero morale FUN_005269a0)
    m.morale = B.morale(a) + E(8) + (lord and E(lord) or 0) + b.morale + puMorale   -- half is added to the army limit
    m.attackSpeed = B.attackSpeed(a) + b.attackSpeed
    -- Vampirism skill + items (FUN_00526f40); Assassin skill (4 + level) + items (binary FUN_00526e70)
    m.vampirism, m.critical, m.resist = b.vampirism + E(53), b.critical, b.resist
    m.assassin = E(51) + b.assassin
    -- life regeneration: (1 + Str/3) points per 20 s, +20% per Regeneration level, plus the items' percentage
    m.regen = B.lifeRegen(a) / 20 * math.max(0, puHeal + E(3) + b.regen) / 100
    local convSecs = M.conversionTime(8 + math.floor(lvl / 2))
    if sd then convSecs = pu.conversionSeconds(sd, convSecs) end
    m.conversion = convSecs / 39                            -- 39 s is the rating-8 time
    m.discount = B.discount(a) + E(9)
    m.manaDiscount = b.manaDiscount                          -- spell cost FUN_00529fa0: the items' discount (spells.cost)
    m.merchant = 100 / (100 + m.discount)                  -- price factor
    m.mana = cl.mana + B.mana(a) + E(5)
    m.manaRegen = B.manaRegen(a) / 20                       -- points per second at 100 %
    m.manaRegenPct = puMana + E(6)                           -- Energy; Enervate (75 + 25 r) is added on top
    m.ritual = E(7) + puCast                                      -- percent added to the casting chance
    self.spells, self.spellCount = {}, 0                    -- spell i of a sphere is castable while its casting skill > i
    for _, sphere in ipairs(content.sphere:all()) do
        local sph = sphere.slot
        for i = 0, math.min(9, (sk[sphere.skill] or 0) + self:sphereBonus(sph) - 1) do
            if content.spell:bySlot(sph * 10 + i) then       -- a spell a mod removed is gone from the book
                self.spells[sph * 10 + i] = true
                self.spellCount = self.spellCount + 1
            end
        end
    end
    local cb = self.bonus          -- campaign bonuses (Global.bon)
    if cb then
        m.armor = m.armor + (cb.armor or 0)
        m.speed = m.speed + (cb.speed or 0)
        m.attackSpeed = (m.attackSpeed or 0) + 10 * (cb["speed attack"] or 0)
        m.manaRegen = m.manaRegen * (1 + (cb["mana regen"] or 0) / 100)
        if cb["cold resistance"] then
            m.resist = m.resist or {}
            m.resist.ice = (m.resist.ice or 0) + cb["cold resistance"]
        end
    end
    local u = self.unit
    if u then
        local old = u.maxHp or m.hits
        u.maxHp = m.hits
        if u.hp then u.hp = math.min(u.maxHp, u.hp + math.max(0, u.maxHp - old)) end
    end
end

-- Overrides a unit's base stats with the hero's abilities.
---@param st UnitStats
---@return UnitStats
function Hero:applyStats(st)
    local m = self.mod
    st.combat, st.speed, st.armor, st.damage = m.combat, m.speed, m.armor, m.damage
    if m.damageType then st.damageType = m.damageType end
    st.resistance = m.resistance
    -- Shadow Strength: combat at night, hero only (binary FUN_0051bd10 reads skill 54 only when it is night)
    local u = self.unit
    if u and u.world and u.world.night then st.combat = st.combat + self:effect(54) end
    return st
end

-- Experience and levels ----------------------------------------------------------

-- Whether this is the hero of a human side in a running battle: its levels come one at a time from `checkLevel`, as in the
-- original (the control panel timer, binary FUN_004d60f0), while computer heroes and heroes outside a battle level at once.
---@return boolean
function Hero:manualLevels()
    local u = self.unit
    return u ~= nil and u.world ~= nil and not u.world.sides[u.side].ai
end

-- The battle's level check of a human side's hero (binary FUN_004d60f0, run on every update of the control panel): when the
-- experience reaches the next level and the previous level-up has been dealt with (the latch byte at 0x709d0c is clear)
-- the hero gains ONE level, an attribute and a skill point, and the latch is set until the points are spent (the level-up
-- dialog's Accept clears it when none are left: FUN_00552990 / FUN_00553320 / FUN_00562ba0). More experience than one level
-- waits; what is still due when the battle ends is counted by `levelsDue`. Returns the levels gained (0 or 1).
---@return integer
function Hero:checkLevel()
    if self.latch or self.frozen or self.level >= M.MAX_LEVEL or self.xp < M.xpFor(self.level + 1) then return 0 end
    self.level = self.level + 1
    self.points.attr = self.points.attr + M.ATTR_POINTS
    self.points.skill = self.points.skill + M.SKILL_POINTS
    self.latch = true
    self:recalc()
    local u = self.unit
    if u then u.hp = u.maxHp end                       -- the level-up effect heals fully (binary)
    return 1
end

-- The level-up dialog was closed: with no points left the next level may come (binary FUN_00552990 / FUN_00562ba0:
-- `if (skill points < 1 && attribute points < 1) latch = 0`; the portrait click does the same, FUN_004d54c0).
function Hero:endLevelUp()
    if self.points.attr <= 0 and self.points.skill <= 0 then self.latch = nil end
end

-- Experience without a level check (the end-of-battle amount of the local hero: the levels come with the victory screen).
---@param n number
function Hero:gainXp(n)
    if self.frozen or self.level >= M.MAX_LEVEL then return end
    self.xp = self.xp + n
end

-- The levels the experience gained so far still owes the hero, at most four (binary FUN_00455b40, called while the
-- victory screen is built: it counts the thresholds of level + 1 .. level + 4 against the experience and adds a
-- point of each kind per level; the level itself follows when Continue is pressed). A frozen hero owes none.
---@return integer
function Hero:levelsDue()
    if self.frozen then return 0 end
    local n = 0
    while n < 4 and self.level + n < M.MAX_LEVEL and self.xp >= M.xpFor(self.level + n + 1) do n = n + 1 end
    return n
end

-- What Continue does with the levels counted by `levelsDue` (binary 0x004546F0: the level grows by the counted amount,
-- the points were added when they were counted).
---@param n integer
function Hero:applyLevels(n)
    if n <= 0 then return end
    self.level = math.min(M.MAX_LEVEL, self.level + n)
    self.points.attr = self.points.attr + n * M.ATTR_POINTS
    self.points.skill = self.points.skill + n * M.SKILL_POINTS
    self:recalc()
end

-- Adds experience; returns the number of levels gained. Ironman mode doubles it (the army experience routine
-- FUN_00527100) unless `raw` (the end-of-battle amount, which applies the Ironman rule itself). A human side's hero in a
-- battle only collects the experience (the update's `checkLevel` makes the level).
---@param n number
---@param raw boolean? the end-of-battle amount (no Ironman doubling)
---@return integer levels gained
function Hero:addXp(n, raw)
    if self.frozen or self.level >= M.MAX_LEVEL then return 0 end
    if self.ironman and not raw then n = n * 2 end
    self.xp = self.xp + n
    if self:manualLevels() then return 0 end
    local gained = 0
    while self.level < M.MAX_LEVEL and self.xp >= M.xpFor(self.level + 1) do
        self.level = self.level + 1
        self.points.attr = self.points.attr + M.ATTR_POINTS
        self.points.skill = self.points.skill + M.SKILL_POINTS
        gained = gained + 1
    end
    if gained > 0 then
        self:recalc()
        local u = self.unit
        if u then u.hp = u.maxHp end                       -- the level-up effect heals fully (binary)
    end
    return gained
end

-- Morale: the hero's own plus Blessing (army limit, troops' attack speed).
---@return number
function Hero:getMorale()
    local fx = self.unit and self.unit.fx
    return self.mod.morale + (fx and fx.morale and fx.morale.value or 0)
end

---@return number?
function Hero:nextLevelXp()
    if self.level >= M.MAX_LEVEL then return nil end
    return M.xpFor(self.level + 1)
end

---@return integer
function Hero:pending()
    return self.points.attr + self.points.skill
end

---@param key string str, dex, int, cha
---@return boolean
function Hero:spendAttr(key)
    if self.points.attr <= 0 or not self.attr[key] then return false end
    self.attr[key] = self.attr[key] + 1
    self.points.attr = self.points.attr - 1
    self:recalc()
    return true
end

---@param id integer
---@return table?
function Hero:skillEntry(id)
    for _, e in ipairs(self.skillList) do
        if e[1] == id then return e end
    end
end

-- A skill can be raised once the hero's level reaches its availability; there is no cap.
---@param id integer
---@return boolean
function Hero:canRaise(id)
    local e = self:skillEntry(id)
    return e ~= nil and self.points.skill > 0 and e[2] <= self.level
end

---@param id integer
---@return boolean
function Hero:spendSkill(id)
    if not self:canRaise(id) then return false end
    self.skill[id] = self.skill[id] + 1
    self.points.skill = self.points.skill - 1
    self:recalc()
    return true
end

-- Takes back a point just spent (the level-up dialog allows undoing its own changes).
---@param key string
---@return boolean
function Hero:refundAttr(key)
    if self.attr[key] <= (M.BASE_ATTR[key] or 1) then return false end
    self.attr[key] = self.attr[key] - 1
    self.points.attr = self.points.attr + 1
    self:recalc()
    return true
end

---@param id integer
---@return boolean
function Hero:refundSkill(id)
    local e = self:skillEntry(id)
    if not e or self.skill[id] <= e[3] then return false end
    self.skill[id] = self.skill[id] - 1
    self.points.skill = self.points.skill + 1
    self:recalc()
    return true
end

-- Computer-controlled heroes spread their points: strength first, then the
-- other attributes round robin, skills in a fixed order of usefulness.
local AI_ATTR = { "str", "str", "dex", "cha", "int" }

-- own: the original picks computer heroes' skills at random with a weighting (FUN_0042a0d0); this spreads the
-- points over the available skills in list order, deterministically (all peers of a network game must agree).
function Hero:autoSpend()
    local i = 0
    while self.points.attr > 0 do
        i = i + 1
        self:spendAttr(AI_ATTR[(i - 1) % #AI_ATTR + 1])
    end
    while self.points.skill > 0 do
        local done = false
        for _, e in ipairs(self.skillList) do
            if self:spendSkill(e[1]) then done = true break end
        end
        if not done then break end
    end
end

-- Items ---------------------------------------------------------------------------

---@param item table
---@return integer?
function Hero:freeSlot(item)
    for i, slot in ipairs(M.SLOT_LAYOUT) do
        if slot.classes[item.slot] and not self.equipped[i] then return i end
    end
end

---@param item table
---@return integer[]
function Hero:slotsFor(item)
    local out = {}
    for i, slot in ipairs(M.SLOT_LAYOUT) do
        if slot.classes[item.slot] then out[#out + 1] = i end
    end
    return out
end

-- Picks an item up: wears it when its slot is free, otherwise puts it into the pack.
---@param item table
---@return boolean, ("equipped"|"pack")?
function Hero:give(item)
    local slot = self:freeSlot(item)
    if slot then
        self.equipped[slot] = item
        self:recalc()
        return true, "equipped"
    end
    if #self.pack < M.PACK_SIZE then
        self.pack[#self.pack + 1] = item
        return true, "pack"
    end
    return false
end

---@return boolean
function Hero:packFull() return #self.pack >= M.PACK_SIZE end

-- Wears pack item `index`; whatever occupied the slot goes back into the pack.
---@param index integer pack index
---@return boolean
function Hero:equip(index)
    local item = self.pack[index]
    if not item then return false end
    local slot = self:freeSlot(item) or self:slotsFor(item)[1]
    if not slot then return false end
    local old = self.equipped[slot]
    self.equipped[slot] = item
    if old then self.pack[index] = old else table.remove(self.pack, index) end
    self:recalc()
    return true
end

---@param slot integer
---@return boolean
function Hero:unequip(slot)
    local item = self.equipped[slot]
    if not item or #self.pack >= M.PACK_SIZE then return false end
    self.equipped[slot] = nil
    self.pack[#self.pack + 1] = item
    self:recalc()
    return true
end

-- Drinks a potion ("health" or "mana"); false if there is none or it would be wasted.
---@param kind string "health" | "mana"
---@return boolean
function Hero:drink(kind)
    local u = self.unit
    if not u or (self.potions[kind] or 0) <= 0 then return false end
    local keep = u.world.eco and u.world.eco:keepLevel(u.side) or 0
    if kind == "health" then
        if u.hp >= u.maxHp then return false end
        local before = u.hp
        u.hp = math.min(u.maxHp, u.hp + M.potionHeal(keep))
        -- the potion is a Cure and Heal spell message (FUN_00561d80), so the army shows "Healing: %d pts"; display only
        u.world:event("tinymsg", u, 1121, 1, math.floor(u.hp - before))
        u.world:event("healthpotion", u)
    elseif kind == "mana" then
        if (self.mana or 0) >= self.mod.mana then return false end
        local before = self.mana or 0
        self.mana = math.min(self.mod.mana, before + M.potionMana(keep))
        -- The mana potion (FUN_00561c30): the sparkle picture and sound, "Mana potion: %+d" over the hero (display only)
        u.world:event("manapotion", u, self.mana - before)
    else
        return false
    end
    self.potions[kind] = self.potions[kind] - 1
    return true
end

-- Throws away a pack item (returns it).
---@param index integer
---@return table? item
function Hero:drop(index)
    return table.remove(self.pack, index)
end

---@param slot integer
---@return table? item
function Hero:dropEquipped(slot)
    local item = self.equipped[slot]
    self.equipped[slot] = nil
    if item then self:recalc() end
    return item
end

-- Undead heroes (status flag 0x4, the same bit as the other armies): the original's life regeneration interval
-- (`FUN_0051b460`) is halved and the regeneration is postponed while it is day (`FUN_0051b820` checks the daylight
-- function `FUN_00499a00` for an undead army); the info area adds "(only at night)" (Game.txt 0663).
---@return boolean
function Hero:isUndead()
    local u = self.unit
    return u ~= nil and require("bit").band(require("src.game.powerups").flags(u.code), 0x4) ~= 0
end

-- Life points per second as the info area shows it (1 / seconds per point) and as `tick` applies it.
---@return number
function Hero:lifeRegen()
    return self:isUndead() and self.mod.regen * 2 or self.mod.regen
end

-- Per-update upkeep: life regeneration and picking up items lying nearby. Inside a tower (`inTower`, called by
-- Eco:healGarrison for the garrisoned hero, who is hidden and so not updated otherwise) the life interval is halved
-- (the regeneration tick FUN_0051b820 halves it for a garrisoned army), the mana regenerates as always, and nothing
-- else happens.
---@param t number
---@param inTower boolean?
function Hero:tick(t, inTower)
    local u = self.unit
    ---@cast u -nil
    local dt = t - (self.lastT or t)
    self.lastT = t
    if dt <= 0 or not (u:alive() or inTower and u.state ~= "dead") then return end
    if not u.world.sides[u.side].ai and self:checkLevel() > 0 then u.world:event("levelup", u, 1) end
    if u.hp < u.maxHp and not (u.fx and (u.fx.poison or u.fx.disease))
        and (u.world.night or not self:isUndead()) then
        u.hp = math.min(u.maxHp, u.hp + self:lifeRegen() * (inTower and 2 or 1) * dt / 1000)
    end
    if (self.mana or 0) < self.mod.mana then
        local world = u.world
        local frozen = world.manaFreeze and world.manaFreeze.t1 > t       -- Freeze Magic stops every side, the caster's too
        if not frozen then
            local sd = world.sides[u.side]
            local pct = self.mod.manaRegenPct + (sd.enervate and sd.enervate > t and (sd.enervatePct or 100) or 0)
            local rate = self.mod.manaRegen * pct / 100
            self.mana = math.min(self.mod.mana, (self.mana or 0) + rate * dt / 1000)
        end
    end
    if inTower then return end
    -- (a Passive side's turn returns before the computer's casting sweep FUN_005001d0 / FUN_00503c60)
    local sd = u.world.sides[u.side]
    if sd.ai and sd.aiLevel ~= 0 then require("src.game.spells").aiThink(u, t) end
    self.scan = (self.scan or 0) + dt
    if self.scan >= 250 then
        self.scan = 0
        if #u.world.chests > 0 then u.world:collectItems(u) end
    end
end

-- Experience a victim is worth (the army / building death routines FUN_005210b0 / FUN_0052b3e0): 1 for a unit, its
-- level + 1 (at least 5) for a hero; 3 for a building, 4 when it can attack.
---@param victim Unit|Building
---@return number
function M.xpValue(victim)
    if victim.kind == "building" then
        if victim.mine then return 0 end
        local t = victim.type or {}
        return (t.damage or 0) > 0 and 4 or 3
    end
    if victim.h then return math.max(5, victim.h.level + 1) end
    return 1
end

return M
