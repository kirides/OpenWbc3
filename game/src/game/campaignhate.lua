-- The campaign's diplomacy between the hero's race and the races of Etheria: the table of the starting standings and the
-- four relations a standing falls into (the "hate index" of the original's campaign data).
--
-- Source (1.04 binary): the 16 x 16 table of 16-bit values at 0x0061c0c4 (row = the hero's race, column = the other race, race
-- slots 0 Knight, 1 Dwarf, 2 Undead, 3 Barbarian, 4 Minotaur, 5 Orc, 6 High Elf, 7 Wood Elf, 8 Dark Elf, 9 Fey, 10 Dark Dwarf,
-- 11 Daemon, 12 Empire, 13 Ssrathi, 14 Swarm, 15 Plague Lord); `FUN_005939a0` (a new campaign) copies the hero's row into the
-- campaign's standings (0x060d2a88 + 2 x race, 16 shorts). The relation of a standing is `FUN_00595470`: below -4 enemy, below 5
-- neutral, below 15 friend, else ally (the values the campaign data's <Diplomacy> limits and the <Condition> ratings are built on:
-- 14 and 15 are the friend / ally limits).
local M = {}

M.TABLE = {
    [0] = { [0] = 20, 10, -10, 0, 0, -1, 7, 4, -5, 0, -1, -5, 4, -1, 0, 0 },
    { [0] = 10, 20, -3, 0, -1, -5, -5, -4, -4, 0, -1, -2, 10, 0, 0, -10 },
    { [0] = -10, -2, 20, 0, 0, 0, -8, -2, 7, -1, 7, 8, -5, 0, 6, 4 },
    { [0] = 1, 7, 2, 20, 4, 1, -1, 5, -2, -8, -6, 0, 0, 0, -10, 0 },
    { [0] = 0, -5, 3, 5, 20, 7, -2, -1, 0, -5, -5, 1, 0, 3, 0, 4 },
    { [0] = -3, -8, 0, 4, 3, 20, -6, -4, 8, -2, 5, 0, -9, 0, 0, 4 },
    { [0] = 8, -4, -7, -1, -2, -3, 20, 10, -6, 6, -4, -5, 3, 0, 0, -1 },
    { [0] = 3, -5, -4, -2, -2, -2, 10, 20, -5, 7, 0, 0, 3, 0, -6, 0 },
    { [0] = -5, 0, 4, 0, 4, 7, -10, -6, 20, -1, 3, 9, 0, 0, 0, 0 },
    { [0] = 0, 0, -3, 0, -1, 0, 7, 5, 0, 20, -2, -6, 0, 0, 0, 0 },
    { [0] = -3, -6, 7, 0, 7, 5, -5, -3, 6, -1, 20, 0, -4, 0, 0, -10 },
    { [0] = -6, 0, 4, -2, 2, 3, -6, -4, 0, -7, 6, 20, -2, 0, 7, 6 },
    { [0] = 4, 6, -5, 5, 0, -6, 0, 0, -1, 0, 1, 0, 20, -10, 0, 0 },
    { [0] = -4, -5, -1, 6, -5, 0, -1, 5, -1, -3, 5, 5, -10, 20, 0, 0 },
    { [0] = -6, -10, 6, -10, 0, 0, -4, -4, 0, -2, 0, 7, -5, 0, 20, 0 },
    { [0] = -2, -9, 0, 0, 0, 5, -6, -3, -1, -4, -6, 8, 0, 0, 0, 20 },
}

-- The standing of `race` for a hero of `heroRace` at the start of a campaign.
---@param heroRace integer
---@param race integer
---@return integer
function M.initial(heroRace, race)
    local row = M.TABLE[heroRace]
    return row and row[race] or 0
end

-- The relation of a standing (`FUN_00595470`).
---@param standing number
---@return "enemy"|"neutral"|"friend"|"ally"
function M.relation(standing)
    if standing < -4 then return "enemy" end
    if standing < 5 then return "neutral" end
    if standing < 15 then return "friend" end
    return "ally"
end

-- A diplomatic action on a standing (`FUN_005955a0`, both the battle and the choice branch): the change is added once,
-- and then - only while the result is still short of the limit - once more up to the limit.
-- So a step of +2 (limit 15) from 3 gives 5 then 7, a step that reaches or passes the limit on the first add stays where it
-- landed (even beyond the limit: the data's "+100, limit 20" steps put a race at 100 + the old standing), and the same
-- mirrored for a negative change and its lower limit. (The data names the limit in the direction of every step.)
---@param standing number
---@param add number
---@param max number?
---@param min number?
---@return number
function M.apply(standing, add, max, min)
    max, min = max or 0, min or 0
    standing = standing + add
    if add > 0 and standing < max then
        standing = math.min(standing + add, max)
    elseif add < 0 and standing > min then
        standing = math.max(standing + add, min)
    end
    return standing
end

return M
