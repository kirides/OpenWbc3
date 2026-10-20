-- The original's scroll bars drawn from their strips (own reading of the bitmaps, not documented by the XCI):
--   vertical (VSBAR156.bmp 32x380, SBAR_V156B): rows 0..155 the track with a grey arrow at each end, then 32 px frames:
--   156 skull thumb, 188 up arrow, 220 up arrow (hover), 284 down arrow, 316 down arrow (hover);
--   horizontal (HSBar170.bmp 394x32, SBAR_H170): x 0..169 the track, 171 skull, 202 left arrow, 297 right arrow.
-- Both are stateless: give the rectangle, the position (0..1), whether the bar takes input and the mouse position.
local UI = require("src.ui.interface")

local M = {}

local V_ARROW, V_THUMB = 31, 32
local H_ARROW, H_THUMB = 31, 30

---@type table<string, love.Quad>
local quads = {}

---@param img love.Image
---@param key string
---@return love.Quad
local function quad(img, key, x, y, w, h)
    local q = quads[key]
    if not q then
        q = love.graphics.newQuad(x, y, w, h, img:getDimensions())
        quads[key] = q
    end
    return q
end

-- Vertical ----------------------------------------------------------------------------------------------------

---@return number
function M.vThumbY(y, h, pos)
    local lo, hi = y + V_ARROW, y + h - V_ARROW - V_THUMB
    return lo + (hi - lo) * math.max(0, math.min(1, pos))
end

-- Which part of the bar (x, y, 32, h) is at (vx, vy): "up", "down", "track" or nil.
---@return "up"|"down"|"track"|nil
function M.vHit(x, y, h, vx, vy)
    if vx < x or vx >= x + 32 or vy < y or vy >= y + h then return nil end
    if vy < y + V_ARROW then return "up" end
    if vy >= y + h - V_ARROW then return "down" end
    return "track"
end

-- The position 0..1 a click at vy on the track means (thumb centred on the pointer).
---@return number
function M.vPos(y, h, vy)
    local lo, hi = y + V_ARROW + V_THUMB / 2, y + h - V_ARROW - V_THUMB / 2
    return math.max(0, math.min(1, (vy - lo) / (hi - lo)))
end

---@param img love.Image?
---@param pos number     0..1
---@param active boolean
function M.vDraw(img, x, y, h, pos, active, mx, my)
    if not img then return end
    local g = love.graphics
    g.setColor(1, 1, 1)
    g.draw(img, quad(img, "vtrack", 0, 0, 32, h), x, y)
    if not active then return end
    local part = M.vHit(x, y, h, mx, my)
    g.draw(img, quad(img, part == "up" and "vuph" or "vup", 0, part == "up" and 220 or 188, 32, 32), x, y)
    g.draw(img, quad(img, part == "down" and "vdnh" or "vdn", 0, part == "down" and 316 or 284, 32, 32), x, y + h - 32)
    g.draw(img, quad(img, "vthumb", 0, 156, 32, 32), x, M.vThumbY(y, h, pos))
end

-- Horizontal ---------------------------------------------------------------------------------------------------

---@return "left"|"right"|"track"|nil
function M.hHit(x, y, w, h, vx, vy)
    if vx < x or vx >= x + w or vy < y or vy >= y + h then return nil end
    if vx < x + H_ARROW then return "left" end
    if vx >= x + w - H_ARROW then return "right" end
    return "track"
end

---@return number
function M.hPos(x, w, vx)
    local lo, hi = x + H_ARROW + H_THUMB / 2, x + w - H_ARROW - H_THUMB / 2
    return math.max(0, math.min(1, (vx - lo) / (hi - lo)))
end

-- `shown` = whether the skull is drawn at all (the points bar shows it from the first point on).
---@param img love.Image?
---@param pos number     0..1
---@param active boolean
---@param shown boolean?
function M.hDraw(img, x, y, w, pos, active, shown)
    if not img then return end
    local g = love.graphics
    g.setColor(1, 1, 1)
    g.draw(img, quad(img, "htrack", 0, 0, 170, 32), x, y)
    if active then
        g.draw(img, quad(img, "hleft", 202, 0, H_ARROW, 32), x, y)
        g.draw(img, quad(img, "hright", 297, 0, H_ARROW, 32), x + w - H_ARROW, y)
    end
    if shown ~= false then
        local lo, hi = x + H_ARROW, x + w - H_ARROW - H_THUMB
        if not active then g.setColor(1, 1, 1, 0.5) end
        g.draw(img, quad(img, "hskull", 171, 0, H_THUMB, 32), lo + (hi - lo) * math.max(0, math.min(1, pos)), y)
        g.setColor(1, 1, 1)
    end
end

return M
