-- Advanced options dialog (PNL_SS_ADVANCEDOPTIONS of the side selection screen; the 1.04 binary opens it in
-- FUN_004e9570 with the event handler at 0x004e9ab0): seven check boxes (random weather, resignation kills
-- a side, AI can resign, tournament mode, I am the greatest, tough towers, no items), the tournament level scroll bar
-- (4..50, only while tournament mode is on) and the game speed drop-down. Only the host / single player can change
-- anything; everybody else sees the values with Cancel greyed. The rules of the boxes (what "I am the greatest" forces and
-- locks, tournament greyed in a No Heroes game) are those of the original; src/game/advanced.lua implements them.
-- The scroll bar art (HSBar170.bmp, XCG 229) has no XCI behaviour of its own here: openwbc3 draws the track, the two
-- arrows and the skull from the strip (track 0..170, skull at x 171, left arrow at 202, right arrow at 297; own reading
-- of the bitmap).
--
--   screens.push(require("src.screens.advancedoptions"), { value = <advanced>, speed = 0..4, editable = bool,
--       single = bool, noHeroes = bool, onDone = function(value, speed) end })
local screens = require("src.core.screens")
local UI = require("src.ui.interface")
local fonts = require("src.ui.fonts")
local dropdown = require("src.ui.dropdown")
local Advanced = require("src.game.advanced")

---@class AdvancedOptionsConfig
---@field value table? the advanced options (src/game/advanced.lua)
---@field speed integer? game speed 0..4
---@field editable boolean? host / single player: may change things
---@field single boolean? single player game
---@field noHeroes boolean? No Heroes game: tournament mode greyed
---@field onDone fun(value: table, speed: integer)?

---@class AdvancedOptionsScreen: Screen
---@field cfg AdvancedOptionsConfig
---@field v table                   the options being edited (Advanced.normalize)
---@field speed integer             game speed 0..4
---@field panel Panel
---@field boxes PanelItem[]         the check boxes, top to bottom
---@field level PanelItem?          tournament level text
---@field bar PanelItem             tournament level scroll bar
---@field speedButton PanelItem     game speed drop-down
---@field hover any
---@field quads table<string, love.Quad>? the scroll bar's pieces
---@field dragging boolean?         the skull is being dragged
local S = { overlay = true }

-- check box i (top to bottom) -> option key
local BOXES = { "randomWeather", "resignKills", "aiResign", "tournament", "greatest", "toughTowers", "noItems" }
local TOURNAMENT, GREATEST = 4, 5

local function copy(t)
    local c = {}
    for k, v in pairs(t) do c[k] = v end
    return c
end

---@param cfg AdvancedOptionsConfig?
function S:enter(cfg)
    cfg = cfg or { value = Advanced.normalize(nil), speed = 3, editable = true, single = true }       -- --show
    self.cfg = cfg
    self.v = Advanced.normalize(cfg.value)
    if not cfg.single then self.v.greatest = false end            -- the original forces it off outside single player
    self.speed = math.max(0, math.min(4, cfg.speed or 3))
    local p = UI.panel("PNL_SS_ADVANCEDOPTIONS", { x = 0, y = 0, onButton = function(name, it) self:button(name, it) end })
    ---@cast p -nil
    self.panel = p
    self.boxes = p:all("BUTT_SS_OPTIONS_CHECKBOX")
    local title = p:find("STR_PARCHLARGE_L400")
    ---@cast title -nil
    p.itemStrings[title] = UI.text(233, 0)
    p.align[title] = "center"
    for _, it in ipairs(p:all("STR_MEDIUMDLG_300")) do p.itemStrings[it] = "" end
    self.level = p:find("STR_MEDIUMDLG_120")
    p.align[self.level] = "center"
    self.bar = p:find("SBAR_H170_2") --[[@as PanelItem]]
    self.speedButton = p:find("BUTT_SS_GAMESPEED") --[[@as PanelItem]]
    p.align[self.speedButton] = "left"
    p:setItemDisabled(p:find("BUTT_CANCEL_160") --[[@as PanelItem]], not cfg.editable)
    self.hover = nil
    self:refresh()
end

function S:tournamentAllowed()
    return not self.cfg.noHeroes
end

function S:refresh()
    local p = self.panel
    p.itemStrings[self.speedButton] = UI.text(212, self.speed) or tostring(self.speed)
    p:setItemDisabled(self.speedButton, not self.cfg.editable)
    p:setItemDisabled(self.boxes[TOURNAMENT], not self:tournamentAllowed())
    if self.v.tournament then
        p.itemStrings[self.level] = (UI.text(233, 7) or "") .. self.v.points
    else
        p.itemStrings[self.level] = ""
    end
end

function S:barActive()
    return self.cfg.editable and self.v.tournament and self:tournamentAllowed() and not self.v.greatest
end

-- A click on check box i (the check box event of the handler at 0x004e9ab0, host side).
---@param i integer
function S:toggle(i)
    local v, key = self.v, BOXES[i]
    if not self.cfg.editable then return end
    if i == GREATEST then
        if not self.cfg.single then return end
        v.greatest = not v.greatest
        -- whichever way it was switched, random weather and resignation kills go on, AI resign and tournament off
        v.randomWeather, v.resignKills, v.aiResign, v.tournament = true, true, false, false
    elseif v.greatest then
        return                                  -- everything else is locked while "I am the greatest" is on
    elseif i == TOURNAMENT then
        if not self:tournamentAllowed() then return end
        v.tournament = not v.tournament
    else
        v[key] = not v[key]
    end
    self:refresh()
end

---@param name string
---@param it PanelItem?
function S:button(name, it)
    if name == "BUTT_OKAY_160" then
        screens.pop()
        if self.cfg.editable and self.cfg.onDone then self.cfg.onDone(Advanced.enforce(self.v, not self.cfg.single), self.speed) end
    elseif name == "BUTT_CANCEL_160" then
        screens.pop()
    elseif name == "BUTT_SS_GAMESPEED" then
        if not self.cfg.editable then return end
        local items = {}
        for i = 0, 4 do items[#items + 1] = UI.text(212, i) or tostring(i) end
        ---@cast it -nil
        local x, y = self.panel.x + it.e.x, self.panel.y + it.e.y + it.ob.h
        dropdown.open(items, x, y, function(index)
            self.speed = index - 1
            self:refresh()
        end)
    elseif name == "BUTT_SS_OPTIONS_CHECKBOX" then
        for i, b in ipairs(self.boxes) do
            if b == it then self:toggle(i) end
        end
    end
end

-- Scroll bar geometry: the track rectangle and the skull's range.
local TRACK_W, ARROW_W, SKULL_W = 170, 31, 30

function S:barRect()
    local it = self.bar
    return self.panel.x + it.e.x, self.panel.y + it.e.y, it.ob.w, it.ob.h
end

function S:setBar(vx)
    local x, _, w = self:barRect()
    local lo, hi = x + ARROW_W + SKULL_W / 2, x + w - ARROW_W - SKULL_W / 2
    local f = math.max(0, math.min(1, (vx - lo) / (hi - lo)))
    self.v.points = Advanced.POINTS_MIN + math.floor(f * (Advanced.POINTS_MAX - Advanced.POINTS_MIN) + 0.5)
    self:refresh()
end

function S:drawBar()
    local img = UI.bitmap(self.bar.ob.source)
    if not img then return end
    local x, y, w, h = self:barRect()
    local g = love.graphics
    local function quad(qx, qw) return g.newQuad(qx, 0, qw, h, img:getDimensions()) end
    self.quads = self.quads or { track = quad(0, TRACK_W), skull = quad(171, SKULL_W), left = quad(202, ARROW_W), right = quad(297, ARROW_W) }
    g.setColor(1, 1, 1)
    g.draw(img, self.quads.track, x, y)
    local active = self:barActive()
    if active then
        g.draw(img, self.quads.left, x, y)
        g.draw(img, self.quads.right, x + w - ARROW_W, y)
    end
    local f = (self.v.points - Advanced.POINTS_MIN) / (Advanced.POINTS_MAX - Advanced.POINTS_MIN)
    local lo, hi = x + ARROW_W, x + w - ARROW_W - SKULL_W
    if self.v.tournament then
        if not active then g.setColor(1, 1, 1, 0.5) end
        g.draw(img, self.quads.skull, lo + (hi - lo) * f, y)
        g.setColor(1, 1, 1)
    end
end

function S:drawBoxes()
    local g = love.graphics
    local mx, my = UI.toVirtual(love.mouse.getPosition())
    local img = UI.bitmapByName("BM_CHECKBOX")
    for i, it in ipairs(self.boxes) do
        local key = BOXES[i]
        local hidden = i == GREATEST and not self.cfg.single
        local label
        if i <= 4 then label = UI.text(233, i)
        elseif i == GREATEST then label = UI.text(233, 5)
        else label = UI.text(236, i - 6) end
        local x, y = self.panel.x + it.e.x, self.panel.y + it.e.y
        if hidden then
            self.panel:hideItem(it, true)
        else
            local disabled = i == TOURNAMENT and not self:tournamentAllowed()
            local hover = mx >= x and mx < x + 24 and my >= y and my < y + it.ob.h
            if img and self.v[key] then
                -- checked art: rows 4..7 (normal, hover, pressed, disabled), like the tip of the day's check box
                local row = 4 + (disabled and 3 or (hover and self.cfg.editable) and 1 or 0)
                g.draw(img, g.newQuad(0, row * it.ob.h, img:getWidth(), it.ob.h, img:getDimensions()), x, y)
            end
            if label then
                local fid = disabled and it.ob.fonts[3] or it.ob.fonts[1]
                fonts.print(fid, label, x + 28, y + fonts.middleY(fid, it.ob.h))
            end
        end
    end
end

function S:update() require("src.audio.music").update() end

function S:draw()
    UI.begin()
    self.panel:draw()
    self:drawBoxes()
    self:drawBar()
    dropdown.draw()
    UI.finish()
end

function S:mousemoved(x, y)
    local vx, vy = UI.toVirtual(x, y)
    if self.dragging then self:setBar(vx) end
    self.panel:mousemoved(vx, vy)
end

function S:mousepressed(x, y, button)
    local vx, vy = UI.toVirtual(x, y)
    if dropdown.pressed(vx, vy) then return end
    if button == 1 and self:barActive() then
        local bx, by, bw, bh = self:barRect()
        if vx >= bx and vx < bx + bw and vy >= by and vy < by + bh then
            require("src.audio.sound").play("Assets/SoundFX.xcr", "NewClick.wav")
            if vx < bx + ARROW_W then
                self.v.points = math.max(Advanced.POINTS_MIN, self.v.points - 1)
                self:refresh()
            elseif vx >= bx + bw - ARROW_W then
                self.v.points = math.min(Advanced.POINTS_MAX, self.v.points + 1)
                self:refresh()
            else
                self.dragging = true
                self:setBar(vx)
            end
            return
        end
    end
    self.panel:mousepressed(vx, vy, button)
end

function S:mousereleased(x, y, button)
    local vx, vy = UI.toVirtual(x, y)
    self.dragging = false
    self.panel:mousereleased(vx, vy, button)
end

function S:keypressed(key)
    if dropdown.isOpen() then dropdown.close() return end
    if key == "escape" then self:button(self.cfg.editable and "BUTT_CANCEL_160" or "BUTT_OKAY_160")
    elseif key == "return" or key == "kpenter" then self:button("BUTT_OKAY_160") end
end

function S:leave() dropdown.close() end

-- developer aid: --show advancedoptions[:tournament|:greatest|:viewer]
function S:dev(sub)
    local cfg = { value = Advanced.normalize({ randomWeather = true, resignKills = true, aiResign = true, points = 20 }),
                  speed = 3, editable = sub ~= "viewer", single = true }
    if sub == "tournament" then cfg.value.tournament = true end
    if sub == "greatest" then cfg.value = Advanced.enforce({ greatest = true }) end
    self:enter(cfg)
end

return S
