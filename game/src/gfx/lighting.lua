-- Coloured light flashes of the battle view (the original's light display item, sprite ELIT): a 200x150 glow in
-- eight brightness steps, shown for 50 ms per step at the spot of a spell, a dragon's breath or a critical hit.
--
-- Verified in the 1.04 binary (the light item FUN_0053db40 / 0x0053dd70 / 0x0053def0, the light routine FUN_0044edb0, the
-- light pool FUN_0058c2e0): the sheet
-- ELIT with the colour given as the second palette effect (white, red, green, blue, purple, yellow light; black is the
-- shadow effect), 50 ms per step, 6 / 16 / 26 steps for a short / long / very long flash, three sizes, the
-- option levels (0 none; 1 one size and two duration classes smaller, nothing for the smallest; 2 one size and one
-- duration class smaller; 3 as asked), only within 4 cells of the view. The step tables of the original (which of the
-- eight pictures at which step, 0x00611ca4 .. 0x00611df4 by class and size) were not copied: openwbc3's own envelope below ramps up, holds and ramps down to
-- the same peak picture per size and class (small / medium / large), with the same length.
--
-- The frame-rate throttle of the original (frameload.lua) refuses new lights from a counter of 4 on (FUN_0058c2e0, 1.04).
--
-- Presentation only: no math.random, no simulation state; must not touch love.graphics at require time.
local frameload = require("src.gfx.frameload")
local M = {}

M.BLACK, M.WHITE, M.RED, M.GREEN, M.BLUE, M.PURPLE, M.YELLOW = 0, 1, 2, 3, 4, 5, 6
M.SMALL, M.MEDIUM, M.LARGE = 0, 1, 2
M.SHORT, M.LONG, M.VERYLONG = 0, 1, 2

-- the .ani effect number of a colour (the sprite's palette effects: 1 shadow, 2 light, 3 red, 4 green, 5 blue, 6 purple, 7 yellow)
local EFFECT = { [0] = 1, 2, 3, 4, 5, 6, 7 }
local STEPS = { [0] = 6, 16, 26 }
local FRAME_MS = 50
local MAX_LIGHTS = 100          -- the original's pool of light display items (FUN_0058c2e0: 100)
-- peak picture per [duration class][size]
local PEAK = { [0] = { [0] = 1, 3, 6 }, [1] = { [0] = 2, 4, 7 }, [2] = { [0] = 2, 4, 7 } }

---@param duration integer
---@param size integer
---@param step integer
---@return integer? picture 0..7, nil when the flash is over
local function envelope(duration, size, step)
    local n = STEPS[duration]
    local peak = PEAK[duration][size]
    local up = duration == 0 and 2 or 3
    local down = 2
    if step >= n then return nil end
    local f
    if step < up then f = peak * (step + 1) / (up + 1)
    elseif step >= n - down - 1 then f = peak * (n - step - 1) / (down + 1)
    else f = peak end
    return math.max(0, math.min(7, math.floor(f + 0.5)))
end

---@class LightImage
---@field image love.Image
---@field w integer
---@field h integer
---@field ox integer
---@field oy integer
---@field quads table<integer, love.Quad>

---@class Light
---@field x number      world pixels
---@field y number
---@field colour integer
---@field size integer
---@field duration integer
---@field t0 number     ms

---@class LightList
---@field items Light[]
---@field images table<integer, LightImage|false>   colour -> picture (false: none)
local List = {}
List.__index = List

---@return LightList
function M.new() return setmetatable({ items = {}, images = {} }, List) end

-- The picture of ELIT in one colour, rendered once (the colour is the sheet's second effect).
---@param anims AnimsModule
---@param colour integer
---@return LightImage?
function List:image(anims, colour)
    local rec = self.images[colour]
    if rec == nil then
        rec = false
        local set = anims.get("ELIT")
        local s = set and set:sheet(0)
        if s then
            ---@cast set -nil
            local sprite = require("src.formats.sprite")
            local img = sprite.render(s, nil, anims.paltype or 0, { 0, EFFECT[colour] or 2 })
            local image = love.graphics.newImage(img)
            image:setFilter("nearest", "nearest")
            local a = set.info[0]
            rec = { image = image, w = a.width, h = a.height, ox = a.originX, oy = a.originY, quads = {} }
        end
        self.images[colour] = rec
    end
    return rec or nil
end

-- Starts a flash at the centre of cell (gx, gy). `level` is the lighting option (0..3), `onScreen` tests the
-- 4-cell margin of the view.
---@param gx integer
---@param gy integer
---@param colour integer
---@param size integer
---@param duration integer
---@param now number
---@param level integer
function List:add(gx, gy, colour, size, duration, now, level)
    if level <= 0 or frameload.problems >= frameload.SOME then return end        -- FUN_0058c2e0: none from 4 on
    if level == 1 then
        if size == 0 and duration == 0 then return end
        size, duration = math.max(0, size - 1), math.max(0, duration - 2)
    elseif level == 2 then
        size, duration = math.max(0, size - 1), math.max(0, duration - 1)
    end
    if #self.items >= MAX_LIGHTS then return end
    self.items[#self.items + 1] = { x = gx * 32 + 16, y = gy * 24 + 12, colour = colour, size = size,
                                    duration = duration, t0 = now }
end

---@param now number
function List:update(now)
    for i = #self.items, 1, -1 do
        local l = self.items[i]
        if math.floor((now - l.t0) / FRAME_MS) >= STEPS[l.duration] then table.remove(self.items, i) end
    end
end

---@param anims AnimsModule
---@param now number
function List:draw(anims, now)
    local g = love.graphics
    for _, l in ipairs(self.items) do
        local frame = envelope(l.duration, l.size, math.floor((now - l.t0) / FRAME_MS))
        local rec = frame and self:image(anims, l.colour)
        if rec then
            ---@cast frame -nil
            local q = rec.quads[frame]
            if not q then
                q = g.newQuad(frame * rec.w, 0, rec.w, rec.h, rec.image:getDimensions())
                rec.quads[frame] = q
            end
            g.setColor(1, 1, 1)
            g.draw(rec.image, q, l.x - rec.ox, l.y - rec.oy)
        end
    end
end

return M
