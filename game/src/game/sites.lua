-- Neutral sites: lairs (creature nests), shops, shrines/mausoleums (see quests.lua).
--
-- Lairs (the original's lair manager: hit FUN_00404b10, spawn FUN_00404e10, boss FUN_00404cf0): a neutral lair breeds a group of
-- monsters every so often (the interval depends on the lair, 70..150 s), and the whole group
-- again the moment it is hit, once its 30 s reactivation cooldown has passed; a destroyed lair
-- leaves its boss behind at the lair itself. Group sizes grow with the elapsed game time (a
-- sixth of the group in the first two minutes, twice the group after an hour), and every
-- monster gets the experience of its level plus 0..3 more. The intervals, the spawn groups,
-- the troop levels and the boss levels are the original's numbers (its lair table from 0x005fb338,
-- read by FUN_00404e10 and FUN_00404cf0). The original's table
-- also has the quirk that the leader count is scaled from the *troop* count in the first three
-- time brackets and floored at 1 in the 8..10 minute bracket; kept here as it is.
-- Shops (the original's shop manager, constructor FUN_00408080): two items plus healing and mana potions, and a hatred
-- value per side that raises the price. Every hit a shop takes raises the hatred of every shop
-- for the attacking side by 50 (and the shop hit by 100), which is the original's doing: it
-- calls the shop manager's destruction notice FUN_00408360 from the building's damage handler FUN_0052bd10. Prices are paid out
-- of all four resources and a bought item is gone for good; the original's battle shop does not
-- sell anything (selling is a campaign feature).
local rules = require("src.game.rules")
local gamedata = require("src.game.gamedata")
local items = require("src.game.items")
local unit = require("src.game.unit")

local M = {}

-- A shop's stock and grudges (Building.shop).
---@class Shop
---@field items integer[]        the two item ids (0 = sold)
---@field hatred table<integer, number> side -> price percentage (90 .. 300)

-- A lair's breeding (Building.lair).
---@class LairState
---@field next number            world time of the next periodic breeding
---@field activeTime number?     a hit makes it breed again from this time on (nil only from a save without it)

M.NEUTRAL, M.RES = 6, require("src.content").resource:ids()
M.LAIR_ACTIVATE, M.LAIR_EFFECT, M.LAIR_BOSS = 30000, "EZ08", "_L@1R8055_"

-- The lair types are `lair` records (content/base/lairs.lua), keyed by the Building.cfg "lair" flag codes: min / max are the spawn
-- interval, boss is { unit, level } and each spawn group is { troops, troop, level, leaders, leader, leaderLevel }.
local content = require("src.content")
local lairs = content.lair
local function lairOf(code) return lairs._recs[code] end

local function isFlag(code, flag)
    local info = rules.building(code)
    return info ~= nil and info[flag] == true
end

---@param code string
---@return boolean
function M.isLair(code) return isFlag(code, "lair") end
---@param code string
---@return boolean
function M.isShop(code) return isFlag(code, "shop") end
---@param code string
---@return boolean
function M.isShrine(code) return isFlag(code, "searchable") end

-- a dice (1, n, -1) like the game's FUN_00458e70: a whole number in 0..n-1.
---@param n integer
---@return integer 0 .. n - 1
function M.dice(n)
    if n <= 0 then return 0 end
    return math.random(n) - 1
end

-- Called when a building is added to the world.
---@param world World
---@param b Building
function M.initBuilding(world, b)
    if b.side ~= M.NEUTRAL then return end
    if M.isShrine(b.code) and world.opts.quests ~= false then
        b.quest = { state = "free" }
    end
    if M.isShop(b.code) and not world.opts.net then
        b.shop = M.newShop(world)
    end
    if M.isLair(b.code) then
        local d = lairOf(b.code)
        -- the original's first interval: max plus 0..max/1000-1 seconds of dice
        b.lair = { next = world.time + d.max + M.dice(math.floor(d.max / 1000)) * 1000,
                   activeTime = world.time }
    end
end

-- Shops ---------------------------------------------------------------------------------

-- A shop's stock: two items rolled from the original's rarity flags, and a hatred of 90..110
-- for every side. The flags are rolled once per shop; artifacts only while the map has four
-- shops or fewer, sets only while it has two or fewer.
---@param world World
---@return Shop
function M.newShop(world)
    local shops = 1
    for _, b in ipairs(world.buildings) do
        if b.shop then shops = shops + 1 end
    end
    local tiers = {}
    if math.random(100) < 80 then tiers[2] = true end
    if math.random(100) < 80 then tiers[1] = true end
    if math.random(100) < 40 then tiers[3] = true end
    if shops <= 4 and math.random(100) < 5 then tiers[4] = true end
    if shops <= 2 and math.random(100) < 2 then tiers[5] = true end
    if not (tiers[1] or tiers[3] or tiers[4] or tiers[5]) then tiers[2] = true end
    local shop = { items = {}, hatred = {} }
    for _ = 1, 2 do
        local it = items.randomOf(tiers)
        shop.items[#shop.items + 1] = it and it.id or 0
    end
    for side = 0, M.NEUTRAL do shop.hatred[side] = 90 + M.dice(21) end
    return shop
end

-- The price of a slot (1 = healing potions, 2 = mana potions, 3..4 = the items) for a side:
-- the item's value times ten (potions 500), scaled by the shop's hatred and capped at 3000.
---@param b Building
---@param slot integer 1, 2 potions, 3, 4 the items
---@param side integer
---@return integer?
function M.price(b, slot, side)
    local shop = b.shop
    if not shop then return nil end
    local base
    if slot <= 2 then
        base = 500
    else
        local it = items.get((shop.items[slot - 2] or 0))
        base = it and (it.value or 0) * 10 or 0
    end
    return math.min(math.floor(base * (shop.hatred[side] or 100) / 100), 3000)
end

-- The original's shop destruction notice FUN_00408360, which the game calls from the building's damage
-- handler: every shop's hatred of the attacking side goes up by 50, and the shop hit again by
-- another 50. Both are capped at 300.
---@param world World
---@param b Building
---@param side integer? the attacker
function M.hit(world, b, side)
    if not b.shop then return end
    side = side or M.NEUTRAL   -- the original uses side 6 when there is no inflictor (FUN_0052bd10)
    for _, o in ipairs(world.buildings) do
        if o.shop then o.shop.hatred[side] = math.min((o.shop.hatred[side] or 100) + 50, 300) end
    end
    b.shop.hatred[side] = math.min((b.shop.hatred[side] or 100) + 50, 300)
end

-- Buys slot `slot` for the hero. Returns true, or false with "expensive" / "noroom" / "sold".
---@param world World
---@param hero Unit
---@param b Building
---@param slot integer
---@return boolean
---@return string? why
function M.buy(world, hero, b, slot)
    local shop = b.shop
    if not shop or not hero.h then return false, "none" end
    local sd = world.sides[hero.side]
    local price = M.price(b, slot, hero.side)
    if slot > 2 and (shop.items[slot - 2] or 0) == 0 then return false, "sold" end
    local key
    if slot <= 2 then
        key = slot == 1 and "health" or "mana"
        if (hero.h.potions[key] or 0) >= 9 then return false, "noroom" end
    end
    for _, r in ipairs(M.RES) do
        if (sd[r] or 0) < price then return false, "expensive" end
    end
    if slot <= 2 then
        hero.h.potions[key] = hero.h.potions[key] + 1
    else
        local it = items.get(shop.items[slot - 2])
        -- an unsold slot holds an item of the catalogue
        ---@cast it -nil
        -- a full backpack means the item lands on the ground next to the hero
        if not hero.h:give(it) then world:dropItem(hero.gx, hero.gy, it) end
        shop.items[slot - 2] = 0
    end
    for _, r in ipairs(M.RES) do sd[r] = sd[r] - price end
    return true
end

-- Lairs ---------------------------------------------------------------------------------

-- The group a lair breeds. `timer` says whether this is the periodic breeding (a fraction of
-- the group, at least one) or the reaction to a hit (the whole group).
local function lairSpawn(world, b, d, timer, t)
    local sp = d.spawns[math.random(#d.spawns)]
    local tCode, tLevel, nTroops = sp.troop, sp.level, sp.troops
    local lCode, lLevel, nLead = sp.leader, sp.leaderLevel or 1, sp.leaders or 0
    local minTroops, minLead = timer and 1 or nTroops, timer and 1 or nLead
    -- the original scales the leaders from the troop count for the first three brackets
    local function scale(num, den, min, base)
        return math.max(min, math.floor(num * (base or sp.troops) / den))
    end
    if t < 2 * 60000 then
        nTroops, nLead = scale(1, 6, minTroops), scale(1, 6, minLead)
    elseif t < 4 * 60000 then
        nTroops, nLead = scale(1, 4, minTroops), scale(1, 4, minLead)
    elseif t < 6 * 60000 then
        nTroops, nLead = scale(1, 3, minTroops), scale(1, 3, minLead)
    elseif t < 8 * 60000 then
        nTroops, nLead = scale(1, 2, minTroops), math.max(1, math.floor(nLead / 2))
    elseif t < 10 * 60000 then
        nTroops, nLead = scale(2, 3, minTroops, nTroops), scale(2, 3, minLead, nLead)
    elseif t < 14 * 60000 then
        nTroops, nLead = scale(3, 4, minTroops, nTroops), scale(3, 4, minLead, nLead)
    elseif t < 20 * 60000 then
        nTroops, nLead = scale(1, 1, minTroops, nTroops), scale(1, 1, minLead, nLead)
    elseif t < 30 * 60000 then
        nTroops, nLead = scale(5, 4, minTroops, nTroops), scale(5, 4, minLead, nLead)
    elseif t < 40 * 60000 then
        nTroops, nLead = scale(3, 2, minTroops, nTroops), scale(3, 2, minLead, nLead)
    elseif t < 60 * 60000 then
        nTroops, nLead = scale(7, 4, minTroops, nTroops), scale(7, 4, minLead, nLead)
    else
        nTroops, nLead = scale(2, 1, minTroops, nTroops), scale(2, 1, minLead, nLead)
    end
    if not tCode then nTroops = 0 end
    if not lCode then nLead = 0 end

    -- the original's production cell (FUN_0052df30) with no rally point: below the building
    local shape = b.shape or { w = 1, h = 1 }
    local py = b.gy + shape.h - math.floor(shape.h / 4)
    local function spawn(code, level, n)
        local xp = (unit.XP_FOR_LEVEL[level] or 0) + M.dice(4)
        local move = (gamedata.army(code) or {}).moveType or 0
        for _ = 1, n do
            local x, y = world:nearestFree(b.gx, py, move, 6)
            if x then
                local u = world:addUnit(code, M.NEUTRAL, x, y, { xp = xp })
                if u then u.lairHome = b end
            end
        end
    end
    if nTroops > 0 then spawn(tCode, tLevel, nTroops) end
    if nLead > 0 then spawn(lCode, lLevel, nLead) end
    M.effect(world, b, M.LAIR_EFFECT)
end

-- The animation the lair's creatures arrive with, at the lair itself.
---@param world World
---@param b Building
---@param code string
function M.effect(world, b, code)
    world.effects = world.effects or {}
    world.effects[#world.effects + 1] = { kind = "sprite", code = code, x = b.x, y = b.y,
                                          t0 = world.time, dur = 1600 }
end

-- A destroyed lair leaves its boss behind at the lair.
---@param world World
---@param b Building
function M.boss(world, b)
    local d = lairOf(b.code)
    if not d or not d.boss then return end
    local code, level = d.boss.unit, d.boss.level
    local xp = (unit.XP_FOR_LEVEL[level + 1] or 0) + M.dice(4)
    world:addUnit(code, M.NEUTRAL, b.gx, b.gy, { name = M.LAIR_BOSS, xp = xp })
    M.effect(world, b, M.LAIR_EFFECT)
end

-- Lair breeding, called from the world update.
---@param world World
---@param t number
function M.update(world, t)
    for _, b in ipairs(world.buildings) do
        local lair = b.lair
        if lair and b.hp > 0 and b.complete ~= false then
            local d = lairOf(b.code)
            if d and t >= lair.next then
                lair.next = t + d.min + M.dice(math.floor((d.max - d.min) / 1000) + 1) * 1000
                lair.activeTime = t + M.LAIR_ACTIVATE
                lairSpawn(world, b, d, true, t)
            end
        end
    end
    require("src.game.quests").update(world, t)
end

-- The original's destruction notices of both managers (FUN_00404ac0, FUN_00408360), which the game also calls when the
-- building dies (FUN_0052b3e0):
-- the lair leaves its boss behind and stops breeding, the shop's hatred is raised once more.
---@param world World
---@param b Building
---@param side integer?
function M.destroyed(world, b, side)
    if b.lair then
        M.boss(world, b)
        b.lair = nil
    end
    if b.shop then M.hit(world, b, side) end
end

-- A lair reacts to a hit once its cooldown has passed; a shop raises its hatred.
---@param world World
---@param b Building
---@param side integer?
function M.damage(world, b, side)
    if b.shop then M.hit(world, b, side) end
    local lair = b.lair
    if lair and world.time >= lair.activeTime then
        local d = lairOf(b.code)
        lair.next = world.time + d.min + M.dice(math.floor((d.max - d.min) / 1000) + 1) * 1000
        lair.activeTime = world.time + M.LAIR_ACTIVATE
        lairSpawn(world, b, d, false, world.time)
    end
end

return M
