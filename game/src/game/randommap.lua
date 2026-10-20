-- Random map generator: the original's generator (entry FUN_00582180, the piece glueing FUN_00582310, the finishing pass
-- FUN_00583960) and the setup helpers it calls (start location FUN_00419440, towers FUN_004183b0, mines FUN_00418df0,
-- quest sites FUN_00418ce0, temples FUN_00418ae0). Points that name no binary check below are not traced in the 1.04
-- binary in detail yet. The result is a scenario
-- table in the shape formats/scn.lua produces, so world.lua loads it like any map and the editor could save it.
--
-- Everything is a function of the seed (headless, no clock, no math.random), so every peer of a network game that gets the
-- same settings, seed and sides builds the same map. The random numbers are the original's own generator
-- (its own dice: last = (25173 * last + 13849) mod 65536, a die is floor(rand * b / 65535) + 1; binary FUN_00582130 /
-- FUN_005820b0); only the low 16 bits of the seed matter, as in the original (it seeds from time(NULL)).
--
-- What follows the binary (verified):
--   * terrain sets and the number of pieces per set, the start piece (one of the first 5, one of 7..26 for lava, caverns
--     and wetlands, never piece 0 or the blocking pieces on the map's first row and column), the row by row glueing of
--     pieces whose edge types match (tried-piece list, restart when stuck), 30 cells per piece, pieces needed =
--     ceil(size / 30); all of this is checked in the binary's FUN_00582310
--   * tiles come from each piece's part-0 slots, features are the piece's features moved by the piece's position, with the
--     original's own test "x / 10 + piece offset < map width" (a pixel position divided by 10 is compared with cells: most
--     features of the right / bottom pieces are dropped on every map size; the binary does the same)
--   * connectivity: the four corner areas must be joined, else the map is built again
--   * start locations (FUN_00419440): 250 candidates per side, scored; 2x2 feature tiles and features within
--     the start's surroundings are removed; the events are the standard victory event only
--   * critters by level (4 / 9 / 16 / 24 plus 1d5-3, scaled 3/2, 2, 5/2 by the map size, the terrain's six-entry table), 20
--     tries each, a critter needs fewer than two water cells 8 cells away (the counts by level are set by FUN_00417280,
--     the rest is FUN_00583960); no chests and no keep are made (after the animals FUN_00583960 rolls a count by the map
--     size and places nothing with it); three starting towers per side (the race's own tower; they are marked
--     `starting`: the world scales them with the hero level as the building setup FUN_00418700 does, see
--     advanced.scaledTower), the mines (level-3 ones of all four kinds
--     around each start, the others in a shuffled grid of the map), shrines / mausoleums for quests, and
--     temples, lairs and shops for "utilities"
-- With `editor = true` (the editor's Ctrl+R, FUN_00582180 with its editor flag) generate stops after the connected piece map: only tiles and
-- features are made, the finishing steps above belong to the game's battle setup FUN_004179f0 (editorlib.randomScenario).
-- Building placement is the original's area placement search (see bestPlacement: read in the 1.04 binary,
-- FUN_00435320, called by the tower / resource / quest / temple setup FUN_004183b0 / 418df0 / 418ce0 / 418ae0).
-- Own choices (the original's numbers or algorithms could not be read): the same single random stream for the whole
-- generator (the original draws the finishing steps from its game dice FUN_00458e70, which the host synchronises by messages), the 6x6 cells
-- around a start are kept free of buildings (the original's "reserved for building" test, which nothing sets while a map is
-- made), the starts and critters must be reachable from the corners, flood fill with 8 directions instead of the original's
-- path search, and the loop guards that stop the original's endless loops.
local gom = require("src.formats.gom")
local evt = require("src.formats.evt")
local scnwrite = require("src.formats.scnwrite")
local terrainMod = require("src.game.terrain")
local gamedata = require("src.game.gamedata")
local fs = require("src.core.fs")
local xml = require("src.core.xml")
local config = require("src.core.config")
local vfs = require("src.vfs.vfs")
local log = require("src.core.log")

local M = {}

local CW, CH = terrainMod.CELL_W, terrainMod.CELL_H
local NEUTRAL = 6
local TYPE = terrainMod.TYPE

-- Settings of the PNL_SS_RANDOMMAP dropdowns (stored by FUN_00450760, read by FUN_00450970): every value is the index of its list, the last entry
-- of each list is "Random" (resolved when the game starts, in the order temples, terrain, size, critters, resources).
M.SIZES = { [0] = 64, 128, 192, 256 }
M.CRITTER_CELLS = { [0] = 0, 4, 9, 16, 24 }       -- none / few / some / many / galore: the counts FUN_00417280 passes on
M.RANDOM = { size = 4, terrain = 10, temples = 5, critters = 5, resources = 3 }
-- the values FUN_00450970 falls back to without a stored setting: large, plains, no utilities, a few animals, medium
M.DEFAULTS = { size = 2, terrain = 0, temples = 0, critters = 1, resources = 1 }
-- "I am the greatest" forces this (the preset FUN_004ea050 writes; how the option leads there is not traced in the 1.04
-- binary yet): a few animals, 3 utilities, X-large, medium, any terrain
M.GREATEST = { size = 3, terrain = 10, temples = 3, critters = 1, resources = 1 }

---@return {size: integer, terrain: integer, temples: integer, critters: integer, resources: integer}
function M.defaults()
    local d = {}
    for k, v in pairs(M.DEFAULTS) do d[k] = v end
    return d
end

-- Random numbers ------------------------------------------------------------------------------------------------------

-- The generator's own random numbers (a 16-bit linear congruential generator), so a seed gives the same map everywhere.
---@class RandomMapRng
---@field last integer           the last value (0 .. 65535)
local Rng = {}
Rng.__index = Rng

---@param seed any
---@return RandomMapRng
function M.rng(seed)
    return setmetatable({ last = math.floor(tonumber(seed) or 0) % 65536 }, Rng)
end

---@return integer
function Rng:next()
    self.last = (25173 * self.last + 13849) % 65536
    return self.last
end

-- The generator's dice (FUN_005820b0)(a, b, c): a dice of b sides, plus c.
---@param a integer dice
---@param b integer sides
---@param c integer? added
---@return integer
function Rng:dice(a, b, c)
    local total = 0
    for _ = 1, a do
        local r = math.floor(self:next() * b / 65535) + 1
        if r < 1 then r = 1 end
        if r > b then r = b end
        total = total + r
    end
    return total + (c or 0)
end

-- a dice (1, n, -1): 0..n-1
---@param n integer
---@return integer
function Rng:index(n) return self:dice(1, n, -1) end

-- Tile catalogue (Assets/Terrain/*.<language>): id -> { index, big, edge[] } ---------------------------------------------

local catalog

local function tileCatalog()
    if catalog then return catalog end
    catalog = {}
    local dir = config.gamedir .. "/Assets/Terrain"
    local ext = config.abbrev or "en"
    local files = fs.list(dir, "%." .. ext .. "$")
    if #files == 0 then files = fs.list(dir, "%.en$") end
    local index = 0
    for _, file in ipairs(files) do
        local data = fs.read(dir .. "/" .. file)
        local root = data and xml.parse(data)
        for _, el in ipairs(root and root.children or {}) do
            if el.tag:lower() == "tile" and el.attrs.id then
                index = index + 1
                local edge = {}
                for n in (el.attrs.edge or ""):gmatch("%-?%d+") do edge[#edge + 1] = tonumber(n) end
                catalog[el.attrs.id:upper()] = { id = el.attrs.id:upper(), index = index,
                                                 big = (el.attrs.big or ""):lower() == "yes", edge = edge }
            end
        end
    end
    return catalog
end
M.tileCatalog = tileCatalog

-- Map slots (tiles of 10x10 cells) --------------------------------------------------------------------------------------

local FOOT = { [0] = { 1, 1 }, { 2, 2 }, { 2, 1 }, { 1, 2 } }

-- Like the tile setter FUN_0048f8c0: puts tile `id` with its top-left slot at (tx, ty); a big tile fills its footprint with parts
-- 0..3 (slots outside the map are dropped). Returns false for a tile the catalogue does not know (FUN_00497c10 gives -1).
local function setTile(scn, id, tx, ty)
    local info = tileCatalog()[id]
    if not info then return false end
    local t = terrainMod.tileType(id)
    local size = t and t.size or 0
    local f = FOOT[size] or FOOT[0]
    for dy = 0, f[2] - 1 do
        for dx = 0, f[1] - 1 do
            local x, y = tx + dx, ty + dy
            if x < scn.tilesW and y < scn.tilesH then
                local part = dy * 2 + dx
                scn.tiles[y * scn.tilesW + x] = { id = id, part = part, size = size,
                    raw = scnwrite.tileRecord(id, info.index, part, t and t.animated, t and t.frames or 1, size) }
            end
        end
    end
    return true
end

-- Piece grid ------------------------------------------------------------------------------------------------------------

-- The row by row glueing of FUN_00582310. Returns grid[gy][gx] = piece number, or nil when it got stuck
-- (the caller starts again, like the original).
local function glue(rng, terrain, size)
    local set = gom.TERRAINS[terrain]
    local n = set.count
    local blocking = set.blocking
    local pieces = math.ceil(size / 30)
    local function piece(i) return gom.load(terrain, i) end
    -- the start piece
    local start
    local guard = 0
    while true do
        guard = guard + 1
        if guard > 1000 then return nil end
        local s
        if blocking then
            s = rng:dice(1, 25, 1)
            if s < 7 then s = nil end
        else
            s = rng:dice(1, 5, 1)             -- guaranteed to be an open area
        end
        if s and s > 1 and piece(s) then start = s break end
    end
    local grid = { [0] = { [0] = start } }
    local tried, attempts = {}, 0
    local cx, cy = 1, 0
    while cy < pieces do
        local found = false
        local spins = 0
        while not found do
            if attempts == n then return nil end
            spins = spins + 1
            if spins > 20000 then return nil end        -- the original would loop forever here
            -- draw a piece that was not tried at this spot yet; the first row and column avoid piece 0 (and, for the
            -- blocking sets, every piece below 7)
            local t
            repeat
                t = rng:index(n)
                local edge = cx == 0 or cy == 0
                if edge and ((blocking and t < 7) or (not blocking and t == 0)) then t = nil end
                if t then
                    for d = 1, attempts do if tried[d] == t then t = nil break end end
                end
                spins = spins + 1
                if spins > 20000 then return nil end
            until t
            if t > 0 then
                local g = piece(t)
                if g then
                    local ok = true
                    if cx > 0 and g.edges[4] ~= piece(grid[cy][cx - 1]).edges[2] then ok = false end
                    if ok and cy > 0 and g.edges[1] ~= piece(grid[cy - 1][cx]).edges[3] then ok = false end
                    if not ok then
                        attempts = attempts + 1
                        tried[attempts] = t
                        if attempts > 1000 then return nil end
                    else
                        attempts = 0
                        found = true
                        grid[cy] = grid[cy] or {}
                        grid[cy][cx] = t
                        cx = cx + 1
                        if cx * 30 >= size then cx, cy = 0, cy + 1 end
                    end
                end
            end
        end
    end
    return grid, pieces
end

-- Tiles and features of the pieces into a fresh scenario body.
local function paste(scn, terrain, grid, pieces, size)
    local tw = scn.tilesW
    scn.tiles, scn.features = {}, {}
    local known = {}
    for gy = 0, pieces - 1 do
        for gx = 0, pieces - 1 do
            local g = gom.load(terrain, grid[gy][gx])
            -- glue only puts pieces that load
            ---@cast g -nil
            local count = 1
            for k = 0, 2 do
                for l = 0, 2 do
                    local id = g.tiles[count]
                    if tileCatalog()[id] then
                        if g.parts[count] == 0 then setTile(scn, id, gx * 3 + l, gy * 3 + k) end
                        count = count + 1
                    end
                end
            end
            for _, f in ipairs(g.features) do
                local ok = known[f.code]
                if ok == nil then
                    ok = vfs.exists(f.code .. ".fea")
                    known[f.code] = ok
                end
                -- the original compares pixel / 10 with the map size in cells (see the header comment)
                if ok and math.floor(f.x / 10) + gx * 30 < size and math.floor(f.y / 10) + gy * 30 < size then
                    scn.features[#scn.features + 1] = { code = f.code, anim = f.anim, dir = f.dir, frame = f.frame,
                                                        x = f.x + gx * 30 * CW, y = f.y + gy * 30 * CH }
                end
            end
        end
    end
    -- slots no piece reached keep the first tile of the set (the original leaves them as they were)
    local base = tileCatalog()[gom.load(terrain, grid[0][0]).tiles[1]] and gom.load(terrain, grid[0][0]).tiles[1]
    for i = 0, tw * scn.tilesH - 1 do
        if not scn.tiles[i] then setTile(scn, base or "TGX0", i % tw, math.floor(i / tw)) end
    end
end

-- Connectivity ----------------------------------------------------------------------------------------------------------

-- Flood fill over the land cells the world lets a walker enter, 8 directions; returns the component of (sx, sy) as a
-- byte array and its size.
local ffi = require("ffi")
local function flood(w, sx, sy)
    local W, H = w.w, w.h
    local mark = ffi.new("uint8_t[?]", W * H)
    local stack, top = {}, 1
    stack[1] = sy * W + sx
    mark[sy * W + sx] = 1
    local n = 0
    while top > 0 do
        local i = stack[top]
        stack[top] = nil
        top = top - 1
        n = n + 1
        local x, y = i % W, math.floor(i / W)
        for dy = -1, 1 do
            for dx = -1, 1 do
                if dx ~= 0 or dy ~= 0 then
                    local nx, ny = x + dx, y + dy
                    if nx >= 0 and ny >= 0 and nx < W and ny < H then
                        local j = ny * W + nx
                        if mark[j] == 0 and w:free(nx, ny, 0) then
                            mark[j] = 1
                            top = top + 1
                            stack[top] = j
                        end
                    end
                end
            end
        end
    end
    return mark, n
end

-- The free cell nearest to (x, y), up to `maxR` away (FUN_0043b4c0).
local function nearestOpen(w, x, y, maxR)
    return w:nearestFree(x, y, 0, maxR or 20)
end

-- The four map corners (4 cells in) must be joined; returns the component of the first one, or nil.
local function connected(w)
    local W, H = w.w, w.h
    local corners = { { 4, 4 }, { W - 4, 4 }, { W - 4, H - 4 }, { 4, H - 4 } }
    local mark
    for i, c in ipairs(corners) do
        local x, y = nearestOpen(w, c[1], c[2])
        if not x then return nil end
        if i == 1 then
            mark = flood(w, x, y)
        elseif mark[y * W + x] == 0 then
            return nil
        end
    end
    return mark
end

-- Starting positions ----------------------------------------------------------------------------------------------------

local BAD_TERRAIN = { [TYPE.WATER] = true, [TYPE.MOUNTAIN] = true, [TYPE.MARSH] = true, [TYPE.VOID] = true,
                      [TYPE.LAVA] = true }

-- FUN_00419440(side, random map): 250 legal candidates, the best by priority (corners are favoured 4 times in 5,
-- the spots away from the sides placed before win). `comp` limits the candidates to the corner-connected area (own).
local function startLocation(w, rng, side, scn, comp)
    local W, H = w.w, w.h
    local halfW, halfH = math.floor(W / 2), math.floor(H / 2)
    local t = w.terrain
    local best, bestX, bestY = -30000, 0, 0
    for _ = 1, 250 do
        local x, y, tries = 0, 0, 0
        while true do
            tries = tries + 1
            x, y = rng:dice(1, W - 20, 10), rng:dice(1, H - 20, 10)
            local legal = w:free(x, y, 0) and w:free(x + 8, y, 0) and w:free(x - 8, y, 0) and w:free(x, y + 8, 0)
                and w:free(x, y - 8, 0)
            if legal and tries < 1000 then
                for _, d in ipairs({ { 0, 0 }, { 8, 0 }, { 0, 8 }, { -8, 0 }, { 0, -8 } }) do
                    if BAD_TERRAIN[t:typeAt(x + d[1], y + d[2])] then legal = false end
                end
                if legal and comp and comp[y * W + x] == 0 then legal = false end
                local h0 = t:heightAt(x, y)
                if legal and tries < 500 then
                    for _, d in ipairs({ { 7, 0 }, { 0, 7 }, { -7, 0 }, { 0, -7 } }) do
                        if t:heightAt(x + d[1], y + d[2]) ~= h0 then legal = false end
                    end
                end
                if legal and tries < 250 then
                    for _, d in ipairs({ { 7, 7 }, { -7, 7 }, { -7, -7 }, { 7, -7 } }) do
                        if t:heightAt(x + d[1], y + d[2]) ~= h0 then legal = false end
                    end
                end
            elseif tries >= 1000 then
                legal = w:free(x, y, 0)          -- the original would spin on; take any free cell
                if not legal and tries > 20000 then return nil end
            end
            if legal then break end
        end
        local priority = 0
        local edge = true
        if rng:dice(1, 100, 0) < 20 then edge = false end
        if edge then priority = priority + math.abs(halfH - y) + math.abs(halfW - x) else priority = priority + halfH end
        for other = 0, side - 1 do
            local sd = scn.sides[other]
            if sd and sd.used then
                local d = math.abs(x - sd.startX) + math.abs(y - sd.startY)
                if d < 25 then priority = priority - 10000
                elseif d < 50 then priority = priority - 1000
                elseif d < 64 then priority = priority - 500
                elseif d < 80 then priority = priority + d
                else priority = priority + d + math.floor(d / 2) end
            end
        end
        if priority > best then best, bestX, bestY = priority, x, y end
    end
    return bestX, bestY
end

-- The default tile that replaces a 2x2 feature tile: T<set>X0, caverns use the rock set and ruins the jungle set.
local function plainTile(id)
    local set = id:sub(2, 2)
    if set == "C" then set = "K" elseif set == "U" then set = "J" end
    return "T" .. set .. "X0"
end

-- What FUN_00583960 does around a start location: big tiles whose twelve edge types agree (a feature picture on
-- plain ground) in the 5x5 tiles from (start - 30) go back to plain ground, and the features within 20 cells go.
local function clearStart(w, scn, sx, sy)
    local cat = tileCatalog()
    local tx0, ty0 = math.floor(math.max(0, sx - 30) / 10), math.floor(math.max(0, sy - 30) / 10)
    for ty = ty0, ty0 + 4 do
        for tx = tx0, tx0 + 4 do
            local rec = tx < scn.tilesW and ty < scn.tilesH and scn.tiles[ty * scn.tilesW + tx]
            local info = rec and rec.part == 0 and cat[rec.id]
            if info and info.big then
                -- info is only set for a tile record
                ---@cast rec -false
                ---@cast rec -?
                local same = true
                for i = 1, 12 do if info.edge[i] ~= info.edge[1] then same = false end end
                local plain = plainTile(rec.id)
                if same and cat[plain] then
                    for _, d in ipairs({ { 0, 0 }, { 1, 0 }, { 1, 1 }, { 0, 1 } }) do
                        local x, y = tx + d[1], ty + d[2]
                        if x < scn.tilesW and y < scn.tilesH then
                            setTile(scn, plain, x, y)
                            w.terrain:setSlot(x, y)
                        end
                    end
                end
            end
        end
    end
    local x0, y0 = math.max(0, sx - 20), math.max(0, sy - 20)
    local keep = {}
    for _, f in ipairs(scn.features) do
        local gx, gy = math.floor(f.x / CW), math.floor(f.y / CH)
        if not (gx >= x0 and gx < x0 + 40 and gy >= y0 and gy < y0 + 40) then keep[#keep + 1] = f end
    end
    -- the world of the generator holds the features too: take the same ones out
    local inside = {}
    for _, f in ipairs(w.features) do
        if f.gx >= x0 and f.gx < x0 + 40 and f.gy >= y0 and f.gy < y0 + 40 then inside[#inside + 1] = f end
    end
    for _, f in ipairs(inside) do w:removeFeature(f) end
    scn.features = keep
end

-- Buildings -------------------------------------------------------------------------------------------------------------

-- The area placement search (the 1.04 binary's FUN_00435320, every test below checked there): scans the rectangle
-- (x0, y0, rw, rh) for runs of cells and picks the building's cell nearest to the target.
--   * a footprint of (shape width + 5) x (shape height + 5) cells is wanted, + 3 for the 18 tower / mortar types (their
--     codes are compared one by one): the building is not put where it just fits but with this much room around it
--   * three passes mark, per cell, "the run of that many cells ending here" (bits 1, 2, 4): all of the same terrain height,
--     none of water / lava / marsh / ford / void (terrain 3, 5, 6, 7, 9), none with move cost 0 or blocked for land units
--     (FUN_0042c8e0 for land) nor reserved for building (nothing is reserved while a map is made, but see `reserved`);
--     a run restarts at the map's edge and after a bad cell
--   * walking down each column, a cell with all three bits (7) whose run of rows of the same height is long enough is a
--     candidate: the centre of the (width x height) block, x = start + (w - 1) / 2 of the run, y likewise (the building's
--     cell is its top middle: tall buildings stand with their upper rows in the block, as in the original)
--   * cost = Chebyshev distance to the target + Chebyshev distance to the rectangle's centre (x0 + rw / 2, y0 + rh / 2); the
--     first candidate in column-then-row order wins a tie
-- Returns the cell, or nil when nothing fits. (Reachability from the corners is NOT asked for: the original does not, a
-- mine may end up on an island.)
-- The 18 codes the original compares one by one are the 16 race towers, the orc totem and the mortar: BWT<letter> and BWM<..>.
local function isTowerType(code)
    local kind = code:sub(1, 3)
    return kind == "BWT" or kind == "BWM"
end

local function bestPlacement(w, st, code, x0, y0, rw, rh, tx, ty)
    local bt = gamedata.building(code)
    if not bt then return nil end
    local W, H = w.w, w.h
    local terrain = w.terrain
    local iw, ih = bt.shape.w + 5, bt.shape.h + 5
    if isTowerType(code) then iw, ih = iw - 2, ih - 2 end
    local ok, hgt = {}, {}
    for k = 0, rw * rh - 1 do ok[k], hgt[k] = 0, 0 end
    local function at(j, i) return j * rh + i end
    -- the "reserved for building" test: openwbc3 reserves the 6x6 cells around each start (own choice, see the header), so the
    -- hero and the builders can be put down there
    local function reserved(gx, gy)
        for _, z in ipairs(st.zones or {}) do
            if gx >= z[1] and gx <= z[3] and gy >= z[2] and gy <= z[4] then return true end
        end
        return false
    end
    -- same terrain height
    for i = 0, rh - 1 do
        local gy = y0 + i
        if gy >= 0 and gy < H then
            local first, count, cur = true, 0, 0
            for j = 0, rw - 1 do
                local gx = x0 + j
                if gx < 0 or gx >= W then
                    count = 0
                else
                    local h = terrain:heightAt(gx, gy)
                    if first then
                        first, count, cur = false, count + 1, h
                    elseif h == cur then
                        count = count + 1
                        if count >= iw then hgt[at(j, i)] = h ok[at(j, i)] = ok[at(j, i)] + 1 end
                    else
                        count, cur = 1, h
                    end
                end
            end
        end
    end
    -- no water, lava, marsh, ford or void
    for i = 0, rh - 1 do
        local gy = y0 + i
        if gy >= 0 and gy < H then
            local count = 0
            for j = 0, rw - 1 do
                local gx = x0 + j
                local t = (gx >= 0 and gx < W) and terrain:typeAt(gx, gy)
                if not t or t == TYPE.WATER or t == TYPE.LAVA or t == TYPE.MARSH or t == TYPE.FORD or t == TYPE.VOID then
                    count = 0
                else
                    count = count + 1
                    if count >= iw then ok[at(j, i)] = ok[at(j, i)] + 2 end
                end
            end
        end
    end
    -- not blocked (move cost 0, features, buildings) and not reserved
    for i = 0, rh - 1 do
        local gy = y0 + i
        if gy >= 0 and gy < W then
            local count = 0
            for j = 0, rw - 1 do
                local gx = x0 + j
                if gx < 0 or gx >= W or gy >= H or not w:free(gx, gy, 0) or reserved(gx, gy) then
                    count = 0
                else
                    count = count + 1
                    if count >= iw then ok[at(j, i)] = ok[at(j, i)] + 4 end
                end
            end
        end
    end
    local cx, cy = x0 + math.floor(rw / 2), y0 + math.floor(rh / 2)
    local bestCost, bx, by
    for j = 0, rw - 1 do
        local count, cur = 0, 0
        for i = 0, rh - 1 do
            local k = at(j, i)
            if ok[k] == 7 then
                if count == 0 then cur = hgt[k]
                elseif hgt[k] ~= cur then count, cur = 0, hgt[k] end
                count = count + 1
                if count >= ih then
                    ok[k] = 5
                    local px = x0 + j - (iw - 1) + math.floor((iw - 1) / 2)
                    local py = y0 + i - (ih - 1) + math.floor((ih - 1) / 2)
                    local cost = math.max(math.abs(px - tx), math.abs(py - ty)) + math.max(math.abs(px - cx), math.abs(py - cy))
                    if not bx or cost < bestCost then bestCost, bx, by = cost, px, py end
                end
            else
                count = 0
            end
        end
    end
    return bx, by
end

local function put(w, st, code, side, gx, gy, starting)
    local rec = { code = code, side = side, x = gx * CW + CW / 2, y = gy * CH + CH / 2, anim = 0, dir = 0, frame = 0,
                  starting = starting }
    st.scn.buildings[#st.scn.buildings + 1] = rec
    w:addBuilding(rec)
    return rec
end

-- FUN_004183b0: three towers of the side's race around each start, up to 6 failed tries per side.
local function randomTowers(w, rng, st)
    local scn = st.scn
    local mid = math.floor(w.w / 2)
    for side = 0, 5 do
        local sd = scn.sides[side]
        if sd and sd.used and sd.startX >= 0 then
            local code = gamedata.raceVariant("BWTC", sd.race or 0)
            local tries = 0
            for tower = 0, 2 do
                local placed = false
                while not placed do
                    tries = tries + 1
                    if tries > 7 then break end
                    local xm = sd.startX < mid and 1 or -1
                    local ym = sd.startY < mid and 1 or -1
                    local x = sd.startX + xm * (rng:dice(1, 8 + tries, 0) * (tower + 1) + rng:dice(1, 3, 1))
                    local y = sd.startY + ym * (rng:dice(1, 8 + tries, 0) * (tower + 1) + rng:dice(1, 3, 1))
                    x = math.max(6, math.min(w.w - 6, x))
                    y = math.max(6, math.min(w.h - 6, y))
                    local gx, gy = bestPlacement(w, st, code, x - 12, y - 12, 24, 24, x, y)
                    if gx then
                        put(w, st, code, side, gx, gy, true)
                        placed = true
                    end
                end
            end
        end
    end
end

-- FUN_00418df0: level-3 mines of all four kinds around every start, then a shuffled grid of mines of each kind.
local MINES = { "BRC", "BRG", "BRM", "BRS" }       -- crystal, gold, ore (metal), quarry (stone)
local MINE_LEVEL = { [0] = 2, 2, 1, 1, 0 }          -- table at 0x00608348 {0,0,1,1,2} counted from the best mine: BRx2 first

local function randomResources(w, rng, st, level, players)
    local scn = st.scn
    local W = w.w
    local count = math.min(players, 5) * (level + 1)
    if level == 0 then count = count + math.floor(count / 2) end
    local factor = ({ [1] = 0.5, [2] = 0.7, [3] = 1.0, [4] = 1.2 })[math.floor(W / 64)] or 1.0
    count = math.floor(count * factor)
    if count == 0 then return end
    for side = 0, 5 do
        local sd = scn.sides[side]
        if sd and sd.used and sd.startX >= 0 then
            local tries = 0
            local mine = rng:index(4)
            for kind = 0, 3 do
                local placed = false
                while not placed do
                    tries = tries + 1
                    if tries > 16 then break end
                    local xm = rng:dice(1, 2, 0) == 1 and 1 or -1
                    local ym = rng:dice(1, 2, 0) == 1 and 1 or -1
                    local x = sd.startX + xm * rng:dice(2, 6 + 2 * tries, 0)
                    local y = sd.startY + ym * rng:dice(2, 6 + 2 * tries, 0)
                    x = math.max(6, math.min(W - 6, x))
                    y = math.max(6, math.min(w.h - 6, y))
                    mine = (mine + 1) % 4
                    local code = MINES[kind + 1] .. "2"
                    local gx, gy = bestPlacement(w, st, code, x - 12, y - 12, 24, 24, x, y)
                    if gx then
                        put(w, st, code, NEUTRAL, gx, gy)
                        placed = true
                    end
                end
            end
        end
    end
    local variance = math.floor(count / 3)
    local amount = {}
    for k = 1, 4 do
        local r = 0
        if variance > 0 then r = rng:dice(1, variance * 2 + 1, -(variance + 1)) end
        amount[k] = count + r
    end
    for k = 1, 4 do
        local n = amount[k]
        if n > 0 then
            local interval = math.floor(W / n)
            local usedV, usedH = {}, {}
            local placed = 0
            while placed < n do
                local v, h
                for _ = 1, 1000 do
                    local r = rng:index(n)
                    if not usedV[r] then v = r break end
                end
                if not v then break end
                for _ = 1, 1000 do
                    local r = rng:index(n)
                    if not usedH[r] then h = r break end
                end
                if not h then break end
                local px = interval * h + math.floor(interval / 4)
                local py = interval * v + math.floor(interval / 4)
                local ox = rng:dice(1, math.floor(interval / 2), -1)
                local oy = rng:dice(1, math.floor(interval / 2), -1)
                local dx = math.min(W - 1, math.max(0, px + ox))
                local dy = math.min(w.h - 1, math.max(0, py + oy))
                local lvl = MINE_LEVEL[rng:index(5)]
                local code = MINES[k] .. lvl
                local gx, gy = bestPlacement(w, st, code, dx - 15, dy - 15, 30, 30, dx, dy)
                if gx then put(w, st, code, NEUTRAL, gx, gy) end
                usedH[h], usedV[v] = true, true
                placed = placed + 1
            end
        end
    end
end

-- FUN_00418ce0: shrines and mausoleums (players + 1d3-2 of them, at least one) when quests are on.
local function randomQuests(w, rng, st, players)
    local n = players + rng:dice(1, 3, -2)
    if n < 1 then n = 1 end
    for i = 0, n - 1 do
        local x, y = rng:dice(1, w.w - 12, 6), rng:dice(1, w.h - 12, 6)
        local code = i % 2 == 0 and "BMSH" or "BZMA"
        local gx, gy = bestPlacement(w, st, code, x - 20, y - 20, 40, 40, x, y)
        if gx then put(w, st, code, NEUTRAL, gx, gy) end
    end
end

-- The list of 17 of FUN_00418ae0 (the original drops its fourth entry, BTEL, so the elemental temple appears once).
local UTILITIES = { "BTCE", "BTIN", "BTDR", "BSFG", "BSFG", "BSFG", "BLHN", "BLGL", "BSBS", "BLBM", "BLGH", "BTCE", "BTIN",
                    "BTDR", "BTEL", "BSFG", "BSFG" }

local function randomTemples(w, rng, st, count)
    for _ = 1, count do
        local code = UTILITIES[rng:index(17) + 1]
        local safety = 0
        while true do
            local x, y = rng:dice(2, math.floor(w.w / 2), 0), rng:dice(2, math.floor(w.w / 2), 0)
            local gx, gy = bestPlacement(w, st, code, x - 20, y - 20, 40, 40, x, y)
            if gx and gx <= w.w and gy <= w.w then      -- FUN_00418ae0 also refuses a cell past the map size
                put(w, st, code, NEUTRAL, gx, gy)
                break
            end
            safety = safety + 1
            if safety > 256 then break end
        end
    end
end

-- The six critters of each terrain set (FUN_00584270).
local CRITTERS = {
    [0] = { "ACSH", "ACCO", "ACSH", "ACCO", "ACGO", "ACTU" },
    { "ACSH", "ACCO", "ACSH", "ACCO", "ACGO", "ACGO" },
    { "ACSH", "ACCO", "ACSH", "ACCO", "ACGO", "ACTU" },
    { "ACSH", "ACCO", "ACCA", "ACCA", "ACCA", "ACCA" },
    { "ACSH", "ACCO", "ACSH", "ACTU", "ACSH", "ACCO" },
    { "ACSH", "ACCO", "ACSH", "ACCA", "ACCA", "ACCA" },
    { "ACTU", "ACTU", "ACTU", "ACTU", "ACTU", "ACTU" },
    { "ACSH", "ACSE", "ACPE", "ACPE", "ACPE", "ACSE" },
    { "ACSH", "ACCO", "ACSH", "ACTU", "ACSE", "ACSE" },
    { "ACSH", "ACCO", "ACTU", "ACTU", "ACTU", "ACTU" },
}
M.CRITTERS = CRITTERS

local function randomCritters(w, rng, st, level, terrain, size)
    if level == 0 then return end
    level = level + rng:dice(1, 5, -3)
    if size == 128 then level = math.floor(level * 3 / 2)
    elseif size == 192 then level = level * 2
    elseif size == 256 then level = math.floor(level * 5 / 2) end
    if level < 0 then level = 0 end
    local taken = {}
    local W, H = w.w, w.h
    for _ = 1, level do
        local tries, gx, gy = 0, nil, nil
        repeat
            local x, y = rng:dice(1, W - 4, 2), rng:dice(1, H - 4, 2)
            local fx, fy = w:nearestFree(x, y, 0, 6)
            local zone = false
            for _, z in ipairs(fx and st.zones or {}) do
                if fx >= z[1] and fx <= z[3] and fy >= z[2] and fy <= z[4] then zone = true end
            end
            if fx and not zone and not taken[fy * W + fx] and (not st.comp or st.comp[fy * W + fx] ~= 0) then
                local water = 0
                for _, d in ipairs({ { 8, 0 }, { 0, 8 }, { -8, 0 }, { 0, -8 } }) do
                    if w.terrain:typeAt(fx + d[1], fy + d[2]) == TYPE.WATER then water = water + 1 end
                end
                if water < 2 then gx, gy = fx, fy break end
            end
            tries = tries + 1
        until tries >= 20
        if gx then
            local code = CRITTERS[terrain][rng:index(6) + 1]
            st.scn.armies[#st.scn.armies + 1] = { code = code, owner = NEUTRAL, side = NEUTRAL, level = 0,
                                                  x = gx * CW + CW / 2, y = gy * CH + CH / 2 }
            for dy = 0, 1 do for dx = 0, 1 do taken[(gy + dy) * W + gx + dx] = true end end   -- FUN_0042d700(gx, gy, 2, 2)
        end
    end
end

-- Scenario --------------------------------------------------------------------------------------------------------------

-- The scenario a random map game starts from before the map exists: six used sides (the setup screen sets 6
-- players for the random map; not traced in the 1.04 binary yet), the header the setup screen reads its options from. Race / resources / team / level are
-- what the setup screen then fills in.
---@return table scn
function M.stub()
    local scn = {
        width = 128, height = 128, tilesW = 13, tilesH = 13, tiles = {},
        armies = {}, buildings = {}, features = {}, items = {}, effects = {}, events = { evt.standardVictory() },
        header = {
            name = "Random Map", description = "", numPlayers = 6, width = 128, height = 128, type = 0,
            options = { fog = 1, hiddenMap = true, quests = true, victory = 0, techLevel = 5, armySetupPoints = 0,
                        handicapping = true, environment = 0, mods = {}, modLocks = {} },
            produceHeroes = true, standardVictory = true, firstSideOnly = false,
        },
        sides = {}, random = true,
    }
    for i = 0, 6 do
        scn.sides[i] = { used = i < 6, race = 0, color = i, team = 0, resources = 2, aiLevel = 2, startX = -1, startY = -1 }
    end
    scn.sides[6].color = 6
    return scn
end

-- The scenario of a game described by `d` = { seed, size, terrain, temples, critters, resources, quests, noStartingTowers,
-- victory, sides = { [i] = { used, race } } }: what every peer of a network game and a loaded save builds the same way.
---@param d table
---@return table scn
---@return table info
function M.build(d)
    local scn = M.stub()
    for i = 0, 5 do
        local s = d.sides and d.sides[i]
        if s then scn.sides[i].used, scn.sides[i].race = s.used, s.race end
    end
    return M.generate(scn, d)
end

-- Developer name "random:<seed>[:key=value,...]" (keys terrain, size, temples, critters, resources, sides): the scenario and
-- the description it was made from. All sides from the count (default 2) are used, side i plays race i.
---@param name string
---@return table scn
---@return table d
function M.fromName(name)
    local seed, rest = name:match("^random:(%-?%d+):?(.*)$")
    local d = { seed = tonumber(seed) or 0, sides = {}, quests = true }
    local count = 2
    for k, v in rest:gmatch("(%w+)=(%-?%d+)") do
        if k == "sides" then count = tonumber(v) --[[@as integer]] else d[k] = tonumber(v) end
    end
    for i = 0, 5 do d.sides[i] = { used = i < count, race = i } end
    local scn = M.build(d)
    return scn, d
end

-- Replaces the "Random" entries of the settings by dice (where the 1.04 binary rolls them is not traced yet; order: temples, terrain, size, critters,
-- resources); returns a table of concrete values.
---@param rng RandomMapRng
---@param s table
---@return {size: integer, terrain: integer, temples: integer, critters: integer, resources: integer}
function M.resolve(rng, s)
    local d = M.defaults()
    local r = {}
    for k in pairs(d) do r[k] = s[k] ~= nil and s[k] or d[k] end
    if r.temples == M.RANDOM.temples then r.temples = rng:dice(1, 5, -1) end
    if r.terrain == M.RANDOM.terrain then r.terrain = rng:dice(1, 10, -1) end
    if r.size == M.RANDOM.size then r.size = rng:dice(1, 4, -1) end
    if r.critters == M.RANDOM.critters then r.critters = rng:dice(1, 5, -1) end
    if r.resources == M.RANDOM.resources then r.resources = rng:dice(1, 3, -1) end
    return r
end

-- Fills `scn` (made by M.stub with the sides set up) with a map. `s` = { seed, size, terrain, temples, critters, resources
-- (dropdown values, "Random" allowed), quests, noStartingTowers, victory }. Returns the scenario and an info table
-- { settings = concrete values, attempts, seed }.
---@param scn table made by M.stub
---@param s table
---@return table scn
---@return table info
function M.generate(scn, s)
    local rng = M.rng(s.seed or 0)
    local r = M.resolve(rng, s)
    local size = s.cells or M.SIZES[r.size] or 128
    local terrain = r.terrain
    scn.width, scn.height = size, size
    scn.tilesW = math.floor((size - 1) / 10) + 1
    scn.tilesH = scn.tilesW
    scn.header.width, scn.header.height = size, size
    scn.events = { evt.standardVictory() }
    scn.armies, scn.buildings, scn.items, scn.effects = {}, {}, {}, {}
    for i = 0, 5 do
        local sd = scn.sides[i]
        sd.startX, sd.startY = -1, -1
    end
    local worldMod = require("src.game.world")
    local w, comp, attempts
    for attempt = 1, 60 do
        attempts = attempt
        local grid, pieces = glue(rng, terrain, size)
        if grid then
            paste(scn, terrain, grid, pieces, size)
            w = worldMod.new(scn, { player = 0, startForces = false, noAI = true })
            comp = connected(w)
            if comp then break end
        end
        w = nil
    end
    if not w then error("random map: no connected map after 60 attempts (seed " .. tostring(s.seed) .. ")") end
    if s.editor then
        -- FUN_00582180 with the editor flag: the editor takes the tiles and features of the piece map only; the start
        -- locations, towers, mines, quests, utilities and animals are made by FUN_00583960, which only the
        -- game's battle setup FUN_004179f0 calls, so none of them exist here
        scn.minimap = require("src.game.editorlib").minimap(scn, w.terrain)
        return scn, { settings = r, attempts = attempts, seed = s.seed, terrain = terrain, size = size }
    end
    local st = { scn = scn, comp = comp, zones = {} }
    -- start locations (random start for every used side, in order), then the clearing around them
    local players = 0
    for side = 0, 5 do
        local sd = scn.sides[side]
        if sd.used then
            players = players + 1
            local x, y = startLocation(w, rng, side, scn, comp)
            if not x then error("random map: no start location for side " .. side) end
            sd.startX, sd.startY = x, y
        end
    end
    for side = 0, 5 do
        local sd = scn.sides[side]
        if sd.used then clearStart(w, scn, sd.startX, sd.startY) end
    end
    -- the hero, the builders and the setup army stand near the start: no building goes on that spot (own choice)
    for side = 0, 5 do
        local sd = scn.sides[side]
        if sd.used then st.zones[#st.zones + 1] = { sd.startX - 2, sd.startY - 2, sd.startX + 3, sd.startY + 3 } end
    end
    -- the free area changed: the corner-connected component is still valid (only features were removed)
    comp = connected(w) or comp
    st.comp = comp
    if not s.noStartingTowers and not require("src.game.victory").get(s.victory, "pitched") then randomTowers(w, rng, st) end
    randomResources(w, rng, st, r.resources, players)
    if s.quests ~= false then randomQuests(w, rng, st, players) end
    if r.temples > 0 then randomTemples(w, rng, st, r.temples) end
    randomCritters(w, rng, st, M.CRITTER_CELLS[r.critters] or 0, terrain, size)
    scn.header.numPlayers = 6
    scn.minimap = require("src.game.editorlib").minimap(scn, w.terrain)
    return scn, { settings = r, attempts = attempts, seed = s.seed, terrain = terrain, size = size }
end

return M
