-- Choose a computer player's AI script (PNL_SELECTAIFILE of the side selection screen, opened by right-clicking a
-- computer side; its event handler is at 0x004eea40 in the 1.04 binary): a list box with "None" first, then the
-- scripts for the side's race; OK takes the selection, Cancel leaves the side as it was. The original reaches this
-- list through the hero view panel (PNL_VIEWHERO, which also lets the host pick the AI hero's race, class and level);
-- openwbc3 opens it from the AI hero panel (aihero.lua) as the original does.
--
--   screens.push(require("src.screens.aifilelist"), { items = { "None", ... }, selected = 1, onDone = function(index) end })
local screens = require("src.core.screens")
local UI = require("src.ui.interface")
local listbox = require("src.ui.listbox")

---@class AIFileListConfig
---@field items string[]        "None" first, then the scripts
---@field selected integer?
---@field onDone fun(index: integer)?

---@class AIFileListScreen: Screen
---@field cfg AIFileListConfig
---@field panel Panel
---@field list ListBox
local S = { overlay = true }

---@param cfg AIFileListConfig?
function S:enter(cfg)
    cfg = cfg or { items = { "None", "Example" }, selected = 1 }
    self.cfg = cfg
    local p = UI.panel("PNL_SELECTAIFILE", { x = 108, y = 154, onButton = function(name) self:button(name) end })
    ---@cast p -nil
    self.panel = p
    local lbItem, bar = p:find("LB_SELECTAIFILE"), p:find("SBAR_V156B")
    ---@cast lbItem -nil
    ---@cast bar -nil
    self.list = listbox.new(p.x + lbItem.e.x, p.y + lbItem.e.y, lbItem.ob.w, lbItem.ob.h, p.x + bar.e.x, p.y + bar.e.y, bar.ob.h,
                            lbItem.ob.fonts[1], lbItem.ob.fonts[2])
    self.list:setItems(cfg.items, cfg.selected)
end

function S:button(name)
    if name == "BUTT_OKAY_180" then
        screens.pop()
        if self.cfg.onDone then self.cfg.onDone(self.list.sel) end
    elseif name == "BUTT_CANCEL_180" then
        screens.pop()
    end
end

function S:update() require("src.audio.music").update() end

function S:draw()
    UI.begin()
    self.panel:draw()
    self.list:draw(true)
    UI.finish()
end

function S:mousemoved(x, y)
    local vx, vy = UI.toVirtual(x, y)
    self.list:drag(vx, vy)
    self.panel:mousemoved(vx, vy)
end

function S:mousepressed(x, y, button)
    local vx, vy = UI.toVirtual(x, y)
    if button == 1 then
        local i = self.list:press(vx, vy)
        if i then self.list.sel = i return end
    end
    self.panel:mousepressed(vx, vy, button)
end

function S:mousereleased(x, y, button)
    local vx, vy = UI.toVirtual(x, y)
    self.list:release()
    self.panel:mousereleased(vx, vy, button)
end

function S:wheelmoved(_, dy) self.list:wheel(dy) end

function S:keypressed(key)
    if key == "escape" then self:button("BUTT_CANCEL_180")
    elseif key == "return" or key == "kpenter" then self:button("BUTT_OKAY_180")
    elseif key == "up" then self.list.sel = math.max(1, self.list.sel - 1) self.list:ensureVisible()
    elseif key == "down" then self.list.sel = math.min(#self.list.items, self.list.sel + 1) self.list:ensureVisible() end
end

function S:dev() self:enter({ items = { "None", "H_Knightlord", "Raider", "Turtle", "Sprinter", "Mage", "A", "B", "C", "D" }, selected = 3 }) end

return S
