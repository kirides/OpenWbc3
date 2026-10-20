-- Computer player: the region system of the original (every routine below was decompiled from the 1.04 binary,
-- addresses in brackets).
--
-- Two things the computer's decisions read:
--
--  * The region map. The map is cut into squares of 8 x 8 cells; inside a square the cells a unit may stand on form
--    regions (connected, 8 neighbours, never across the square's edge), a building's cells form a region of their own
--    ("building region", terrain 255; renumbering FUN_00509f30, flood fill FUN_0050a370, adjacency FUN_0050a5c0).
--    Land regions only hold land cells, liquid regions water cells (the terrain broad types, table at
--    0x00603ed0 {0,0,0,1,0,1,0,0,0,3,2,0,2}; high / blank terrain has no region). Regions of different squares that
--    touch are adjacent. The expansion (FUN_00509320) is a breadth first search over the adjacency lists with a ring
--    of 4 (500 for the "safe" search) buckets: a step costs 2 (straight) or 3 (diagonal between the region centres), a
--    safe search also adds the modified danger of the arrival region's danger square (capped at 499 per step), the
--    first time a region is reached fixes its cost (not the cheapest one) and a building region is reached but never
--    left. Terrain legality per movement type is the table at 0x00603ee0. A building that stands in a reached
--    building region gets that cost as its "path danger" (the building's field +0x2c, a wait counter).
--  * The danger map (update FUN_005095a0, smoothing FUN_00509840, danger level
--    FUN_00509980): every 3 s each army and building adds a strength to the 16 x 16 cell square it stands in, for every
--    side that is not allied to its owner (neutral armies and buildings count for everybody): army (hits / 4 + combat +
--    speed + damage + range) / 4, an armed building hits / 2 + damage + range / 2; the modified danger of a square is
--    its own value plus half of each of the eight neighbours' (indices, not rows, so the left and right neighbours of a
--    square at the edge of a row are the squares of the next / previous row, as in the original).
--
-- Not original (openwbc3's own choices, where the original gives nothing to follow or cannot be reproduced):
--  * the squares are numbered row by row with the real width (the original uses the map height for the pitch, which
--    only matters for maps that are not square), the regions' adjacency lists are always in the order a full scan of
--    the map gives (the original's depend on which parts of the map were remapped last) and only the region sizes 1 and 2
--    exist (the original builds 1 and 2 as well; size 3 has no regions: a search from one finds none);
--  * the map is rebuilt lazily from the cells the buildings and features block (`world.blockRev` changes), where the
--    original remaps when a building or feature is added or removed;
--  * the waiting counter an army target shares with the path danger in the original is not modelled (always -1);
--  * the danger arrays are saved (AI:save) so a loaded game goes on with the same snapshot and the same update time.
local ffi = require("ffi")
local bit = require("bit")

local arshift = bit.arshift

local M = {}

M.DANGER_INTERVAL = 3000        -- next update = now + 3000 (FUN_005095a0)
local SLOTS = 1024              -- danger squares per side (the original keeps 1024 per array)
local SIDES = 7                 -- side slots

local BUILDING = 255
local VOID = 9
-- broad type (table at 0x00603ed0: 0 land, 1 liquid, 2 high, 3 blank) per movement index (the terrain, 12 = impassable))
local BROAD = { [0] = 0, 0, 0, 1, 0, 1, 0, 0, 0, 3, 2, 0, 2 }
-- legality [move][broad] (table at 0x00603ee0): land / flier / ship / floater against land, liquid, high, blank
local LEGAL = {
    [0] = { [0] = true, false, false, false },
    { [0] = true, true, true, false },
    { [0] = false, true, false, false },
    { [0] = true, true, false, false },
}
-- move cost over 100 in the land row (shorts at 0x00603e68, 13 per movement type): land cannot enter (water, lava,
-- void, mountain, impassable)
local LAND_BLOCKED = { [3] = true, [5] = true, [9] = true, [10] = true, [12] = true }
local WATER = 3                 -- the only index the ship row (0x00603e9c) enters

-- One region: cells of a square a unit may stand on (or one building's cells).
---@class AIRegionArea
---@field id integer
---@field sq integer                the square's index
---@field num integer               its number within the square
---@field terrain integer           the movement index of its first cell, 255 = a building region
---@field cx integer                the square's centre cell
---@field cy integer
---@field cells integer[]           cell indices
---@field adj AIRegionArea[]        the regions that touch it
---@field stamp integer             == the size's stamp: reached by the last search
---@field cost integer              the search's cost to it (-1 none)
---@field prev AIRegionArea?        where the search came from
---@field building Building?        the building of a building region

-- The regions of one unit size.
---@class AIRegionSize
---@field size integer
---@field cellRegion ffi.cdata*     int32_t[w * h]: cell -> region id (0 none)
---@field regions table<integer, AIRegionArea> id -> region
---@field nextId integer
---@field squares table<integer, AIRegionArea[]> square -> its regions in order
---@field dirty table<integer, boolean> squares to rebuild
---@field stamp integer             bumped by every search

-- The region map and the danger map of the computer players.
---@class AIRegion
---@field world World
---@field w integer                 map size in cells
---@field h integer
---@field sw integer                region squares (8 x 8 cells) per row / column
---@field sh integer
---@field sizes table<integer, AIRegionSize> unit size 1 / 2 -> its regions
---@field rev integer               the world.blockRev the blocking was taken from
---@field bld table<integer, Building> cell -> the building blocking it
---@field nextDanger number         next danger update (world time)
---@field stride integer            danger squares per row (the map height / 16, as the original)
---@field feat ffi.cdata*           uint8_t[w * h]: 1 = a feature blocks the cell
---@field srcLand ffi.cdata*        uint8_t[w * h]: 1 = land units cannot stand there
---@field srcSea ffi.cdata*         uint8_t[w * h]: 1 = ships cannot
---@field index ffi.cdata*          uint8_t[w * h]: the movement index of the cell
---@field void ffi.cdata*           uint8_t[w * h]: 1 = void terrain
---@field raw ffi.cdata*            int16_t[7 * 1024]: danger per side and square
---@field mod ffi.cdata*            int16_t[7 * 1024]: the smoothed ("modified") danger
---@field buckets table<integer, AIRegionArea[]> the search's ring of buckets
---@field counts table<integer, integer>
local R = {}
R.__index = R

---@param world World
---@return AIRegion
function M.new(world)
    local w, h = world.w, world.h
    local self = setmetatable({
        world = world, w = w, h = h, sw = arshift(w - 1, 3) + 1, sh = arshift(h - 1, 3) + 1,
        sizes = {}, rev = -1, bld = {}, nextDanger = 0, stride = arshift(h, 4),
        feat = ffi.new("uint8_t[?]", w * h), srcLand = ffi.new("uint8_t[?]", w * h), srcSea = ffi.new("uint8_t[?]", w * h),
        index = ffi.new("uint8_t[?]", w * h), void = ffi.new("uint8_t[?]", w * h),
        raw = ffi.new("int16_t[?]", SIDES * SLOTS), mod = ffi.new("int16_t[?]", SIDES * SLOTS),
        buckets = {}, counts = {},
    }, R)
    -- the movement index of each cell (the original's per-cell move table: the terrain, or 12 where the move cost is 0; the
    -- outermost ring was never filled in, so it counts as terrain 0)
    local terrain = world.terrain
    for y = 1, h - 2 do
        for x = 1, w - 2 do
            local i = y * w + x
            local t = terrain.moveCost[i] == 0 and 12 or math.min(12, terrain.terrain[i])
            self.index[i] = t
        end
    end
    for i = 0, w * h - 1 do
        local t = self.index[i]
        self.srcLand[i] = LAND_BLOCKED[t] and 1 or 0
        self.srcSea[i] = t ~= WATER and 1 or 0
        self.void[i] = terrain.terrain[i] == VOID and 1 or 0
    end
    return self
end

-- Blocking ---------------------------------------------------------------------------------------------------------

-- The cells a unit of `size` standing on (x, y) takes up, as the original's map blocking data spreads them: a source cell
-- (cx, cy) blocks the 2 x 2 units standing on x in cx-1 .. cx, y in cy .. cy+1.
local function footprint(size, x, y)
    if size == 1 then return x, y, x, y end
    return x, y - 1, x + 1, y
end

-- FUN_0042cda0: terrain and features. kind 0 = land, 2 = water.
local function freeTerrain(self, x, y, size, kind)
    local w = self.w
    if self.void[y * w + x] ~= 0 then return false end
    local src = kind == 0 and self.srcLand or self.srcSea
    local x0, y0, x1, y1 = footprint(size, x, y)
    for cy = y0, y1 do
        for cx = x0, x1 do
            local i = cy * w + cx
            if src[i] ~= 0 or self.feat[i] ~= 0 then return false end
        end
    end
    return true
end

-- FUN_0042cc10: and no building in the way.
local function freeCell(self, x, y, size, kind)
    if not freeTerrain(self, x, y, size, kind) then return false end
    local w = self.w
    local x0, y0, x1, y1 = footprint(size, x, y)
    for cy = y0, y1 do
        for cx = x0, x1 do
            if self.bld[cy * w + cx] then return false end
        end
    end
    return true
end

-- Region squares ---------------------------------------------------------------------------------------------------

local function newSize(self, size)
    local S = { size = size, cellRegion = ffi.new("int32_t[?]", self.w * self.h), regions = {}, nextId = 1, squares = {},
                dirty = {}, stamp = 0 }
    for sq = 0, self.sw * self.sh - 1 do S.dirty[sq] = true end
    self.sizes[size] = S
    return S
end

local function sortedKeys(set)
    local keys = {}
    for k in pairs(set) do keys[#keys + 1] = k end
    table.sort(keys)
    return keys
end

-- Fills the region starting at (x, y) of square (sx, sy) (FUN_0050a370): a land / water region takes the cells
-- around it that a unit may stand on, a building region the cells of the same building that terrain alone would allow.
local function flood(self, S, region, sx, sy, x, y, kind)
    local w, h, size, cr = self.w, self.h, S.size, S.cellRegion
    local building = region.building
    local stack, n = { y * w + x }, 1
    cr[y * w + x] = region.id
    local cells = region.cells
    while n > 0 do
        local i = stack[n]
        stack[n] = nil
        n = n - 1
        cells[#cells + 1] = i
        local cx = i % w
        local cy = (i - cx) / w
        for dx = -1, 1 do
            local nx = cx + dx
            if arshift(nx, 3) == sx and nx > 0 and nx < w - 1 then
                for dy = -1, 1 do
                    local ny = cy + dy
                    if arshift(ny, 3) == sy and ny > 0 and ny < h - 1 then
                        local ni = ny * w + nx
                        if cr[ni] == 0 then
                            local take
                            if building then
                                take = not freeCell(self, nx, ny, size, kind) and freeTerrain(self, nx, ny, size, kind)
                                    and self.bld[ni] ~= nil and self.bld[ni] == building
                            else
                                take = freeCell(self, nx, ny, size, kind)
                            end
                            if take then
                                cr[ni] = region.id
                                n = n + 1
                                stack[n] = ni
                            end
                        end
                    end
                end
            end
        end
    end
end

-- FUN_00509f30: the regions of one square, numbered in the order their first cells are met (rows from the top, left to
-- right).
local function renumberSquare(self, S, sq)
    local w, h, size, cr = self.w, self.h, S.size, S.cellRegion
    local sx = sq % self.sw
    local sy = (sq - sx) / self.sw
    for _, old in ipairs(S.squares[sq] or {}) do
        S.regions[old.id] = nil
        for _, i in ipairs(old.cells) do cr[i] = 0 end
    end
    local list = {}
    S.squares[sq] = list
    local x0, y0 = sx * 8, sy * 8
    for y = math.max(1, y0), math.min(y0 + 7, h - 2) do
        for x = math.max(1, x0), math.min(x0 + 7, w - 2) do
            local i = y * w + x
            if cr[i] == 0 then
                local tid = self.index[i]
                local broad = BROAD[tid] or 3
                if broad == 2 then broad = 3 elseif broad == 1 then broad = 2 end
                if broad ~= 3 and freeTerrain(self, x, y, size, broad) then
                    local solid = not freeCell(self, x, y, size, broad)
                    local region = { id = S.nextId, sq = sq, num = #list, terrain = solid and BUILDING or tid,
                                     cx = x0 + 4, cy = y0 + 4, cells = {}, adj = {}, stamp = 0, cost = -1,
                                     building = solid and self.bld[i] or nil }
                    S.nextId = S.nextId + 1
                    S.regions[region.id] = region
                    list[#list + 1] = region
                    flood(self, S, region, sx, sy, x, y, broad)
                    table.sort(region.cells, function(a, b)
                        local ax, bx = a % w, b % w
                        if ax ~= bx then return ax < bx end
                        return a < b
                    end)
                end
            end
        end
    end
end

-- FUN_0050a5c0: the regions that touch a region's cells (8 neighbours), in the order a scan of the map meets
-- them (cells column by column, neighbours column by column).
local function computeAdjacency(self, S, region)
    local w, h, cr = self.w, self.h, S.cellRegion
    local adj, seen = {}, {}
    for _, i in ipairs(region.cells) do
        local x = i % w
        local y = (i - x) / w
        for dx = -1, 1 do
            local nx = x + dx
            if nx >= 0 and nx < w then
                for dy = -1, 1 do
                    local ny = y + dy
                    if ny >= 0 and ny < h then
                        local rid = cr[ny * w + nx]
                        if rid ~= 0 and rid ~= region.id and not seen[rid] then
                            seen[rid] = true
                            adj[#adj + 1] = S.regions[rid]
                        end
                    end
                end
            end
        end
    end
    region.adj = adj
end

-- Rebuilds the squares marked dirty and the adjacency of those and their neighbours.
local function rebuild(self, S)
    local dirty = sortedKeys(S.dirty)
    S.dirty = {}
    local touched = {}
    for _, sq in ipairs(dirty) do
        renumberSquare(self, S, sq)
        local sx = sq % self.sw
        local sy = (sq - sx) / self.sw
        for dy = -1, 1 do
            for dx = -1, 1 do
                local nx, ny = sx + dx, sy + dy
                if nx >= 0 and ny >= 0 and nx < self.sw and ny < self.sh then touched[ny * self.sw + nx] = true end
            end
        end
    end
    for _, sq in ipairs(sortedKeys(touched)) do
        for _, region in ipairs(S.squares[sq] or {}) do computeAdjacency(self, S, region) end
    end
end

-- The cells the buildings and features block, from the world; marks the squares around every change.
function R:refresh()
    local world = self.world
    local rev = world.blockRev or 0
    if rev == self.rev then return end
    self.rev = rev
    local w, h, static = self.w, self.h, world.static
    local new = {}
    for _, b in ipairs(world.buildings) do
        if b.shape and not b.rubbleSince and not b.destroyed then
            for _, c in ipairs(world:shapeCells(b.gx, b.gy, b.shape)) do
                local x, y = c[1], c[2]
                if x >= 0 and y >= 0 and x < w and y < h and static[y * w + x] ~= 0 then new[y * w + x] = b end
            end
        end
    end
    local old, feat = self.bld, self.feat
    local changed = {}
    for i = 0, w * h - 1 do
        local nf = (static[i] ~= 0 and not new[i]) and 1 or 0
        if nf ~= feat[i] or new[i] ~= old[i] then
            feat[i] = nf
            changed[#changed + 1] = i
        end
    end
    self.bld = new
    for _, S in pairs(self.sizes) do
        for _, i in ipairs(changed) do
            local x = i % w
            local y = (i - x) / w
            for dy = -1, 1 do
                for dx = -1, 1 do
                    local nx, ny = x + dx, y + dy
                    if nx >= 0 and ny >= 0 and nx < w and ny < h then S.dirty[arshift(ny, 3) * self.sw + arshift(nx, 3)] = true end
                end
            end
        end
    end
end

---@param size integer
---@return AIRegionSize?
function R:sizeData(size)
    if size ~= 1 and size ~= 2 then return nil end
    self:refresh()
    local S = self.sizes[size] or newSize(self, size)
    if next(S.dirty) then rebuild(self, S) end
    return S
end

-- The region a unit of `size` standing on the cell belongs to, nil when there is none.
---@param gx integer
---@param gy integer
---@param size integer
---@return AIRegionArea?
function R:regionAt(gx, gy, size)
    local S = self:sizeData(size)
    if not S or gx < 0 or gy < 0 or gx >= self.w or gy >= self.h then return nil end
    return S.regions[S.cellRegion[gy * self.w + gx]]
end

-- Searching ---------------------------------------------------------------------------------------------------------

-- Index of the danger square that holds the cell (x, y): the original's pitch is the map height / 8 and the squares
-- are 16 cells wide.
---@param x integer
---@param y integer
---@return integer
function R:dangerIndex(x, y)
    return arshift(y, 4) * self.stride + arshift(x, 4)
end

-- FUN_00509980: the modified danger of the square at (x, y) for `side`. The computer's target choice FUN_004fa990 hands
-- it the location already divided by 16, which the function divides once more (so every location there is the first
-- square).
---@param side integer
---@param x integer
---@param y integer
---@return integer
function R:dangerLevel(side, x, y)
    local idx = self:dangerIndex(x, y)
    if idx < 0 or idx >= SLOTS then return 0 end
    return self.mod[side * SLOTS + idx]
end

-- FUN_00509320: costs of the regions reachable from `start` for a unit of movement type `move`.
-- `limit` stops after that many levels, `cutoff` skips regions whose danger for `side` is higher and `safe` adds the
-- danger of the arrival squares and writes the path danger of the buildings reached (the safe search FUN_0050b0f0).
-- Afterwards `region.stamp == S.stamp` marks a region as reached and `region.cost` is its cost.
---@param start AIRegionArea
---@param move integer
---@param size integer
---@param limit integer?
---@param cutoff integer?
---@param side integer?             (needed with `cutoff` or `safe`)
---@param safe boolean
function R:search(start, move, size, limit, cutoff, side, safe)
    local S = self.sizes[size]
    S.stamp = S.stamp + 1
    local stamp = S.stamp
    local margin = safe and 500 or 4
    local buckets, counts = self.buckets, self.counts
    for i = 0, margin - 1 do
        counts[i] = 0
        buckets[i] = buckets[i] or {}
    end
    start.stamp, start.cost, start.prev = stamp, 1, nil
    buckets[0][1], counts[0] = start, 1
    local legal = LEGAL[move] or LEGAL[0]
    local level, finished = 0, 0
    while finished < margin do
        if limit and limit < level then return end
        local idx = level % margin
        local count = counts[idx]
        if count == 0 then
            finished = finished + 1
        else
            finished = 0
            counts[idx] = 0
            local list = buckets[idx]
            for k = 1, count do
                local this = list[k]
                for _, adj in ipairs(this.adj) do
                    if (not cutoff or self:dangerLevel(side --[[@as integer]], adj.cx, adj.cy) <= cutoff)
                        and adj.stamp ~= stamp
                        and (adj.terrain == BUILDING or legal[BROAD[adj.terrain] or 3]) then
                        local add = (adj.cx == this.cx or adj.cy == this.cy) and 2 or 3
                        if safe then
                            add = math.min(499, add + self:dangerLevel(side --[[@as integer]], adj.cx, adj.cy))
                            if adj.building then adj.building.pathDanger = add + level end
                        end
                        adj.stamp, adj.cost, adj.prev = stamp, add + level, this
                        if adj.terrain ~= BUILDING or move == 1 then
                            local bi = (add + level) % margin
                            local c = counts[bi] + 1
                            counts[bi] = c
                            buckets[bi][c] = adj
                        end
                    end
                end
            end
        end
        level = level + 1
    end
end

-- FUN_00509320 for a unit that walks / swims (no danger): the regions it can reach from `start`.
---@param start AIRegionArea
---@param move integer
---@param size integer
function R:expand(start, move, size)
    self:search(start, move, size, nil, nil, nil, false)
end

-- Safe search (FUN_0050b0f0): the path danger of the side's own buildings is reset (the original resets the list of
-- the side it is asked for, not the enemy's, so an enemy building keeps the value of the last search that reached it -
-- or 0 when none did), then a land search with danger runs from the leader's region.
---@param start AIRegionArea
---@param side integer
function R:safeSearch(start, side)
    for _, b in ipairs(self.world.buildings) do
        if b.side == side then b.pathDanger = -1 end
    end
    self:search(start, 0, 1, nil, nil, side, true)
end

-- Whether the search that ran last for `size` reached the region.
---@param region AIRegionArea
---@param size integer
---@return boolean
function R:reached(region, size)
    local S = self.sizes[size]
    return S ~= nil and region.stamp == S.stamp and region.cost ~= -1
end

-- Danger map -------------------------------------------------------------------------------------------------------

local function strength(world, e)
    if e.kind == "building" then
        local bt = e.type
        if not bt then return 0 end
        local gDmg, gRange = world.eco:garrisonBonus(e)
        local damage, range = (bt.damage or 0) + gDmg, (bt.range or 0) + gRange
        if damage <= 0 then return 0 end
        return math.floor(e.maxHp / 2) + damage + math.floor(range / 2)
    end
    local st = e:stats(true)
    return arshift(math.floor(e.maxHp / 4) + st.combat + st.speed + st.damage + st.range, 2)
end

-- The danger update (FUN_005095a0, every 3 s) with the smoothing (FUN_00509840).
---@param t number world time
function R:update(t)
    if t <= self.nextDanger then return end
    self.nextDanger = t + M.DANGER_INTERVAL
    local world = self.world
    local raw, mod = self.raw, self.mod
    ffi.fill(raw, ffi.sizeof(raw) --[[@as integer]], 0)
    ffi.fill(mod, ffi.sizeof(mod) --[[@as integer]], 0)
    local function add(e, owner)
        local idx = self:dangerIndex(e.gx, e.gy)
        if idx < 0 or idx >= SLOTS then return end
        local s = strength(world, e)
        for side = 0, SIDES - 1 do
            local sd = world.sides[side]
            if side == 6 or (sd and sd.used and (owner == 6 or world:enemies(side, owner))) then
                raw[side * SLOTS + idx] = raw[side * SLOTS + idx] + s
            end
        end
    end
    for _, u in ipairs(world.units) do
        if u:alive() then add(u, u.side) end
    end
    for _, b in ipairs(world.buildings) do
        if b.hp > 0 and not b.rubbleSince then add(b, b.side) end
    end
    local stride = self.stride
    local size = arshift(self.h, 4) * stride
    for side = 0, 5 do
        local sd = world.sides[side]
        if sd and sd.used then
            local base = side * SLOTS
            for i = 0, size - 1 do
                local v = raw[base + i]
                if i - stride >= 0 then v = v + arshift(raw[base + i - stride], 1) end
                if i + stride < size then v = v + arshift(raw[base + i + stride], 1) end
                if i - 1 >= 0 then v = v + arshift(raw[base + i - 1], 1) end
                if i + 1 < size then v = v + arshift(raw[base + i + 1], 1) end
                if i - stride - 1 >= 0 then v = v + arshift(raw[base + i - stride - 1], 1) end
                if i - stride + 1 >= 0 then v = v + arshift(raw[base + i - stride + 1], 1) end
                if i + stride - 1 < size then v = v + arshift(raw[base + i + stride - 1], 1) end
                if i + stride + 1 < size then v = v + arshift(raw[base + i + stride + 1], 1) end
                mod[base + i] = v
            end
        end
    end
end

-- Saved games -------------------------------------------------------------------------------------------------------

---@param t number
---@return {next: number, mod: integer[]}
function R:save(t)
    local list = {}
    for side = 0, SIDES - 1 do
        for i = 0, SLOTS - 1 do
            local v = self.mod[side * SLOTS + i]
            if v ~= 0 then list[#list + 1] = side * SLOTS + i list[#list + 1] = v end
        end
    end
    return { next = self.nextDanger - t, mod = list }
end

---@param data {next: number?, mod: integer[]?}?
---@param t number
function R:restore(data, t)
    ffi.fill(self.mod, ffi.sizeof(self.mod) --[[@as integer]], 0)
    if not data then return end
    self.nextDanger = t + (data.next or 0)
    local list = data.mod or {}
    for k = 1, #list - 1, 2 do self.mod[list[k]] = list[k + 1] end
end

return M
