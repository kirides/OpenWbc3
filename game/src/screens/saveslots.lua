-- Save / load slot list. enter("save", battle) or enter("load", battle?).
local screens = require("src.core.screens")
local fonts = require("src.ui.fonts")
local savegame = require("src.game.savegame")
local profile = require("src.game.profile")
local l10n = require("src.game.l10n")

---@class SaveSlotsScreen: Screen
---@field mode "save"|"load"
---@field battle BattleScreen?       the battle to save (or the one left when loading)
---@field sel integer                the selected row
---@field notice string?
---@field slots table<integer, table>   savegame.list(): the slots' headers
---@field rows integer[]             the slot numbers listed
---@field font love.Font
---@field title love.Font
local S = { overlay = true }

local ROW_H, TOP, LEFT, WIDTH = 34, 120, 0, 520

---@param mode "save"|"load"
---@param battle BattleScreen?
function S:enter(mode, battle)
    self.mode, self.battle = mode, battle
    self.sel = 1
    self.notice = nil
    self:refresh()
    self.font = fonts.plain(16)
    self.title = fonts.plain(26)
end

function S:leave() end

-- Saving offers every slot; loading only lists the saves made with the active hero.
function S:refresh()
    self.slots = savegame.list()
    self.rows = {}
    local cur = profile.current()
    for i = 1, savegame.SLOTS do
        local s = self.slots[i]
        if self.mode == "save" or (s and cur and s.hero == cur.id) then self.rows[#self.rows + 1] = i end
    end
    self.sel = math.max(1, math.min(self.sel or 1, #self.rows))
end

function S:left()
    return math.floor((love.graphics.getWidth() - WIDTH) / 2)
end

---@param row integer
function S:activate(row)
    local i = self.rows[row]
    if not i then return end
    if self.mode == "save" then
        if self.battle:saveGame(i) then
            self:refresh()
            self.notice = l10n.game("0304", "Game Saved")
        else
            self.notice = l10n.game("0305", "Error - Game NOT Saved")
        end
    elseif self.slots[i] then
        local battle = self.battle
        screens.pop()                      -- this list
        if battle then
            screens.pop()                  -- the battle menu
            screens.pop()                  -- the battle
        end
        local ok, why = savegame.start(i)
            if not ok then self.notice = why and l10n.own("Loading failed: %s"):format(why) or l10n.own("Loading failed") end
    end
end

---@return integer?
function S:rowAt(x, y)
    local i = math.floor((y - TOP) / ROW_H) + 1
    local lx = self:left()
    if x >= lx and x <= lx + WIDTH and i >= 1 and i <= #self.rows then return i end
end

function S:draw()
    local g = love.graphics
    local W, H = g.getDimensions()
    g.setColor(0, 0, 0, 0.8)
    g.rectangle("fill", 0, 0, W, H)
    g.setFont(self.title)
    g.setColor(1, 0.85, 0.55)
    g.printf(self.mode == "save" and l10n.game("0307", "Save Game") or l10n.game("0306", "Load Game"), 0, 50, W, "center")
    g.setFont(self.font)
    local lx = self:left()
    if #self.rows == 0 then
        g.setColor(0.5, 0.5, 0.5)
        g.printf(l10n.own("No saved games for this hero"), 0, TOP + 8, W, "center")
    end
    for r, i in ipairs(self.rows) do
        local y = TOP + (r - 1) * ROW_H
        if r == self.sel then
            g.setColor(0.4, 0.28, 0.12)
            g.rectangle("fill", lx, y, WIDTH, ROW_H - 4)
        end
        local s = self.slots[i]
        g.setColor(0.95, 0.9, 0.8)
        if s then
            local min = math.floor(s.time / 60000)
            g.print(("%d. %s"):format(i, s.title or "?"), lx + 8, y + 5)
            g.setColor(0.7, 0.7, 0.7)
            g.printf(("%d min  %s"):format(min, os.date("%Y-%m-%d %H:%M", s.saved)), lx, y + 5, WIDTH - 8, "right")
        else
            g.setColor(0.5, 0.5, 0.5)
            g.print(("%d. (empty)"):format(i), lx + 8, y + 5)
        end
    end
    g.setColor(0.6, 0.6, 0.6)
    g.printf("Enter / click: " .. (self.mode == "save" and "save" or "load") .. "    Del: delete    Esc: back",
        0, TOP + math.max(1, #self.rows) * ROW_H + 16, W, "center")
    if self.notice then
        g.setColor(1, 0.85, 0.55)
        g.printf(self.notice, 0, TOP + math.max(1, #self.rows) * ROW_H + 44, W, "center")
    end
    g.setColor(1, 1, 1)
end

function S:mousepressed(x, y, button)
    if button ~= 1 then return end
    local i = self:rowAt(x, y)
    if i then
        self.sel = i
        self:activate(i)
    end
end

function S:keypressed(key)
    if key == "up" then self.sel = math.max(1, self.sel - 1)
    elseif key == "down" then self.sel = math.min(math.max(1, #self.rows), self.sel + 1)
    elseif key == "return" or key == "kpenter" then self:activate(self.sel)
    elseif key == "delete" then
        if self.rows[self.sel] then savegame.delete(self.rows[self.sel]) end
        self:refresh()
    elseif key == "escape" then
        screens.pop()
    end
end

return S
