-- The special-ability keys of KeyMap.txt (the file's second block, src/ui/keymap.lua), after the 1.04 binary.
-- FUN_00427fb0 hands every key to FUN_00427f70 before any other shortcut; that runs, in table order, the case of the
-- ability handler FUN_00426350 of every ability key that is the pressed key, until one of them reports it is done. A
-- key that is done goes no further; otherwise it goes on to the other shortcuts (Shift+H: Healing, then Goblin Horde
-- in the shipped file, then Add / Remove Hero). The unit ability buttons call the same cases (their actions at
-- 0x004cfa80 ... push the case number and call FUN_00426350).
--
-- A unit ability case (an `ability` record with `key`, content/base/abilities.lua) picks one caster with FUN_00427cf0:
-- per caster type in the record's order (`keyUnits` or `units`), the first selected army of the type with the mana
-- (FUN_0051b340: mana >= cost and a mana pool; a cost of 0 asks nothing here), else the player's first army of that type
-- inside the cells the screen shows with the mana, column by column from the left and each column top down. The first
-- type that gives a caster is used (`keyFirst` types are looked for in the selection only, before the others: Entangle,
-- case 0xc). The case is done when its checks pass: the army limit for the summons (FUN_005776c0), the Feast power-up
-- (case 0x19, DAT_0070d58b is set by PZOM); Feast and Scavenge are done even when their once-a-second timer then
-- refuses. Invisibility (case 0xd) first lets every selected army of its `keyLoop` types with the mana cast (the Chameleon
-- with Blending; ASWM is accepted although no button offers it and no such army exists); when one did, the case is not
-- done; else one caster of `keyUnits` as above. Earthpower's key needs neither the power-up nor the race (case 0x18).
-- Drunkenness (case 0xf) presses the Drunkenness button for the selection (FUN_004cf7d0) and is never done; Star of
-- Sartek (0x10) has no case. A building ability (Holy Word 0x13, Elcor's Balm 0x14, Chaos Plague 0x22, Couatl's Wrath
-- 0x24, Famine 0x2a, Sword of Sirian 0x2e) needs its power-up and a building of `keyBuildings`, tried in that order
-- (FUN_00427e30, always with the whole-map flag: the first selected one, else the player's first one anywhere on the
-- map in the same column order); it is then used without the button's timer and target check, Chaos Plague, Wrath
-- and Sword without paying (buildingabilities.use with `key`), and the case is never done.
-- The picks are made here, on the machine of the player who pressed the key, and the commands carry the ids, so every
-- peer of a network game applies the same thing. openwbc3 only picks the player's own armies and buildings from the
-- selection (the binary's selection passes do not look at the owner; a command can only act for its own side).
local content = require("src.content")
local powerups = require("src.game.powerups")

local M = {}

M.DRUNKENNESS = 15                -- case 0xf: the Drunkenness button

---@type table<integer, table>? case -> ability record
local byCase

local function records()
    if not byCase then
        byCase = {}
        for _, a in ipairs(content.ability:all()) do
            if a.key then byCase[a.key] = a end
        end
    end
    return byCase
end

-- FUN_0051b340: enough mana, and a mana pool at all
local function hasMana(u, cost)
    return (u.maxMana or 0) > 0 and (u.mana or 0) >= cost
end

-- The map's order: column by column, each column top down (the per-column object lists FUN_00547b80).
local function mapBefore(a, b)
    if a.gx ~= b.gx then return a.gx < b.gx end
    if a.gy ~= b.gy then return a.gy < b.gy end
    return (a.id or 0) < (b.id or 0)
end

local function own(e, side) return e.side == side end

-- FUN_00427cf0: the caster of type `code`. `view` = { x0, y0, x1, y1 }, the cells on the screen (inclusive).
---@return Unit?
local function findCaster(world, side, code, cost, selection, view, selectionOnly)
    for _, e in ipairs(selection) do
        if e.kind == "unit" and own(e, side) and e:alive() and e.code == code and (cost == 0 or hasMana(e, cost)) then
            return e
        end
    end
    if selectionOnly then return nil end
    local best
    for _, u in ipairs(world.units) do
        if own(u, side) and u.code == code and u:alive() and not u.hidden and u.gx >= view[1] and u.gy >= view[2]
            and u.gx <= view[3] and u.gy <= view[4] and hasMana(u, cost) and (not best or mapBefore(u, best)) then
            best = u
        end
    end
    return best
end

-- FUN_00427e30 with the whole-map flag: the building of type `code`.
---@return Building?
local function findBuilding(world, side, code, selection)
    for _, e in ipairs(selection) do
        if e.kind == "building" and own(e, side) and e.hp > 0 and e.code == code then return e end
    end
    local best
    for _, b in ipairs(world.buildings) do
        if own(b, side) and b.code == code and b.hp > 0 and (not best or mapBefore(b, best)) then best = b end
    end
    return best
end

local function unitCase(world, side, a, selection, view)
    local sd = world.sides[side]
    local cost = a.cost or a.mana
    local function powered(code)
        local need = not a.keyNoPower and a.power and a.power[code]
        return not need or powerups.has(sd, need)
    end
    if a.keyLoop then
        local types, ids = {}, {}
        for _, code in ipairs(a.keyLoop) do types[code] = true end
        for _, e in ipairs(selection) do
            if e.kind == "unit" and own(e, side) and e:alive() and types[e.code] and powered(e.code) and hasMana(e, cost) then
                ids[#ids + 1] = e.id
            end
        end
        if #ids > 0 then return { { t = "army", ids = ids, ability = a.id, key = true } }, false end
    end
    local caster
    for _, code in ipairs(a.keyFirst or {}) do
        caster = caster or findCaster(world, side, code, cost, selection, view, true)
    end
    for _, code in ipairs(a.keyUnits or a.units) do
        caster = caster or findCaster(world, side, code, cost, selection, view, false)
    end
    if not caster or not powered(caster.code) then return {}, false end
    if a.limit and not world.eco:roomFor(side, a.limit) then return {}, false end
    return { { t = "army", ids = { caster.id }, ability = a.id, key = true } }, true
end

local function buildingCase(world, side, a, selection)
    if require("src.game.buildingabilities").level(world.sides[side], a) == 0 then return {}, false end
    for _, code in ipairs(a.keyBuildings) do
        local b = findBuilding(world, side, code, selection)
        if b then return { { t = "ability", bid = b.id, ability = a.id, key = true } }, false end
    end
    return {}, false
end

-- One case of FUN_00426350 for the player `side`: the commands it gives and whether it is done.
---@param world World
---@param side integer
---@param case integer 0 .. 47
---@param selection (Unit|Building)[]
---@param view integer[] { x0, y0, x1, y1 }: the cells on the screen
---@return Command[], boolean
function M.case(world, side, case, selection, view)
    if case == M.DRUNKENNESS then
        local first = selection[1]
        local ids = {}
        if first and first.kind == "unit" then
            for _, e in ipairs(selection) do
                if e.kind == "unit" and own(e, side) then ids[#ids + 1] = e.id end
            end
        end
        if #ids == 0 then return {}, false end
        return { { t = "army", ids = ids, ability = "drunkenness" } }, false
    end
    local a = records()[case]
    if not a then return {}, false end
    if a.kind == "building" then return buildingCase(world, side, a, selection) end
    return unitCase(world, side, a, selection, view)
end

-- A key press (FUN_00427f70): the cases of the pressed key in table order until one is done. Returns the commands to
-- issue, in order, and whether the key is used up (no other shortcut then sees it).
---@param world World
---@param side integer
---@param cases integer[] keymap.abilities(key)
---@param selection (Unit|Building)[]
---@param view integer[] { x0, y0, x1, y1 }: the cells on the screen
---@return Command[], boolean
function M.press(world, side, cases, selection, view)
    local out = {}
    for _, case in ipairs(cases) do
        local cmds, done = M.case(world, side, case, selection, view)
        for _, c in ipairs(cmds) do out[#out + 1] = c end
        if done then return out, true end
    end
    return out, false
end

return M
