-- Small drawing helpers shared by the dialogs (virtual 800x600 coordinates).
local fonts = require("src.ui.fonts")

local M = {}

-- Splits `text` into lines no wider than `width` pixels in font `fontId`.
---@param fontId integer
---@param text string
---@param width number
---@return string[]
function M.wrap(fontId, text, width)
    local _, f = fonts.get(fontId)
    local lines = {}
    if not f then return { text } end
    local line = ""
    for word in text:gmatch("%S+") do
        local try = line == "" and word or (line .. " " .. word)
        if f:getWidth(try) > width and line ~= "" then
            lines[#lines + 1] = line
            line = word
        else
            line = try
        end
    end
    if line ~= "" then lines[#lines + 1] = line end
    return lines
end

-- Tooltip box. `lines` are strings or { text, colour }.
---@param lines (string|{[1]: string, [2]: number[]?})[]
---@param vw? number
---@param vh? number
function M.tooltip(lines, mx, my, vw, vh)
    local g = love.graphics
    local _, f = fonts.get(2)
    if not f then return end
    local w = 0
    for _, l in ipairs(lines) do
        local s = type(l) == "table" and l[1] or l --[[@as string]]
        w = math.max(w, f:getWidth(s))
    end
    w = w + 14
    local h = #lines * 15 + 10
    local x = math.max(2, math.min(mx + 14, (vw or 800) - w - 2))
    local y = my + 18
    if y + h > (vh or 600) - 2 then y = my - h - 8 end
    g.setColor(0.08, 0.02, 0.02, 0.95)
    g.rectangle("fill", x, y, w, h)
    g.setColor(0.86, 0.7, 0.47)
    g.rectangle("line", x + 0.5, y + 0.5, w - 1, h - 1)
    g.setColor(1, 1, 1)
    for i, l in ipairs(lines) do
        local s, c = l, nil
        if type(l) == "table" then s, c = l[1], l[2] end
        if c then g.setColor(c[1], c[2], c[3]) end
        g.setFont(select(2, fonts.get(2)))
        local d = fonts.get(2)
        ---@cast d -nil         -- font 2 gave a face above, so it has a definition
        local by = math.floor(y + 5 + (i - 1) * 15 + d.baseline - f:getBaseline())
        g.print(s, x + 7, by)
        g.setColor(1, 1, 1)
    end
end

-- Quality colours of items.
M.TIER_COLOR = { { 0.8, 0.8, 0.8 }, { 0.5, 0.9, 0.5 }, { 0.5, 0.7, 1 }, { 1, 0.7, 0.3 }, { 0.9, 0.5, 1 } }

---@return boolean
function M.inside(x, y, rx, ry, rw, rh)
    return x >= rx and y >= ry and x < rx + rw and y < ry + rh
end

return M
