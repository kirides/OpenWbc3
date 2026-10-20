-- A list box of the XCI screens (LISTBOX objects such as LB_SS_MAPS, LB_SELECTAIFILE) with the vertical scroll bar
-- next to it (SBAR_V156B, ui/scrollbars.lua). The XCI object only gives the rectangle and two fonts (normal, selected);
-- the row height (font height + 3) and the highlight band are openwbc3's own reading, not verified against the original.
--   local lb = listbox.new(x, y, w, h, barX, barY, barH, fontNormal, fontSelected)
--   lb:setItems(list, selected)    lb:draw(enabled)    lb:press(vx, vy) -> index | nil    lb:wheel(dy)
--   lb:drag(vx, vy) / lb:release() while the thumb is held
local UI = require("src.ui.interface")
local fonts = require("src.ui.fonts")
local bars = require("src.ui.scrollbars")

local M = {}

---@class ListBox
---@field x number
---@field y number
---@field w number
---@field h number
---@field bar {x: number, y: number, h: number}  the scroll bar
---@field fontN integer        font of the rows
---@field fontS integer        font of the selected row
---@field rowH number
---@field items string[]
---@field sel integer          selected row (1-based)
---@field scroll integer       rows scrolled past
---@field dragging boolean?    the thumb is held
local L = {}
L.__index = L

---@param fontN integer
---@param fontS integer?
---@return ListBox
function M.new(x, y, w, h, barX, barY, barH, fontN, fontS)
    local d = fonts.get(fontN)
    return setmetatable({ x = x, y = y, w = w, h = h, bar = { x = barX, y = barY, h = barH or 156 },
                          fontN = fontN, fontS = fontS or fontN, rowH = (d and d.size or 14) + 3,
                          items = {}, sel = 1, scroll = 0 }, L) --[[@as ListBox]]
end

---@return integer
function L:rows() return math.max(1, math.floor(self.h / self.rowH)) end
---@return integer
function L:maxScroll() return math.max(0, #self.items - self:rows()) end

---@param items string[]
---@param sel integer?
function L:setItems(items, sel)
    self.items = items
    self.sel = math.max(1, math.min(sel or 1, math.max(1, #items)))
    self.scroll = math.min(self:maxScroll(), math.max(0, self.scroll))
    self:ensureVisible()
end

function L:ensureVisible()
    if self.sel <= self.scroll then self.scroll = self.sel - 1 end
    if self.sel > self.scroll + self:rows() then self.scroll = self.sel - self:rows() end
    self.scroll = math.max(0, math.min(self:maxScroll(), self.scroll))
end

---@param enabled boolean?   false: greyed, no scrolling
function L:draw(enabled)
    local g = love.graphics
    local mx, my = UI.toVirtual(love.mouse.getPosition())
    for r = 1, self:rows() do
        local i = r + self.scroll
        local s = self.items[i]
        if not s then break end
        local y = self.y + (r - 1) * self.rowH
        local selected = i == self.sel
        if selected then
            g.setColor(0, 0, 0, 0.55)
            g.rectangle("fill", self.x, y, self.w, self.rowH)
        end
        g.setColor(1, 1, 1, enabled == false and 0.6 or 1)
        local fid = selected and self.fontS or self.fontN
        fonts.print(fid, s, self.x + 6, y + fonts.middleY(fid, self.rowH), "left", self.w - 12)
    end
    g.setColor(1, 1, 1)
    local pos = self:maxScroll() > 0 and self.scroll / self:maxScroll() or 0
    bars.vDraw(UI.bitmapByName("BM_SBAR_V156B"), self.bar.x, self.bar.y, self.bar.h, pos, enabled ~= false and self:maxScroll() > 0,
               mx, my)
end

-- Click at (vx, vy): returns the index of a row hit, or nil (arrows / track act on the scroll position).
---@return integer?
function L:press(vx, vy)
    if vx >= self.x and vx < self.x + self.w and vy >= self.y and vy < self.y + self.h then
        local i = math.floor((vy - self.y) / self.rowH) + 1 + self.scroll
        if self.items[i] then return i end
        return nil
    end
    local part = bars.vHit(self.bar.x, self.bar.y, self.bar.h, vx, vy)
    if part == "up" then self.scroll = math.max(0, self.scroll - 1)
    elseif part == "down" then self.scroll = math.min(self:maxScroll(), self.scroll + 1)
    elseif part == "track" then
        self.dragging = true
        self:drag(vx, vy)
    end
    return nil
end

function L:drag(vx, vy)
    if not self.dragging then return end
    self.scroll = math.floor(bars.vPos(self.bar.y, self.bar.h, vy) * self:maxScroll() + 0.5)
end

function L:release() self.dragging = false end

---@param dy number
function L:wheel(dy)
    self.scroll = math.max(0, math.min(self:maxScroll(), self.scroll - dy * 3))
end

return M
