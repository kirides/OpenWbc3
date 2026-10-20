-- Player commands as plain data. Every order a player gives (move, attack, build, cast ...) is a
-- command table that refers to units and buildings by id; `apply` carries it out. In a network
-- game the commands are exchanged and applied by every peer at the same game tick.
--
--   { t = "move", moves = { {id, x, y}, ... }, pace }
--   { t = "attack", ids, target = {kind, id} }
--   { t = "task", kind = "convert"|"mine"|"garrison"|"visit", ids, bid }
--   { t = "stop", ids }                       orders accept queue = true (Shift) / interrupt = true (Alt)
--   { t = "patrol", ids, points = {{gx, gy} ...} }  { t = "guard", ids, target = id }  { t = "unqueue", ids, all }
--   { t = "build", id, code, gx, gy }         or { t = "build", id, sections = { {code, gx, gy} ... } }: drag-built walls
--   { t = "rally", bid, gx, gy }              { t = "enqueue", bid, code, n }
--   { t = "select", ids }                    what the side has selected (scenario events react to it)
--   { t = "cancel", bid }  { t = "dequeue", bid, index }  { t = "unload", bid, uid? }  { t = "repair", bid, speed 0|1 }
--   { t = "keepconvert", bid }                a keep's Convert button
--   { t = "gift", to = side, res = "gold"|..., amount }   resources to another side (diplomacy dialog)
--   { t = "army", ids, ability }              army ability button: morph*, drunkenness, fanaticism, sacrifice, mergeWisps
--   { t = "army", ids, ability, key = true }  a KeyMap.txt ability key: ids = the casters it picked (game/abilitykeys.lua)
--   { t = "ability", bid, ability, key? }     a building's ability button (key: its KeyMap.txt key)
--   { t = "guard", ids, target = id, attitude = "guardian" | "magicGuardian" | a custom designating attitude }
--   { t = "cast", id, spell, target = {gx, gy} | {unit = id} }
--   { t = "quest", op = "accept"|"complete", bid, hero, answer? }   a shrine's quest (answer: the typed text of a kind 4 quest)
--   { t = "chooseFoe", index }               the Knight's Quest dialog: candidate 1..4 becomes a chosen foe
--   { t = "hero", id, op, a }   op: spendAttr | spendSkill | refundAttr | refundSkill (a = key), learn (a = spell),
--                               potion (a = "health" | "mana"), equip | unequip | drop | dropEquipped (a = pack index / slot)
-- `side` is added by the issuer; units and buildings of other sides are ignored.

-- A player command (see the list above): plain data, the same on every peer of a network game. One class for all kinds;
-- which fields a kind uses is in the list above.
---@class Command
---@field t string                  the kind: "move", "attack", "task", "build", "cast" ...
---@field side integer?             set by the issuer (the lockstep host for network commands)
---@field ids integer[]?            the units given the order
---@field id integer?               the one unit (build, hero, cast)
---@field bid integer?              the building
---@field bids integer[]?           the buildings (destroy, attitude)
---@field queue boolean?            Shift: queue behind the current orders
---@field interrupt boolean?        Alt: run first, the current order resumes afterwards
---@field moves {[1]: integer, [2]: integer, [3]: integer}[]? move: { unit id, x, y } each
---@field pace number?
---@field target any                attack: {kind, id}; guard: a unit id; cast: {gx, gy} | {unit = id} | {choice = i}
---@field kind string?              task: "convert" | "mine" | "garrison" | "visit"
---@field points {[1]: integer, [2]: integer}[]? patrol
---@field all boolean?              unqueue: every queued order
---@field code string?              build / enqueue
---@field gx integer?
---@field gy integer?
---@field sections {code: string, gx: integer, gy: integer}[]? build: drag-built walls
---@field n integer?                enqueue: how many
---@field index integer?            dequeue: queue slot; chooseFoe: candidate
---@field uid integer?              unload: one army
---@field speed integer?            repair: 0 slow, 1 fast
---@field to integer?               gift: the side; trade: the resource (index of economy.GIFT_RESOURCES)
---@field from integer?             trade
---@field res string?               gift: the resource
---@field amount integer?           gift / trade
---@field ability string?           army / building ability
---@field key boolean?              army / ability: pressed with its KeyMap.txt key (game/abilitykeys.lua)
---@field attitude string?          attitude / guard
---@field op string?                hero / quest: the operation
---@field a any                     hero: the operation's argument
---@field spell integer?            cast
---@field hero integer?             quest: the hero's unit id
---@field answer string?            quest: a typed answer

local M = {}

---@param world World
---@return Unit?
local function unit(world, id, side)
    for _, u in ipairs(world.units) do
        if u.id == id then return u.side == side and u:alive() and u or nil end
    end
end

---@param world World
---@return Unit?
local function anyUnit(world, id)
    for _, u in ipairs(world.units) do if u.id == id then return u end end
end

---@param world World
---@return Building?
local function building(world, id)
    for _, b in ipairs(world.buildings) do if b.id == id then return b end end
end

local function idSet(ids)
    local set = {}
    for _, id in ipairs(ids or {}) do set[id] = true end
    return set
end

---@param world World
---@return Unit[]
local function mine(world, side, ids)
    local set, out = idSet(ids), {}
    for _, u in ipairs(world.units) do
        if set[u.id] and u.side == side and u:alive() then out[#out + 1] = u end
    end
    return out
end

-- Gives an order: with `queue` (shift) it waits behind the unit's current ones; Alt (`interrupt`) inserts it at the
-- head so it runs first and the running order resumes afterwards; otherwise it replaces them.
-- `spec` is a plain order (see Unit:enqueue), so that queued orders can be saved.
---@param u Unit
---@param cmd Command
---@param spec UnitOrder
local function give(u, cmd, spec)
    if cmd.queue then
        u:enqueue(spec)
    elseif cmd.interrupt then
        u:insertOrder(spec)
    else
        u:clearOrders()
        u:runOrder(spec)
    end
end

---@param world World
---@param cmd Command
function M.apply(world, cmd)
    local side = cmd.side
    ---@cast side -nil
    local t = cmd.t
    local eco = world.eco
    if t == "move" then
        local byId = {}
        for _, m in ipairs(cmd.moves) do byId[m[1]] = m end
        for _, u in ipairs(world.units) do
            local m = byId[u.id]
            if m and u.side == side and u:alive() then
                give(u, cmd, { kind = "move", x = m[2], y = m[3], pace = cmd.pace })
            end
        end
    elseif t == "attack" then
        local target = cmd.target
        local tg
        if target.kind == "building" then tg = building(world, target.id) else tg = anyUnit(world, target.id) end
        if not tg then return end
        for _, u in ipairs(mine(world, side, cmd.ids)) do give(u, cmd, { kind = "attack", target = tg }) end
    elseif t == "task" then
        local b = building(world, cmd.bid)
        if not b then return end
        local list = mine(world, side, cmd.ids)
        for _, u in ipairs(list) do give(u, cmd, { kind = "taskb", what = cmd.kind, building = b }) end
    elseif t == "convert" then
        -- the convert button (Ctrl+C): Shift queues a deferred convert that converts whatever is in range where the unit
        -- stands when the order runs; Alt inserts it; plain converts now (needs a target nearby)
        for _, u in ipairs(mine(world, side, cmd.ids)) do give(u, cmd, { kind = "convert" }) end
    elseif t == "stop" then
        for _, u in ipairs(mine(world, side, cmd.ids)) do u:stop() end
    elseif t == "build" then
        local u = unit(world, cmd.id, side)
        if u and cmd.sections then
            -- drag-built walls (the dragged wall line of FUN_00429820, ordered by the map action executor FUN_0041f0b0):
            -- the first section is built now, the others wait behind it as queued build orders; heroes and treants
            -- cannot build walls
            local walls = require("src.game.walls")
            if not walls.canBuild(u) then return end
            for i, s in ipairs(cmd.sections) do
                if i > walls.MAX then break end
                if walls.isWall(s.code) then
                    local spec = { kind = "build", code = s.code, gx = s.gx, gy = s.gy }
                    if i == 1 then give(u, cmd, spec) else u:enqueue(spec) end
                end
            end
        elseif u then
            give(u, cmd, { kind = "build", code = cmd.code, gx = cmd.gx, gy = cmd.gy })
        end
    elseif t == "patrol" then
        for _, u in ipairs(mine(world, side, cmd.ids)) do u:setPatrol(cmd.points, cmd.queue) end
    elseif t == "guard" then
        local other = anyUnit(world, cmd.target)
        if other and other.side == side then
            -- the Guard order gives the Guardian attitude with the designated unit (FUN_0051a3f0: attitude 7 with
            -- the target)
            local def = require("src.game.attitude").def[cmd.attitude]
            local att = def and def.designated and cmd.attitude or "guardian"       -- custom .uai attitudes may designate too
            for _, u in ipairs(mine(world, side, cmd.ids)) do
                u:setGuard(other)
                if u.guarding then u.attitude = att end
            end
        end
    elseif t == "army" then
        -- army ability buttons (armyabilities.lua) and formation rotation needs no command (it is a move)
        require("src.game.armyabilities").use(world, side, mine(world, side, cmd.ids), cmd.ability, cmd.key)
    elseif t == "unqueue" then
        for _, u in ipairs(mine(world, side, cmd.ids)) do
            if cmd.all then u:removeQueuedOrders() else u:removeLastOrder() end
        end
    elseif t == "rally" then
        local b = building(world, cmd.bid)
        if b and b.side == side then b.rally = { cmd.gx, cmd.gy } end
    elseif t == "enqueue" then
        local b = building(world, cmd.bid)
        if b and b.side == side and b.complete then eco:enqueue(b, cmd.code, cmd.n) end
    elseif t == "cancel" then
        local b = building(world, cmd.bid)
        if b and b.side == side then eco:cancel(b) end
    elseif t == "keepconvert" then
        local b = building(world, cmd.bid)
        if b and b.side == side then eco:startKeepConversion(b) end
    elseif t == "dequeue" then
        local b = building(world, cmd.bid)
        if b and b.side == side and b.queue[cmd.index] then table.remove(b.queue, cmd.index) end
    elseif t == "continuous" then
        -- the control panel's continuous army production button (button 0x36 of the panel's mouse handler
        -- FUN_004d54c0 flips the flag at +0x190 of the selected building)
        local b = building(world, cmd.bid)
        if b and b.side == side then b.continuous = not b.continuous end
    elseif t == "repair" then
        local b = building(world, cmd.bid)
        if b and b.side == side then eco:repair(b, cmd.speed) end
    elseif t == "gift" then
        local amount = require("src.game.economy").GIFT_AMOUNTS
        local ok = false
        for _, a in ipairs(amount) do if a == cmd.amount then ok = true end end
        if ok then eco:gift(side, cmd.to, cmd.res, cmd.amount) end
    elseif t == "destroy" then
        -- Ctrl+D: own units and buildings destroy themselves (heroes only when selected alone)
        local list = cmd.ids or {}
        local alone = #list + #(cmd.bids or {}) == 1
        for _, u in ipairs(mine(world, side, list)) do
            if alone or not u.hero then u:die(world.time, nil) end
        end
        for _, id in ipairs(cmd.bids or {}) do
            local b = building(world, id)
            if b and b.side == side and b.hp > 0 then
                b.hp = 0
                b.destroyed = true
                if b.shape then world:blockShape(b.gx, b.gy, b.shape, false) end
            end
        end
    elseif t == "attitude" then
        -- the attitude of units, and of buildings (what the units they produce start with)
        local attitude = require("src.game.attitude")
        -- Guardian / Magic Guardian need a designated unit: they come with the guard command
        if attitude.def[cmd.attitude] and not attitude.def[cmd.attitude].designated then
            for _, u in ipairs(mine(world, side, cmd.ids)) do
                u.attitude = cmd.attitude
                u.guarding = nil
            end
            for _, id in ipairs(cmd.bids or {}) do
                local b = building(world, id)
                if b and b.side == side then b.attitude = cmd.attitude end
            end
        end
    elseif t == "ability" then
        local b = building(world, cmd.bid)
        if b then require("src.game.buildingabilities").use(world, side, b, cmd.ability, nil, cmd.key) end
    elseif t == "trade" then
        local rate = require("src.game.buildingabilities").tradeRate(world, side)
        for _, a in ipairs(require("src.game.economy").GIFT_AMOUNTS) do
            if a == cmd.amount then eco:trade(side, cmd.from, cmd.to, cmd.amount, rate) end
        end
    elseif t == "resign" then
        -- advanced option "Resignation kills a side": without it the player just leaves (battle.lua), nothing happens here
        if world.advanced.resignKills then eco:resign(side) end
    elseif t == "chooseFoe" then
        require("src.game.powerups").chooseFoe(world, side, cmd.index)
    elseif t == "quest" then
        require("src.game.quests").command(world, side, cmd)
    elseif t == "select" then
        local selected = world.selected or {}
        world.selected = selected
        selected[side] = cmd.ids or {}
    elseif t == "unload" then
        local b = building(world, cmd.bid)
        if b and b.side == side then
            local who
            for _, g in ipairs(b.garrison or {}) do if g.id == cmd.uid then who = g end end
            if not cmd.uid or who then eco:unload(b, who) end       -- one army (the info area's slot click) or all
        end
    elseif t == "hero" then
        local u = unit(world, cmd.id, side)
        local h = u and u.h
        if not h then return end
        ---@cast u -nil
        local op, a = cmd.op, cmd.a
        if op == "spendAttr" then h:spendAttr(a)
        elseif op == "spendSkill" then h:spendSkill(a)
        elseif op == "refundAttr" then h:refundAttr(a)
        elseif op == "refundSkill" then h:refundSkill(a)
        elseif op == "levelDone" then h:endLevelUp()          -- the level-up dialog was closed
        elseif op == "potion" then h:drink(a)
        elseif op == "equip" then h:equip(a)
        elseif op == "unequip" then h:unequip(a)
        elseif op == "drop" or op == "dropEquipped" then
            local item = op == "drop" and h:drop(a) or h:dropEquipped(a)
            if item then world:dropItem(u.gx, u.gy, item, 4, u) end
        end
    elseif t == "cast" then
        local hero = unit(world, cmd.id, side)
        if not hero or not hero.h then return end
        local target = cmd.target
        if target and target.unit then target = anyUnit(world, target.unit) end
        require("src.game.spells").cast(hero, cmd.spell, target)
    end
end

return M
