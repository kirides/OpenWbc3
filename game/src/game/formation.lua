-- Formations for group move orders, after the original's formation slot placement (1.04 binary FUN_00530f80) and its
-- formation direction change (FUN_0040c770).
--
-- There are eight formations in the order of the formation panel: Block, Defensive Ring, Wedge, Skirmish, Double Line,
-- Single Column, Wide Line, Double Column. Their slots are the original's compiled formation table (VA 0x005FBC9C,
-- extracted into formationdata.lua by tools/dev/genformations.lua): for every group size n 1..32 a list of n offsets in
-- cells. The units are handed out to the slots in the table's order by range, longest first, and lower combat first
-- among equal ranges, so archers take the early slots (the rear of a block, the middle of the ring).
-- The formation faces one of eight directions (0 TOP, 1 TOPLEFT, 2 LEFT, 3 BOTTOMLEFT, 4 BOTTOM, 5 BOTTOMRIGHT, 6 RIGHT,
-- 7 TOPRIGHT; the rotate buttons step through them); the table is in the frame of BOTTOM (offset (x, y) = x cells
-- right, y cells down), the other directions turn it by 90 degrees or, for the diagonals, by 45 degrees with halved
-- offsets (arithmetic shift, as the original's `>> 1`). Slots are centred on the order's target cell, not on the leader.
-- The default formation of every new army is type 1 (the Defensive Ring, "ranged middle"), direction TOP
-- (army initialisation, FUN_00519ae0).
-- The formation type and direction live on every army (a unit: bytes at +0x104 / +0x105 of the army record), not on the
-- selection: u.formationType (index into KINDS) and u.formationDir, nil meaning the defaults. A group move reads them
-- from the group leader only (the leader pick FUN_00531400: the selected army with the highest base damage, the first
-- of equal ones) and, when the direction change FUN_0040c770 turns the formation, writes the leader's type and the new
-- direction to every selected army (FUN_00532900). The formation buttons and the rotate keys change the leader alone and
-- then send the group to the leader's own cell. This is UI state of the issuing player (the commands carry the slot cells), so it is not
-- part of the world hash; savegame.lua keeps it with the unit.
-- A group marches at the pace of its slowest member (battle.lua).
--
-- openwbc3's own choice: the original selects at most 32 armies; a larger group (select all) fills the table for 32 and
-- puts each further batch of 32 behind the previous one, two cells clear of it.
local data = require("src.game.formationdata")

local M = {}

M.KINDS = { "block", "circle", "wedge", "skirmish", "line", "column", "wideline", "doublefile" }
M.NAMES = { block = "Block", circle = "Defensive Ring", wedge = "Wedge", skirmish = "Skirmish", line = "Double Line",
            column = "Single Column", wideline = "Wide Line", doublefile = "Double Column" }
M.DIRECTIONS = 8
M.TOP, M.TOPLEFT, M.LEFT, M.BOTTOMLEFT, M.BOTTOM, M.BOTTOMRIGHT, M.RIGHT, M.TOPRIGHT = 0, 1, 2, 3, 4, 5, 6, 7

-- Index into KINDS of a new army's formation and its direction.
M.DEFAULT_KIND = 2
M.DEFAULT_DIR = M.TOP

-- The formation type (index into KINDS) and direction an army has.
---@param u Unit
---@return integer kind index into KINDS
---@return integer dir
function M.state(u)
    return u.formationType or M.DEFAULT_KIND, u.formationDir or M.DEFAULT_DIR
end

-- The group leader (FUN_00531400): the unit of `units` with the highest damage (the +0x9e field of the army record next
-- to range and combat), the first one of equal damage.
---@param units Unit[]
---@return Unit?
function M.leader(units)
    local best, top = nil, -1
    for _, u in ipairs(units) do
        local d = u:stats(true).damage or 0
        if d > top then best, top = u, d end
    end
    return best
end

-- Sets the formation type and direction of every one of `units` (FUN_00532900 for the selection).
---@param units Unit[]
---@param kind integer index into KINDS
---@param dir integer
function M.apply(units, kind, dir)
    for _, u in ipairs(units) do u.formationType, u.formationDir = kind, dir end
end

-- The table's slots for a group of n (1..32) as a flat list { x1, y1, x2, y2 ... }.
---@param kind string a name of KINDS
---@param n integer
---@return integer[]
function M.table(kind, n)
    return data.slots[kind][n]
end

-- Offset in cells of table slot (sx, sy) when the formation faces `dir`.
---@param dir integer
---@param sx integer
---@param sy integer
---@return integer dx
---@return integer dy
function M.offset(dir, sx, sy)
    local hx, hy = math.floor(sx / 2), math.floor(sy / 2)
    if dir == 4 then return sx, sy
    elseif dir == 6 then return sy, -sx
    elseif dir == 0 then return -sx, -sy
    elseif dir == 2 then return -sy, sx
    elseif dir == 5 then return hy - hx, hy + hx
    elseif dir == 3 then return -hy - hx, hy - hx
    elseif dir == 1 then return hx - hy, -hy - hx
    else return hy + hx, hx - hy end            -- 7
end

-- The direction change (FUN_0040c770): the direction the formation faces when the group at distance (dx, dy) cells from the
-- target is sent there. Nearer than 5 cells keeps `old`; otherwise the quadrant of the target decides, with a
-- 2 : 1 ratio between the straight and the diagonal directions.
---@param dx integer
---@param dy integer
---@param old integer
---@return integer
function M.directionFor(dx, dy, old)
    local ax, ay = math.abs(dx), math.abs(dy)
    if math.max(ax, ay) < 5 then return old end
    local half = math.floor(ay / 2)
    if dx <= 0 then
        if dy <= 0 then
            if ax < half then return 0 end
            return ay * 2 < ax and 2 or 1
        end
        if ax < half then return 4 end
        return ax <= ay * 2 and 3 or 2
    end
    if dy <= 0 then
        if ax < half then return 0 end
        return ax <= ay * 2 and 7 or 6
    end
    if ax < half then return 4 end
    return ay * 2 < ax and 6 or 5
end

-- The slots (cell offsets, table frame) for n units: { {x, y}, ... } in the order they are handed out.
---@param kind string
---@param n integer
---@return {[1]: integer, [2]: integer}[]
local function slotsFor(kind, n)
    local out = {}
    local shift = 0
    local left = n
    while left > 0 do
        local m = math.min(32, left)
        local list = data.slots[kind][m]
        local lo, hi = math.huge, -math.huge
        for i = 1, #list, 2 do
            out[#out + 1] = { list[i], list[i + 1] + shift }
            lo, hi = math.min(lo, list[i + 1]), math.max(hi, list[i + 1])
        end
        left = left - m
        shift = shift - (hi - lo) - 2           -- the next batch goes behind (-y is the rear)
    end
    return out
end

-- Returns { {unit = u, gx = cell, gy = cell}, ... } for `units` ordered to (gx, gy) in formation `kind` facing `dir`
-- (0..7). The units are ranked by range (longest first) and combat (lowest first), the first of equal ones first.
---@param kind string a name of KINDS
---@param units Unit[]
---@param gx integer
---@param gy integer
---@param dir integer
---@return {unit: Unit, gx: integer, gy: integer}[]
function M.assign(kind, units, gx, gy, dir)
    local n = #units
    local ranked = {}
    for i, u in ipairs(units) do
        local st = u:stats(true)
        ranked[i] = { unit = u, range = st.range or 0, combat = st.combat or 0, i = i }
    end
    table.sort(ranked, function(a, b)
        if a.range ~= b.range then return a.range > b.range end
        if a.combat ~= b.combat then return a.combat < b.combat end
        return a.i < b.i
    end)
    local slots = slotsFor(kind, n)
    local out = {}
    for k, r in ipairs(ranked) do
        local s = slots[k]
        local ox, oy = M.offset(dir, s[1], s[2])
        out[#out + 1] = { unit = r.unit, gx = gx + ox, gy = gy + oy }
    end
    return out
end

return M
