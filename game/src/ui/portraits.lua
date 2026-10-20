-- Hero portraits (Assets/Heroes/Portraits.xcr: Portrait00.bmp .. Portrait89.bmp).
local vfs = require("src.vfs.vfs")
local bmp = require("src.formats.bmp")
local log = require("src.core.log")

local M = { COUNT = 90 }

---@type table<integer, love.Image|false>
local cache = {}

-- Portrait n (modulo the 90 there are); nil when it cannot be loaded.
---@param n integer?
---@return love.Image?
function M.get(n)
    n = (n or 0) % M.COUNT
    local img = cache[n]
    if img == nil then
        img = false
        local data = vfs.read("Assets/Heroes/Portraits.xcr", ("Portrait%02d.bmp"):format(n))
        if data then
            local ok, res = pcall(bmp.image, data)
            if ok and res then
                img = res
                img:setFilter("linear", "linear")
            else
                log.warn("portrait %d: %s", n, tostring(res))
            end
        end
        cache[n] = img
    end
    return img or nil
end

-- Draws portrait n inside the box (x, y, w, h), keeping the aspect ratio.
---@param n integer?
function M.draw(n, x, y, w, h)
    local img = M.get(n)
    local g = love.graphics
    g.setColor(0, 0, 0, 0.9)
    g.rectangle("fill", x - 3, y - 3, w + 6, h + 6)
    g.setColor(0.86, 0.7, 0.47)
    g.rectangle("line", x - 3.5, y - 3.5, w + 7, h + 7)
    if not img then return end
    local iw, ih = img:getDimensions()
    local s = math.min(w / iw, h / ih)
    g.setColor(1, 1, 1)
    g.draw(img, x + (w - iw * s) / 2, y + (h - ih * s) / 2, 0, s, s)
end

return M
