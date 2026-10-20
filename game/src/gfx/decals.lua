-- Ground decals of the battle view (the original's decal system, 1.04 FUN_004795f0..FUN_00479e80): footprints in sand and snow, gore where an army
-- died, scorch marks of dragon breath and the dirt under a building. One decal per cell; a new one replaces the old
-- one when its priority is at least as high. Lifetimes are in game time (world.time, ms); decals with no lifetime
-- stay until the building they are linked to is gone.
--
-- Verified in the 1.04 binary (type registration FUN_004795f0 / FUN_004797f0, creation FUN_00479a10, drawing FUN_00479e80): the sprite codes
-- (EDFS footsteps rows 0..7 and the scorch mark in row 8, EDBL gore rows 0 red / 1 green, EDBA / EDBD / EDBI base
-- standard / dirt / snow), the lifetimes (footsteps 30 s, gore 120 s - but 0.8 s on water, lava or marsh, scorch
-- 45 s, bases permanent), the priorities (20 / 50 / 60 / 100), the random frame, that gore is skipped on cells with
-- no move cost, that "decals" off creates and draws nothing and "blood" off creates no gore. The original registers a
-- "fade out" flag for gore (sixth argument of FUN_004797f0) but no routine reads it, so a decal simply disappears at the end
-- of its life, as here. Decals are only drawn on cells the player can see (the fog test FUN_0047f560). The frame-rate throttle of the original
-- (frameload.lua; verified in the 1.04 binary: FUN_00479a10 / FUN_00479e80) creates none from a counter of 8 and draws none from 12.
--
-- Presentation only: no math.random, no simulation state; must not touch love.graphics at require time.
local frameload = require("src.gfx.frameload")
local M = {}

---@class DecalType
---@field code string     sprite set
---@field row integer      direction row of the sheet
---@field life integer     ms, 0 = until the linked object is gone
---@field frames integer   random frame 0..frames-1
---@field prio integer
---@field gore boolean?

---@type table<string, DecalType>
local TYPES = {
    footSmallH = { code = "EDFS", row = 0, life = 30000, frames = 4, prio = 20 },
    footSmallV = { code = "EDFS", row = 1, life = 30000, frames = 4, prio = 20 },
    footSmallU = { code = "EDFS", row = 2, life = 30000, frames = 4, prio = 20 },
    footSmallD = { code = "EDFS", row = 3, life = 30000, frames = 4, prio = 20 },
    footLargeH = { code = "EDFS", row = 4, life = 30000, frames = 4, prio = 20 },
    footLargeV = { code = "EDFS", row = 5, life = 30000, frames = 4, prio = 20 },
    footLargeU = { code = "EDFS", row = 6, life = 30000, frames = 4, prio = 20 },
    footLargeD = { code = "EDFS", row = 7, life = 30000, frames = 4, prio = 20 },
    goreRed = { code = "EDBL", row = 0, life = 120000, frames = 8, prio = 50, gore = true },
    goreGreen = { code = "EDBL", row = 1, life = 120000, frames = 8, prio = 50, gore = true },
    scorch = { code = "EDFS", row = 8, life = 45000, frames = 4, prio = 60 },
    baseStandard = { code = "EDBA", row = 0, life = 0, frames = 10, prio = 100 },
    baseDirt = { code = "EDBD", row = 0, life = 0, frames = 10, prio = 100 },
    baseSnow = { code = "EDBI", row = 0, life = 0, frames = 10, prio = 100 },
}
M.TYPES = TYPES

local TERRAIN = { WATER = 3, LAVA = 5, MARSH = 6 }
local MAX_DECALS = 2048

---@class Decal
---@field gx integer
---@field gy integer
---@field ty DecalType
---@field prio integer
---@field link any          the object it is tied to (a building), or nil
---@field frame integer
---@field expires number?   world.time (ms) it disappears; nil = never

---@class DecalList
---@field terrain Terrain
---@field opts { decals: (fun(): boolean), blood: (fun(): boolean) }
---@field cells table<integer, Decal>   gy * terrain.w + gx -> decal
---@field count integer
---@field seq integer
local List = {}
List.__index = List

-- terrain: the battle terrain (cell data); opts: a table with `decals` / `blood` flags that are read on each use.
---@param terrain Terrain
---@param opts { decals: (fun(): boolean), blood: (fun(): boolean) }
---@return DecalList
function M.new(terrain, opts)
    return setmetatable({ terrain = terrain, opts = opts, cells = {}, count = 0, seq = 0 }, List)
end

local function hash(a, b, c)
    local h = (a * 73856093 + b * 19349663 + c * 83492791) % 2147483647
    return h
end

function List:clear() self.cells, self.count = {}, 0 end

-- Creates a decal of type `kind` (a key of TYPES) on cell (gx, gy). `link` ties it to an object (a building).
---@param kind string
---@param gx integer
---@param gy integer
---@param now number
---@param link any?
---@return boolean created
function List:create(kind, gx, gy, now, link)
    if not self.opts.decals() or frameload.problems >= frameload.MODERATE then return false end      -- FUN_00479a10
    local ty = TYPES[kind]
    if not ty then return false end
    if ty.gore and not self.opts.blood() then return false end
    local t = self.terrain
    if not t:inside(gx, gy) then return false end
    local life = ty.life
    if ty.gore then
        local terr, _, cost = t:cell(gx, gy)
        if (cost or 0) <= 0 then return false end
        if terr == TERRAIN.WATER or terr == TERRAIN.LAVA or terr == TERRAIN.MARSH then life = 800 end
    end
    local key = gy * t.w + gx
    local old = self.cells[key]
    if old then
        if ty.prio < old.prio then return false end
        self.count = self.count - 1
    elseif self.count >= MAX_DECALS then
        return false
    end
    self.seq = self.seq + 1
    self.cells[key] = { gx = gx, gy = gy, ty = ty, prio = ty.prio, link = link, frame = hash(gx, gy, self.seq) % ty.frames,
                        expires = life > 0 and now + life or nil }
    self.count = self.count + 1
    return true
end

---@param link any
function List:removeLinked(link)
    for key, d in pairs(self.cells) do
        if d.link == link then self.cells[key] = nil; self.count = self.count - 1 end
    end
end

---@param now number
function List:update(now)
    for key, d in pairs(self.cells) do
        if d.expires and d.expires <= now then self.cells[key] = nil; self.count = self.count - 1 end
    end
end

-- Draws the decals inside the cell box x0..x1, y0..y1 that `visible(gx, gy)` allows.
---@param anims AnimsModule
---@param x0 integer
---@param y0 integer
---@param x1 integer
---@param y1 integer
---@param visible fun(gx: integer, gy: integer): boolean
function List:draw(anims, x0, y0, x1, y1, visible)
    if not self.opts.decals() or frameload.problems >= frameload.BAD then return end                  -- FUN_00479e80
    local g = love.graphics
    g.setColor(1, 1, 1)
    for _, d in pairs(self.cells) do
        if d.gx >= x0 and d.gx <= x1 and d.gy >= y0 and d.gy <= y1 and visible(d.gx, d.gy) then
            local set = anims.get(d.ty.code)
            if set then set:draw(0, d.ty.row, d.frame, d.gx * 32, d.gy * 24) end
        end
    end
end

return M
