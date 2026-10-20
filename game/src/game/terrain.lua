-- Battle map terrain: tile pictures and per-cell data (height, terrain type,
-- move cost) taken from the tile type definitions (<id>.ter / <id>.bmp).
--
-- The map is a grid of 320x240 tile slots, 10x10 cells of 32x24 pixels each.
-- Big tiles (640x480 etc.) cover several slots; each slot says which quadrant
-- ("part") of the picture it shows. A .ter file holds 20x20 cells
-- (x-major) of {u8 height, u8 terrain, u8 moveCost, u8 flags} at offset 4,
-- then u8 loaded, animated, numFrames, size at 1604 and u32 frameTimes[8] at 1612.
local ffi = require("ffi")
local vfs = require("src.vfs.vfs")
local bmp = require("src.formats.bmp")
local bin = require("src.core.bin")
local log = require("src.core.log")

local M = {}
M.CELL_W, M.CELL_H = 32, 24
M.TILE_W, M.TILE_H = 320, 240

M.TYPE = { GRASS = 0, DIRT = 1, SAND = 2, WATER = 3, ROCK = 4, LAVA = 5, MARSH = 6, FORD = 7, SNOW = 8,
           VOID = 9, MOUNTAIN = 10 }

local SIZES = { [0] = { 320, 240 }, { 640, 480 }, { 640, 240 }, { 320, 480 } }

-- tile type cache (shared between maps)
local types = {}

local function loadType(id)
    local key = id:upper()
    local t = types[key]
    if t ~= nil then return t or nil end
    local ter = vfs.find(id .. ".ter")
    if not ter or #ter < 1652 then
        log.warn("terrain: missing %s.ter", id)
        types[key] = false
        return nil
    end
    t = { id = id, cells = ter:sub(5, 1604) }
    t.animated = ter:byte(1606) ~= 0
    t.frames = math.max(1, ter:byte(1607))
    t.size = ter:byte(1608)
    t.times = {}
    for i = 0, 7 do t.times[i] = bin.u32(ter, 1612 + i * 4) end
    types[key] = t
    return t
end

local function tileImage(t)
    if t.image == nil then
        local data = vfs.find(t.id .. ".bmp")
        if data then
            local ok, img = pcall(bmp.image, data)
            t.image = ok and img or false
            if ok and img then
                local sz = SIZES[t.size] or SIZES[0]
                t.frameH = sz[2]
                t.frames = math.max(1, math.min(t.frames, math.floor(img:getHeight() / sz[2])))
            end
        else
            t.image = false
        end
    end
    return t.image or nil
end

M.tileType = loadType
M.tileImage = tileImage

-- One 320x240 tile slot of the map: the tile type it shows, which quadrant and the animation frame.
---@class TerrainSlot
---@field type table?               the tile type (loadType), nil when the .ter is missing
---@field part integer              0..3: quadrant of a big tile
---@field frame integer
---@field nextTime number

-- The terrain of a battle map: per-cell height, terrain type and move cost, and the tile pictures.
---@class Terrain
---@field w integer                 size in cells
---@field h integer
---@field tw integer                size in tile slots
---@field th integer
---@field pixelW integer
---@field pixelH integer
---@field height ffi.cdata*         uint8_t[w * h]
---@field terrain ffi.cdata*        uint8_t[w * h]: M.TYPE
---@field moveCost ffi.cdata*       uint8_t[w * h]: 0 = only fliers
---@field slots table<integer, TerrainSlot> ty * tw + tx -> slot
---@field scn table                 the scenario (its `tiles` list)
---@field quads table?              draw cache: image -> quads
local Terrain = {}
Terrain.__index = Terrain

---@param scn table the scenario (width, height, tilesW, tilesH, tiles)
---@return Terrain
function M.new(scn)
    ---@type Terrain
    local self = setmetatable({}, Terrain)
    self.w, self.h = scn.width, scn.height
    self.tw, self.th = scn.tilesW, scn.tilesH
    self.pixelW, self.pixelH = self.w * M.CELL_W, self.h * M.CELL_H
    local n = self.w * self.h
    self.height = ffi.new("uint8_t[?]", n)
    self.terrain = ffi.new("uint8_t[?]", n)
    self.moveCost = ffi.new("uint8_t[?]", n)
    self.slots = {}
    self.scn = scn
    for ty = 0, self.th - 1 do
        for tx = 0, self.tw - 1 do self:setSlot(tx, ty) end
    end
    return self
end

-- (Re)reads map slot (tx, ty) from the scenario's tile list: picture and per-cell data.
-- The editor calls this after changing a tile record.
function Terrain:setSlot(tx, ty)
    local rec = self.scn.tiles[ty * self.tw + tx]
    local t = rec and loadType(rec.id)
    local slot = { type = t, part = rec and rec.part or 0, frame = 0, nextTime = 0 }
    self.slots[ty * self.tw + tx] = slot
    if not t then return end
    local ox = (slot.part == 1 or slot.part == 3) and 10 or 0
    local oy = (slot.part == 2 or slot.part == 3) and 10 or 0
    for cy = 0, 9 do
        for cx = 0, 9 do
            local gx, gy = tx * 10 + cx, ty * 10 + cy
            if gx < self.w and gy < self.h then
                local o = ((cx + ox) * 20 + (cy + oy)) * 4 + 1
                local hgt, ter, cost = t.cells:byte(o, o + 2)
                local i = gy * self.w + gx
                self.height[i], self.terrain[i], self.moveCost[i] = hgt, ter, cost
            end
        end
    end
end

function Terrain:inside(gx, gy)
    return gx >= 0 and gy >= 0 and gx < self.w and gy < self.h
end

-- Terrain type, height and move cost of a cell; nil outside the map.
---@return integer? terrain, integer? height, integer? moveCost
function Terrain:cell(gx, gy)
    if not self:inside(gx, gy) then return nil end
    local i = gy * self.w + gx
    return self.terrain[i], self.height[i], self.moveCost[i]
end

function Terrain:heightAt(gx, gy)
    if not self:inside(gx, gy) then return 0 end
    return self.height[gy * self.w + gx]
end

function Terrain:typeAt(gx, gy)
    if not self:inside(gx, gy) then return M.TYPE.VOID end
    return self.terrain[gy * self.w + gx]
end

-- Movement classes and which terrain types they may enter (index = terrain type).
M.MOVE = { LAND = 0, FLY = 1, SEA = 2, FLOAT = 3 }
local LEGAL = {
    [0] = { [0] = true, true, true, false, true, false, true, true, true, false, false },  -- land
    { [0] = true, true, true, true, true, true, true, true, true, false, true },           -- flier
    { [0] = false, false, false, true, false, false, false, false, false, false, false },  -- sea
    { [0] = true, true, true, true, true, false, true, true, true, false, false },         -- floater
}

-- Whether a unit of movement class `move` may stand on a cell. The outermost
-- ring of cells is never enterable; cells with move cost 0 (cliffs, walls in
-- the tile art) only stop non-fliers.
---@param gx integer
---@param gy integer
---@param move integer? movement class (M.MOVE), default land
---@return boolean
function Terrain:passable(gx, gy, move)
    if gx <= 0 or gy <= 0 or gx >= self.w - 1 or gy >= self.h - 1 then return false end
    move = move or 0
    local i = gy * self.w + gx
    if move ~= 1 and self.moveCost[i] == 0 then return false end
    local legal = LEGAL[move][self.terrain[i]]
    return legal == true
end

function Terrain:update(timeMs)
    for _, slot in pairs(self.slots) do
        local t = slot.type
        if t and t.animated and t.frames > 1 then
            if timeMs >= slot.nextTime then
                slot.frame = (slot.frame + 1) % t.frames
                local d = t.times[slot.frame]
                slot.nextTime = timeMs + ((d and d > 0) and d or 150)
            end
        end
    end
end

-- Draws the slots overlapping the world rectangle (vx, vy, vw, vh); the caller
-- has already translated the coordinate system so world (0,0) is the map origin.
function Terrain:draw(vx, vy, vw, vh)
    local tx0 = math.max(0, math.floor(vx / M.TILE_W))
    local ty0 = math.max(0, math.floor(vy / M.TILE_H))
    local tx1 = math.min(self.tw - 1, math.floor((vx + vw) / M.TILE_W))
    local ty1 = math.min(self.th - 1, math.floor((vy + vh) / M.TILE_H))
    self.quads = self.quads or {}
    for ty = ty0, ty1 do
        for tx = tx0, tx1 do
            local slot = self.slots[ty * self.tw + tx]
            local t = slot.type
            local img = t and tileImage(t)
            if img then
                ---@cast t -nil
                local sx = (slot.part == 1 or slot.part == 3) and M.TILE_W or 0
                local sy = ((slot.part == 2 or slot.part == 3) and M.TILE_H or 0) + slot.frame * (t.frameH or 240)
                local key = img
                local qs = self.quads[key]
                if not qs then qs = {} self.quads[key] = qs end
                local qk = sx * 100000 + sy
                local q = qs[qk]
                if not q then
                    q = love.graphics.newQuad(sx, sy, M.TILE_W, M.TILE_H, img:getDimensions())
                    qs[qk] = q
                end
                love.graphics.draw(img, q, tx * M.TILE_W, ty * M.TILE_H)
            else
                love.graphics.setColor(0.1, 0.1, 0.1)
                love.graphics.rectangle("fill", tx * M.TILE_W, ty * M.TILE_H, M.TILE_W, M.TILE_H)
                love.graphics.setColor(1, 1, 1)
            end
        end
    end
end

return M
