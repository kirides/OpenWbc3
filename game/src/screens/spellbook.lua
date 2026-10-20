-- Spell book (original: the spell book dialog, constructor FUN_0056f910, drawing FUN_00570590): the parchment book
-- (sprite EMDS, 613x445) opens on one sphere, the left page lists its ten spells (icons EMDI), the right page tells
-- about the spell under the mouse. A spell that is known and affordable is cast with a click or its number key (1..0);
-- F1..F8 over a known spell make it the hot key of that slot (FUN_004258a0, stored with the hero); the arrows (or the
-- sphere keys) turn to the neighbouring sphere the hero can cast from. Positions, fonts and texts follow the original's
-- dialog (800x600 offsets).
-- Not traced in the 1.04 binary yet: the original counts a 16-frame sphere animation every 100 ms but never draws it,
-- its sphere icon buttons do not exist (its button hit test always fails), so the "leave the dialog with the mouse after
-- a button was used" rule can never trigger either - nothing to port there. What is ported: the cursors (the pointer hand over the cancel
-- button, the arrow over the two pages, the pointer-up hand elsewhere in the dialog), the click casts only a known spell
-- with enough mana, and so do the number keys.
local screens = require("src.core.screens")
local UI = require("src.ui.interface")
local fonts = require("src.ui.fonts")
local anims = require("src.gfx.anims")
local strings = require("src.game.strings")
local spells = require("src.game.spells")
local heroMod = require("src.game.hero")
local keymap = require("src.ui.keymap")

---@class SpellBookScreen: Screen
---@field battle BattleScreen
---@field world World
---@field hover integer?             the spell (0..9) of the left page under the mouse
---@field cancel integer             the cancel button: 0 normal, 1 hover, 2 pressed
---@field cancelDown boolean?
---@field opened number              when it opened (the number keys wait OPEN_DELAY)
---@field wrapped table<integer, string[]>   the descriptions split into lines, by spell id
---@field sphere integer             the sphere shown
local S = { overlay = true }

local BX, BY = 94, 2                       -- the book's place on the 800x600 layout
local LEFT_X, LEFT_Y, RIGHT_X = 45, 100, 340
local PAGE_W, PAGE_H = 224, 230
local ROW_H = 23
local CANCEL_X, CANCEL_Y, CANCEL_W = 288, 382, 30
local ORB_X, ORB_Y, STAFF_X, STAFF_Y = 158, 387, 432, 387
local SPHERE_X, SPHERE_Y = 296, 32
local ARROW_L, ARROW_R, ARROW_W, ARROW_H = { 51, 20 }, { 479, 19 }, 70, 62
local OPEN_DELAY = 0.15                    -- seconds before the number keys cast
local CHANCE_PENALTY = 50                  -- each level below the best costs 50 % (FUN_00570590)

-- Font.ini indexes
local FONT_LARGE, FONT_SMALL, FONT_MEDIUM, FONT_BLACK, FONT_RED, FONT_GREY = 1, 2, 5, 9, 10, 11

local lastSphere = 0                       -- the book reopens on the sphere it was left on

local function str(file, key, default) return strings.get(file, key) or default end

---@param battle BattleScreen
function S:enter(battle)
    self.battle = battle
    self.world = battle.world
    self.hover = nil
    self.cancel = 0                         -- 0 normal, 1 hover, 2 pressed
    self.opened = love.timer.getTime()
    self.wrapped = {}
    local hero = self:hero()
    -- A sphere the hero cannot cast from is replaced by its best one.
    if hero and hero.h and not self:knows(lastSphere) then
        local best, bestSkill = lastSphere, 0
        for sph = 0, spells.SPHERES - 1 do
            local skill = spells.castSkill(hero.h, sph)
            if skill > bestSkill then best, bestSkill = sph, skill end
        end
        lastSphere = best
    end
    self.sphere = lastSphere
end

function S:leave() end

---@return Unit?
function S:hero()
    return self.world.eco:heroAlive(self.world.player)
end

-- The spell level check FUN_0040c6b0 for spell sphere * 10: the first spell of the sphere is castable.
---@param sphere integer
---@return boolean
function S:knows(sphere)
    local hero = self:hero()
    return hero and hero.h and hero.h.spells[sphere * 10] or false
end

---@param step integer -1 or 1
function S:turn(step)
    for _ = 1, spells.SPHERES do
        self.sphere = (self.sphere + step) % spells.SPHERES
        if self:knows(self.sphere) then break end
    end
    lastSphere = self.sphere
    self.hover = nil
end

function S:update()
    if not self:hero() then screens.pop() end
end

-- The cursor (not traced in the 1.04 binary yet): over the dialog the cancel button gives the pointer hand, the book (both
-- pages) the arrow and everything else the pointer-up hand; outside it the normal map cursor (the arrow here).
function S:cursorName()
    local x, y = UI.toVirtual(love.mouse.getPosition())
    if x >= BX and x < BX + 613 and y >= BY and y < BY + 445 then
        if x >= BX + CANCEL_X and x < BX + CANCEL_X + 30 and y >= BY + CANCEL_Y and y < BY + CANCEL_Y + 30 then
            return "POINTER"
        end
        if x >= BX + LEFT_X and x < BX + LEFT_X + 2 * PAGE_W and y >= BY + LEFT_Y and y < BY + LEFT_Y + PAGE_H then
            return "ARROW"
        end
        return "POINTERUP"
    end
    return "ARROW"
end

-- Mouse ------------------------------------------------------------------------------

local function inside(x, y, rx, ry, w, h) return x >= BX + rx and x < BX + rx + w and y >= BY + ry and y < BY + ry + h end

local function overSpell(x, y)
    if not inside(x, y, LEFT_X, LEFT_Y, PAGE_W, PAGE_H) then return nil end
    local i = math.floor((y - BY - LEFT_Y) / ROW_H)
    if i >= 0 and i < 10 then return i end
end

function S:mousemoved(px, py)
    local x, y = UI.toVirtual(px, py)
    if inside(x, y, CANCEL_X, CANCEL_Y, CANCEL_W, CANCEL_W) then
        self.cancel = self.cancelDown and 2 or 1
        return
    end
    self.cancel = 0
    if inside(x, y, LEFT_X, LEFT_Y, PAGE_W, PAGE_H) then self.hover = overSpell(x, y) end
end

function S:mousepressed(px, py, button)
    local x, y = UI.toVirtual(px, py)
    if inside(x, y, CANCEL_X, CANCEL_Y, CANCEL_W, CANCEL_W) then
        self.cancelDown, self.cancel = true, 2
    elseif inside(x, y, ARROW_L[1], ARROW_L[2], ARROW_W, ARROW_H) then self:turn(-1)
    elseif inside(x, y, ARROW_R[1], ARROW_R[2], ARROW_W, ARROW_H) then self:turn(1)
    else
        local i = overSpell(x, y)
        local hero = self:hero()
        -- FUN_00570510: only a known spell the hero has the mana for can be picked
        if i and hero and hero.h.spells[self.sphere * 10 + i]
            and (hero.h.mana or 0) >= spells.cost(hero, self.sphere * 10 + i) then
            local id = self.sphere * 10 + i
            local battle = self.battle
            screens.pop()
            battle.hud:castSpell(id)
        end
    end
end

function S:mousereleased(px, py)
    local x, y = UI.toVirtual(px, py)
    if self.cancelDown and inside(x, y, CANCEL_X, CANCEL_Y, CANCEL_W, CANCEL_W) then
        screens.pop()
        return
    end
    self.cancelDown = false
    self.cancel = inside(x, y, CANCEL_X, CANCEL_Y, CANCEL_W, CANCEL_W) and 1 or 0
end

-- Keys -------------------------------------------------------------------------------

function S:keypressed(key)
    local hero = self:hero()
    local f = key:match("^f(%d+)$")
    if f and tonumber(f) <= heroMod.SHORTCUTS then
        local id = self.hover and self.sphere * 10 + self.hover
        if id and hero and hero.h.spells[id] then hero.h:setShortcut(tonumber(f) --[[@as integer]], id) end
        return
    end
    if key == "escape" then screens.pop() return end
    for sph = 0, spells.SPHERES - 1 do
        if keymap.is("sphere" .. sph, key) then
            if self:knows(sph) then self.sphere, lastSphere, self.hover = sph, sph, nil end
            return
        end
    end
    if love.timer.getTime() > self.opened + OPEN_DELAY then
        local n = tonumber(key) or tonumber((key:gsub("^kp", "")))
        if n and n >= 0 and n <= 9 then
            local i = n == 0 and 9 or n - 1
            local id = self.sphere * 10 + i
            -- FUN_00570200: a living hero, a legal spell and enough mana
            if hero and hero.h.spells[id] and (hero.h.mana or 0) >= spells.cost(hero, id) then
                local battle = self.battle
                screens.pop()
                battle.hud:castSpell(id)
            end
        end
    end
end

-- Drawing ----------------------------------------------------------------------------

-- The description split into at most four lines that fit a page (FUN_0056f700).
---@param id integer
---@return string[]
function S:lines(id)
    local l = self.wrapped[id]
    if not l then
        local _, f = fonts.get(FONT_BLACK)
        ---@cast f -nil
        local _, wrapped = f:getWrap(spells.desc(id), PAGE_W - 25)
        l = {}
        for i = 1, math.min(4, #wrapped) do l[i] = wrapped[i]:gsub("%s+$", "") end
        self.wrapped[id] = l
    end
    return l
end

local function centred(font, s, cx, y)
    fonts.print(font, s, cx - 150, y, "center", 300)
end

function S:draw()
    local hero = self:hero()
    if not hero or not hero.h then return end
    local h = hero.h --[[@as Hero]]
    UI.begin()
    local set = anims.get("EMDS")
    if set then set:drawCell(0, 0, 0, BX, BY) end
    local cancel = anims.get("EMDC")
    if cancel then cancel:drawCell(0, self.cancel, 0, BX + CANCEL_X, BY + CANCEL_Y) end

    local mana, skill = math.floor(h.mana or 0), spells.castSkill(h, self.sphere)
    centred(FONT_SMALL, str("Game.txt", "0865", "Mana"), BX + ORB_X, BY + ORB_Y - 22)
    centred(FONT_MEDIUM, ("%d/%d"):format(mana, h.mod.mana or 0), BX + ORB_X, BY + ORB_Y)
    centred(FONT_SMALL, str("Game.txt", "0866", "Skill"), BX + STAFF_X, BY + STAFF_Y - 22)
    centred(FONT_MEDIUM, ("%+d"):format(skill), BX + STAFF_X, BY + STAFF_Y)
    centred(FONT_LARGE, str("Spells.txt", "SPELL_NAME_PLURAL_" .. self.sphere, spells.SPHERE_NAMES[self.sphere]),
        BX + SPHERE_X, BY + SPHERE_Y)

    local icons = anims.get("EMDI")
    for i = 0, 9 do
        local id = self.sphere * 10 + i
        local known = h.spells[id]
        local x, y = BX + LEFT_X + 2, BY + LEFT_Y + 4 + i * ROW_H
        if icons then
            local rec = require("src.content").sphere:bySlot(self.sphere)
            icons:drawCell(0, 1, known and (rec and rec.icon or 12) or 13, x, y)       -- cell 13 is the grey one
            icons:drawCell(0, 0, i, x, y)
        end
        local font = FONT_GREY
        if known and mana >= spells.cost(hero, id) then font = i == self.hover and FONT_RED or FONT_BLACK end
        fonts.print(font, spells.name(id), BX + LEFT_X + 28, BY + LEFT_Y + 2 + i * ROW_H)
    end

    if self.hover then self:drawInfo(hero, self.sphere * 10 + self.hover) end
    UI.finish()
end

-- Right page: cost, description, the chance for each success level and the hot key.
---@param hero Unit
---@param id integer
function S:drawInfo(hero, id)
    local h = hero.h --[[@as Hero]]   -- (draw only shows a hero with its progression)
    local cx, y = BX + RIGHT_X + math.floor(PAGE_W / 2) - 9, BY + LEFT_Y
    centred(FONT_GREY, str("Spells.txt", "SPELL_DLG_TEXT_12", "%d Mana"):format(spells.cost(hero, id)), cx, y + 9)
    for i, line in ipairs(self:lines(id)) do centred(FONT_GREY, line, cx, y + 16 + i * 18) end
    if not h.spells[id] then return end
    local chance = str("Spells.txt", "SPELL_DLG_TEXT_13", "Chance to cast (level %d): %d%%")
    local level, pct = spells.castLevel(h, id), spells.chance(hero, id)
    centred(FONT_GREY, chance:format(level, pct), cx, y + 120)
    for row = 1, 3 do
        if pct >= 100 then break end
        level, pct = level - 1, math.min(pct + CHANCE_PENALTY, 100)
        if level >= 1 then centred(FONT_GREY, chance:format(level, pct), cx, y + 120 + row * 18) end
    end
    local key = h:shortcutOf(id)
    if key then centred(FONT_GREY, str("Spells.txt", "SPELL_HOTKEY_TEXT_0", "(F%d )"):format(key), cx, y + 200) end
end

return S
