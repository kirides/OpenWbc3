-- Per-side battle statistics for the results screen (the original's results screen FUN_00449ce0 and its per-side
-- counters, e.g. the hero counter FUN_00518a10): hero kills and spells, resources obtained and spent, units produced /
-- lost / killed (also per enemy side), buildings built / lost / razed / converted. Fed by world events and the economy;
-- not part of the simulation hash.
---@class BattleStats
---@field sides table<integer, BattleSideStats> 0..5
local M = {}

-- The counters of one side.
---@class BattleSideStats
---@field heroKills integer
---@field spells integer
---@field unitsProduced integer
---@field unitsLost integer
---@field unitsKilled integer
---@field killedBySide table<integer, integer>
---@field built integer
---@field lost integer
---@field razed integer
---@field converted integer
---@field razedBySide table<integer, integer>
---@field obtained table<string, number> resource -> amount
---@field spent table<string, number>
---@field heroesSlain integer?
---@field heroDied boolean?
---@field levelled boolean?
---@field xpGained number?          the experience the side got at the end (battlexp.lua)

local RES = { "gold", "metal", "stone", "crystal" }
M.RESOURCES = RES

---@return BattleSideStats
local function side()
    local s = { heroKills = 0, spells = 0, unitsProduced = 0, unitsLost = 0, unitsKilled = 0, killedBySide = {},
                built = 0, lost = 0, razed = 0, converted = 0, razedBySide = {}, obtained = {}, spent = {} }
    for _, r in ipairs(RES) do s.obtained[r], s.spent[r] = 0, 0 end
    return s
end

---@return BattleStats
function M.new()
    ---@type BattleStats
    local self = { sides = {} }
    for i = 0, 5 do self.sides[i] = side() end
    return setmetatable(self, { __index = M })
end

---@param i integer side
---@param r string resource
---@param amount number
---@param what "obtained"|"spent"
function M:resource(i, r, amount, what)
    local s = self.sides[i]
    if s and amount ~= 0 then s[what][r] = math.max(0, s[what][r] + amount) end
end

-- A world event (kind and its arguments, see World:emit).
---@param kind string
---@param a any
---@param b any
---@param c any
function M:note(kind, a, b, c)
    local S = self.sides
    if kind == "kill" and a and b then
        local k, v = S[a.side], S[b.side]
        if v then v.unitsLost = v.unitsLost + 1 end
        if k and a.side ~= b.side then
            k.unitsKilled = k.unitsKilled + 1
            k.killedBySide[b.side] = (k.killedBySide[b.side] or 0) + 1
            if a.hero then k.heroKills = k.heroKills + 1 end
            if b.hero then k.heroesSlain = (k.heroesSlain or 0) + 1 end
        end
    elseif kind == "produced" and a and S[a.side] then
        S[a.side].unitsProduced = S[a.side].unitsProduced + 1
    elseif kind == "built" and a and S[a.side] then
        S[a.side].built = S[a.side].built + 1
    elseif kind == "destroyed" and a then
        if S[a.side] then S[a.side].lost = S[a.side].lost + 1 end
        local r = a.razedBy
        if r and r ~= a.side and S[r] then
            S[r].razed = S[r].razed + 1
            S[r].razedBySide[a.side] = (S[r].razedBySide[a.side] or 0) + 1
        end
    elseif kind == "pillaged" and a and b and S[b] and b ~= a.side then
        S[b].razed = S[b].razed + 1
        S[b].razedBySide[a.side] = (S[b].razedBySide[a.side] or 0) + 1
    elseif kind == "converted" and a and S[a.side] then
        S[a.side].converted = S[a.side].converted + 1
        if c and S[c] then S[c].lost = S[c].lost + 1 end
    elseif kind == "herodied" and a and S[a.side] then
        S[a.side].heroDied = true
    elseif kind == "levelup" and a and S[a.side] then
        S[a.side].levelled = true
    elseif kind == "spellcast" and a and c and S[a.side] then
        S[a.side].spells = S[a.side].spells + 1
    end
end

return M
