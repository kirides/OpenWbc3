-- The choice dialog of the four-choice spells (Change Weather, Elementalism, Raise Champion). The 1.04 binary's cast
-- routine FUN_005717e0 opens the four-picture dialog FUN_0055bc90 (vtable 0x005ea8dc; the same dialog as Choose a Foe,
-- screens/choosefoe.lua) for them instead of casting: the sprite EMD4 (370x431) at x 400, y 10 of the 800x600 screen,
-- the spell's name (Spells.txt) as title in font 1 centred on x 178, y 28, the four pictures of the spell's table (0x61b4b8
-- weather: EWTH frames 0..3; 0x61b4f8 / 0x61b538: the armies' interface picture, frame 3) at x 86 / 185, y 68 / 167, the
-- text of the picture under the mouse ([SPELL_DLG_TEXT_nn] of Spells.txt, FUN_0056f490) in font 2 centred on x 178, y 300,
-- and the 30x30 button EMDC at (163, 369). Mouse (FUN_0055c070 press, FUN_0055c160 release, FUN_0055be80 move, hit test
-- FUN_0055c420: x 86..176 / 185..275, y 68..158 / 167..257): a press on a picture arms the dialog, the release then closes
-- it and casts the picture under the mouse (none when it is over no picture), and leaving the dialog with the button held
-- cancels. The Cancel button (press and release on it) and Escape (FUN_0055c320) close it without a cast. The pick goes
-- out as the cast command with target = { choice = 0..3 } (the callback 0x00571df0 sends the cast message with the choice;
-- Cancel sends nothing, so no mana is spent). openwbc3's own: a click outside the dialog does nothing (the original hands
-- it on to the battle view).
local screens = require("src.core.screens")
local UI = require("src.ui.interface")
local fonts = require("src.ui.fonts")
local anims = require("src.gfx.anims")
local strings = require("src.game.strings")
local spells = require("src.game.spells")

---@class SpellChoiceScreen: Screen
---@field battle BattleScreen
---@field hero Unit                 the casting hero
---@field spell integer              the spell slot
---@field choices SpellChoice[]
---@field cancel integer             the close button: 0 normal, 1 hover, 2 pressed
---@field cancelDown boolean?        the close button is held
---@field armed boolean?             a press on a picture started (the original's flag +0x130)
---@field hover integer?             the picture under the mouse (1..4)
local S = { overlay = true }

local BX, BY = 400, 10
local CELLS = { { 86, 68 }, { 185, 68 }, { 86, 167 }, { 185, 167 } }       -- left / top; 90 x 90 pictures
local CELL_W, CELL_H = 91, 91                                              -- hit boxes
local DLG_W, DLG_H = 370, 431
local TEXT_X, TITLE_Y, NAME_Y = 178, 28, 300
local CANCEL_X, CANCEL_Y, CANCEL_W = 163, 369, 30
local FONT_LARGE, FONT_SMALL = 1, 2

---@param battle BattleScreen
---@param hero Unit
---@param spell integer
function S:enter(battle, hero, spell)
    self.battle = battle
    self.hero = hero
    self.spell = spell
    self.choices = spells.choices(spell) or {}
    self.cancel, self.cancelDown, self.armed, self.hover = 0, false, false, nil
end

function S:leave() end

local function inside(x, y, rx, ry, w, h) return x >= BX + rx and x < BX + rx + w and y >= BY + ry and y < BY + ry + h end

---@return integer?
local function cellAt(x, y)
    for i, c in ipairs(CELLS) do
        if inside(x, y, c[1], c[2], CELL_W, CELL_H) then return i end
    end
end

-- The text of choice `i`: the install's Spells.txt entry, else the army's name or the weather's.
---@param i integer
---@return string
function S:text(i)
    local ch = self.choices[i]
    if not ch then return "" end
    local s = ch.text and strings.get("Spells.txt", ch.text)
    if s and s ~= "" then return s end
    if ch.unit then
        return require("src.game.rules").unitName(ch.picture, require("src.game.gamedata").army(ch.picture))
    end
    return require("src.game.weather").NAMES[i - 1] or ch.picture
end

function S:close() screens.pop() end

---@param i integer 1..4
function S:pick(i)
    local battle = self.battle
    self:close()
    local hero = self.hero
    if spells.canCast(hero, self.spell) then
        battle:issue({ t = "cast", id = hero.id, spell = self.spell, target = { choice = i - 1 } })
    end
end

function S:mousemoved(px, py)
    local x, y = UI.toVirtual(px, py)
    -- leaving the dialog with a picture pressed cancels (FUN_0055be80)
    if self.armed and not inside(x, y, 0, 0, DLG_W, DLG_H) then return self:close() end
    if inside(x, y, CANCEL_X, CANCEL_Y, CANCEL_W, CANCEL_W) then
        self.cancel = self.cancelDown and 2 or 1
        self.hover = nil
        return
    end
    self.cancel = 0
    self.hover = cellAt(x, y)
end

function S:mousepressed(px, py, button)
    if button ~= 1 then return end
    local x, y = UI.toVirtual(px, py)
    if inside(x, y, CANCEL_X, CANCEL_Y, CANCEL_W, CANCEL_W) then
        self.cancelDown, self.cancel = true, 2
        return
    end
    local i = cellAt(x, y)
    if i then self.armed, self.hover = true, i end
end

function S:mousereleased(px, py, button)
    if button ~= 1 then return end
    local x, y = UI.toVirtual(px, py)
    if self.armed then
        local i = cellAt(x, y)
        if i then return self:pick(i) end
        return self:close()
    end
    if self.cancelDown then
        self.cancelDown = false
        if inside(x, y, CANCEL_X, CANCEL_Y, CANCEL_W, CANCEL_W) then return self:close() end
        self.cancel = 0
    end
end

function S:keypressed(key)
    if key == "escape" then self:close() end
end

function S:draw()
    UI.begin()
    local bg = anims.get("EMD4")
    if bg then bg:drawCell(0, 0, 0, BX, BY) end
    local cancel = anims.get("EMDC")
    if cancel then cancel:drawCell(0, self.cancel, 0, BX + CANCEL_X, BY + CANCEL_Y) end
    fonts.print(FONT_LARGE, spells.name(self.spell), BX + TEXT_X - 200, BY + TITLE_Y, "center", 400)
    local world = self.battle.world
    local side = world.sides[world.player]
    local team = side and side.color or 0
    for i, c in ipairs(CELLS) do
        local ch = self.choices[i]
        local set = ch and anims.get(ch.picture)
        if set then
            ---@cast ch -nil
            if ch.unit then
                set:drawInterface(3, BX + c[1], BY + c[2], team)
            else
                set:drawCell(0, 0, ch.frame or 0, BX + c[1], BY + c[2])
            end
        end
    end
    if self.hover then fonts.print(FONT_SMALL, self:text(self.hover), BX + TEXT_X - 200, BY + NAME_Y, "center", 400) end
    UI.finish()
end

return S
