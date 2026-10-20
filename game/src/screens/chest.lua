-- Chest dialog: enter(battle, hero, chest). A hero that comes next to a treasure chest of a scenario sees what it wears, its
-- backpack and the chest's items; a click on an item moves it to the other side (chest <-> backpack / worn), so the hero
-- can make room. A click picks an item up, a second click on a slot puts it there. An item taken from the chest goes into
-- the backpack, never onto the hero unless it is put on a worn slot (it may be meant for selling in the campaign);
-- a right click on a backpack item wears it. An emptied chest stays until the hero leaves it.
-- The battle goes on behind the dialog (like the original; update runs the world).
-- Not traced in the 1.04 binary: the frame and layout are openwbc3's own (ui/frame.lua), the closing when the hero leaves
-- the chest is too. The chest holds at most four items.
local screens = require("src.core.screens")
local UI = require("src.ui.interface")
local fonts = require("src.ui.fonts")
local frame = require("src.ui.frame")
local widgets = require("src.ui.widgets")
local heroMod = require("src.game.hero")
local items = require("src.game.items")
local sound = require("src.audio.sound")
local music = require("src.audio.music")

---@class ChestScreen: Screen
---@field battle BattleScreen
---@field world World
---@field hero Unit
---@field chest Chest
---@field panel Panel
---@field font integer
---@field small integer
---@field savedFrame {X: number, Y: number, W: number, H: number}?
---@field held {kind: string, i: integer, item: table}?   the item picked up, waiting for a slot
local S = { overlay = true }

local WORN = { 1, 2, 7, 3, 4, 5, 6 }     -- the worn slots in the order of the hero dialog's list (heroinfo.lua)
local SYMBOL = 0.9                    -- the slot symbols of Items.bmp are 50 x 50
local ICON = 0.8                      -- the 70 x 110 picture cell of Items.bmp, drawn whole as the original draws it
local MARGIN = 2                      -- space between a picture and the tile edge
local TILE_W, TILE_H, GAP = 70 * ICON + 2 * MARGIN, 110 * ICON + 2 * MARGIN, 6
local LX = 24                            -- left edge of the tile rows, relative to the frame
local WORN_Y, PACK_Y, CHEST_Y = 92, 214, 336
local MAX_ITEMS = 4
local FRAME = { X = 130, Y = 40, W = 540, H = 450 }     -- bigger than the shared frame: the items are drawn large

---@param battle BattleScreen
---@param hero Unit
---@param chest Chest
function S:enter(battle, hero, chest)
    self.held = nil
    self.battle, self.world, self.hero, self.chest = battle, battle.world, hero, chest
    local p = UI.panel("PNL_OKAYCANCEL", { onButton = function(name) if name == "BUTT_OKAY_180" then self:close() end end })
    ---@cast p -nil
    self.panel = p
    self.savedFrame = { X = frame.X, Y = frame.Y, W = frame.W, H = frame.H }
    frame.X, frame.Y, frame.W, frame.H = FRAME.X, FRAME.Y, FRAME.W, FRAME.H
    frame.prepare(p, "Treasure")
    local ok = p:add("BUTT_OKAY_180", frame.X + 310, frame.Y + PACK_Y + 30, "BUTT_OKAY_180")
    ---@cast ok -nil
    p.itemStrings[ok] = "Done"
    self.font = UI.ui.objByName.STR_MEDIUM200.font
    self.small = UI.ui.objByName.STR_SMALLDLG_300.font
end

function S:close() screens.pop() end

function S:leave()
    local f = self.savedFrame
    if f then frame.X, frame.Y, frame.W, frame.H = f.X, f.Y, f.W, f.H end
end

-- The battle goes on behind the dialog; it closes when the hero falls, walks off or the chest is gone.
function S:update(dt)
    music.update()
    self.battle:runBackground(math.min(dt, 0.1))
    local c, h = self.chest, self.hero
    local alive = h:alive() and self.world:chestNear(h, c.id)
    if not alive then self:close() end
    -- the held item may have gone meanwhile (a network game applies commands a turn later)
    local held = self.held
    if held then
        local list = held.kind == "chest" and c.items or held.kind == "pack" and h.h.pack or h.h.equipped
        if list[held.i] ~= held.item then self.held = nil end
    end
end

-- Rows: list of { kind, index, x, y }, filled from the hero's current items.
---@return {kind: string, i: integer, x: number, y: number, item: table?}[]
function S:rows()
    local out = {}
    local hr = assert(self.hero.h)
    for r = 1, #WORN do
        out[#out + 1] = { kind = "worn", i = WORN[r], x = LX + (r - 1) * (TILE_W + GAP), y = WORN_Y,
                          item = hr.equipped[WORN[r]] }
    end
    for i = 1, heroMod.PACK_SIZE do
        out[#out + 1] = { kind = "pack", i = i, x = LX + (i - 1) * (TILE_W + GAP), y = PACK_Y,
                          item = hr.pack[i] }
    end
    for i = 1, MAX_ITEMS do
        out[#out + 1] = { kind = "chest", i = i, x = LX + (i - 1) * (TILE_W + GAP), y = CHEST_Y,
                          item = self.chest.items[i] }
    end
    return out
end

local function hit(r, vx, vy)
    return widgets.inside(vx, vy, frame.X + r.x, frame.Y + r.y, TILE_W, TILE_H)
end

function S:draw()
    UI.begin()
    frame.draw()
    local g = love.graphics
    local vx, vy = UI.toVirtual(love.mouse.getPosition())
    local function head(x, y, label) fonts.print(self.font, label, frame.X + x, frame.Y + y) end
    head(LX, WORN_Y - 22, "Equipment")
    head(LX, PACK_Y - 22, ((UI.text(311, 7) or "Backpack:"):gsub(":$", "")))
    head(LX, CHEST_Y - 22, "Chest")
    local tip
    for _, r in ipairs(self:rows()) do
        local x, y = frame.X + r.x, frame.Y + r.y
        local over = r.item and hit(r, vx, vy)
        g.setColor(0, 0, 0, 1)
        g.rectangle("fill", x, y, TILE_W, TILE_H)
        g.setColor(1, 1, 1)
        local held = self.held
        if r.item and not (held and held.kind == r.kind and held.i == r.i) then
            items.drawIcon(r.item, x + MARGIN, y + MARGIN, ICON)
        elseif r.kind == "worn" then
            -- an empty worn slot shows the picture of the item class it takes (the symbols of Items.bmp)
            g.setColor(1, 1, 1, 0.55)
            items.drawSlotSymbol(heroMod.SLOT_LAYOUT[r.i].class, x + (TILE_W - 50 * SYMBOL) / 2,
                y + (TILE_H - 50 * SYMBOL) / 2, SYMBOL)
            g.setColor(1, 1, 1)
        end
        if held then
            -- the slots the held item can go to glow, the others are dimmed
            if self:canDrop(held, r) then
                local pulse = 0.5 + 0.5 * math.sin(love.timer.getTime() * 5)
                g.setColor(0.3, 1, 0.4, 0.1 + 0.12 * pulse)
                g.rectangle("fill", x, y, TILE_W, TILE_H)
                g.setColor(0.4, 1, 0.5, 0.7 + 0.3 * pulse)
                g.setLineWidth(2)
                g.rectangle("line", x + 1, y + 1, TILE_W - 2, TILE_H - 2)
                g.setLineWidth(1)
            elseif not (held.kind == r.kind and held.i == r.i) then
                g.setColor(0, 0, 0, 0.5)
                g.rectangle("fill", x, y, TILE_W, TILE_H)
            end
            g.setColor(1, 1, 1)
        end
        -- the outline and the highlight go over the picture (its cell is opaque black)
        local tc = r.item and widgets.TIER_COLOR[r.item.tier]
        if over then
            g.setColor(1, 1, 1, 0.15)
            g.rectangle("fill", x, y, TILE_W, TILE_H)
            tip = r.item
        end
        if tc then g.setColor(tc[1], tc[2], tc[3], 0.8) else g.setColor(0.86, 0.7, 0.47, 0.3) end
        g.rectangle("line", x + 0.5, y + 0.5, TILE_W - 1, TILE_H - 1)
        g.setColor(1, 1, 1)
    end
    fonts.print(self.small, "Click an item, then click a slot", frame.X + 310, frame.Y + CHEST_Y + 12)
    fonts.print(self.small, "Right click: wear / put back", frame.X + 310, frame.Y + CHEST_Y + 32)
    self.panel:draw()
    if self.held then
        items.drawIcon(self.held.item, vx - 70 * ICON / 2, vy - 110 * ICON / 2, ICON)
    elseif tip then
        ---@type (string|{[1]: string, [2]: number[]?})[]
        local lines = { { tip.name, widgets.TIER_COLOR[tip.tier] } }
        for _, l in ipairs(items.powerLines(tip)) do lines[#lines + 1] = l end
        for _, l in ipairs(widgets.wrap(2, tip.desc, 280)) do lines[#lines + 1] = { l, { 0.75, 0.7, 0.6 } } end
        widgets.tooltip(lines, vx, vy)
    end
    UI.finish()
end

function S:mousemoved(x, y) self.panel:mousemoved(UI.toVirtual(x, y)) end
function S:mousereleased(x, y, b)
    local vx, vy = UI.toVirtual(x, y)
    self.panel:mousereleased(vx, vy, b)
end

-- Click an item to pick it up (it follows the pointer), click a slot to put it down there: the chest takes an item from the
-- backpack or the hero's worn items, the backpack takes one from the chest or a worn one, a worn slot takes a backpack
-- item (or one from the chest, through the backpack) that fits it. Right click puts a held item back, or wears a
-- backpack item.
---@param from {kind: string, i: integer, item: table} the held item
---@param r {kind: string, i: integer}
---@return boolean
function S:canDrop(from, r)
    local hr = assert(self.hero.h)
    if from.kind == r.kind then return false end
    if r.kind == "chest" then return #self.chest.items < MAX_ITEMS end
    if r.kind == "pack" then return not hr:packFull() end
    for _, slot in ipairs(hr:slotsFor(from.item)) do         -- a worn slot: the item must fit it
        if slot == r.i then return from.kind == "pack" or not hr:packFull() end
    end
    return false
end

---@param r {kind: string, i: integer, item: table?}
function S:drop(r)
    local from, hr = assert(self.held), assert(self.hero.h)
    self.held = nil
    if not self:canDrop(from, r) then return end
    local function cmd(op, a) self.battle:issue({ t = "hero", id = self.hero.id, op = op, a = a, chest = self.chest.id }) end
    if r.kind == "chest" then
        cmd(from.kind == "pack" and "chestPut" or "chestPutWorn", from.i)
    elseif r.kind == "pack" then
        if from.kind == "chest" then cmd("chestTake", from.i) else self.battle:heroOp("unequip", from.i) end
    elseif from.kind == "chest" then
        local at = #hr.pack + 1                        -- it lands at the end of the backpack
        cmd("chestTake", from.i)
        self.battle:heroOp("equip", at)
    else
        self.battle:heroOp("equip", from.i)
    end
    sound.play("Assets/SoundFX.xcr", "Statpop.wav")
end

function S:mousepressed(x, y, button)
    local vx, vy = UI.toVirtual(x, y)
    if self.panel:mousepressed(vx, vy, button) or button > 2 then return end
    local target
    for _, r in ipairs(self:rows()) do
        if hit(r, vx, vy) then target = r break end
    end
    if button == 2 then
        if self.held then self.held = nil
        elseif target and target.item and target.kind == "pack" then self.battle:heroOp("equip", target.i) end
        return
    end
    if not target then self.held = nil return end
    if self.held then
        self:drop(target)
    elseif target.item then
        self.held = { kind = target.kind, i = target.i, item = target.item }
        sound.play("Assets/SoundFX.xcr", "NewClick.wav")
    end
end

function S:keypressed(key)
    if key == "escape" or key == "return" or key == "space" then self:close() end
end

return S
