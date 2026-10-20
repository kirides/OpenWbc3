-- "Choose a Foe" dialog of the Knight's Quest power-up (original: the four-choice picture dialog FUN_0055bc90 and the
-- callback at 0x00439000 that FUN_00438de0 passes it): the sprite EMD4 (370x431) on the right of the 800x600 screen
-- (x 400, y 10 as the original places it), the title Game.txt 0869 and the four candidate foes in a 2x2 grid; the
-- cells are the army's interface picture, frame 3, or frame 4 for a foe that was chosen before (the original greys it
-- and ignores clicks). A click on a free foe chooses it (command chooseFoe), the 30x30 button EMDC at the bottom
-- (163, 369) or Escape closes the dialog without a choice. Cell hit areas are the original's FUN_0055c420 (x 86..176 /
-- 185..275, y 68..158 / 167..257, only for a free foe); the pictures are drawn at x 86 / 185, y 68 / 167. Draw routine
-- of the original (vtable slot at 0x55c500 of the dialog's vtable 0x005ea8dc): the title (Game.txt 0869) in font 1
-- (large) centred on x 178, y 28, the name of the foe under the mouse in font 2 (small) centred on x 178, y 300 (the
-- box under the grid is empty otherwise).
local screens = require("src.core.screens")
local UI = require("src.ui.interface")
local fonts = require("src.ui.fonts")
local anims = require("src.gfx.anims")
local strings = require("src.game.strings")
local rules = require("src.game.rules")
local powerups = require("src.game.powerups")

---@class ChooseFoeScreen: Screen
---@field battle BattleScreen
---@field world World
---@field cancel integer             the close button: 0 normal, 1 hover, 2 pressed
---@field cancelDown boolean?        the close button is held
---@field hover integer?             the cell under the mouse
---@field pressed integer?           the cell a press started on
---@field candidates string[]        the four candidate foes (army codes)
local S = { overlay = true }

local BX, BY = 400, 10
local CELLS = { { 86, 68 }, { 185, 68 }, { 86, 167 }, { 185, 167 } }       -- left / top; 90 x 90 pictures
local CELL_W, CELL_H = 91, 91                                              -- hit boxes
local TEXT_X, TITLE_Y, NAME_Y = 178, 28, 300
local CANCEL_X, CANCEL_Y, CANCEL_W = 163, 369, 30
local FONT_LARGE, FONT_SMALL = 1, 2

---@param battle BattleScreen
function S:enter(battle)
    self.battle = battle
    self.world = battle.world
    self.cancel = 0                       -- 0 normal, 1 hover, 2 pressed
    self.hover = nil
    self.candidates = powerups.questCandidates(self.world, self.world.player)
end

function S:leave() end

local function inside(x, y, rx, ry, w, h) return x >= BX + rx and x < BX + rx + w and y >= BY + ry and y < BY + ry + h end

function S:taken(code)
    return powerups.isQuestFoe(self.world.sides[self.world.player], code)
end

---@return integer?
function S:cellAt(x, y)
    for i, c in ipairs(CELLS) do
        if self.candidates[i] and inside(x, y, c[1], c[2], CELL_W, CELL_H) and not self:taken(self.candidates[i]) then
            return i
        end
    end
end

function S:mousemoved(px, py)
    local x, y = UI.toVirtual(px, py)
    if inside(x, y, CANCEL_X, CANCEL_Y, CANCEL_W, CANCEL_W) then
        self.cancel = self.cancelDown and 2 or 1
        self.hover = nil
        return
    end
    self.cancel = 0
    self.hover = self:cellAt(x, y)
end

function S:mousepressed(px, py, button)
    if button ~= 1 then return end
    local x, y = UI.toVirtual(px, py)
    if inside(x, y, CANCEL_X, CANCEL_Y, CANCEL_W, CANCEL_W) then
        self.cancelDown, self.cancel = true, 2
        return
    end
    self.pressed = self:cellAt(x, y)
end

function S:mousereleased(px, py, button)
    if button ~= 1 then return end
    local x, y = UI.toVirtual(px, py)
    if self.cancelDown then
        self.cancelDown = false
        if inside(x, y, CANCEL_X, CANCEL_Y, CANCEL_W, CANCEL_W) then screens.pop() return end
        self.cancel = 0
    end
    local i = self.pressed
    self.pressed = nil
    if i and i == self:cellAt(x, y) then
        local battle = self.battle
        screens.pop()
        battle:issue({ t = "chooseFoe", index = i })
    end
end

function S:keypressed(key)
    if key == "escape" then screens.pop() end
end

function S:draw()
    UI.begin()
    local bg = anims.get("EMD4")
    if bg then bg:drawCell(0, 0, 0, BX, BY) end
    local cancel = anims.get("EMDC")
    if cancel then cancel:drawCell(0, self.cancel, 0, BX + CANCEL_X, BY + CANCEL_Y) end
    fonts.print(FONT_LARGE, strings.get("Game.txt", "0869") or "Choose a Foe", BX + TEXT_X - 200, BY + TITLE_Y, "center", 400)
    local side = self.world.sides[self.world.player]
    local team = side and side.color or 0
    for i, c in ipairs(CELLS) do
        local code = self.candidates[i]
        if code then
            local taken = self:taken(code)
            local set = anims.get(code)
            love.graphics.setColor(1, 1, 1, (self.hover == i) and 1 or (taken and 0.6 or 0.9))
            if set then set:drawInterface(taken and 4 or 3, BX + c[1], BY + c[2], team) end
            love.graphics.setColor(1, 1, 1)
        end
    end
    -- the name of the foe under the mouse below the grid
    local code = self.hover and self.candidates[self.hover]
    if code then
        fonts.print(FONT_SMALL, rules.unitName(code, require("src.game.gamedata").army(code)), BX + TEXT_X - 200, BY + NAME_Y,
            "center", 400)
    end
    UI.finish()
end

return S
