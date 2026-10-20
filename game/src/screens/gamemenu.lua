-- In-battle menu (Esc): resume, hero, options, leave the battle.
local screens = require("src.core.screens")
local UI = require("src.ui.interface")
local music = require("src.audio.music")
local frame = require("src.ui.frame")

---@class GameMenuScreen: Screen
---@field battle BattleScreen
---@field mode "menu"|"confirm"|"resign"
---@field panel Panel
local S = { overlay = true }

local ENTRIES = {
    { id = "resume", label = "Resume" },
    { id = "hero", label = "Hero" },
    { id = "save", label = "Save Game" },
    { id = "load", label = "Load Game" },
    { id = "options", label = "Options" },
    { id = "resign", label = "Resign" },
    { id = "leave", label = "Leave Battle" },
}

---@param battle BattleScreen
function S:enter(battle)
    self.battle = battle
    self:build("menu")
end

---@param mode "menu"|"confirm"|"resign"
function S:build(mode)
    self.mode = mode
    -- no saving and loading in a network game or with the advanced Tournament mode (the game menu dialog FUN_00565670)
    local noSave = self.battle.net or self.battle.world.advanced.tournament
    local entries = {}
    for _, e in ipairs(ENTRIES) do
        if not (noSave and (e.id == "save" or e.id == "load")) then entries[#entries + 1] = e end
    end
    local step = #entries > 6 and 34 or 38
    local strings = require("src.game.strings")
    local p = UI.panel("PNL_OKAYCANCEL", { onButton = function(name) self:button(name) end })
    ---@cast p -nil
    self.panel = p
    local FX, FY, FW, FH = frame.X, frame.Y, frame.W, frame.H
    if mode == "menu" then
        frame.prepare(p, "Menu")
        -- Resume on top and Leave Battle at the bottom, each set off from the rest by half a button height
        local y = 82
        for i, e in ipairs(entries) do
            local it = p:add("BUTT_OKAY_180", FX + (FW - 180) / 2, FY + y, "MENU_" .. e.id)
            ---@cast it -nil
            p.itemStrings[it] = e.id == "resign" and strings.get("Game.txt", "0308") or e.label
            y = y + step
            if i == 1 or i == #entries - 1 then y = y + 18 end
        end
    else
        local resign = mode == "resign"
        frame.prepare(p, resign and strings.get("Game.txt", "0308") or "Leave the battle?")
        local text = p:all("STR_MEDIUM500")[1]
        frame.place(p, text, (FW - text.ob.w) / 2, 120)
        p.align[text] = "center"
        p.itemStrings[text] = resign and ((strings.get("Game.txt", "0313") or "") .. " " .. (strings.get("Game.txt", "0314") or ""))
            or "Your hero keeps its experience."
        local by = FH - 36 - 22
        local no = p:add("BUTT_CANCEL_180", FX + 40, FY + by, "LEAVE_NO")
        local yes = p:add("BUTT_OKAY_180", FX + FW - 40 - 180, FY + by, resign and "RESIGN_YES" or "LEAVE_YES")
        ---@cast no -nil
        ---@cast yes -nil
        p.itemStrings[no] = "Stay"
        p.itemStrings[yes] = resign and strings.get("Game.txt", "0308") or "Leave"
    end
end

function S:button(name)
    if name == "MENU_resume" then screens.pop()
    elseif name == "MENU_hero" then
        screens.pop()
        self.battle:openHero(1)
    elseif name == "MENU_save" then
        screens.push(require("src.screens.saveslots"), "save", self.battle)
    elseif name == "MENU_load" then
        screens.push(require("src.screens.saveslots"), "load", self.battle)
    elseif name == "MENU_options" then
        screens.push(require("src.screens.options"), true)
    elseif name == "MENU_leave" then self:build("confirm")
    elseif name == "MENU_resign" then self:build("resign")
    elseif name == "RESIGN_YES" then
        screens.pop()               -- this menu
        self.battle:resign()        -- kills the side or leaves, by the advanced option
    elseif name == "LEAVE_NO" then self:build("menu")
    elseif name == "LEAVE_YES" then
        screens.pop()               -- this menu
        screens.pop()               -- the battle
    end
end

function S:update() music.update() end

function S:draw()
    frame.dim()
    UI.begin()
    frame.draw()
    self.panel:draw()
    UI.finish()
end

function S:mousemoved(x, y)
    local vx, vy = UI.toVirtual(x, y)
    self.panel:mousemoved(vx, vy)
end

function S:mousepressed(x, y, b)
    local vx, vy = UI.toVirtual(x, y)
    self.panel:mousepressed(vx, vy, b)
end

function S:mousereleased(x, y, b)
    local vx, vy = UI.toVirtual(x, y)
    self.panel:mousereleased(vx, vy, b)
end

function S:keypressed(key)
    if key == "escape" then
        if self.mode == "confirm" or self.mode == "resign" then self:build("menu") else screens.pop() end
    end
end

return S
