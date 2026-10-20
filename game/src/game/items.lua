-- Items: the item catalogue (<Lang>/Items.xcr/Items.xml), the equipment slots
-- and how an item's powers turn into hero bonuses.
--
-- Items.xml: <Item id> <Name> <Power id type data [chance level]>text</Power>
-- <Description> <Image iconrow iconcol/> <Data value level rarity/>. The icon
-- row doubles as the equipment slot (Items.bmp has one row per item class).
local content = require("src.content")
local strings = require("src.game.strings")

local M = {}

-- The catalogue lives in the content registry (`item` records, imported from Items.xml by src/import/wbc3/items.lua; mods add
-- their own). Items.bmp: row r (110 px high) holds a 50x50 slot symbol at x = 0 and the item pictures (70 px wide) from x = 70;
-- the row is the item class (`itemclass` records: name, how many are worn).

-- Item class names by row (the `itemclass` records), read-only.
M.SLOTS = setmetatable({}, { __index = function(_, row)
    for _, c in ipairs(content.itemclass:all()) do
        if c.slot == row then return c.id end
    end
end })
-- How many items of a class a hero wears (the `count` of the class record; two rings).
---@param row integer
---@return integer
function M.slotCount(row)
    for _, c in ipairs(content.itemclass:all()) do
        if c.slot == row then return c.count or 1 end
    end
    return 1
end

-- Kept for callers written before the registry: the records are there from start-up.
---@return boolean
function M.load() return true end

-- All items in catalogue order (the registry's list: read only).
---@return ItemRecord[]
function M.all() return content.item:all() end

-- The item with this number (or mod id), or nil.
---@param id (integer|string)?
---@return ItemRecord?
function M.get(id)
    return content.item._recs[id]
end

-- Weighted random item. `tier` (1..3) caps the quality of the find; artifacts
-- and sets (rarity 0 or tiers 4/5) only come from `special` drops.
-- A random item whose tier is in `tiers` (a set {[1]=true, ...}).
---@param tiers table<integer, boolean>
---@param rng (fun(): number)? 0 <= x < 1
---@return ItemRecord?
function M.randomOf(tiers, rng)
    rng = rng or math.random
    local pool, total = {}, 0
    for _, it in ipairs(content.item:all()) do
        if it.rarity > 0 and tiers[it.tier] then
            pool[#pool + 1] = it
            total = total + it.rarity
        end
    end
    if total == 0 then return nil end
    local r = rng() * total
    for _, it in ipairs(pool) do
        r = r - it.rarity
        if r <= 0 then return it end
    end
    return pool[#pool]
end

---@param tier integer
---@param rng (fun(): number)?
---@return ItemRecord?
function M.random(tier, rng)
    rng = rng or math.random
    local pool, total = {}, 0
    for _, it in ipairs(content.item:all()) do
        if it.rarity > 0 and it.tier <= tier and it.tier <= 3 then
            -- better tiers are rarer even when their rarity value is the same
            local w = it.rarity * (it.tier == tier and 2 or 1)
            pool[#pool + 1] = { it, w }
            total = total + w
        end
    end
    if total == 0 then return nil end
    local r = rng() * total
    for _, e in ipairs(pool) do
        r = r - e[2]
        if r <= 0 then return e[1] end
    end
    return pool[#pool][1]
end

-- Bonus table of a list of items: sums of the numeric powers the game applies. With `weaponSlot` (the worn slot a hero's
-- weapon sits in) the damage powers (piercing, slashing, crushing, fire, ice, electricity, magic) count for that slot's
-- item only, its first three powers, and the last of them names the hero's damage type `damageType` (the hero part of
-- the army damage getter, binary 0x00526540 ff.: a loop over the power list of the item in worn slot 2); without it
-- every item counts.
-- "cast spell" powers are no bonuses, spells.itemCast fires them when the hero strikes; "hero skill" powers add skill
-- levels (`skills`).
-- What a hero's items add.
---@class ItemBonuses
---@field combat number
---@field speed number
---@field armor number
---@field resistance number
---@field morale number
---@field command number
---@field damage number
---@field damageType string?         the damage type the weapon's powers name
---@field attackSpeed number
---@field regen number
---@field vampirism number
---@field critical number
---@field assassin number
---@field manaDiscount number
---@field resist table<string, number> element (fire, ice, electricity, magic) -> resistance
---@field skills table<integer, integer> hero skill -> levels added

---@param items table<integer, ItemRecord> slot -> item
---@param weaponSlot integer?
---@return ItemBonuses
function M.bonuses(items, weaponSlot)
    ---@type ItemBonuses
    local b = { combat = 0, speed = 0, armor = 0, resistance = 0, morale = 0, command = 0, damage = 0,
                attackSpeed = 0, regen = 0, vampirism = 0, critical = 0, assassin = 0, manaDiscount = 0, resist = {}, skills = {} }
    local powers = content.itempower
    for slot, it in pairs(items) do
        for i, p in ipairs(it.powers) do
            local def, d = powers._recs[p.type], p.data
            if def then
                if def.stat then
                    b[def.stat] = b[def.stat] + (def.sign or 1) * d
                elseif def.damageType then
                    if not weaponSlot or (slot == weaponSlot and i <= 3) then
                        b.damage = b.damage + d
                        b.damageType = def.damageType
                    end
                elseif def.resist then
                    b.resist[def.resist] = (b.resist[def.resist] or 0) + d
                elseif def.skill then
                    -- hero skill power (99): `data` is the skill, the power's level the levels it adds (FUN_00402e30)
                    b.skills[d] = (b.skills[d] or 0) + (p.level or 0)
                end
            end
        end
    end
    return b
end

-- The items of a computer hero (the computer hero routine, binary FUN_0042a0d0; the tables at 0x6084c8 / 0x6084dc, the
-- dice and the funky item ids were read from the binary). A `rng(n)` gives 1..n.
--   backpack: 0,0,1,1,1,1,1,2,2,3 items (none in an Assassin game, victory condition 3), each a random item
--             (FUN_0043e340) with major = 2d(level+2)+1 >= 45; duplicates of the pack are dropped
--   worn:     0,1,1,1,2,2,2,3,3,4 items from FUN_00402f90(minor, lesser, major, artifact, set) with
--             points = 2d(4 level)+1, major >= 45, artifact >= 70, set = 1d2-1; a chance of 5 % each for the Ring of Fire and
--             Ice (8), the Thunder Shield (9), the Blackfire Axe (15), the Staff of Pyreakon (7) (once per hero, the rolls
--             d100 > 95 / 90 / 85 / 80 in that order); the last item is always the Boots of Speed (2); an item goes to the
--             slot of its class (a later one of the same slot replaces the earlier; the second ring slot stays empty)
-- Returns the worn items { [slot 1..7] = item } (the slots of hero.SLOT_LAYOUT) and the backpack list.
-- (the worn slot of an item class is `worn` of the `itemclass` records)
local BACKPACK_COUNT = { [0] = 0, 0, 1, 1, 1, 1, 1, 2, 2, 3 }
local WORN_COUNT = { [0] = 0, 1, 1, 1, 2, 2, 2, 3, 3, 4 }

local function dice(rng, n, sides, bonus)
    local s = bonus
    for _ = 1, n do s = s + rng(sides) end
    return s
end

local function wornSlotOf(row)
    for _, c in ipairs(content.itemclass:all()) do
        if c.slot == row then return c.worn end
    end
end

-- A random catalogue item of the tiers named by the flags (FUN_00402f90: weighted by rarity).
local function randomByTier(rng, major, artifact, set)
    return M.randomOf({ true, true, major, artifact, set }, function() return (rng(65535) - 1) / 65535 end)
end

-- The random item (FUN_0043e260): 1 in 200 (twice for a major item) a treasure, an artifact or set item.
local function randomItemTotally(rng, major)
    if rng(200) == 1 or (major and rng(200) == 1) then
        local it = M.randomOf({ false, false, false, true, true }, function() return (rng(65535) - 1) / 65535 end)
        if it then return it end
    end
    return randomByTier(rng, major, major, false)
end

---@param level integer
---@param assassin boolean?
---@param rng (fun(n: integer): integer)?
---@return table<integer, ItemRecord> worn slot -> item
---@return ItemRecord[] pack
function M.computerKit(level, assassin, rng)
    rng = rng or math.random
    local worn, pack = {}, {}
    local n = assassin and 0 or BACKPACK_COUNT[rng(10) - 1]
    for _ = 1, n do
        local major = dice(rng, 2, level + 2, 1) >= 45
        local it = randomItemTotally(rng, major)
        local have = not it
        for _, p in ipairs(pack) do if it and p.id == it.id then have = true end end
        if not have then pack[#pack + 1] = it end
    end
    n = WORN_COUNT[rng(10) - 1]
    local funky = false
    for i = 1, n do
        local points = dice(rng, 2, level * 4, 1)
        local it = randomByTier(rng, points >= 45, points >= 70, rng(2) == 2)
        for _, f in ipairs({ { 95, 8 }, { 90, 9 }, { 85, 15 }, { 80, 7 } }) do
            if rng(100) > f[1] and not funky then
                it, funky = M.get(f[2]) or it, true
            end
        end
        if i == n then it = M.get(2) or it end
        local slot = it and wornSlotOf(it.slot)
        if slot then worn[slot] = it end
    end
    return worn, pack
end

-- Description lines of an item's powers (localised templates from Game.txt, named by the `text` of the `itempower` records).

local function format(template, n)
    return (template:gsub("%%%+?d", function(spec)
        return spec:find("+", 1, true) and ("%+d"):format(n) or ("%d"):format(n)
    end):gsub("%%%%", "%%"))
end

---@param it ItemRecord
---@return string[]
function M.powerLines(it)
    local out = {}
    for _, p in ipairs(it.powers) do
        local line
        if p.text then
            line = p.text
        elseif p.type == "cast spell" then
            local name = strings.get("Spells.txt", ("SPELL_NAME_%02d"):format(p.data))
            line = name and ("Casts " .. name) or nil
            if line and p.chance then line = line .. (" (%d%%)"):format(p.chance) end
        elseif p.type == "spell failure" then
            line = ("%+d%% Spell Failure"):format(p.data)
        elseif content.itempower._recs[p.type] and content.itempower._recs[p.type].text then
            local tpl = strings.get("Game.txt", content.itempower._recs[p.type].text)
            line = tpl and format(tpl, p.data) or nil
        end
        if line then out[#out + 1] = line end
    end
    return out
end

-- Item picture: a quad of Items.bmp, drawn at (x, y) scaled to `size` pixels high.
---@param it ItemRecord
---@param x number
---@param y number
---@param scale number?
function M.drawIcon(it, x, y, scale)
    local interface = require("src.ui.hud")
    local img = interface.bitmap("Items.bmp")
    if not img then return end
    M.quads = M.quads or {}
    local key = it.row * 100 + it.col
    local q = M.quads[key]
    if not q then
        q = love.graphics.newQuad(70 + it.col * 70, it.row * 110, 70, 110, img:getDimensions())
        M.quads[key] = q
    end
    love.graphics.draw(img, q, x, y, 0, scale or 1, scale or 1)
end

---@param slot integer
---@param x number
---@param y number
---@param scale number?
function M.drawSlotSymbol(slot, x, y, scale)
    local interface = require("src.ui.hud")
    local img = interface.bitmap("Items.bmp")
    if not img then return end
    M.symbolQuads = M.symbolQuads or {}
    local q = M.symbolQuads[slot]
    if not q then
        q = love.graphics.newQuad(0, slot * 110, 50, 50, img:getDimensions())
        M.symbolQuads[slot] = q
    end
    love.graphics.draw(img, q, x, y, 0, scale or 1, scale or 1)
end

return M
