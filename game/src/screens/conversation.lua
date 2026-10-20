-- Conversation box over the battle (scenario .nis files, see src/game/conversation.lua): the speaker's
-- portrait, name and one message at a time; a click, Enter or Space shows the next one, Esc skips the rest.
-- Each speaker has a fixed spot on the screen, the player's hero in blue, everybody else in orange.
-- enter(battle, conv, who): who = { race, class, name, portrait } describes the player's hero.
local screens = require("src.core.screens")
local UI = require("src.ui.interface")
local fonts = require("src.ui.fonts")
local widgets = require("src.ui.widgets")
local portraits = require("src.ui.portraits")
local sound = require("src.audio.sound")
local cursor = require("src.ui.cursor")
local conversation = require("src.game.conversation")

---@class ConversationScreen: Screen
---@field battle BattleScreen
---@field conv table                 the conversation (src/game/conversation.lua: messages, characters)
---@field who table                  the player's hero { race, class, name, portrait }
---@field shown table[]              the messages whose conditions hold, in order
---@field spots table<integer, number[]> character -> { x, y } of its box
---@field index integer              the message shown (index into shown)
---@field openedAt number            love.timer seconds
---@field speaker { name: string, portrait: integer } the current message's speaker
---@field current table?             the current message
---@field lines string[]             its wrapped text
---@field h number                   the box height
local S = { overlay = true }

local W, MIN_H, LINE_H = 400, 106, 17
local NAME_FONT, TEXT_FONT = 5, 14

---@param battle BattleScreen
---@param conv table
---@param who table
function S:enter(battle, conv, who)
    self.battle, self.conv, self.who = battle, conv, who
    self.shown = {}
    for _, m in ipairs(conv.messages) do
        if conversation.test(m.condition, who) then self.shown[#self.shown + 1] = m end
    end
    -- speaker spots: the hero top left, the others staggered below
    local n = 1
    for id in pairs(conv.characters) do n = math.max(n, id + 1) end
    self.spots = { [0] = { 20, 70 } }
    for i = 1, n - 1 do
        local px, py = self.spots[i - 1][1], self.spots[i - 1][2]
        self.spots[i] = { px < 50 and px + 50 or px - 50, py + math.min(math.floor(200 / n), 50) }
    end
    self.index = 0
    self.openedAt = love.timer.getTime()
    self:advance()
end

function S:leave()
    cursor.enable(true)
    self.battle:conversationDone(self.conv)
end

function S:advance()
    self.index = self.index + 1
    local m = self.shown[self.index]
    if not m then
        screens.pop()
        return
    end
    local who = self.who
    local c = m.character == 0 and { name = who.name or "", portrait = who.portrait or 0 }
        or self.conv.characters[m.character] or { name = "", portrait = 0 }
    self.speaker, self.current = c, m
    self.lines = widgets.wrap(TEXT_FONT, m.text, 290)
    self.h = math.max(MIN_H, 8 + 20 + #self.lines * LINE_H)
    sound.playFile(require("src.core.config").gamedir .. "/Data/Bing.WAV")
end

function S:draw()
    local g = love.graphics
    local m = self.current
    if not m then return end
    local spot = self.spots[m.character] or self.spots[0]
    local x, y, h = spot[1], spot[2], self.h
    UI.begin()
    g.setColor(0, 0, 0, 0.72)
    g.rectangle("fill", x, y, W, h)
    if m.character == 0 then g.setColor(0, 64 / 255, 128 / 255) else g.setColor(128 / 255, 64 / 255, 0) end
    g.rectangle("line", x + 1.5, y + 1.5, W - 3, h - 3)
    g.setColor(1, 1, 1)
    portraits.draw(self.speaker.portrait, x + 4, y + 4, 98, 98)
    fonts.print(NAME_FONT, self.speaker.name, x + 108, y + 2)
    for i, l in ipairs(self.lines) do fonts.print(TEXT_FONT, l, x + 108, y + 22 + (i - 1) * LINE_H) end
    UI.finish()
end

function S:mousepressed()
    if love.timer.getTime() - self.openedAt > 1 then self:advance() end
end

function S:keypressed(key)
    if key == "escape" then
        screens.pop()
    elseif key == "return" or key == "kpenter" or key == "space" then
        self:advance()
    end
end

return S
