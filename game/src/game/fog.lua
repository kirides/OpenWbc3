-- Fog of war for one viewing side: cells are unexplored (black), explored but
-- not currently seen (dimmed) or visible. The cells decide what is seen; the screen draws soft sight circles round
-- every viewer at its pixel position each frame and keeps what they have cleared as its explored ground (the explored
-- cells come in only when something else uncovers the map), so the fog moves with the armies and its edges are round.
-- That is the option "Fog of war mode: Modern" (smoothfog, on); "Classic" draws the cells alone, a 1-pixel-per-cell
-- texture with linear filtering. Both looks are openwbc3's own: the original draws the fog cell by cell with edge
-- pieces picked from the 8 neighbours of a smoothed cell grid (FUN_0047f110 smooths, FUN_0047d880 picks).
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
---@field expData love.ImageData?  the explored cells (r8), sampled by the screen's fog shader
---@field expImage love.Image?
---@field sight love.Canvas?        the sight circles of this frame (SIGHT_PX pixels a texel)
---@field seen love.Canvas?         the ground the sight circles have cleared so far, the explored cells merged in
---@field uncovered boolean?        explored cells were set by something else than sight: merge them into `seen`
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
    if not simOnly and love.image then
        self.data = love.image.newImageData(w, h)
        self.expData = love.image.newImageData(w, h, "r8")
    end
    return self
end

-- Marks the whole map as explored (the Farseeing power-up).
function Fog:revealAll()
    for i = 0, self.w * self.h - 1 do self.explored[i] = 1 end
    self.dirty = true
    self.uncovered = true
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

-- Calls fn(gx, gy, radius, x, y) for every army and building that gives this side sight (x, y: its pixel position).
---@param fn fun(gx: integer, gy: integer, r: integer, x: number, y: number)
function Fog:eachViewer(fn)
    local world = self.world
    for _, u in ipairs(world.units) do
        if u:alive() and self:allied(u.side) then
            local sd = world.sides[u.side]
            fn(u.gx, u.gy, M.radius(u.type and u.type.view) + (sd.trueSight and 2 or 0) + (sd.visionBonus or 0), u.x, u.y)
        end
    end
    for _, b in ipairs(world.buildings) do
        if b.hp > 0 and self:allied(b.side) then
            fn(b.gx, b.gy + 1, 8, b.gx * 32 + 16, (b.gy + 1) * 24 + 12)
        end
    end
end

function Fog:recompute()
    ffi.fill(self.visible, self.w * self.h, 0)
    self:eachViewer(function(gx, gy, r) stamp(self, gx, gy, r) end)
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
    local q = ffi.cast("uint8_t*", self.expData:getFFIPointer())
    for i = 0, self.w * self.h - 1 do q[i] = exp[i] ~= 0 and 255 or 0 end
    if self.image then
        self.image:replacePixels(self.data)
        self.expImage:replacePixels(self.expData)
    else
        self.image = love.graphics.newImage(self.data)
        self.image:setFilter("linear", "linear")
        self.expImage = love.graphics.newImage(self.expData)
        self.expImage:setFilter("linear", "linear")
    end
    self.dirty = false
end

-- The sight circles: SIGHT_PX map pixels a texel of the canvas; a circle is clear up to FADE_PX inside its edge and
-- fades out to SOFT_PX beyond it. Its edge is the last cell centre a stamp of that radius takes (r * 32 + 16 px: the
-- stamp's ellipse in cells is a circle in pixels), so an army in the last seen cell stands in the fading edge.
local SIGHT_PX, FADE_PX, SOFT_PX = 8, 40, 8
local discs = {}

---@param r integer the radius in cells
---@return love.Image
local function disc(r)
    local img = discs[r]
    if img then return img end
    local outer = (r * 32 + 16 + SOFT_PX) / SIGHT_PX         -- in texels
    local fade = FADE_PX / SIGHT_PX
    local n = math.ceil(outer) * 2 + 2
    local data = love.image.newImageData(n, n)
    local c = n / 2
    data:mapPixel(function(x, y)
        local d = math.sqrt((x + 0.5 - c) ^ 2 + (y + 0.5 - c) ^ 2)
        local v = math.max(0, math.min(1, (outer - d) / fade))
        v = v * v * (3 - 2 * v)
        return v, v, v, 1
    end)
    img = love.graphics.newImage(data)
    img:setFilter("linear", "linear")
    discs[r] = img
    return img
end

-- What the fog shader draws: the sight canvas clears, the explored ground dims (`dim`) instead of hiding.
local SHADER = [[
uniform Image seen;
uniform float dim;
vec4 effect(vec4 colour, Image sight, vec2 uv, vec2 sc) {
    float v = Texel(sight, uv).r;
    float e = Texel(seen, uv).r;
    return vec4(0.0, 0.0, 0.0, (1.0 - v) * mix(1.0, dim, e)) * colour;
}
]]
local shader

-- Draws the fog over the map (world coordinates).
function Fog:draw()
    if not self.enabled then return end
    if self.dirty or not self.image then self:refreshTexture() end
    local g = love.graphics
    if not require("src.core.gameopts").get("smoothfog") then
        -- by cells: the texture stretched over the map, texel centres on cell centres
        g.setColor(1, 1, 1)
        g.draw(self.image, 0, 0, 0, 32, 24)
        self.sight, self.seen = nil, nil                    -- Modern starts over from the cells when picked again
        self.uncovered = true
        return
    end
    local cw, ch = self.w * 32 / SIGHT_PX, self.h * 24 / SIGHT_PX
    if not self.sight then
        self.sight, self.seen = g.newCanvas(cw, ch), g.newCanvas(cw, ch)
        self.sight:setFilter("linear", "linear")
        self.seen:setFilter("linear", "linear")
        g.push("all")
        g.setCanvas(self.seen)
        g.clear(0, 0, 0, 1)
        g.pop()
    end
    shader = shader or g.newShader(SHADER)
    g.push("all")
    g.origin()
    g.setCanvas(self.sight)
    g.clear(0, 0, 0, 1)
    g.setBlendMode("lighten", "premultiplied")             -- overlapping circles: the clearer one wins
    g.setColor(1, 1, 1)
    self:eachViewer(function(_, _, r, x, y)
        local img = disc(r)
        local half = img:getWidth() / 2
        g.draw(img, x / SIGHT_PX - half, y / SIGHT_PX - half)
    end)
    g.setCanvas(self.seen)
    g.draw(self.sight)
    if self.uncovered then                                  -- an explored map, a saved game, Farseeing, an event
        self.uncovered = false
        g.draw(self.expImage, 0, 0, 0, 32 / SIGHT_PX, 24 / SIGHT_PX)
    end
    g.pop()
    shader:send("seen", self.seen)
    shader:send("dim", self.dim / 255)
    g.setShader(shader)
    g.setColor(1, 1, 1)
    g.draw(self.sight, 0, 0, 0, SIGHT_PX, SIGHT_PX)
    g.setShader()
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
