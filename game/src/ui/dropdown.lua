-- Drop-down list box (the original's drop-down opener FUN_0045cfe0): a black box with a thin tan border that opens at
-- the mouse position, one row per entry (font of the DROPDOWNLIST object of PNL_DROPDOWNLIST); a click on an entry
-- picks it, a click anywhere else closes the list. Usage: `dropdown.open(items, vx, vy, onPick)`, then call
-- `dropdown.draw()` last in the screen's draw and give mouse presses to `dropdown.pressed(vx, vy)` first (it
-- returns true while a list is open, so the click does not reach the screen below).
local UI = require("src.ui.interface")
local fonts = require("src.ui.fonts")

local M = {}

---@class DropdownList        the open list
---@field items string[]
---@field onPick fun(index: integer, text: string)
---@field fid integer          font
---@field row number           row height
---@field x number
---@field y number
---@field w number
---@field h number

---@type DropdownList?
local cur

---@return boolean
function M.isOpen() return cur ~= nil end

function M.close() cur = nil end

local function metrics(items)
    local ob = UI.ui and UI.ui.objByName.DROPDOWNLIST
    local fid = ob and ob.fonts and ob.fonts[1] or 5
    local d = fonts.get(fid)
    local row = (d and d.size or 14) + 5
    local w = 0
    for _, s in ipairs(items) do w = math.max(w, fonts.width(fid, s)) end
    return fid, row, w + 12
end

-- items: list of strings; onPick(index, text)
---@param items string[]
---@param x number
---@param y number
---@param onPick fun(index: integer, text: string)
function M.open(items, x, y, onPick)
    local fid, row, w = metrics(items)
    local h = #items * row + 4
    cur = { items = items, onPick = onPick, fid = fid, row = row,
            x = math.max(0, math.min(x, 800 - w)), y = math.max(0, math.min(y, 600 - h)), w = w, h = h }
end

---@param cur DropdownList
---@return integer?
local function indexAt(cur, vx, vy)
    if vx < cur.x or vx >= cur.x + cur.w or vy < cur.y + 2 or vy >= cur.y + cur.h - 2 then return nil end
    return math.floor((vy - cur.y - 2) / cur.row) + 1
end

function M.draw()
    if not cur then return end
    local g = love.graphics
    local mx, my = UI.toVirtual(love.mouse.getPosition())
    local hover = indexAt(cur, mx, my)
    g.setColor(0, 0, 0, 1)
    g.rectangle("fill", cur.x, cur.y, cur.w, cur.h)
    g.setColor(0.86, 0.7, 0.47)
    g.rectangle("line", cur.x + 0.5, cur.y + 0.5, cur.w - 1, cur.h - 1)
    for i, s in ipairs(cur.items) do
        local y = cur.y + 2 + (i - 1) * cur.row
        if i == hover then
            g.setColor(0.45, 0.3, 0.12, 0.8)
            g.rectangle("fill", cur.x + 2, y, cur.w - 4, cur.row)
        end
        g.setColor(1, 1, 1)
        fonts.print(cur.fid, s, cur.x + 6, y + fonts.middleY(cur.fid, cur.row))
    end
end

---@return boolean consumed
function M.pressed(vx, vy)
    if not cur then return false end
    local list = cur
    cur = nil
    local i = indexAt(list, vx, vy)
    if i and list.items[i] then list.onPick(i, list.items[i]) end
    return true
end

return M
