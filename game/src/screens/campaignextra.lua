-- "Extra army points" of the campaign (PNL_EXTRA_APS; the 1.04 binary:
-- `FUN_005a8330` opens panel 11 at (120, 135), `FUN_005a8420` greys the options, `FUN_005a8490` sets the texts,
-- `FUN_005a86e0` buys: option 1 = 4 points for 10 crowns, option 2 = 10 points for 30 crowns). It opens over the army
-- setup screen of a campaign battle when the hero has 10 crowns or more: a description, the points the battle gives, the
-- crowns the hero has, three radio buttons (nothing / 4 points for 10 crowns / 10 points for 30 crowns, the last one
-- greyed below 30 crowns) and Continue; a note says when the battle allows no buildings (techLevel 0).
--
--   screens.push(require("src.screens.campaignextra"), { points = 10, crowns = 45, techLevel = 1,
--       onDone = function(option) end })      -- option 0 / 1 / 2, called after the dialog is closed
local screens = require("src.core.screens")
local UI = require("src.ui.interface")
local strings = require("src.game.strings")
local run = require("src.game.campaignrun")

---@class CampaignExtraConfig
---@field points integer?            the battle's army setup points
---@field crowns integer?            the hero's crowns
---@field techLevel integer?         0: no buildings in this battle
---@field onDone fun(option: integer)? option 0 / 1 / 2

---@class CampaignExtraScreen: Screen
---@field cfg CampaignExtraConfig
---@field choice integer             the radio button picked, 0..2
---@field panel Panel
---@field radios PanelItem[]
---@field quad love.Quad?            the checked radio button's art
local S = { overlay = true }

local function G(n, fallback) return strings.get("Game.txt", ("%04d"):format(n)) or fallback end

---@param cfg CampaignExtraConfig?
function S:enter(cfg)
    cfg = cfg or { points = 10, crowns = 45, techLevel = 0 }         -- --show
    self.cfg = cfg
    self.choice = 0
    local p = UI.panel("PNL_EXTRA_APS", { x = 120, y = 135, onButton = function(name, it) self:button(name, it) end })
    ---@cast p -nil
    self.panel = p
    self.radios = p:all("BUTT_EXTRA_APS")
    local function centred(it, text)
        p.itemStrings[it] = text
        p.align[it] = "center"
    end
    local heading = p:find("STR_PARCHLARGEH_L400")
    centred(heading, G(706, "Extra Army Points"))
    local lines = p:all("STR_MEDIUMDLG_500")
    centred(lines[1], G(707, "You may buy extra army points for this battle."))
    local points, crowns = cfg.points or 0, cfg.crowns or 0
    centred(lines[2], (points == 1 and G(708, "You currently have +%d point.") or G(709, "You currently have %d points.")):format(points))
    centred(lines[3], (crowns == 1 and G(710, "You have %d crown.") or G(711, "You have %d crowns.")):format(crowns))
    centred(p:find("STR_SMALL500"), (cfg.techLevel or 1) == 0 and G(715, "(Please note: no buildings in this battle.)") or "")
    local labels = p:all("STR_MEDIUMDLG_300")
    for i = 1, 3 do p.itemStrings[labels[i]] = G(711 + i, "") end
    p:setItemDisabled(self.radios[3], crowns < run.EXTRA_POINTS[2].crowns)
end

function S:button(name, it)
    if name == "BUTT_EXTRA_APS" then
        for i, r in ipairs(self.radios) do
            if r == it then self.choice = i - 1 end
        end
    elseif name == "BUTT_CONTINUE_180" then
        screens.pop()
        if self.cfg.onDone then self.cfg.onDone(self.choice) end
    end
end

function S:update() require("src.audio.music").update() end

function S:draw()
    UI.begin()
    self.panel:draw()
    -- the selected radio button: the filled ring of CheckBox.bmp (row 4), as in the options screen
    local img = UI.bitmapByName("BM_CHECKBOX")
    local it = self.radios[self.choice + 1]
    if img and it then
        self.quad = self.quad or love.graphics.newQuad(0, 4 * it.ob.h, img:getWidth(), it.ob.h, img:getDimensions())
        love.graphics.draw(img, self.quad, self.panel.x + it.e.x, self.panel.y + it.e.y)
    end
    UI.finish()
end

function S:mousemoved(x, y) self.panel:mousemoved(UI.toVirtual(x, y)) end

function S:mousepressed(x, y, button)
    local vx, vy = UI.toVirtual(x, y)
    self.panel:mousepressed(vx, vy, button)
end

function S:mousereleased(x, y, button)
    local vx, vy = UI.toVirtual(x, y)
    self.panel:mousereleased(vx, vy, button)
end

-- developer aid: --show campaignextra[:poor]
function S:dev(sub)
    self:enter({ points = 12, crowns = sub == "poor" and 14 or 45, techLevel = sub == "nobuilding" and 0 or 1 })
end

return S
