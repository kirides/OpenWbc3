-- Fog of war for one viewing side: cells are unexplored (black), explored but
-- not currently seen (dimmed) or visible. Rendered as a 1-pixel-per-cell
-- texture stretched over the map with linear filtering for soft edges.
local ffi = require("ffi")

local M = {}

-- Vision radius in cells by the unit type's view index (the setting `fog.viewRadius`).
local VIEW_RADIUS
require("src.content").onReady(function()
    VIEW_RADIUS = require("src.content").setting:value("fog.viewRadius")
    M.VIEW_RADIUS = VIEW_RADIUS
end)

---@param view integer? the unit type's view index
---@return integer cells
function M.radius(view)
    return VIEW_RADIUS[math.max(0, math.min(29, view or 8))] or 10
end

-- The fog of one viewing side: the battle screen's (drawn) or the simulation's sight of a human side (`simOnly`).
---@class Fog
---@field world World
---@field side integer
---@field w integer
---@field h integer
---@field explored ffi.cdata*       uint8_t[w * h]: 1 = explored
---@field visible ffi.cdata*        uint8_t[w * h]: 1 = seen now
---@field nextUpdate number
---@field enabled boolean           false: everything counts as seen (F9)
---@field dim integer               darkness (0..255) of explored ground out of sight
---@field hiddenOnly boolean?       the hidden map alone (fog mode 4): explored counts as seen (battle screen)
---@field data love.ImageData?      the texture's pixels (not in a headless run / for the simulation's fog)
---@field image love.Image?
---@field dirty boolean?            the texture needs refreshing
---@field simMode integer?          the simulation's fog: the game's fog mode (M.mode)
---@field simSlice integer?         the attitude slice it was last recomputed in
local Fog = {}
Fog.__index = Fog

---@param world World
---@param side integer
---@param simOnly boolean? no texture (the simulation's own sight)
---@return Fog
function M.new(world, side, simOnly)
    local w, h = world.w, world.h

    ---@type Fog
    local self = setmetatable({
        world = world, side = side, w = w, h = h,
        explored = ffi.new("uint8_t[?]", w * h),
        visible = ffi.new("uint8_t[?]", w * h),
        nextUpdate = 0,
        enabled = true,
        dim = 110,                 -- darkness (0..255) of explored ground out of sight; 0 = stays lit
    }, Fog)
    if not simOnly then self.data = love.image and love.image.newImageData(w, h) or nil end
    return self
end

-- Marks the whole map as explored (the Farseeing power-up).
function Fog:revealAll()
    for i = 0, self.w * self.h - 1 do self.explored[i] = 1 end
    self.dirty = true
end

function Fog:allied(side)
    local world = self.world
    if side == self.side then return true end
    local a, b = world.sides[side], world.sides[self.side]
    return a and b and a.team ~= 0 and a.team == b.team
end

local function stamp(self, gx, gy, r)
    local w, h = self.w, self.h
    local vis, exp = self.visible, self.explored
    -- cells are 32x24 px, so a circle in pixels is an ellipse in cells
    local ry = math.floor(r * 32 / 24 + 0.5)
    for dy = -ry, ry do
        local y = gy + dy
        if y >= 0 and y < h then
            local fy = dy * 24 / 32
            local span = math.floor(math.sqrt(math.max(0, r * r - fy * fy)) + 0.5)
            local x0, x1 = math.max(0, gx - span), math.min(w - 1, gx + span)
            local row = y * w
            for x = x0, x1 do
                vis[row + x] = 1
                exp[row + x] = 1
            end
        end
    end
end

function Fog:recompute()
    local world = self.world
    ffi.fill(self.visible, self.w * self.h, 0)
    for _, u in ipairs(world.units) do
        if u:alive() and self:allied(u.side) then
            stamp(self, u.gx, u.gy, M.radius(u.type and u.type.view) + (world.sides[u.side].trueSight and 2 or 0) + (world.sides[u.side].visionBonus or 0))
        end
    end
    for _, b in ipairs(world.buildings) do
        if b.hp > 0 and self:allied(b.side) then
            stamp(self, b.gx, b.gy + 1, 8)
        end
    end
    self.dirty = true
end

function Fog:update(t)
    if t >= self.nextUpdate then
        self.nextUpdate = t + 200
        self:recompute()
    end
end

function Fog:isVisible(gx, gy)
    if not self.enabled then return true end
    if gx < 0 or gy < 0 or gx >= self.w or gy >= self.h then return false end
    return self.visible[gy * self.w + gx] ~= 0
end

function Fog:isExplored(gx, gy)
    if not self.enabled then return true end
    if gx < 0 or gy < 0 or gx >= self.w or gy >= self.h then return false end
    return self.explored[gy * self.w + gx] ~= 0
end

function Fog:refreshTexture()
    if not self.data then return end
    local p = ffi.cast("uint8_t*", self.data:getFFIPointer())
    local vis, exp = self.visible, self.explored
    for i = 0, self.w * self.h - 1 do
        local a = vis[i] ~= 0 and 0 or (exp[i] ~= 0 and self.dim or 255)
        local o = i * 4
        p[o], p[o + 1], p[o + 2], p[o + 3] = 0, 0, 0, a
    end
    if self.image then
        self.image:replacePixels(self.data)
    else
        self.image = love.graphics.newImage(self.data)
        self.image:setFilter("linear", "linear")
    end
    self.dirty = false
end

-- Draws the fog over the map (world coordinates).
function Fog:draw()
    if not self.enabled then return end
    if self.dirty or not self.image then self:refreshTexture() end
    -- texel centres line up with cell centres
    love.graphics.setColor(1, 1, 1)
    love.graphics.draw(self.image, 0, 0, 0, 32, 24)
end

-- The simulation's own sight (not drawn) ---------------------------------------------------------------------------
-- The original's threat search asks the local player's fog (the cell visibility test FUN_0047f560) for every side that is
-- no computer player: with fog of war (modes 1 and 2) the cell has to be seen now, with the hidden map alone (mode 4) it
-- has to be explored, without either (mode 3) everything counts; a building is only a target once it has been seen
-- (a has-been-seen test; not traced in the 1.04 binary yet). The original runs one process per human; openwbc3's
-- simulation runs every human side in every process, so the screen's fog (one viewer, updated at the frame rate, toggled
-- by F9) cannot answer. Each human side gets a fog of its own here (world.sight[side]), recomputed at the attitude slices
-- from the state of the world alone, so all peers agree, and saved with the game (savegame.lua).

-- The fog mode of the game (1 fog of war, 2 explored map, 3 no fog, 4 hidden map; nil = none, as in headless tests)
---@param world World
---@return integer?
function M.mode(world)
    local m = world.opts and world.opts.fogMode
    if m == 1 or m == 2 or m == 4 then return m end
    return nil
end

-- The simulation's fog of a side, or nil when the game has none.
---@param world World
---@param side integer
---@return Fog?
function M.sightOf(world, side)
    local mode = M.mode(world)
    if not mode then return nil end
    local set = world.sight
    if not set then set = {} world.sight = set end
    local f = set[side]
    if not f then
        f = M.new(world, side, true)
        f.simMode = mode
        set[side] = f
    end
    return f
end

-- The cell visibility test for the simulation: seen now (fog of war) or explored (hidden map alone)
function Fog:sees(gx, gy)
    if gx < 0 or gy < 0 or gx >= self.w or gy >= self.h then return false end
    local i = gy * self.w + gx
    if self.simMode == 4 then return self.explored[i] ~= 0 end
    return self.visible[i] ~= 0
end

-- The original's visibility of a building (not traced in the 1.04 binary yet): the cell it stands on, its bottom cell and
-- the two cells beside the middle
---@param b Building
function Fog:seesBuilding(b)
    local w, h = 1, 1
    if b.shape then w, h = math.max(1, b.shape.w), math.max(1, b.shape.h) end
    local gx, gy = b.gx, b.gy
    return self:sees(gx, gy) or self:sees(gx, gy + h - 1) or self:sees(gx + math.floor(w / 2), gy + math.floor(h / 2))
        or self:sees(gx - math.floor(w / 2), gy + math.floor(h / 2))
end

-- Brings the fog of a side up to the slice (a no-op within one slice) and notes the buildings it has seen; returns it.
---@param world World
---@param side integer
---@return Fog?
function M.refresh(world, side)
    local f = M.sightOf(world, side)
    if not f then return nil end
    local slice = world.attSlice or 0
    if f.simSlice ~= slice then
        f.simSlice = slice
        f:recompute()
        for _, b in ipairs(world.buildings) do
            if b.hp > 0 and not (b.seen and b.seen[side]) and f:seesBuilding(b) then
                b.seen = b.seen or {}
                b.seen[side] = true
            end
        end
    end
    return f
end

-- Marks the cells round (gx, gy) explored for the human sides `pick(side)` accepts (scenario events that uncover the map).
---@param world World
---@param gx integer
---@param gy integer
---@param radius integer
---@param pick fun(side: integer): boolean
function M.uncoverSim(world, gx, gy, radius, pick)
    local attitude = require("src.game.attitude")
    for side = 0, 5 do
        local sd = world.sides[side]
        if sd and sd.used and attitude.humanSide(world, side) and pick(side) then
            local f = M.sightOf(world, side)
            if f then
                for y = math.max(0, gy - radius), math.min(f.h - 1, gy + radius) do
                    for x = math.max(0, gx - radius), math.min(f.w - 1, gx + radius) do
                        f.explored[y * f.w + x] = 1
                    end
                end
            end
        end
    end
end

return M
