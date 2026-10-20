-- Shown when the original game installation could not be found.
local log = require("src.core.log")

---@class NoDataScreen: Screen
local S = {}

function S:draw()
    love.graphics.clear(0.08, 0.06, 0.05)
    love.graphics.setColor(1, 0.85, 0.6)
    love.graphics.printf(
        "openwbc3 needs the original Warlords Battlecry III data (GOG version).\n\n" ..
        "Start with:  love game --data \"<path to Warlords Battlecry 3>\"\n" ..
        "or set [game] dir=<path> in openwbc3.ini in the save directory:\n" ..
        love.filesystem.getSaveDirectory() .. "\n\nPress Esc to quit.",
        40, 60, love.graphics.getWidth() - 80)
    love.graphics.setColor(0.7, 0.7, 0.7)
    local y = 260
    for i = math.max(1, #log.lines - 10), #log.lines do
        love.graphics.print(log.lines[i], 40, y)
        y = y + 16
    end
    love.graphics.setColor(1, 1, 1)
end

function S:keypressed(key)
    if key == "escape" then love.event.quit() end
end

return S
