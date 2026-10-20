-- The campaign's mercenary selection (PNL_CAMPAIGN_SELECTMERCENARY; the 1.04 binary: `FUN_005a5040` opens panel 373 at
-- (52, 58), `FUN_005a51a0` sets the buttons and texts, `FUN_005a5320` draws the two company slots, the handler at
-- 0x005a5110 toggles a slot with BUTT_CAMPAIGN_HIRETHEM and copies the choice to the selection flags on Done). It opens
-- over the army setup screen of a campaign battle whenever a hired company waits in one of the two slots: each slot
-- shows the company's picture (the strip BM_CAMPAIGN_MERCENARIES, 90 x 110 per race), its name and its troops; an
-- unselected company is greyed out (the black BM_MERCENARY_GRAYOUT over the picture, level 12), a selected one says
-- "Selected for this battle"; the button below it reads Select / Deselect. Done closes; the companies that were
-- selected join the battle and are disbanded, the others keep their slot. BUTT_CAMPAIGN_DISBANDMERCS and the
-- BUTT_CAMPAIGN_SELECTMERC areas of the panel are never activated by the 1.04 binary, so they are not shown. Own:
-- the grey-out opacity (the original's level 12 of its 16 steps, read as three quarters).
--
--   screens.push(require("src.screens.campaignmercs"), { companies = { [1] = <mercenary>, [2] = <mercenary> or nil },
--       onDone = function(selected) end })     -- selected: slot -> true
local screens = require("src.core.screens")
local UI = require("src.ui.interface")
local fonts = require("src.ui.fonts")

---@class CampaignMercsConfig
---@field companies table<integer, table> slot 1 / 2 -> mercenary company (campaigndata) or nil
---@field onDone fun(selected: table<integer, true>)?

---@class CampaignMercsScreen: Screen
---@field cfg CampaignMercsConfig
---@field selected table<integer, true> slot -> selected for this battle
---@field panel Panel
---@field buttons PanelItem[]        BUTT_CAMPAIGN_HIRETHEM of the two slots
---@field image PanelItem?           where the slots are drawn
---@field pics table<integer, love.Quad>? race -> picture of BM_CAMPAIGN_MERCENARIES
---@field grayQuad love.Quad?
local S = { overlay = true }

local SLOT_DY = 170                    -- the second slot sits this far below the first (the drawing code's i * 170)
local FONT_NAME, FONT_UNIT, FONT_SELECTED, FONT_EMPTY = 2, 34, 42, 36

local function T(sub, fallback) return UI.text(325, sub) or fallback end

---@param cfg CampaignMercsConfig?
function S:enter(cfg)
    cfg = cfg or self:sample()
    self.cfg = cfg
    self.selected = {}
    local p = UI.panel("PNL_CAMPAIGN_SELECTMERCENARY", { x = 52, y = 58, onButton = function(name, it) self:button(name, it) end })
    ---@cast p -nil
    self.panel = p
    p:hide("BUTT_CAMPAIGN_SELECTMERC")
    p:hide("BUTT_CAMPAIGN_DISBANDMERCS")
    local heading = p:find("STR_PARCHLARGEH_L400")
    ---@cast heading -nil
    p.itemStrings[heading] = T(0, "Select Mercenaries")
    p.align[heading] = "center"
    local lines = p:all("STR_SMALL_450")
    p.itemStrings[lines[1]] = T(3, "Click on the mercenaries to select or deselect them for this battle.")
    p.itemStrings[lines[2]] = ""
    p.align[lines[1]], p.align[lines[2]] = "center", "center"
    self.buttons = p:all("BUTT_CAMPAIGN_HIRETHEM")
    self.image = p:find("IM_CAMPAIGN_SELECTMERC")
    p:setOwnerDraw(self.image, function(x, y) self:drawSlots(x, y) end)
    self:refresh()
end

-- A sample for --show campaignmercs.
---@return CampaignMercsConfig
function S:sample()
    local D = require("src.game.campaigndata").load()
    local list = {}
    for id, m in pairs(D.mercenaries) do list[#list + 1] = id end
    table.sort(list)
    return { companies = { D.mercenaries[list[3]], D.mercenaries[list[12]] } }
end

function S:refresh()
    for i, b in ipairs(self.buttons) do
        local has = self.cfg.companies[i] ~= nil
        self.panel:hideItem(b, not has)
        self.panel.itemStrings[b] = self.selected[i] and T(6, "Deselect") or T(5, "Select")
    end
end

function S:button(name, it)
    if name == "BUTT_CAMPAIGN_HIRETHEM" then
        for i, b in ipairs(self.buttons) do
            if b == it and self.cfg.companies[i] then
                self.selected[i] = not self.selected[i] or nil
                self:refresh()
            end
        end
    elseif name == "BUTT_DONE_180" then
        screens.pop()
        if self.cfg.onDone then self.cfg.onDone(self.selected) end
    end
end

function S:drawSlots(px, py)
    local g = love.graphics
    local pics = UI.bitmapByName("BM_CAMPAIGN_MERCENARIES")
    local gray = UI.bitmapByName("BM_MERCENARY_GRAYOUT")
    for i = 1, 2 do
        local dy = (i - 1) * SLOT_DY
        local m = self.cfg.companies[i]
        if m then
            if pics then
                self.pics = self.pics or {}
                local q = self.pics[m.race]
                if not q then
                    q = g.newQuad(m.race * 90, 0, 90, 110, pics:getDimensions())
                    self.pics[m.race] = q
                end
                g.setColor(1, 1, 1)
                g.draw(pics, q, px + 140, py + 96 + dy)
            end
            fonts.print(FONT_NAME, m.name or "", px + 236, py + 101 + dy)
            for k, u in ipairs(m.units) do
                fonts.print(FONT_UNIT, u.text or u.name or "", px + 236, py + 122 + dy + (k - 1) * 16)
            end
            if self.selected[i] then
                fonts.print(FONT_SELECTED, T(4, "Selected for this battle"), px + 236, py + 189 + dy)
            elseif gray then
                if not self.grayQuad then self.grayQuad = g.newQuad(0, 0, 415, 113, gray:getDimensions()) end
                g.setColor(1, 1, 1, 0.75)
                g.draw(gray, self.grayQuad, px + 140, py + 96 + dy)
                g.setColor(1, 1, 1)
            end
        else
            -- an empty slot (TXT_CAMPAIGN_MERCENARIES2 2), centred on the screen
            fonts.print(FONT_EMPTY, UI.text(323, 2) or "Empty", 0, py + 132 + dy, "center", 800)
        end
    end
end

function S:update() require("src.audio.music").update() end

function S:draw()
    UI.begin()
    self.panel:draw()
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

-- developer aid: --show campaignmercs[:one|:picked]
function S:dev(sub)
    local cfg = self:sample()
    if sub == "one" or sub == "picked" then cfg.companies[2] = nil end
    self:enter(cfg)
    if sub == "picked" then self:button("BUTT_CAMPAIGN_HIRETHEM", self.buttons[1]) end
end

return S
