-- Scenario information over the battle (shown when a battle starts and on Alt+I): the mission text or victory
-- condition, then, on the next click, the special rules. enter(battle, info) with info from game/scenarioinfo.lua.
-- Layout after the original: a translucent black box in the side colour with the heading, a rule under it,
-- one line per row and a reminder about Alt+I at the bottom.
local screens = require("src.core.screens")
local UI = require("src.ui.interface")
local fonts = require("src.ui.fonts")
local cursor = require("src.ui.cursor")

---@class RulesDialogScreen: Screen
---@field battle BattleScreen
---@field info table                 game/scenarioinfo.lua: heading, text, rulesHeading, rules, none, footer
---@field mode "text"|"rules"        the page shown
---@field colour number[]            the side colour of the frame (r, g, b)
---@field pressed boolean            a click started on the dialog
local S = { overlay = true }

local HEADING, BODY, SMALL = 8, 5, 14
local SIDE_COLOURS = { { 200, 0, 0 }, { 0, 0, 200 }, { 0, 200, 0 }, { 150, 0, 200 }, { 50, 50, 50 }, { 200, 150, 0 }, { 125, 125, 125 } }

---@param battle BattleScreen
---@param info table
function S:enter(battle, info)
    self.battle, self.info = battle, info
    self.mode = (info.text and "text") or "rules"
    local c = SIDE_COLOURS[(battle:teamColor(battle.world.player) or 0) + 1] or SIDE_COLOURS[7]
    self.colour = { c[1] / 255, c[2] / 255, c[3] / 255 }
    self.pressed = false
end

function S:leave()
    cursor.enable(true)
end

-- The heading and the rows of the page shown.
---@return string heading, string[] rows
function S:lines()
    local info = self.info
    if self.mode == "text" then return info.heading, info.text end
    if #info.rules > 0 then return info.rulesHeading, info.rules end
    return info.rulesHeading, { info.none }
end

-- Advances from the mission text to the rules, or closes.
function S:next()
    if self.mode == "text" and #self.info.rules > 0 then
        self.mode = "rules"
    else
        screens.pop()
    end
end

function S:draw()
    local g = love.graphics
    local heading, lines = self:lines()
    local info = self.info
    -- the box is sized for both pages so it does not jump when the page changes
    local w = math.max(32, fonts.width(HEADING, info.heading), fonts.width(HEADING, info.rulesHeading))
    local rows = math.max(info.text and #info.text or 0, #info.rules, 1)
    for _, l in ipairs(info.text or {}) do w = math.max(w, fonts.width(BODY, l)) end
    for _, l in ipairs(info.rules) do w = math.max(w, fonts.width(BODY, l)) end
    for _, l in ipairs(info.footer) do w = math.max(w, fonts.width(SMALL, l)) end
    w = w + 16
    local h = 35 + rows * 20 + 30 + 40
    local x, y = math.floor((UI.W - w) / 2), math.floor((UI.H - h) / 2) - 75
    UI.begin()
    g.setColor(0, 0, 0, 0.72)
    g.rectangle("fill", x, y, w, h)
    g.setColor(0, 0, 0, 1)
    g.rectangle("line", x + 1.5, y + 1.5, w - 3, h - 3)
    local c = self.colour
    g.setColor(c[1], c[2], c[3], 1)
    g.rectangle("line", x + 2.5, y + 2.5, w - 5, h - 5)
    g.line(x + 8, y + 29.5, x + w - 8, y + 29.5)
    g.setColor(1, 1, 1)
    fonts.print(HEADING, heading, x, y, "center", w)
    for i, l in ipairs(lines) do fonts.print(BODY, l, x, y + 38 + (i - 1) * 20, "center", w) end
    fonts.print(SMALL, info.footer[1], x, y + h - 40, "center", w)
    fonts.print(SMALL, info.footer[2], x, y + h - 23, "center", w)
    UI.finish()
end

function S:mousepressed()
    self.pressed = true
end

function S:mousereleased()
    if self.pressed then self:next() end
end

function S:keypressed(key)
    if key == "escape" or key == "return" or key == "kpenter" then self:next() end
end

return S
