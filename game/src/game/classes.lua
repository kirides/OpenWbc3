-- Hero classes (names from <Lang>/WBC3HeroSelectionText.txt) and their numbers.
-- The original's hero stat function: starting attributes = 5 + race modifier + class
-- modifier; base life, life per level, base armour and base mana per class. The race /
-- class attribute modifiers follow the original's hero creation as seen in the game
-- (not yet cross-checked against the binary); the others were read from the binary's
-- tables. openwbc3's own: the four "broad" groups of the class picker. Spell spheres are
-- hero skills (ids 10..22) in the race and class skill lists below.
local vfs = require("src.vfs.vfs")
local text = require("src.core.text")
local content = require("src.content")

-- the English race names (`name` of the race records), kept as a fallback for when the text file cannot be read
local FALLBACK_RACE_NAMES = content.race:view("name")

local M = {}

-- Race names come from <Lang>/WBC3HeroSelectionText.txt, a plain line list read in order: the sixteen
-- race names are lines 34..49 (`nameLine` of the race records; the class names above them are lines 6..33; verified
-- against the English and German copies in the install). Read on first use, so the archives are already mounted by then.
---@return table<integer, string>
local function loadRaceNames()
    local data = vfs.langFile("WBC3HeroSelectionText.txt")
    local lines = {}
    if data then
        local i = 0
        for line in (data .. "\n"):gmatch("(.-)\r?\n") do
            i = i + 1
            lines[i] = text.fromCP1252(line)
        end
    end
    local names = {}
    for _, race in ipairs(content.race:all()) do
        names[race.slot] = race.nameLine and lines[race.nameLine] or FALLBACK_RACE_NAMES[race.slot]
    end
    return names
end

-- indexed like a normal table (race numbers 0..15), but read only when first indexed, which is
-- after the archives are mounted. The options screen calls `invalidate` on a language change.
local raceNames
local function at(k)
    if not raceNames then raceNames = loadRaceNames() end
    return raceNames[k]
end
M.RACE_NAMES = setmetatable({}, { __index = function(_, k) return at(k) end })

-- The race numbers the setup screens offer (the playable races, in slot order).
---@return integer[]
function M.raceSlots()
    local out = {}
    for i, race in ipairs(content.race:playable()) do out[i] = race.slot end
    return out
end

function M.invalidate()
    raceNames = nil
end

-- The four broad groups of the class picker (openwbc3's own: the setting `hero.broad`).
content.onReady(function() M.BROAD = content.setting:value("hero.broad") end)

-- { name, broad index, str, dex, int, cha modifiers, base life, life per level, base armour, base mana }: the `class` records
-- (content/base/classes.lua) in the shape the screens use, in class number order.
-- A class as a row of the legacy table.
---@class ClassRow
---@field [1] string                the class id
---@field [2] integer               its broad group
---@field [3] integer               attribute modifiers: strength
---@field [4] integer               dexterity
---@field [5] integer               intelligence
---@field [6] integer               charisma
---@field [7] number                life
---@field [8] number                life per level
---@field [9] number                armour
---@field [10] number               mana

---@return ClassRow[]
function M.list()
    local cache = content.class.cache
    if not cache.legacy then
        local list = {}
        for i, c in ipairs(content.class:all()) do
            list[i] = { c.id, c.broad, c.attrMod[1], c.attrMod[2], c.attrMod[3], c.attrMod[4], c.life, c.lifePerLevel, c.armor, c.mana }
        end
        cache.legacy = list
    end
    return cache.legacy
end

-- The localised name of class `name`: the XCI text resources 8..11 hold the class names, eight each, in class
-- number order (falls back to the id where the interface is not loaded, e.g. headless runs).
local CLASS_GROUP_TEXT = { 8, 9, 10, 11 }
---@param name string?
---@return string
function M.className(name)
    local ui = package.loaded["src.ui.interface"]
    for i, c in ipairs(M.list()) do
        if c[1] == name then
            local n = i - 1
            return ui and ui.ui and ui.text(CLASS_GROUP_TEXT[math.floor(n / 8) + 1], n % 8) or c[1]
        end
    end
    return name or ""
end

---@param broad integer
---@return ClassRow[]
function M.of(broad)
    local out = {}
    for _, c in ipairs(M.list()) do
        if c[2] == broad then out[#out + 1] = c end
    end
    return out
end

---@param name string
---@return ClassRow?
function M.find(name)
    for _, c in ipairs(M.list()) do
        if c[1] == name then return c end
    end
end

-- Life / armour / mana numbers of a class (by name; unknown names count as Warrior).
---@param name string
---@return {life: number, perLevel: number, armor: number, mana: number}
function M.data(name)
    local c = M.find(name) or M.list()[1]
    return { life = c[7], perLevel = c[8], armor = c[9], mana = c[10] }
end

-- Starting attributes of a hero of `race` (0-15) and class `className`.
---@param race integer?
---@param className string
---@return {str: integer, dex: integer, int: integer, cha: integer}
function M.baseAttr(race, className)
    local c = M.find(className) or M.list()[1]
    local r = (content.race:bySlot(race or 0) or content.race:bySlot(0)).attrMod
    return { str = 5 + r[1] + c[3], dex = 5 + r[2] + c[4], int = 5 + r[3] + c[5], cha = 5 + r[4] + c[6] }
end

-- Hero skills. Ids are the original's (binary enum, names are Game.txt 759 + id, content/base/skills.lua): 1 Ferocity, 2 Constitution,
-- 3 Regeneration, 4 Running, 5 Lore, 6 Energy, 7 Ritual, 8 Leadership, 9 Merchant, 10..22 the magic spheres (Healing .. Arcane, sphere =
-- id - 10), 23 Armorer, 24 Warding, 31 Invulnerability and so on up to 101.
-- A hero has at most 10 skills: 5 from the race (`skills` of the race record) and 5 from the class (`skills` of the class record), each
-- { skill, availableAtLevel, startLevel } (the hero skill setup `FUN_0054c620` in the binary). Skill 0 = no entry.

-- The hero's skill list: race entry i, then class entry i, for i = 1..5 (duplicates merge: the earlier availability,
-- levels add, then the entry becomes available at 1 (race) / 0 (class) and gains 2 levels); finally sorted by
-- availability, then level (descending). Returns { { id, avail, level }, ... } (`FUN_0054c620` in the binary).
---@param race integer?
---@param className string
---@return {[1]: integer, [2]: integer, [3]: integer}[] skill id, from race (1) or class (0), weight
function M.skillList(race, className)
    local rs = (content.race:bySlot(race or 0) or content.race:bySlot(0)).skills
    local cs = (content.class._recs[className] or content.class._recs["Warrior"]).skills
    local list, at = {}, {}
    local function add(e, fromRace)
        if e[1] == 0 then return end
        local old = at[e[1]]
        if old then
            old[2] = math.min(old[2], e[2])
            old[3] = old[3] + e[3]
            old[2] = fromRace and 1 or 0
            old[3] = old[3] + 2
        else
            old = { e[1], e[2], e[3] }
            at[e[1]] = old
            list[#list + 1] = old
        end
    end
    for i = 1, 5 do
        add(rs[i], true)
        add(cs[i], false)
    end
    for i = 2, #list do   -- stable insertion sort
        local v, j = list[i], i - 1
        while j >= 1 and (list[j][2] > v[2] or (list[j][2] == v[2] and list[j][3] < v[3])) do
            list[j + 1] = list[j]
            j = j - 1
        end
        list[j + 1] = v
    end
    return list
end

-- The hero save table (see Hero:save) of a new level 1 hero.
---@param className string
---@param race integer
---@return table the hero's saved state (Hero:save)
function M.newHero(className, race)
    local c = M.find(className) or M.list()[1]
    return { class = c[1], race = race, level = 1, xp = 0, attr = M.baseAttr(race, c[1]),
             points = { attr = 0, skill = 0 } }
end

return M
