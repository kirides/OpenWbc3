-- Hero dialog (PNL_HEROINFO): portrait, name, race / class / level / experience and six tabs as in the
-- original (HeroInfo): Stats, Combat, Skills, Titles, Retinue and Items. Opened from a battle
-- (enter(battle, tab)) or read-only for a profile hero from the hero selection (enter(nil, tab, record)).
-- Layout and texts follow the original; what is added: the Items tab shows each item's icon and a tooltip with
-- its effects, and in a battle it also wears / takes off (left click), drops (right click) and drinks potions.
local screens = require("src.core.screens")
local UI = require("src.ui.interface")
local fonts = require("src.ui.fonts")
local widgets = require("src.ui.widgets")
local heroMod = require("src.game.hero")
local herobonus = require("src.game.herobonus")
local classes = require("src.game.classes")
local items = require("src.game.items")
local gamedata = require("src.game.gamedata")
local rules = require("src.game.rules")
local profile = require("src.game.profile")
local portraits = require("src.ui.portraits")
local sound = require("src.audio.sound")
local music = require("src.audio.music")

---@class HeroInfoScreen: Screen
---@field battle BattleScreen?       nil: read-only for a profile hero (hero selection)
---@field world World?               the battle's world
---@field rec table?                 the profile record of the hero
---@field tab integer                1..6: Stats, Combat, Skills, Titles, Retinue, Items
---@field hero Unit?                 the hero's unit in a battle (nil once fallen)
---@field h Hero?                    the hero's state
---@field name string
---@field race integer
---@field fMed integer               fonts
---@field fSmall integer
---@field freezeFont integer
---@field panel Panel
---@field retinue table?             the profile's retinue (slot -> entry)
---@field retinueSlots integer       retinue slots the Charisma enables
---@field freezeQuads table<integer, love.Quad>? rows of the freeze check box
local S = { overlay = true }

local TAB_COUNT = 6
local CX, CY = 99, 262           -- content area (the tab strip is the 24 pixels above)
local TAB_W, TAB_H = 100, 24
local RETINUE_SLOTS = 8          -- the hero's Charisma enables min(Cha / 4, 7) + 1 of them (FUN_0054a720)

-- Worn slots in the order of the original's list (Head, Body, Feet, Right Hand, Left Hand, Right / Left Misc.),
-- as indexes into heroMod.SLOT_LAYOUT.
local WORN = { 1, 2, 7, 3, 4, 5, 6 }
local ROW_H = 17
local ICON = 0.15                -- item pictures are 70 x 110

local POTIONS = { { key = "health", colour = { 0.85, 0.12, 0.15 } }, { key = "mana", colour = { 0.2, 0.4, 0.95 } } }

local function fontOf(name) return UI.ui.objByName[name].font end

---@param battle BattleScreen?
---@param tab integer?
---@param rec table?                 the profile record (read-only view without a battle)
function S:enter(battle, tab, rec)
    self.battle = battle
    self.rec = rec
    self.tab = tab or 1
    if battle then
        self.world = battle.world
        self.hero = self.world.eco:heroAlive(self.world.player)
        self.h = self.hero and self.hero.h
        self.name = self.hero and (self.hero.name or "Hero") or "Fallen hero"
        self.race = self.world.sides[self.world.player].race
        local cur = self.world.opts.profile and profile.current()
        if cur and cur.race == self.race then self.rec = cur end
    else
        ---@cast rec -nil
        self.h = heroMod.new(nil, rec.hero)
        self.name = rec.name
        self.race = rec.race
    end
    self.fMed, self.fSmall = fontOf("STR_MEDIUM200"), fontOf("STR_SMALLDLG_300")
    self.freezeFont = UI.ui.objByName.BUTT_FREEZEHERO.fonts[1]
    local panel = UI.panel("PNL_HEROINFO", { onButton = function(name) self:button(name) end })
    ---@cast panel -nil
    self.panel = panel
    panel:hide("PAD_HEROINFOTABS")
    panel:hide("BUTT_FREEZEHERO")        -- drawn here: the check mark is a row of its own bitmap
    for _, it in ipairs(panel.items) do
        if it.ob.type == 4 and it.name ~= "STR_LARGE400" then panel.itemStrings[it] = "" end
    end
    panel:setTextAt("STR_LARGE400", 236, 109, self.name)
    local h = self.h
    if h then
        local function put(lx, ly, label, vx, value)
            panel.align[panel:setTextAt("STR_MEDIUM120", lx, ly, label)] = "right"
            panel:setTextAt("STR_MEDIUM200", vx, ly, value)
        end
        put(200, 158, UI.text(6, 3) or "Race:", 328, classes.RACE_NAMES[self.race] or gamedata.RACES[self.race] or "?")
        put(200, 178, UI.text(6, 4) or "Class:", 328, h.class)
        put(200, 198, UI.text(6, 5) or "Level:", 328, tostring(h.level))
        put(450, 178, UI.text(6, 6) or "XP:", 578, tostring(h.xp))
        local nxt = h:nextLevelXp()
        put(450, 198, UI.text(6, 7) or "Next Level At:", 578, nxt and tostring(nxt) or "-")
    end
    self.retinue, self.retinueSlots = nil, RETINUE_SLOTS
    local id = self.rec and self.rec.id
    local rec = id and require("src.game.profile").get(id)
    if rec then
        self.retinue = rec.retinue
        self.retinueSlots = require("src.game.retinue").slotsOf(rec)       -- by Charisma (the binary's FUN_0040b130)
    end
end

function S:button(name)
    if name == "BUTT_OKAY_200" then self:close() end
end

function S:close()
    screens.pop()
end

function S:update()
    music.update()
end

function S:setFrozen(on)
    if not self.h then return end
    self.h.frozen = on
    local rec = self.rec
    if rec and rec.hero then
        rec.hero.frozen = on or nil
        profile.update(rec)
    end
end

-- Drawing ---------------------------------------------------------------------------

local function text(fid, s, x, y, align, w, alpha)
    fonts.print(fid, s, x, y, align, w, alpha)
end

function S:drawStats(h, x, y)
    for i = 1, 4 do
        local ry = y + (i - 1) * 40
        text(self.fMed, UI.text(130, i - 1) or "", x + 10, ry + 20)
        text(self.fMed, tostring(h.attr[heroMod.ATTRS[i].key]), x + 115, ry + 20)
        local l = herobonus.lines(i, h.attr[heroMod.ATTRS[i].key])
        text(self.fSmall, l[1] .. "    " .. l[2], x + 160, ry + 12)
        text(self.fSmall, l[3] .. "    " .. l[4], x + 160, ry + 28)
    end
end

-- Armour per damage type and the resistances: the hero's complete armour (Unit:completeArmour), which adds the Armorer /
-- Scales / Thick Hide and the resistance skills to the base values.
function S:drawCombat(h, x, y)
    local m = h.mod
    local ca = self.hero and self.hero:completeArmour() or { [0] = m.armor, m.resistance, m.resistance, m.resistance, 0,
                                                              m.armor, m.armor }
    local function row(label, value, lx, ly)
        text(self.fMed, UI.text(307, label) or "", lx, ly)
        text(self.fMed, tostring(value), lx + 100, ly)
    end
    row(0, m.combat, x + 10, y + 20)
    row(1, m.speed, x + 10, y + 60)
    row(2, m.hits, x + 10, y + 100)
    row(3, m.damage, x + 10, y + 140)
    row(4, m.armor, x + 220, y + 20)
    row(5, m.resistance, x + 430, y + 20)
    local function sub(label, value, lx, ly)
        text(self.fSmall, UI.text(308, label) or "", lx, ly)
        text(self.fSmall, tostring(value), lx + 100, ly)
    end
    sub(0, ca[0], x + 230, y + 50)             -- piercing, slashing, crushing
    sub(1, ca[6], x + 230, y + 70)
    sub(2, ca[5], x + 230, y + 90)
    sub(3, ca[1], x + 440, y + 50)             -- ice, fire, electricity
    sub(4, ca[3], x + 440, y + 70)
    sub(5, ca[2], x + 440, y + 90)
    text(self.fMed, UI.text(307, 6) or "", x + 260, y + 135)
    text(self.fMed, tostring(ca[4]), x + 420, y + 135)
    text(self.fSmall, herobonus.merchantLine(m.discount), x, y + 165, "center", 600)
end

function S:drawSkills(h, x, y)
    for i, e in ipairs(h.skillList) do
        local ry = y + 10 + 15 * (i - 1)
        if h.level >= e[2] then
            text(self.fMed, heroMod.skillName(e[1]), x + 10, ry)
            text(self.fMed, tostring(h:lvl(e[1])), x + 150, ry)
            text(self.fSmall, heroMod.skillDesc(e[1], h:lvl(e[1])), x + 250, ry)
        else
            text(self.fMed, heroMod.skillName(e[1]), x + 10, ry, nil, nil, 0.5)
            text(self.fSmall, (UI.text(307, 7) or "Available at level %d"):format(e[2]), x + 200, ry)
        end
    end
end

-- Only battles fought are counted so far (profile.addBattle); the other categories read rec.stats if present.
local STAT_KEYS = { "battles", "victories", "heroesKilled", "enemiesKilled", "dragonsKilled", "titansKilled",
                    "quests", "spellsCast" }

function S:drawTitles(h, x, y)
    local rec = self.rec or {}
    local stats = rec.stats or {}
    local total = 0
    for i = 1, herobonus.CATEGORIES do
        local n = i == 1 and (rec.battles or 0) or (stats[STAT_KEYS[i]] or 0)
        local rank = herobonus.rank(i, n)
        total = total + rank
        local ry = y + 10 + ROW_H * (i - 1)
        text(self.fMed, UI.text(309, i - 1) or "", x + 10, ry)
        text(self.fMed, tostring(n), x + 200, ry)
        text(self.fSmall, rank > 0 and herobonus.titleName(i, rank) or "-", x + 350, ry - 2)
    end
    local ry = y + 10 + 153
    text(self.fMed, UI.text(308, 6) or "Overall Ranking", x + 150, ry, "right", 101)
    text(self.fMed, tostring(total), 400, ry)
    text(self.fSmall, herobonus.rankingName(total), 450, ry - 2)
end

function S:drawRetinue(h, x, y)
    for i = 1, RETINUE_SLOTS do
        local ry = y + 10 + ROW_H * (i - 1)
        local e = self.retinue and self.retinue[i]
        if e then
            local t = gamedata.army(e.code)
            local unit = rules.unitName(e.code, t)
            text(self.fMed, (e.name and e.name ~= "") and e.name or unit, x + 10, ry)
            text(self.fMed, unit, x + 150, ry)
            text(self.fSmall, (UI.text(280, 0) or "Level %d"):format(e.level or 1), x + 300, ry)
        elseif i <= (self.retinueSlots or RETINUE_SLOTS) then
            text(self.fMed, UI.text(310, 0) or "Empty", x + 10, ry)
        end
    end
end

-- Geometry of the Items tab: seven worn slots on the left, the backpack on the right.
local function itemRow(kind, i)
    if kind == "eq" then return 205, CY + 8 + (i - 1) * ROW_H, 285, ROW_H end
    return 505, CY + 8 + (i - 1) * ROW_H, 250, ROW_H
end

local function potionRect(i) return 509 + (i - 1) * 64, CY + 8 + (heroMod.PACK_SIZE + 1) * ROW_H, 56, 20 end

function S:slotItem(h, kind, i)
    if kind == "eq" then return h.equipped[WORN[i]] end
    return h.pack[i]
end

function S:itemAt(vx, vy)
    for i = 1, #WORN do
        if widgets.inside(vx, vy, itemRow("eq", i)) then return "eq", i end
    end
    for i = 1, heroMod.PACK_SIZE do
        if widgets.inside(vx, vy, itemRow("pack", i)) then return "pack", i end
    end
    if self.battle then
        for i = 1, #POTIONS do
            if widgets.inside(vx, vy, potionRect(i)) then return "potion", i end
        end
    end
end

function S:drawItems(h, x, y)
    local mx, my = UI.toVirtual(love.mouse.getPosition())
    local hk, hi = self:itemAt(mx, my)
    local function line(kind, i, lx, ry)
        local it = self:slotItem(h, kind, i)
        if hk == kind and hi == i and it then
            love.graphics.setColor(1, 1, 1, 0.1)
            love.graphics.rectangle("fill", itemRow(kind, i))
            love.graphics.setColor(1, 1, 1)
        end
        if it then
            items.drawIcon(it, lx, ry - 1, ICON)
            text(self.fSmall, it.name, lx + 14, ry - 2)
        else
            text(self.fSmall, "-", lx, ry - 2)
        end
    end
    for r = 1, #WORN do
        local ry = y + 10 + ROW_H * (r - 1)
        text(self.fMed, UI.text(311, r - 1) or "", x, ry, "right", 100)
        line("eq", r, 209, ry)
    end
    for i = 1, heroMod.PACK_SIZE do
        local ry = y + 10 + ROW_H * (i - 1)
        if i == 1 then text(self.fMed, UI.text(311, 7) or "Backpack:", 499 - 100, ry, "right", 100) end
        line("pack", i, 509, ry)
    end
    if self.battle then
        local g = love.graphics
        for i, p in ipairs(POTIONS) do
            local px, py, pw, ph = potionRect(i)
            local n = h.potions[p.key] or 0
            local c, a = p.colour, n > 0 and 1 or 0.3
            if hk == "potion" and hi == i then
                g.setColor(1, 1, 1, 0.15)
                g.rectangle("fill", px, py, pw, ph)
            end
            g.setColor(c[1], c[2], c[3], a)
            g.rectangle("fill", px + 4, py + 7, 12, 12, 3, 3)                 -- flask
            g.rectangle("fill", px + 7, py + 2, 6, 7)                         -- neck
            g.setColor(1, 1, 1)
            text(self.fMed, tostring(n), px + 22, py + 1, nil, nil, a)
        end
    end
end

-- The tooltip lines of an item (widgets.tooltip: strings or { text, colour }).
---@param item ItemRecord
---@return (string|{[1]: string, [2]: number[]?})[]
function S:itemTip(item)
    ---@type (string|{[1]: string, [2]: number[]?})[]
    local lines = { { item.name, widgets.TIER_COLOR[item.tier] } }
    lines[#lines + 1] = { ("%s - %s"):format(items.SLOTS[item.slot] or "?", item.tierName), { 0.7, 0.7, 0.7 } }
    for _, l in ipairs(items.powerLines(item)) do lines[#lines + 1] = l end
    for _, l in ipairs(widgets.wrap(2, item.desc, 280)) do lines[#lines + 1] = { l, { 0.75, 0.7, 0.6 } } end
    return lines
end

local FREEZE_X, FREEZE_Y, FREEZE_W, FREEZE_H = 115, 460, 350, 17

function S:drawFreeze()
    local img = UI.bitmap(6)
    local h = self.h
    if not img or not h then return end
    local mx, my = UI.toVirtual(love.mouse.getPosition())
    local hot = widgets.inside(mx, my, FREEZE_X, FREEZE_Y, FREEZE_W, FREEZE_H)
    local rh = img:getHeight() / 8                    -- rows: normal, hover, pressed, disabled; then the same checked
    local row = (h.frozen and 4 or 0) + (hot and (love.mouse.isDown(1) and 2 or 1) or 0)
    self.freezeQuads = self.freezeQuads or {}
    local q = self.freezeQuads[row]
    if not q then
        q = love.graphics.newQuad(0, row * rh, img:getWidth(), rh, img:getDimensions())
        self.freezeQuads[row] = q
    end
    love.graphics.draw(img, q, FREEZE_X, FREEZE_Y + (FREEZE_H - rh) / 2)
    text(self.freezeFont, UI.text(333, 0) or "Freeze your hero's level.", FREEZE_X + 22,
        FREEZE_Y + fonts.middleY(self.freezeFont, FREEZE_H))
end

function S:draw()
    UI.begin()
    self.panel:draw()
    local h = self.h
    local g = love.graphics
    if self.battle then
        if self.hero and self.hero.set then
            self.hero.set:drawInterface(3, 117, 120, self.battle:teamColor(self.world.player))
        end
    elseif self.rec then
        portraits.draw(self.rec.portrait, 113, 116, 98, 98)
    end
    -- tab bar: the shapes are part of the dialog background; the open tab merges with the content area
    for i = 1, TAB_COUNT do
        local x = CX + (i - 1) * TAB_W
        text(self.fMed, UI.text(18, i - 1) or "", x, CY - TAB_H + fonts.middleY(self.fMed, TAB_H), "center", TAB_W)
    end
    g.setColor(0, 0, 0)
    g.rectangle("fill", CX + 2 + TAB_W * (self.tab - 1), CY - 1, TAB_W - 3, 1)
    g.setColor(1, 1, 1)
    if h then
        local t = self.tab
        if t == 1 then self:drawStats(h, CX, CY)
        elseif t == 2 then self:drawCombat(h, CX, CY)
        elseif t == 3 then self:drawSkills(h, CX, CY)
        elseif t == 4 then self:drawTitles(h, CX, CY)
        elseif t == 5 then self:drawRetinue(h, CX, CY)
        else self:drawItems(h, CX, CY) end
        self:drawFreeze()
        if self.tab == 6 then
            local mx, my = UI.toVirtual(love.mouse.getPosition())
            local kind, i = self:itemAt(mx, my)
            local item = kind and kind ~= "potion" and self:slotItem(h, kind, i)
            if item then widgets.tooltip(self:itemTip(item), mx, my) end
        end
    else
        text(self.fMed, "Your hero has fallen.", CX, CY + 80, "center", 600)
    end
    UI.finish()
end

-- Input ------------------------------------------------------------------------------

function S:mousemoved(x, y)
    self.panel:mousemoved(UI.toVirtual(x, y))
end

function S:mousepressed(x, y, button)
    local vx, vy = UI.toVirtual(x, y)
    if self.panel:mousepressed(vx, vy, button) then return end
    if button == 1 and vy >= CY - TAB_H and vy < CY and vx >= CX and vx < CX + TAB_W * TAB_COUNT then
        self.tab = math.floor((vx - CX) / TAB_W) + 1
        sound.play("Assets/SoundFX.xcr", "NewClick.wav")
        return
    end
    local h = self.h
    if h and button == 1 and widgets.inside(vx, vy, FREEZE_X, FREEZE_Y, FREEZE_W, FREEZE_H) then
        sound.play("Assets/SoundFX.xcr", "NewClick.wav")
        self:setFrozen(not h.frozen)
        return
    end
    if not (h and self.battle and self.tab == 6) then return end
    local kind, i = self:itemAt(vx, vy)
    if not kind then return end
    if kind == "potion" then
        if button == 1 then self.battle:heroOp("potion", POTIONS[i].key) end
        return
    end
    if not self:slotItem(h, kind, i) then return end
    if button == 1 then
        self.battle:heroOp(kind == "eq" and "unequip" or "equip", kind == "eq" and WORN[i] or i)
    elseif button == 2 then
        self.battle:heroOp(kind == "eq" and "dropEquipped" or "drop", kind == "eq" and WORN[i] or i)
    end
end

function S:mousereleased(x, y, button)
    local vx, vy = UI.toVirtual(x, y)
    self.panel:mousereleased(vx, vy, button)
end

function S:keypressed(key)
    if key == "escape" or key == "return" or (self.battle and (key == "i" or key == "h")) then self:close()
    elseif key == "tab" then self.tab = self.tab % TAB_COUNT + 1
    end
end

return S
