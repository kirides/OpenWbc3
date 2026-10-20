-- Dialog frame shared by the in-battle menu and the options window. The original scroll art is too small
-- for these lists, so the frame is drawn here (dark parchment, bronze double border, gold corner studs);
-- only the title font and the button art come from the XCI panel PNL_OKAYCANCEL. Coordinates are the
-- virtual 800x600 canvas (call between UI.begin() and UI.finish()).
local UI = require("src.ui.interface")

local M = { X = 160, Y = 110, W = 480, H = 380 }

local mesh

-- Smooth vertical gradient (near-black at the top, dark red at the bottom).
local function background()
    if not mesh then
        local top, bot = { 0.04, 0.02, 0.02, 1 }, { 0.2, 0.04, 0.04, 1 }
        mesh = love.graphics.newMesh({
            { 0, 0, 0, 0, top[1], top[2], top[3], top[4] },
            { 1, 0, 0, 0, top[1], top[2], top[3], top[4] },
            { 1, 1, 0, 0, bot[1], bot[2], bot[3], bot[4] },
            { 0, 1, 0, 0, bot[1], bot[2], bot[3], bot[4] },
        }, "fan", "static")
    end
    return mesh
end

-- Darkens the whole window (outside the virtual canvas transform).
function M.dim()
    local g = love.graphics
    g.setColor(0, 0, 0, 0.6)
    g.rectangle("fill", 0, 0, g.getDimensions())
    g.setColor(1, 1, 1)
end

function M.draw()
    local g = love.graphics
    local x, y, w, h = M.X, M.Y, M.W, M.H
    g.setColor(1, 1, 1)
    g.draw(background(), x + 2, y + 2, 0, w - 4, h - 4)
    g.setColor(0.55, 0.4, 0.26)
    g.setLineWidth(3)
    g.rectangle("line", x + 1.5, y + 1.5, w - 3, h - 3, 6, 6)
    g.setLineWidth(1)
    g.setColor(0.86, 0.7, 0.47, 0.8)
    g.rectangle("line", x + 7.5, y + 7.5, w - 15, h - 15, 3, 3)
    for _, c in ipairs({ { x, y }, { x + w, y }, { x, y + h }, { x + w, y + h } }) do
        g.setColor(0.86, 0.7, 0.47)
        g.circle("fill", c[1], c[2], 6)
        g.setColor(0.3, 0.2, 0.1)
        g.circle("line", c[1], c[2], 6)
    end
    -- divider under the title
    g.setColor(0.86, 0.7, 0.47, 0.6)
    g.line(x + 30, y + 64, x + w - 30, y + 64)
    g.setColor(1, 1, 1)
end

-- Hides everything of a PNL_OKAYCANCEL panel and shows its title centred at the top of the frame.
---@param p Panel
---@param title string
---@return PanelItem title
function M.prepare(p, title)
    for _, it in ipairs(p.items) do p:hideItem(it) end
    local t = p:find("STR_LARGE400")
    ---@cast t -nil
    t.e = { x = M.X + (M.W - t.ob.w) / 2, y = M.Y + 14, z = t.e.z }
    p:hideItem(t, false)
    p.align[t] = "center"
    p.itemStrings[t] = title
    return t
end

-- Re-places a panel item inside the frame (x, y relative to the frame) and shows it.
---@param p Panel
---@param it PanelItem
---@param x number
---@param y number
function M.place(p, it, x, y)
    it.e = { x = M.X + x, y = M.Y + y, z = it.e.z }
    p:hideItem(it, false)
end

return M
