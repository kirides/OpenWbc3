-- Shrine / mausoleum quest dialog: enter(battle, info, hero, building) with info from quests.visit().
-- Drawn like the original's quest dialog (the hit areas, the modes and the keys were checked in the 1.04 binary:
-- constructor FUN_0056a150, mouse down / move / up FUN_0056a6f0 / FUN_0056a480 / FUN_0056a840, keys FUN_0056abe0): the
-- 430x417 sprite EMDQ at (185, 24) of the 800x600 layout, the 30x30 cancel button EMDC (79, 345), the 180x36 button
-- EMDE (156, 341) with the Accept text (Game.txt 0326) in font 5 centred 12 px down (13 when pressed), the quest
-- giver's 128x160 picture at (78, 75), the title in font 24 centred on x 213, y 28, up to 13 text rows in font 19 (rows
-- 0..8 at x 217, 142 wide, y 72 + 20 * row; rows 9..12 at x 70, 290 wide; row 9 moves back to x 217 when it is narrow)
-- and the "your count" line (Game.txt 0325) in font 19 centred on x 216, y 317. EMDC and EMDE are sheets of cells for
-- normal / hover / pressed.
-- The original has four modes: a new quest and a resource quest that can be paid right away (both with the Accept button, Enter
-- accepts), one already accepted at this shrine (only the cancel button) and one finished there: no button at all, a click
-- anywhere or the cancel button or Enter hands the quest in, Escape only closes. There is no OKAY / Not now / Close text.
-- A kind 4 quest ("provide an answer", mode "answer") has no Accept button but an entry box where the answer is typed:
-- printable characters (ASCII 32..127 and the accented letters the original lists) up to 15, Backspace deletes, Enter
-- tries the answer, Escape closes. A wrong answer closes the dialog and shows Game.txt 0327 for 3 s; a right one turns the
-- dialog into the "quest complete" page. The entry box is an outline in (220, 180, 80) where the Accept button is, its
-- hint (Game.txt 0358, font 2) sits under it on a 50 % black strip, and the cursor blinks every 250 ms.
-- Accept and complete are commands (`quest`, see commands.lua), the dialog only asks. Not like the original: the dialog is
-- modal here (the original lets clicks outside it reach the game and the battle goes on); it closes by itself when the
-- hero dies or the shrine loses its quest (the original's dialog notification and timer methods; not traced in the 1.04 binary yet).
local screens = require("src.core.screens")
local UI = require("src.ui.interface")
local fonts = require("src.ui.fonts")
local anims = require("src.gfx.anims")
local quests = require("src.game.quests")
local strings = require("src.game.strings")
local sound = require("src.audio.sound")
local utf8 = require("utf8")

---@class QuestDialogScreen: Screen
---@field battle BattleScreen
---@field info table                 quests.visit()'s answer: mode, title, text, pic, hint, done
---@field hero Unit                  the visiting hero
---@field building Building          the shrine / mausoleum
---@field answer string              the answer typed in (mode "answer")
---@field answered boolean           the answer was right
---@field down "cancel"|"okay"|nil   the button pressed
---@field lines { text: string, x: number, y: number }[]?   the text rows, laid out once
---@field opened number              love.timer time it opened (cursor blink)
local S = { overlay = true }

local DX, DY, DW, DH = 185, 24, 430, 417                -- place and size on the 800x600 layout
local CANCEL_X, CANCEL_Y, CANCEL_W = 79, 345, 30
local OKAY_X, OKAY_Y, OKAY_W, OKAY_H = 156, 341, 180, 36
local PICTURE_X, PICTURE_Y = 78, 75
local HEADING_X, HEADING_Y = 213, 28
local REPORT_X, REPORT_Y = 216, 317
local ROW_Y0, ROW_STEP, ROWS, WIDE_ROW = 72, 20, 13, 9
local FONT_SMALL, FONT_MEDIUM, FONT_DIALOG, FONT_DIALOG_LARGE = 2, 5, 19, 24

---@param battle BattleScreen
---@param info table
---@param hero Unit
---@param building Building
function S:enter(battle, info, hero, building)
    self.battle, self.info, self.hero, self.building = battle, info, hero, building
    self.answer, self.answered = "", false
    self.down = nil
    self.lines = nil
    self.opened = love.timer.getTime()
    sound.play("Assets/SoundFX.xcr", "NewClick.wav")
end

local function inside(x, y, rx, ry, w, h) return x >= DX + rx and x < DX + rx + w and y >= DY + ry and y < DY + ry + h end

function S:hasAccept() local m = self.info.mode return m == "new" or m == "instant" end

function S:overCancel(x, y) return inside(x, y, CANCEL_X, CANCEL_Y, CANCEL_W, CANCEL_W) end

function S:overOkay(x, y) return self:hasAccept() and inside(x, y, OKAY_X, OKAY_Y, OKAY_W, OKAY_H) end

-- Accept (a new or instant quest) or hand in (a finished one) through the command, then close.
---@param op "accept"|"complete"
function S:finish(op)
    self.battle:issue({ t = "quest", op = op, bid = self.building.id, hero = self.hero.id,
                        answer = self.answered and self.answer or nil })
    screens.pop()
end

-- The text rows (the original's line splitter FUN_0044ef60: words are added while the row stays within its width, a row always takes its
-- first word), each with its position.
function S:rows()
    if self.lines then return self.lines end
    local _, font = fonts.get(FONT_DIALOG)
    local words = {}
    for w in (self.info.text or ""):gmatch("%S+") do words[#words + 1] = w end
    local rows, i = {}, 1
    while i <= #words and #rows < ROWS do
        local row = #rows
        local width = row < WIDE_ROW and 142 or 290
        local line = words[i]
        i = i + 1
        while i <= #words and font and font:getWidth(line .. " " .. words[i]) <= width do
            line = line .. " " .. words[i]
            i = i + 1
        end
        local x = row < WIDE_ROW and 217 or 70
        if row == WIDE_ROW and font and font:getWidth(line) <= 142 then x = 217 end
        rows[#rows + 1] = { text = line, x = x, y = ROW_Y0 + row * ROW_STEP }
    end
    self.lines = rows
    return rows
end

function S:update(dt)
    -- the original closes the dialog when the hero is gone or the shrine no longer has the quest
    local b = self.building
    if not self.hero:alive() or b.hp <= 0 or not b.quest or b.quest.state ~= "held" then screens.pop() end
end

function S:draw()
    UI.begin()
    local g = love.graphics
    local mx, my = UI.toVirtual(love.mouse.getPosition())
    local bg = anims.get("EMDQ")
    if bg then
        bg:drawCell(0, 0, 0, DX, DY)
    else
        g.setColor(0.12, 0.05, 0.03, 0.97)
        g.rectangle("fill", DX, DY, DW, DH)
        g.setColor(1, 1, 1)
    end
    local cancel = anims.get("EMDC")
    if cancel then
        local state = 0
        if self:overCancel(mx, my) then state = self.down == "cancel" and 2 or 1 end
        cancel:drawCell(0, state, 0, DX + CANCEL_X, DY + CANCEL_Y)
    end
    local pic = quests.picture(self.info.pic)
    if pic then g.draw(pic, DX + PICTURE_X, DY + PICTURE_Y) end
    fonts.print(FONT_DIALOG_LARGE, self.info.title, DX + HEADING_X - 200, DY + HEADING_Y, "center", 400)
    for _, r in ipairs(self:rows()) do fonts.print(FONT_DIALOG, r.text, DX + r.x, DY + r.y) end
    if self.info.mode == "answer" then
        g.setColor(220 / 255, 180 / 255, 80 / 255)
        g.rectangle("line", DX + OKAY_X + 0.5, DY + OKAY_Y + 0.5, OKAY_W - 1, OKAY_H - 1)
        g.setColor(1, 1, 1)
        local on = (love.timer.getTime() - self.opened) % 0.5 < 0.25
        fonts.print(FONT_DIALOG, self.answer .. (on and "_" or ""), DX + OKAY_X + 4, DY + OKAY_Y + 12)
        local hint = strings.get("Game.txt", "0358") or "Type your answer, then press Enter"
        g.setColor(0, 0, 0, 0.5)
        g.rectangle("fill", DX + OKAY_X - 52, DY + OKAY_Y + OKAY_H + 1, fonts.width(FONT_SMALL, hint) + 16, 13)
        g.setColor(1, 1, 1)
        fonts.print(FONT_SMALL, hint, DX + OKAY_X - 48, DY + OKAY_Y + OKAY_H + 1)
    end
    if self.info.hint then
        fonts.print(FONT_DIALOG, self.info.hint, DX + REPORT_X - 200, DY + REPORT_Y, "center", 400)
    end
    if self:hasAccept() then
        local state = 0
        if self:overOkay(mx, my) then state = self.down == "okay" and 2 or 1 end
        local button = anims.get("EMDE")
        if button then button:drawCell(0, state, 0, DX + OKAY_X, DY + OKAY_Y) end
        local label = strings.get("Game.txt", "0326") or "I Accept"     -- both modes
        fonts.print(FONT_MEDIUM, label, DX + OKAY_X, DY + OKAY_Y + 12 + (state == 2 and 1 or 0), "center", OKAY_W)
    end
    UI.finish()
end

function S:mousepressed(px, py, button)
    if button ~= 1 then return end
    local x, y = UI.toVirtual(px, py)
    if self:overCancel(x, y) then
        self.down = "cancel"
    elseif self:overOkay(x, y) or self.info.mode == "complete" then
        self.down = "okay"           -- a finished quest is handed in by a click anywhere
    end
end

function S:mousereleased(px, py, button)
    if button ~= 1 then return end
    local x, y = UI.toVirtual(px, py)
    local down = self.down
    self.down = nil
    local complete = self.info.mode == "complete"
    if down == "cancel" and self:overCancel(x, y) then
        if complete then self:finish("complete") else screens.pop() end
    elseif down == "okay" and (complete or self:overOkay(x, y)) then
        self:finish(complete and "complete" or "accept")
    end
end

-- The characters the original's entry box takes: 32..127 and the accented letters it lists.
local ACCENTED = {}
for _, c in ipairs({ 0xfc, 0xe9, 0xe2, 0xe4, 0xe0, 0xe7, 0xea, 0xeb, 0xe8, 0xef, 0xee, 0xc4, 0xf4, 0xf6, 0xfb, 0xf9,
                     0xd6, 0xdc, 0xf1, 0xdf }) do ACCENTED[c] = true end

function S:textinput(t)
    if self.info.mode ~= "answer" then return end
    for _, c in utf8.codes(t) do
        if (c >= 32 and c <= 127 or ACCENTED[c]) and (utf8.len(self.answer) or 0) < quests.MAX_ANSWER then
            self.answer = self.answer .. utf8.char(c)
        end
    end
end

-- Tries the typed answer (FUN_0056b740).
function S:tryAnswer()
    local def = quests.def(self.building)
    if quests.rightAnswer(def, self.answer) then
        self.answered = true
        self.info.mode, self.info.text = "complete", self.info.done or self.info.text
        self.lines = nil
    else
        screens.pop()
        local text = strings.get("Game.txt", "0327")
        if text then self.battle:notify(text, 3) end
    end
end

function S:keypressed(key)
    local enter = key == "return" or key == "kpenter"
    if self.info.mode == "answer" then
        if key == "escape" then screens.pop()
        elseif key == "backspace" then
            local n = utf8.len(self.answer) or 0
            if n > 0 then self.answer = self.answer:sub(1, (utf8.offset(self.answer, n) or 1) - 1) end
        elseif enter and self.answer ~= "" then self:tryAnswer() end
        return
    end
    if key == "escape" then screens.pop()
    elseif enter then
        local mode = self.info.mode
        if mode == "new" or mode == "instant" then self:finish("accept")
        elseif mode == "complete" then self:finish("complete")
        else screens.pop() end
    end
end

function S:leave() end

return S
