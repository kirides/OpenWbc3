-- "Customize Your Hero" (PNL_CUSTOMIZEHERO), opened from the new-hero screen:
-- portrait and avatar (arrows), password, voice set and hero mode (drop-down lists). The changes go straight into
-- the hero being created, so both Cancel and Okay just close the screen, as in the original.
-- enter(hero): hero = { race, portrait, avatar, voice, password, heroMode }.
-- Not verified against the original: the password field shows its text unmasked, and the avatar walks at 10 frames
-- per second facing the original's direction 3.
local UI = require("src.ui.interface")
local fonts = require("src.ui.fonts")
local portraits = require("src.ui.portraits")
local anims = require("src.gfx.anims")
local sprite = require("src.formats.sprite")
local dropdown = require("src.ui.dropdown")
local sound = require("src.audio.sound")
local config = require("src.core.config")
local herocustom = require("src.game.herocustom")

---@class HeroCustomizeScreen: Screen
---@field hero table                 the hero being created { race, portrait, avatar, voice, password, heroMode, tournament }
---@field start number               love.timer seconds when opened (the avatar's walk)
---@field panel Panel?
---@field voiceButton PanelItem?
---@field modeButton PanelItem?
---@field portraitLeft PanelItem?
---@field portraitRight PanelItem?
---@field avatarLeft PanelItem?
---@field avatarRight PanelItem?
---@field editFont integer           the password's font
local S = { overlay = true }
S.helpId = 3          -- screen help (src/screens/screenhelp.lua)

local PASSWORD_LENGTH = 15          -- the original's field holds 16 bytes with the terminator
local AVATAR_X, AVATAR_Y = 500, 180 -- where the original blits the avatar (FUN_0054efa0)
local AVATAR_FACING, AVATAR_TEAM = 3, 0
local FRAME_RATE = 10

---@param hero table
function S:enter(hero)
    self.hero = hero
    self.start = love.timer.getTime()
    self:buildPanel()
end

function S:leave() dropdown.close() end

function S:buildPanel()
    local p = UI.panel("PNL_CUSTOMIZEHERO", { x = 0, y = 0, onButton = function(name, it) self:button(name, it) end })
    self.panel = p
    if not p then return end
    for _, n in ipairs({ "IM_PORTRAIT", "IM_UNIT", "IM_AVATAR" }) do p:hide(n) end     -- drawn by us
    for _, n in ipairs({ "BUTT_LEFT_20", "BUTT_RIGHT_20" }) do p:setString(n, "") end   -- arrows only
    p:setString("STR_LARGE400", UI.text(7, 0) or "Customize Your Hero")
    p.align[p:find("STR_LARGE400")] = "center"
    p:setTextAt("STR_MEDIUM220", 235, 73, UI.text(7, 1) or "Portrait")
    p:setTextAt("STR_MEDIUM220", 453, 73, UI.text(7, 2) or "Avatar")
    p:setTextAt("STR_MEDIUM220", 271, 249, UI.text(7, 3) or "Password (optional)")
    p:setTextAt("STR_MEDIUM220", 271, 319, UI.text(7, 4) or "Voice Set")
    p:setTextAt("STR_MEDIUM220", 271, 382, UI.text(7, 5) or "Mode")
    self.voiceButton = p:at("BUTT_OPTIONS_DROPLIST", 270, 340)
    self.modeButton = p:at("BUTT_OPTIONS_DROPLIST", 270, 400)
    -- the mode of a Tournament hero is fixed (the button state routine FUN_0054e790 greys the second
    -- list)
    p:setItemDisabled(self.modeButton, self.hero.tournament == true)
    p.align[self.voiceButton] = "left"
    p.align[self.modeButton] = "left"
    self.portraitLeft, self.avatarLeft = p:at("BUTT_LEFT_20", 213, 131), p:at("BUTT_LEFT_20", 431, 131)
    self.portraitRight, self.avatarRight = p:at("BUTT_RIGHT_20", 348, 131), p:at("BUTT_RIGHT_20", 567, 131)
    local ob = UI.ui.objByName.BUTT_OPTIONS_DROPLIST
    self.editFont = ob and ob.fonts and ob.fonts[1] or 5
end

local MODE_TEXT = { [0] = 0, 3 }                   -- TXT_HCRE_HEROMODE: Normal Mode, Ironman Mode
local MODE_DESC = { [0] = { 0, 1 }, { 6, 7 } }     -- TXT_HEROMODE_DESC lines

function S:playVoice(set)
    local def = herocustom.VOICE_SETS[set]
    if not def then return end
    local lang = config.voiceSuffix()
    local arch = ("Assets/Sides/%s%s.xcr"):format(def[2], lang)
    local name = def[1] .. "DeathBlow.wav"
    if sound.exists(arch, name) then sound.play(arch, name, { voice = true }) end
end

---@param name string
---@param it PanelItem?
function S:button(name, it)
    local h = self.hero
    if name == "BUTT_OKAY_200" or name == "BUTT_CANCEL_200" then
        require("src.core.screens").pop()
    elseif it == self.portraitLeft or it == self.portraitRight then
        h.portrait = herocustom.step(herocustom.PORTRAITS[h.race], h.portrait, it == self.portraitLeft and -1 or 1)
    elseif it == self.avatarLeft or it == self.avatarRight then
        h.avatar = herocustom.step(herocustom.AVATARS[h.race], h.avatar, it == self.avatarLeft and -1 or 1)
    elseif it == self.voiceButton then
        local sets, items = herocustom.voiceList(h.race), {}
        for _, v in ipairs(sets) do items[#items + 1] = herocustom.voiceName(v) end
        local mx, my = UI.toVirtual(love.mouse.getPosition())
        dropdown.open(items, mx, my, function(i)
            h.voice = sets[i]
            self:playVoice(h.voice)
        end)
    elseif it == self.modeButton then
        local items = { UI.text(234, MODE_TEXT[0]) or "Normal Mode", UI.text(234, MODE_TEXT[1]) or "Ironman Mode" }
        local mx, my = UI.toVirtual(love.mouse.getPosition())
        dropdown.open(items, mx, my, function(i) h.heroMode = i - 1 end)
    end
end

-- Mode description wrapped to the 200 pixel wide lines of the panel (at most five).
function S:describeMode(p)
    local ob = UI.ui.objByName.STR_SMALL200
    local d, f = fonts.get(ob.font)
    local lines = MODE_DESC[self.hero.heroMode] or MODE_DESC[0]
    local text = ("%s %s"):format(UI.text(235, lines[1]) or "", UI.text(235, lines[2]) or "")
    local wrapped = {}
    if f then
        local _, w = f:getWrap(text, 200)
        wrapped = w
    end
    for i = 0, 4 do p:setTextAt("STR_SMALL200", 280, 429 + i * 18, wrapped[i + 1] or "") end
end

function S:draw()
    local p, h = self.panel, self.hero
    UI.begin()
    if p then
        p.itemStrings[self.voiceButton] = herocustom.voiceName(h.voice)
        p.itemStrings[self.modeButton] = UI.text(234, MODE_TEXT[h.heroMode] or 0) or ""
        self:describeMode(p)
        p:draw()
    end
    local img = portraits.get(h.portrait)
    if img then
        local iw, ih = img:getDimensions()
        love.graphics.draw(img, 242, 101, 0, 98 / iw, 98 / ih)
    end
    local set = anims.get(herocustom.AVATAR_CODES[h.avatar] or "AHHX")
    if set then
        local frames = math.max(1, set:frames(sprite.ANIM.WALK))
        local frame = math.floor((love.timer.getTime() - self.start) * FRAME_RATE) % frames
        set:draw(sprite.ANIM.WALK, AVATAR_FACING, frame, AVATAR_X, AVATAR_Y, AVATAR_TEAM)
    end
    local caret = (math.floor(love.timer.getTime() * 2) % 2 == 0) and "|" or ""
    fonts.print(self.editFont, h.password .. caret, 284, 270 + fonts.middleY(self.editFont, 19))
    dropdown.draw()
    UI.finish()
end

function S:mousemoved(x, y)
    if self.panel then self.panel:mousemoved(UI.toVirtual(x, y)) end
end

function S:mousereleased(x, y, button)
    if not self.panel then return end
    local vx, vy = UI.toVirtual(x, y)
    self.panel:mousereleased(vx, vy, button)
end

function S:mousepressed(x, y, button)
    local vx, vy = UI.toVirtual(x, y)
    if dropdown.pressed(vx, vy) then return end
    if self.panel then self.panel:mousepressed(vx, vy, button) end
end

function S:textinput(t)
    if dropdown.isOpen() or t:match("%c") then return end
    local h = self.hero
    if #h.password < PASSWORD_LENGTH then h.password = (h.password .. t):sub(1, PASSWORD_LENGTH) end
end

function S:keypressed(key)
    if dropdown.isOpen() then
        if key == "escape" then dropdown.close() end
        return
    end
    if key == "backspace" then
        local off = require("utf8").offset(self.hero.password, -1)
        if off then self.hero.password = self.hero.password:sub(1, off - 1) end
    elseif key == "return" or key == "kpenter" or key == "escape" then
        require("src.core.screens").pop()
    end
end

return S
