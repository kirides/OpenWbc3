-- Main menu (SCR_STARTUP + PNL_MAINMENU from War4Int.xci).
local screens = require("src.core.screens")
local UI = require("src.ui.interface")
local music = require("src.audio.music")
local fonts = require("src.ui.fonts")
local l10n = require("src.game.l10n")

---@class MainMenuScreen: Screen
---@field panel Panel                PNL_MAINMENU
---@field fx MenuEffects             the entries' hover effect (ui/menueffect.lua)
---@field notice { text: string, t: number }?   a short message under the menu
---@field showTip boolean?           the first start: the tip of the day may follow (set by boot.lua)
---@field box MsgBox?                a message box over the menu
local S = {}
S.helpId = 0          -- screen help (src/screens/screenhelp.lua)

local VERSION = "openwbc3 0.1"

function S:enter()
    self.notice = nil
    self.panel = UI.panel("PNL_MAINMENU", {
        x = 0, y = 0,
        onButton = function(name) self:button(name) end,
        onFocus = function(name)
            self.fx:focus(name, function(n) return UI.text(0, n) end, love.timer.getTime())
        end,
    }) --[[@as Panel]]
    self.fx = require("src.ui.menueffect").new()
    self.panel:setString("STR_SMALL80", VERSION)
    self.panel:hide("IM_MAINMENU_MESSAGE")
    self.panel:hide("IM_MAINMENUEFFECT")
    self.panel:hide("IM_ESRB_LOGO")
    music.play("intro")
    if self.showTip then
        self.showTip = false
        -- the first start shows the main menu's screen help (pushed by screens.push); the tip of the day only
        -- when there was no help to show, as in the original (FUN_0041d2c0 opens the tip FUN_00453e30 only then)
        if require("src.core.config").get("help", "screen00", false) then require("src.screens.tip").open() end
    end
end

function S:resume()
    music.play("intro")
end

-- A message box over the menu (what a booted player sees after he was sent back here): the generic box of ui/msgbox.lua.
---@param cfg MsgBoxConfig
function S:message(cfg)
    local inner = cfg.onResult
    cfg.onResult = function(yes)
        self.box = nil
        if inner then inner(yes) end
    end
    self.box = require("src.ui.msgbox").new(cfg)
end

---@param name string
function S:button(name)
    if name == "BUTT_MM_SINGLEPLAYER" then
        screens.push(require("src.screens.heroselect"), function()
            screens.push(require("src.screens.skirmish"))
        end)
    elseif name == "BUTT_MM_CAMPAIGN" then
        screens.push(require("src.screens.heroselect"), function(hero)
            screens.push(require("src.screens.campaignmap"), hero)
        end)
    elseif name == "BUTT_MM_TUTORIAL" then
        if not require("src.game.tutorial").start() then
            self.notice = { text = l10n.own("Tutorial scenario not found"), t = love.timer.getTime() }
        end
    elseif name == "BUTT_MM_MULTIPLAYER" then
        screens.push(require("src.screens.heroselect"), function(hero)
            screens.push(require("src.screens.multiplayer"), hero)
        end)
    elseif name == "BUTT_MM_EDITOR" then
        screens.push(require("src.screens.editor"))
    elseif name == "BUTT_MM_OPTIONS" then
        screens.push(require("src.screens.options"))
    elseif name == "BUTT_MM_QUIT" then
        love.event.quit()
    else
        self.notice = { text = l10n.own("Not implemented yet"), t = love.timer.getTime() }
    end
end

function S:update(dt)
    music.update()
    self.fx:update(love.timer.getTime())
end

function S:draw()
    UI.begin()
    UI.drawScreen("SCR_STARTUP")
    self.panel:draw()
    self.fx:draw(love.timer.getTime())
    if self.notice and love.timer.getTime() - self.notice.t < 2 then
        fonts.print(1, self.notice.text, 0, 520, "center", 800)
    end
    -- the mod manager (openwbc3's own, not in the original): a small link in the corner
    do
        local n = #require("src.content.mods").loaded()
        local vx, vy = UI.toVirtual(love.mouse.getPosition())
        local over = vx >= 100 and vx < 200 and vy >= 566 and vy < 594
        fonts.print(5, n > 0 and ("Mods (%d)"):format(n) or "Mods", 100, 570, "left", 100, over and 1 or 0.7)
    end
    if self.box then self.box:draw() end
    UI.finish()
end

function S:mousemoved(x, y)
    if self.box then return self.box:mousemoved(UI.toVirtual(x, y)) end
    self.panel:mousemoved(UI.toVirtual(x, y))
end

function S:mousepressed(x, y, b)
    local vx, vy = UI.toVirtual(x, y)
    if self.box then return self.box:mousepressed(vx, vy, b) end
    if b == 1 and vx >= 100 and vx < 200 and vy >= 566 and vy < 594 then
        screens.push(require("src.screens.mods"))
        return
    end
    self.panel:mousepressed(vx, vy, b)
end

function S:mousereleased(x, y, b)
    local vx, vy = UI.toVirtual(x, y)
    if self.box then return self.box:mousereleased(vx, vy, b) end
    self.panel:mousereleased(vx, vy, b)
end

-- Dev: `--show mainmenu:hover` starts the hover effect of every entry (for screenshots).
function S:dev(sub)
    if sub == "hover" then
        local now = love.timer.getTime()
        for name in pairs(require("src.ui.menueffect").ENTRIES) do
            self.fx:focus(name, function(n) return UI.text(0, n) end, now)
        end
    end
end

function S:keypressed(key)
    if self.box then return self.box:keypressed(key) end
    if key == "escape" then love.event.quit() end
    if key == "l" then screens.push(require("src.screens.saveslots"), "load") end
    if key == "s" or key == "return" then self:button("BUTT_MM_SINGLEPLAYER") end
end

return S
