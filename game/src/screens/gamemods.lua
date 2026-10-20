-- Game rules dialog ("Rules..." of the skirmish / multiplayer setup, original PNL_SS_GAMEMODS; opener
-- FUN_004ea2d0, handler 0x004ea8c0): seven check boxes (No Dragons, No Eyries, No Titans, Tough Towers, No
-- Towers, No Walls, No Heroes; strings 238.0 title, 238.1 .. 238.7), OK and Cancel. A box the scenario locked
-- (header lock byte of the mod) is greyed, No Heroes is also greyed in Tournament mode and for the Assassin victory
-- condition. Only the host / single player may change anything: everybody else sees the boxes with Cancel greyed.
-- In openwbc3 Battle of Titans additionally locks No Lords (Titans) and No Heroes (the setup screen's own rule).
--
--   screens.push(require("src.screens.gamemods"), { mods = { noDragons = bool ... }, locked = { noHeroes = true ... },
--       editable = bool, onDone = function(mods) end })
local screens = require("src.core.screens")
local UI = require("src.ui.interface")
local fonts = require("src.ui.fonts")

---@class GameModsConfig
---@field mods table<string, boolean>   mod key -> on
---@field locked table<string, boolean> mod key -> locked by the scenario / setup
---@field editable boolean?
---@field onDone fun(mods: table<string, boolean>)?

---@class GameModsScreen: Screen
---@field cfg GameModsConfig
---@field v table<string, boolean>   the mods being edited
---@field panel Panel
---@field boxes PanelItem[]          the check boxes, in KEYS order
local S = { overlay = true }

-- check box i (top to bottom) -> mod key; the same order as the strings 238.1 .. 238.7
S.KEYS = { "noDragons", "noFliers", "noLords", "toughTowers", "noTowers", "noWalls", "noHeroes" }

---@param cfg GameModsConfig?
function S:enter(cfg)
    cfg = cfg or { mods = {}, locked = {}, editable = true }                      -- --show
    self.cfg = cfg
    self.v = {}
    for _, k in ipairs(S.KEYS) do self.v[k] = cfg.mods[k] == true end
    local p = UI.panel("PNL_SS_GAMEMODS", { x = 0, y = 0, onButton = function(name, it) self:button(name, it) end })
    ---@cast p -nil
    self.panel = p
    self.boxes = p:all("BUTT_SS_GAMEMOD_CHECK")
    for _, it in ipairs(self.boxes) do p.itemStrings[it] = "" end                -- the labels are drawn below
    local title = p:find("STR_PARCHLARGE_L400")
    ---@cast title -nil
    p.itemStrings[title] = UI.text(238, 0)
    p.align[title] = "center"
    p:setItemDisabled(p:find("BUTT_CANCEL_160") --[[@as PanelItem]], not cfg.editable)
end

function S:isLocked(i)
    return not self.cfg.editable or self.cfg.locked[S.KEYS[i]] == true
end

function S:toggle(i)
    if self:isLocked(i) then return end
    local key = S.KEYS[i]
    self.v[key] = not self.v[key]
end

---@param name string
---@param it PanelItem?
function S:button(name, it)
    if name == "BUTT_OKAY_160" then
        screens.pop()
        if self.cfg.editable and self.cfg.onDone then self.cfg.onDone(self.v) end
    elseif name == "BUTT_CANCEL_160" then
        screens.pop()
    elseif name == "BUTT_SS_GAMEMOD_CHECK" then
        for i, b in ipairs(self.boxes) do
            if b == it then self:toggle(i) end
        end
    end
end

function S:drawBoxes()
    local g = love.graphics
    local mx, my = UI.toVirtual(love.mouse.getPosition())
    local img = UI.bitmapByName("BM_CHECKBOX")
    for i, it in ipairs(self.boxes) do
        local x, y = self.panel.x + it.e.x, self.panel.y + it.e.y
        local disabled = self:isLocked(i)
        local hover = mx >= x and mx < x + 24 and my >= y and my < y + it.ob.h
        if img and self.v[S.KEYS[i]] then
            -- checked art: rows 4..7 (normal, hover, pressed, disabled), like the advanced options dialog
            local row = 4 + (disabled and 3 or hover and 1 or 0)
            g.draw(img, g.newQuad(0, row * it.ob.h, img:getWidth(), it.ob.h, img:getDimensions()), x, y)
        end
        local label = UI.text(238, i)
        if label then
            local fid = disabled and it.ob.fonts[3] or it.ob.fonts[1]
            fonts.print(fid, label, x + 28, y + fonts.middleY(fid, it.ob.h))
        end
    end
end

function S:update() require("src.audio.music").update() end

function S:draw()
    UI.begin()
    self.panel:draw()
    self:drawBoxes()
    UI.finish()
end

function S:mousemoved(x, y)
    local vx, vy = UI.toVirtual(x, y)
    self.panel:mousemoved(vx, vy)
end

function S:mousepressed(x, y, button)
    local vx, vy = UI.toVirtual(x, y)
    self.panel:mousepressed(vx, vy, button)
end

function S:mousereleased(x, y, button)
    local vx, vy = UI.toVirtual(x, y)
    self.panel:mousereleased(vx, vy, button)
end

function S:keypressed(key)
    if key == "escape" then self:button(self.cfg.editable and "BUTT_CANCEL_160" or "BUTT_OKAY_160")
    elseif key == "return" or key == "kpenter" then self:button("BUTT_OKAY_160") end
end

-- developer aid: --show gamemods[:locked|:viewer]
function S:dev(sub)
    self:enter({ mods = { noDragons = true, toughTowers = true }, locked = sub == "locked" and { toughTowers = true, noHeroes = true } or {},
                 editable = sub ~= "viewer" })
end

return S
