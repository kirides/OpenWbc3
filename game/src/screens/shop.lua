-- Shop dialog: enter(battle, hero, building). The original's shop in a battle sells nothing
-- (selling is a campaign feature): it offers two potions and two items, and a bought item is
-- gone for good. The price is paid out of all four resources at once.
local screens = require("src.core.screens")
local fonts = require("src.ui.fonts")
local sites = require("src.game.sites")
local items = require("src.game.items")
local strings = require("src.game.strings")
local sound = require("src.audio.sound")

-- One of the four offers (S:slots).
---@class ShopSlot
---@field slot integer               1, 2 the potions, 3, 4 the shop's items
---@field x number
---@field price integer?
---@field name string
---@field desc string?
---@field have integer?              potions: how many the hero has
---@field item table?                the item record (game/items.lua)

---@class ShopScreen: Screen
---@field battle BattleScreen
---@field world World
---@field hero Unit                  the hero that shops
---@field building Building          the shop
---@field font love.Font
---@field small love.Font
---@field title love.Font
---@field hover ShopSlot?            the offer under the mouse
---@field notice string?             why the last purchase failed
local S = { overlay = true }

local SLOT_W, SLOT_H = 190, 200

local POTIONS = { { key = "1127", desc = "1128", use = "1129" },
                  { key = "1130", desc = "1131", use = "1132" } }

local function heroPotions(hero)
    local p = hero.h and hero.h.potions or {}
    return { p.health or 0, p.mana or 0 }
end

---@param battle BattleScreen
---@param hero Unit
---@param building Building
function S:enter(battle, hero, building)
    self.battle, self.hero, self.building = battle, hero, building
    self.world = battle.world
    self.font = fonts.plain(15)
    self.small = fonts.plain(12)
    self.title = fonts.plain(24)
    self.hover = nil
    self.notice = nil
end

---@return number x, number y
function S:origin()
    local sw = love.graphics.getWidth()
    return math.floor(sw / 2) - (4 * SLOT_W) / 2, 110
end

-- The four slots: healing and mana potions, then the shop's two items.
---@return ShopSlot[]
function S:slots()
    local shop = self.building.shop or { items = {} }
    local have = heroPotions(self.hero)
    local ox = self:origin()
    local out = {}
    for slot = 1, 4 do
        local row = { slot = slot, x = ox + (slot - 1) * SLOT_W,
                      price = sites.price(self.building, slot, self.hero.side) }
        if slot <= 2 then
            local p = POTIONS[slot]
            row.name = strings.get("Game.txt", p.key) or (slot == 1 and "Healing Potion" or "Mana Potion")
            row.desc = strings.get("Game.txt", p.desc) or ""
            row.have = have[slot]
        else
            local it = items.get(shop.items[slot - 2] or 0)
            if it then
                row.item, row.name, row.desc = it, it.name, it.desc
            else
                row.name = strings.get("Game.txt", "1124") or "This item has been sold"
            end
        end
        out[#out + 1] = row
    end
    return out
end

function S:draw()
    local g = love.graphics
    local sw, sh = g.getDimensions()
    g.setColor(0, 0, 0, 0.8)
    g.rectangle("fill", 0, 0, sw, sh)
    local ox, oy = self:origin()
    g.setFont(self.title)
    g.setColor(1, 0.85, 0.55)
    g.printf(strings.get("Game.txt", "1125") or "Shop", 0, 60, sw, "center")
    local mx, my = love.mouse.getPosition()
    self.hover = nil
    for _, r in ipairs(self:slots()) do
        local hover = mx >= r.x and mx < r.x + SLOT_W and my >= oy and my < oy + SLOT_H
        if hover then self.hover = r end
        g.setColor(hover and 0.35 or 0.15, hover and 0.22 or 0.08, 0.05, 0.9)
        g.rectangle("fill", r.x + 2, oy, SLOT_W - 4, SLOT_H)
        g.setColor(0.86, 0.7, 0.47, 0.7)
        g.rectangle("line", r.x + 2.5, oy + 0.5, SLOT_W - 5, SLOT_H - 1)
        g.setFont(self.font)
        if r.item then
            items.drawIcon(r.item, r.x + 60, oy + 14, 0.8)
        end
        g.setColor(1, 0.9, 0.5)
        g.printf(r.name, r.x, oy + 104, SLOT_W, "center")
        if r.price and r.price > 0 then
            -- the original shows the four costs, which are all the same number
            g.setColor(1, 0.85, 0.4)
            g.printf(("%d each"):format(r.price), r.x, oy + 128, SLOT_W, "center")
        end
        g.setFont(self.small)
        g.setColor(0.8, 0.8, 0.85)
        if r.desc then
            g.printf(r.desc, r.x + 6, oy + 152, SLOT_W - 12, "center")
        end
        if r.have then
            local have = strings.get("Game.txt", "1137")
            g.printf((have and have:format(r.have)) or ("(you have %d)"):format(r.have),
                r.x, oy + 172, SLOT_W, "center")
        end
    end
    if self.hover and self.hover.item then
        local lines = items.powerLines(self.hover.item) or {}
        if #lines > 0 then
            g.setFont(self.small)
            g.setColor(0.9, 0.9, 0.95)
            g.printf(table.concat(lines, "   "), 0, oy + SLOT_H + 26, sw, "center")
        end
    end
    if self.notice then
        g.setFont(self.font)
        g.setColor(1, 0.5, 0.4)
        g.printf(self.notice, 0, sh - 62, sw, "center")
    end
    g.setFont(self.small)
    g.setColor(0.6, 0.6, 0.6)
    g.printf((strings.get("Game.txt", "1126") or "Click on an item to buy it") .. "    Esc: leave",
        0, sh - 32, sw, "center")
    g.setColor(1, 1, 1)
end

-- The original's two refusals are drawn as two lines each ("Too" / "Expensive", "No" / "Room").
local function refuse(why)
    local function two(a, b, fallback)
        local x, y = strings.get("Game.txt", a), strings.get("Game.txt", b)
        if x and y then return x .. " " .. y end
        return fallback
    end
    if why == "expensive" then return two("1133", "1134", "Too expensive") end
    if why == "noroom" then return two("1135", "1136", "No room") end
    return strings.get("Game.txt", "1124") or "This item has been sold"
end

function S:mousepressed(mx, my, button)
    if button ~= 1 then return end
    local ox, oy = self:origin()
    if my < oy or my >= oy + SLOT_H then return end
    local slot = math.floor((mx - ox) / SLOT_W) + 1
    if slot < 1 or slot > 4 then return end
    local ok, why = sites.buy(self.world, self.hero, self.building, slot)
    if ok then
        sound.play("Assets/SoundFX.xcr", "Bing.wav")
        self.notice = nil
    else
        self.notice = refuse(why)
    end
end

function S:keypressed(key)
    if key == "escape" or key == "return" then screens.pop() end
end

function S:leave() end

return S
