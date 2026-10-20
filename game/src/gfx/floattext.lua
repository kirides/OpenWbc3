-- Floating text over armies (the original's floating message lines, "floating text" option): a short line such as "Critical:
-- Cleave", "Gained Level 3" or "Healing: 40 pts" that appears above an army, drifts up 25 pixels and fades out.
--
-- Verified in the 1.04 binary (the army's message adder FUN_0053a010, the line set-up FUN_005349b0): at most two messages per army
-- (a third is dropped), shown only for an army that is on screen and visible; the text sits 40 pixels above the army's
-- effect point and is centred on it; it lives for the given time (1000 ms) plus 1500 ms, rises 25 pixels over that and
-- fades during the last 1500 ms in 16 steps; a message that starts within 300 ms of the previous one and within 40
-- pixels of its height is moved to 30 pixels below it and delayed by 250 ms (a message added while another of the same
-- army is less than 500 ms old is delayed by 500 ms). Fonts 37..41 of Font.ini: standard white, good green, bad red,
-- magic cyan, level yellow; the type is turned into "good" for own and allied armies and "bad" for the rest, except
-- that levels and magic of own armies keep their colour.
--
-- Presentation only: world.time is the clock, no math.random; must not touch love.graphics at require time.
local M = {}

M.STANDARD, M.GOOD, M.BAD, M.MAGIC, M.LEVEL = 0, 1, 2, 3, 4
local FONT = { [0] = 37, 38, 39, 40, 41 }
local EXTRA, RISE = 1500, 25
local MAX_PER_ARMY = 2

---@class FloatText
---@field unit Unit
---@field text string
---@field font integer    Font.ini number
---@field x number        world pixels
---@field y0 number
---@field start number    ms
---@field finish number

---@class FloatTextList
---@field items FloatText[]
---@field lastStart number
---@field lastY number
local List = {}
List.__index = List

---@return FloatTextList
function M.new() return setmetatable({ items = {}, lastStart = 0, lastY = 0 }, List) end

-- unit: the army; x, y: its effect point (world pixels); mineOrAlly: whether it belongs to the viewer or an ally.
---@param unit Unit
---@param text string
---@param kind integer M.STANDARD .. M.LEVEL
---@param mineOrAlly boolean
---@param x number
---@param y number
---@param now number
---@param duration number? ms (default 1000)
---@return boolean added
function List:add(unit, text, kind, mineOrAlly, x, y, now, duration)
    -- the type as seen by the viewer (FUN_0053a010)
    if kind == M.BAD then if mineOrAlly then kind = M.GOOD end
    elseif kind == M.GOOD then if not mineOrAlly then kind = M.BAD end
    elseif not mineOrAlly then kind = M.BAD end
    local mine, justStarted = 0, false
    for _, m in ipairs(self.items) do
        if m.unit == unit then
            mine = mine + 1
            if now < m.start + 500 then justStarted = true end
        end
    end
    if mine >= MAX_PER_ARMY then return false end
    local start = justStarted and now + 500 or now
    duration = duration or 1000
    local my = y - 40
    if math.abs(start - self.lastStart) < 300 and math.abs(my - self.lastY) < 40 then
        my = self.lastY + 30
        start = start + 250
    end
    self.lastStart, self.lastY = start, my
    self.items[#self.items + 1] = { unit = unit, text = text, font = FONT[kind] or 37, x = x, y0 = my, start = start,
                                    finish = start + duration + EXTRA }
    return true
end

---@param now number
function List:update(now)
    for i = #self.items, 1, -1 do
        if now >= self.items[i].finish then table.remove(self.items, i) end
    end
end

-- Draws the messages (world coordinates); `fonts` is src.ui.fonts.
---@param fonts table src.ui.fonts
---@param now number
function List:draw(fonts, now)
    for _, m in ipairs(self.items) do
        if now >= m.start then
            local y = m.y0 - math.floor((now - m.start) * RISE / (m.finish - m.start))
            local alpha = 1
            if now > m.finish - EXTRA then alpha = (15 - math.floor((now - (m.finish - EXTRA)) * 15 / EXTRA)) / 15 end
            fonts.print(m.font, m.text, m.x - 100, y, "center", 200, math.max(0, alpha))
        end
    end
end

return M
