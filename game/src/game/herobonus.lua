-- What the hero info panel prints: the attribute bonus lines of the Stats tab and the titles of the Titles tab.
--
-- Verified: the line texts are Game.txt [0679]..[0695]; the formulas reproduce every value of the original's
-- Stats tab for a Knight Warrior (Str 8, Dex 4, Int 3, Cha 6: +8 Combat, +4 Damage, +40 Life, +3 Life Regeneration,
-- +2 Move Speed at 1.02 sec. Attack Speed, +4 Resistance, +2 Armor, -4 seconds to Conversion, +9 Mana, +2 Mana
-- Regeneration, +9% Spellcasting, +1 Initial Troop XP, +3 Morale, +1 Merchant skill at 0.99% discount, +7 Command
-- Radius, +1 Retinue Slots). Other attribute values were not compared against the original game.
-- Note that these are the numbers the original *prints*; the abilities openwbc3's battles use are in hero.lua
-- (documented in docs/hero.md) and differ in a few places (life per Strength, command radius, damage).
-- The title thresholds are the table at 0x00614a84 of the game binary (8 categories x 11 steps).
local strings = require("src.game.strings")

local M = {}

local function text(n) return strings.get("Game.txt", ("%04d"):format(n)) or "" end

---@param attr integer 1 strength, 2 dexterity, 3 intelligence, 4 charisma
---@param v integer
---@return table<string, number>
local function bonuses(attr, v)
    if attr == 1 then
        return { combat = v, damage = math.floor(v / 2), life = 5 * v, regen = 1 + math.floor(v / 3) }
    elseif attr == 2 then
        return { speed = math.floor((v + 1) / 2), attackSpeed = math.min(2 * v - 10, 60), resistance = v,
                 armor = math.floor(v / 2), conversion = math.max(-v, -40) }
    elseif attr == 3 then
        return { mana = 3 * v, manaRegen = 2 + math.floor(v / 10), spellcasting = 3 * v, troopXp = math.floor(v / 2) }
    end
    return { morale = math.floor(v / 2), discount = -5 + v, command = 6 + math.min(math.floor(v / 4), 13),
             retinue = math.floor(v / 4) }
end

-- The four lines of an attribute (1 Strength, 2 Dexterity, 3 Intelligence, 4 Charisma) at value v.
---@param attr integer
---@param v integer
---@return string[]
function M.lines(attr, v)
    local b = bonuses(attr, v)
    if attr == 1 then
        return { text(679):format(b.combat), text(680):format(b.damage), text(681):format(b.life),
                 text(682):format(b.regen) }
    elseif attr == 2 then
        return { text(683):format(b.speed, 1 - b.attackSpeed * 0.01), text(684):format(b.resistance),
                 text(685):format(b.armor), text(686):format(b.conversion) }
    elseif attr == 3 then
        return { text(687):format(b.mana), text(688):format(b.manaRegen), text(689):format(b.spellcasting),
                 text(690):format(b.troopXp) }
    end
    local d = b.discount
    local pct = d == 0 and 0 or 100 - 100 * (100 / (d + 100))
    return { text(691):format(b.morale), d >= 0 and text(692):format(d, pct) or text(693):format(-d, -pct),
             text(694):format(b.command), text(695):format(b.retinue) }
end

-- "Total Merchant Skill: +n (x% discount)" for a discount value in percent points.
---@param discount number
---@return string
function M.merchantLine(discount)
    local pct = discount == 0 and 0 or 100 - 100 * (100 / (discount + 100))
    if discount >= 0 then return text(862):format(discount, pct) end
    return text(861):format(-discount, -pct)
end

-- Titles: battles fought, battles won, heroes killed, enemies killed, dragons killed, titans killed, quests
-- completed, spells cast. STEPS[category][rank + 1] is the count needed for `rank` (0 .. 10).
M.CATEGORIES = 8
M.STEPS = {
    { 0, 1, 5, 10, 20, 40, 80, 160, 250, 400, 600 },
    { 0, 1, 4, 8, 15, 25, 40, 80, 150, 250, 350 },
    { 0, 1, 6, 12, 25, 50, 100, 200, 350, 550, 800 },
    { 0, 1, 1500, 3000, 6000, 12000, 25000, 50000, 100000, 200000, 400000 },
    { 0, 1, 6, 12, 25, 50, 80, 120, 180, 240, 300 },
    { 0, 1, 5, 10, 20, 30, 50, 70, 90, 120, 150 },
    { 0, 1, 5, 15, 30, 50, 80, 150, 300, 500, 700 },
    { 0, 1, 20, 80, 100, 200, 400, 800, 1500, 2500, 4000 },
}

---@param category integer 1..8
---@param count number
---@return integer 0..10
function M.rank(category, count)
    for i = 2, 11 do
        if count < M.STEPS[category][i] then return i - 2 end
    end
    return 10
end

-- Name of rank 1..10 of a category (Game.txt 936 + 10 x (category - 1) + rank - 1).
---@param category integer
---@param rank integer
---@return string
function M.titleName(category, rank)
    return text(936 + (category - 1) * 10 + rank - 1)
end

-- Name of the overall ranking (sum of the eight ranks, 0 .. 80).
---@param total integer
---@return string
function M.rankingName(total)
    return text(1016 + total)
end

return M
