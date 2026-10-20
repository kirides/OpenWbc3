-- Graveyard: the retinue units that fell in battle (the hero's `graveyard`, ten places, game/retinue.lua settle: the
-- most valuable grave stays in the first place, a full graveyard gives up the oldest). A read-only memorial; the dead
-- cannot be brought back.
--
-- The original's PNL_GRAVEYARD (background, title, stones and the stats area) and PNL_GRAVEYARD_PART2 (the second layer
-- of texts), opened by FUN_0054f260 (stone positions at 0x00b9252c / 0x00b92558: two columns of five at x 165 / 420, y
-- 136 + 70 n; the eleventh place (626, 269) of the panel is never used, the loops stop at ten): a used place shows the
-- unit's name, "Level n" and "n Battles" next to its number, the unit's picture (interface frame 1, 32 x 50) on a
-- stone; resting the mouse on a stone shows the stats area at the bottom: picture at (184, 478), name, the battle it
-- fell in (English only: the original leaves the line empty in every other language; the scenario "Random" reads "Slain
-- in a random battle.") and the level's medals (FUN_0054f980, FUN_0054fc00; silver medals at x 220 + 12 n, gold ones at
-- x 220 + 17 n, 15 px lower). The stats stay until the mouse moves to another stone or to the empty background; unused
-- places are greyed. The killer of a unit (`killer`, the unit type that struck the last blow) is recorded in the grave as
-- in the original, but no 1.04 screen shows it.
--
-- enter(list): array of { code, name, level, battles, scenario, killer } (places may be empty)
local screens = require("src.core.screens")
local UI = require("src.ui.interface")
local fonts = require("src.ui.fonts")
local config = require("src.core.config")
local rules = require("src.game.rules")
local gamedata = require("src.game.gamedata")
local anims = require("src.gfx.anims")

---@class GraveyardScreen: Screen
---@field list table<integer, table> place -> grave { code, name, level, battles, scenario, killer } (places may be empty)
---@field sel integer?               the place whose stats are shown (0-based)
---@field p1 Panel?                  PNL_GRAVEYARD
---@field p2 Panel                   PNL_GRAVEYARD_PART2 (there whenever p1 is: same interface file)
---@field nameItem PanelItem?        stats area: the name
---@field sceneItem PanelItem?       stats area: the battle it fell in
---@field devHold boolean?           --show graveyard:stats keeps the stats shown
local S = {}
S.helpId = 12          -- screen help (src/screens/screenhelp.lua)

local PLACES = 10
local MEDAL_X = { 0, 12, 24, 36, 48 }
local GOLD_X = { 0, 17, 34 }
local MEDAL_BASE_X, MEDAL_BASE_Y, GOLD_DY = 220, 512, 15
local PICTURE_X, PICTURE_Y = 184, 478

-- the items of a panel by their index (the original's panel string setter FUN_00464a90 takes panel, name and index)
local function indexed(p, name)
    local out = {}
    for _, it in ipairs(p:all(name)) do out[it.e.extra] = it end
    return out
end

local quads = {}
local function piece(id, sx, sy, w, h, x, y)
    local img = UI.bitmap(id)
    if not img then return end
    local key = id .. ":" .. sx
    quads[key] = quads[key] or love.graphics.newQuad(sx, sy, w, h, img:getDimensions())
    love.graphics.draw(img, quads[key], x, y)
end

---@param list table?               the hero's graveyard (a sample without)
function S:enter(list)
    self.list = list or self:sample()
    self.sel = nil
    self:build()
end

function S:sample()
    return { { code = "AHDX", level = 7, name = "Sir Test", battles = 4, scenario = "Bridges", killer = "AOBX" },
             { code = "AHBX", level = 0, battles = 1, scenario = "Random" },
             [4] = { code = "AHKX", level = 17, name = "Aelfric", battles = 12, scenario = "Dragon's Lair" },
             [5] = { code = "AHMX", level = 3, name = "Wulf", battles = 3, scenario = "Bridges" },
             [8] = { code = "AHEX", level = 9, name = "Mercutio", battles = 6, scenario = "Bridges" } }
end

function S:build()
    local function button(name) if name == "BUTT_OKAY_STARTUP" then self:close() end end
    local p1 = UI.panel("PNL_GRAVEYARD", { x = 0, y = 0, onButton = button })
    local p2 = UI.panel("PNL_GRAVEYARD_PART2", { x = 0, y = 0 })
    ---@cast p2 -nil
    self.p1, self.p2 = p1, p2
    if not p1 then return end
    -- the panel filler FUN_0054f6f0: title, places, texts
    p1:setString("BUTT_OKAY_STARTUP", "")
    local title = p1:find("STR_PARCHLARGE_L500")
    ---@cast title -nil
    p1.itemStrings[title] = UI.text(280, 2) or "Graveyard"
    p1.align[title] = "center"
    for _, it in ipairs(p1:all("BUTT_GY_BUTTON")) do p1:hideArt(it) p1.itemStrings[it] = "" end
    p1:hideArt(p1:find("BUTT_GY_FULLSCREEN") --[[@as PanelItem]])
    p1.itemStrings[p1:find("BUTT_GY_FULLSCREEN")] = ""
    for _, it in ipairs(p1:all("IM_RETINUE_MEDAL")) do p1:hideItem(it) end
    local names, levels = indexed(p1, "STR_PARCHMEDIUM_L250"), indexed(p1, "STR_PARCHSMALL_L250")
    local battles, numbers = indexed(p2, "STR_PARCHSMALL_L250"), indexed(p2, "STR_PARCHMED_L100")
    local buttons, stones = indexed(p1, "BUTT_GY_BUTTON"), indexed(p1, "IM_GY_STONE_PICT")
    for i = 0, PLACES do
        local e = i < PLACES and self.list[i + 1] or nil
        if e then
            local t = gamedata.army(e.code)
            -- the original prints the unit's own name; one without gets its type name
            p1.itemStrings[names[i]] = (e.name and e.name ~= "") and e.name or rules.unitName(e.code, t)
            p1.itemStrings[levels[i]] = (UI.text(280, 0) or "Level %d"):format((e.level or 0) + 1)
            p2.itemStrings[battles[i]] = (UI.text(280, 1) or "%d Battles"):format(e.battles or 0)
            p2.itemStrings[numbers[i]] = tostring(i + 1)
        else
            if names[i] then p1.itemStrings[names[i]] = "" end
            if levels[i] then p1.itemStrings[levels[i]] = "" end
            if battles[i] then p2.itemStrings[battles[i]] = "" end
            if numbers[i] then p2.itemStrings[numbers[i]] = "" end
            p1:setItemDisabled(buttons[i], true)
        end
        if stones[i] then
            local x, y = stones[i].e.x, stones[i].e.y
            p1:setOwnerDraw(stones[i], function() self:drawStone(i, x, y) end)
        end
    end
    p1:setOwnerDraw(p1:find("IM_GY_PICT") --[[@as PanelItem]], function() self:drawPicture() end)
    self.nameItem = p1:find("STR_SMALL200")
    self.sceneItem = p1:all("STR_SMALL500")[2]
    for _, it in ipairs(p1:all("STR_SMALL500")) do p1.itemStrings[it] = "" end
end

-- FUN_0054fb70: the picture of a used place (not the eleventh) on its stone.
function S:drawStone(i, x, y)
    local e = self.list[i + 1]
    local set = e and i < PLACES and anims.get(e.code)
    if set then set:drawInterface(1, x, y, 1) end
end

-- FUN_0054fc00: the picture and the medals of the shown grave.
function S:drawPicture()
    local e = self.sel and self.list[self.sel + 1]
    if not e then return end
    local set = anims.get(e.code)
    if set then set:drawInterface(1, PICTURE_X, PICTURE_Y, 1) end
    local level = math.max(0, math.min(19, e.level or 0))
    for i = 1, math.floor(level / 5) do
        piece(395, 10, 0, 16, 15, MEDAL_BASE_X + GOLD_X[i], MEDAL_BASE_Y + GOLD_DY)
    end
    for i = 1, level % 5 + 1 do piece(395, 0, 0, 11, 14, MEDAL_BASE_X + MEDAL_X[i], MEDAL_BASE_Y) end
end

-- The stats area (FUN_0054f980): the name and the battle the unit fell in.
---@param i integer?                 the place (0-based), nil for none
function S:showStats(i)
    self.sel = i
    local p = self.p1
    ---@cast p -nil
    local e = i and self.list[i + 1]
    p.itemStrings[self.nameItem] = e and ((e.name and e.name ~= "") and e.name or rules.unitName(e.code, gamedata.army(e.code))) or ""
    local line = ""
    if e and config.language == "English" then
        local s = e.scenario or ""
        if s == UI.text(83, 0) then line = UI.text(38, 0) or "Slain in a random battle."
        else line = (UI.text(169, 0) or "Slain in the battle of %s."):format(s) end
    end
    p.itemStrings[self.sceneItem] = line
end

function S:close() screens.pop() end

function S:draw()
    UI.begin()
    local p1 = self.p1
    if p1 then
        local mx, my = love.mouse.getPosition()
        local vx, vy = UI.toVirtual(mx, my)
        local it = not self.devHold and p1:hit(vx, vy)
        if it and it.name == "BUTT_GY_BUTTON" then
            if self.sel ~= it.e.extra then self:showStats(it.e.extra) end
        elseif it and it.name == "BUTT_GY_FULLSCREEN" and self.sel then
            self:showStats(nil)
        end
        p1:draw()
        self.p2:draw()
        UI.panelOver = p1:over(vx, vy) or nil
    end
    UI.finish()
end

function S:mousemoved(x, y)
    local vx, vy = UI.toVirtual(x, y)
    if self.p1 then self.p1:mousemoved(vx, vy) end
end

function S:mousepressed(x, y, button)
    local vx, vy = UI.toVirtual(x, y)
    if self.p1 then self.p1:mousepressed(vx, vy, button) end
end

function S:mousereleased(x, y, button)
    local vx, vy = UI.toVirtual(x, y)
    if self.p1 then self.p1:mousereleased(vx, vy, button) end
end

function S:keypressed(key)
    if key == "escape" or key == "return" then self:close() end
end

-- developer aid: --show graveyard[:stats]
function S:dev(sub)
    if sub == "stats" then self:enter() self:showStats(3) self.devHold = true end
end

return S
