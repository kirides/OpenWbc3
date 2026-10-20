-- Statistic gains of army levels (the original's level-up routine, 1.04 binary FUN_0040daa0; the tables are read from the
-- binary: combat 0x607d70, speed 0x607ed0, hits 0x608030). Every troop level adds to combat, speed and hits by
-- tables indexed with the current value (8 value ranges x 20 levels), and always to damage (+2, +1 more from level 5, 10
-- and 15), resistance and armour (+1, +1 more from level 5 and 12). Combat and speed stop at 50. A troop's level counts
-- from 0 and is at most 19. Nothing here is saved: a unit's statistics follow from its type and its level.
--
-- gain(base, level) -> { combat, speed, hits, damage, resistance, armor }: what `level` levels add to the type's values
-- (base = { combat, speed, hits, damage }; a damage of 0 stays 0, units without an attack do not learn one - openwbc3's
-- own reading, the original adds regardless).
local M = { MAX_LEVEL = 19 }

-- { min, max, { bonus at level 0 .. 19 } } per range of the current value
M.COMBAT = {
    { 0, 4, { 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 } },
    { 5, 8, { 0, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2 } },
    { 9, 12, { 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2 } },
    { 13, 16, { 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 2, 2 } },
    { 17, 20, { 0, 0, 1, 1, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 2 } },
    { 21, 24, { 0, 0, 1, 1, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2 } },
    { 25, 28, { 0, 0, 0, 1, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2, 2, 2 } },
    { 29, 99, { 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2, 2 } },
}
M.SPEED = {
    { 0, 4, { 0, 0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1, 1 } },
    { 5, 8, { 0, 1, 1, 0, 1, 1, 0, 1, 1, 0, 1, 1, 0, 1, 1, 0, 1, 1, 0, 1 } },
    { 9, 12, { 0, 1, 0, 1, 1, 0, 1, 1, 0, 1, 1, 0, 1, 1, 0, 1, 1, 0, 1, 1 } },
    { 13, 16, { 0, 1, 0, 1, 1, 0, 1, 1, 0, 1, 1, 0, 1, 1, 0, 1, 1, 0, 1, 1 } },
    { 17, 20, { 0, 0, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 1, 0, 0, 1, 0, 1, 0, 1 } },
    { 21, 24, { 0, 0, 0, 0, 0, 0, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1 } },
    { 25, 28, { 0, 0, 0, 0, 0, 0, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1 } },
    { 29, 99, { 0, 0, 0, 0, 0, 0, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1 } },
}
M.HITS = {
    { 0, 30, { 0, 5, 5, 5, 5, 10, 10, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20 } },
    { 31, 50, { 0, 5, 5, 5, 10, 10, 10, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20 } },
    { 51, 70, { 0, 10, 10, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20 } },
    { 71, 90, { 0, 10, 10, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20 } },
    { 91, 120, { 0, 10, 10, 10, 10, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20 } },
    { 121, 160, { 0, 10, 10, 10, 10, 10, 10, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20 } },
    { 161, 220, { 0, 10, 10, 10, 10, 10, 10, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20 } },
    { 221, 999, { 0, 10, 10, 10, 10, 10, 10, 15, 15, 15, 15, 15, 15, 15, 15, 20, 20, 20, 20, 20 } },
}

---@param rows {[1]: integer, [2]: integer, [3]: integer[]}[]
---@param value number
---@param level integer
---@return integer
local function bonus(rows, value, level)
    for _, r in ipairs(rows) do
        if value >= r[1] and value <= r[2] then return r[3][level + 1] end
    end
    return 0
end

---@type table<string, ArmyLevelGain>
local cache = {}

-- What the levels add to a troop's stats.
---@class ArmyLevelGain
---@field combat integer
---@field speed integer
---@field hits integer
---@field damage integer
---@field resistance integer
---@field armor integer

---@param base {combat: number?, speed: number?, hits: number?, damage: number?} the type record
---@param level integer?
---@return ArmyLevelGain
function M.gain(base, level)
    level = math.max(0, math.min(M.MAX_LEVEL, level or 0))
    local g = { combat = 0, speed = 0, hits = 0, damage = 0, resistance = 0, armor = 0 }
    if level == 0 then return g end
    local key = ("%d:%d:%d:%d:%d"):format(base.combat or 0, base.speed or 0, base.hits or 0, base.damage or 0, level)
    local c = cache[key]
    if c then return c end
    local combat, speed, hits = base.combat or 0, base.speed or 0, base.hits or 0
    for l = 1, level do
        combat = math.min(50, combat + bonus(M.COMBAT, combat, l))
        speed = math.min(50, speed + bonus(M.SPEED, speed, l))
        local h = bonus(M.HITS, hits, l)
        hits = hits + h
        g.hits = g.hits + h
        if (base.damage or 0) > 0 then
            g.damage = g.damage + 2 + (l >= 5 and 1 or 0) + (l >= 10 and 1 or 0) + (l >= 15 and 1 or 0)
        end
        local d = 1 + (l >= 5 and 1 or 0) + (l >= 12 and 1 or 0)
        g.resistance, g.armor = g.resistance + d, g.armor + d
    end
    g.combat, g.speed = combat - (base.combat or 0), speed - (base.speed or 0)
    cache[key] = g
    return g
end

return M
