-- Tip of the day (1.04: opener FUN_00453e30, tip pick FUN_00454110): PNL_TIPOFTHEDAY with a random tip of
-- <language>/TipOfTheDay.xml, wrapped to 280 px over up to five lines, a checkbox to switch the tips off (stored as
-- [game] tips in openwbc3.ini) and Done. Shown once when the main menu first opens, if tips are on.
local screens = require("src.core.screens")
local UI = require("src.ui.interface")
local fonts = require("src.ui.fonts")
local widgets = require("src.ui.widgets")
local xml = require("src.core.xml")
local fs = require("src.core.fs")
local config = require("src.core.config")
local text = require("src.core.text")

---@class TipScreen: Screen
---@field panel Panel                PNL_TIPOFTHEDAY
---@field check PanelItem?           the "show tips" check box
local S = { overlay = true }
local WRAP_W, MAX_LINES = 280, 5

local function tips()
    local data = fs.read(config.gamedir .. "/" .. config.language .. "/TipOfTheDay.xml")
        or fs.read(config.gamedir .. "/English/TipOfTheDay.xml")
    local out = {}
    if not data then return out end
    local function walk(n)
        if n.tag == "Tip" then out[#out + 1] = (n.text or ""):gsub("^%s+", ""):gsub("%s+$", "") end
        for _, c in ipairs(n.children) do walk(c) end
    end
    walk(xml.parse(text.fromCP1252(data)))
    return out
end

---@return boolean
function S.enabled() return config.get("game", "tips", true) end

-- Opens a random tip when tips are on; returns whether it did.
---@return boolean opened
function S.open()
    if not S.enabled() then return false end
    screens.push(S)
    return true
end

---@param index integer? the tip (else a random one)
function S:enter(index)
    local list = tips()
    local tip = list[index or (#list > 0 and math.random(#list) or 1)] or ""
    self.panel = UI.panel("PNL_TIPOFTHEDAY", { x = 0, y = 0, onButton = function(name) self:button(name) end }) --[[@as Panel]]
    local lines = widgets.wrap(UI.ui.objByName["STR_PARCHSMALL_L400"].font, tip, WRAP_W)
    local slots = self.panel:all("STR_PARCHSMALL_L400")
    for i, it in ipairs(slots) do
        self.panel.itemStrings[it] = lines[i] or ""
        self.panel.align[it] = "center"
    end
    local title = self.panel:find("STR_LARGE400") --[[@as PanelItem]]
    self.panel.itemStrings[title] = UI.text(312, 1)
    self.panel.align[title] = "center"
    self.check = self.panel:find("BUTT_TIPOFTHEDAY")
end

function S:button(name)
    if name == "BUTT_DONE_180" then screens.pop()
    elseif name == "BUTT_TIPOFTHEDAY" then
        config.set("game", "tips", not S.enabled())
        config.save()
    end
end

function S:draw()
    UI.begin()
    self.panel:draw()
    -- the checkbox state: the original's skull art (CheckBox.bmp, BM_CHECKBOX). Eight rows of 17 px:
    -- unchecked (normal / hover / pressed / disabled) then checked (normal = bright skull / hover =
    -- brighter ring / pressed = dim skull / disabled). So the row is (checked and 4 or 0) + hover.
    local it = self.check
    if it then
        local img = UI.bitmapByName("BM_CHECKBOX")
        if img then
            local x, y = self.panel.x + it.e.x, self.panel.y + it.e.y
            local mx, my = UI.toVirtual(love.mouse.getPosition())
            local hover = mx >= x and mx < x + it.ob.w and my >= y and my < y + it.ob.h
            local row = (S.enabled() and 4 or 0) + (hover and 1 or 0)
            local h = it.ob.h
            local q = love.graphics.newQuad(0, row * h, img:getWidth(), h, img:getDimensions())
            love.graphics.draw(img, q, x, y)
        end
    end
    UI.finish()
end

function S:mousemoved(x, y) self.panel:mousemoved(UI.toVirtual(x, y)) end
function S:mousepressed(x, y, b) local vx, vy = UI.toVirtual(x, y) self.panel:mousepressed(vx, vy, b) end
function S:mousereleased(x, y, b) local vx, vy = UI.toVirtual(x, y) self.panel:mousereleased(vx, vy, b) end
function S:keypressed(key) if key == "escape" or key == "return" then screens.pop() end end

return S
