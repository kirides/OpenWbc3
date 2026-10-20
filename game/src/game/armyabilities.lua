-- Army abilities: the special buttons of selected units (the original's ability buttons, filled by FUN_004d3200 in the
-- 1.04 binary) and what they do.
--
--   morphWight ... morphLiche   Undead only: a Skeleton becomes a Wight / Wraith, a Wraith a Shadow, a Wight a Slayer Knight /
--                               Liche, a Slayer Knight a Doom Knight. Fixed price (80 / 70 / 120 / 250 / 150 / 350
--                               metal or crystal, Merchant discount applies), needs the matching building, the unit
--                               keeps its fraction of hit points. A group morphs as many units as the resources allow.
--   drunkenness                 Dwarves (not heroes) and Minotaurs, power-up Dwarven Brew (PDRU): 10 gold per unit, two
--                               minutes of +4 combat and speed and immunity to psychic effects (status.lua kind drunk).
--   fanaticism                  Minotaurs and Axe Throwers of the Minotaur race, Barbarians and Reavers of the Barbarian race;
--                               enabled by the Berserk power-up (PFAN): three minutes of +6 combat / +4 speed, one hit point
--                               lost per second, rampant attitude (status.lua kind fanatic).
--   sacrifice                   Dark Elves (or the Sacrifice power-up PSAC): infantry that is not undead, planar, a hero or a
--                               named character is sacrificed for 5 crystal each; the chance of a Daemon is 4 % per unit
--                               (button action 0x004ced00: count * 5 crystal, 1d100 against count * 4).
--   mergeWisps                  4 Wisps within 30 cells (power-up PWSP, 100 crystal per group of four): they walk to the
--                               first one, which waits there until the others have arrived; the original's wait counter
--                               is never finished, so a merge has no timeout (not traced in the 1.04 binary yet).
--   rotate                      Formation rotation buttons (battle screen S:formUp) when little else is on offer.
-- Star of Sartek is a passive power-up in the original (its button function does nothing) and Follow does nothing
-- either, so neither has a button here. Disguise and Earthquake have no button either: the original never offers them
-- (the binary has no Earthquake text at all, "Disguise" is only the Thief hero speciality name; the button layout itself
-- was not traced in the 1.04 binary for them yet).
-- Computer players: drunkenness when hit and Dwarven Brew owned (the ability decision FUN_00500830), the wisp merge
-- (FUN_004f8290: with four idle wisps it merges, paying only if it can) and the Undead morph missions (FUN_004fd8c0 /
-- FUN_004fd940 / FUN_004f8dc0).
local content = require("src.content")
local powerups = require("src.game.powerups")
local rules = require("src.game.rules")
local gamedata = require("src.game.gamedata")
local strings = require("src.game.strings")
local status = require("src.game.status")

local M = {}

local ICON = { rotateLeft = 42, rotateRight = 43 }

-- race numbers by name (the race records' slots): RACE.DWARF ...
local RACE = setmetatable({}, { __index = function(_, name) return content.race:slotOf(name:lower()) end })
M.DRUNK_COST, M.DRUNK_TIME = 10, 120000
M.SACRIFICE_COST, M.SACRIFICE_PERCENT, M.SACRIFICE_PAUSE = 5, 4, 3000
M.MERGE_COST, M.MERGE_RANGE = 100, 30
M.FANATIC_TIME = 180000
M.MORPH_PAUSE = 50000          -- the AI's time between builds of an army type (unset: 50000, FUN_004f8600)

-- The morph and spell-button abilities are the `ability` records of content/base/abilities.lua (documented there): `MORPHS` (kind "morph",
-- by id), `M.MORPH_ORDER` (the buttons per source type) and `ABILITIES` (kind "spell", by id) are views of them.
M.MORPHS, M.MORPH_ORDER, M.ABILITIES = {}, {}, {}
local ABIL_BY_CODE = {}
for _, a in ipairs(content.ability:all()) do
    if a.kind == "morph" then
        M.MORPHS[a.id] = a
        local list = M.MORPH_ORDER[a.from] or {}
        list[a.order] = a.id
        M.MORPH_ORDER[a.from] = list
    elseif a.kind == "spell" then
        M.ABILITIES[a.id] = a
        for _, code in ipairs(a.units) do
            ABIL_BY_CODE[code] = ABIL_BY_CODE[code] or {}
            ABIL_BY_CODE[code][#ABIL_BY_CODE[code] + 1] = a.id
        end
    end
end

local function text(id)
    return strings.get("Game.txt", id) or id
end

local function has(world, side, code) return powerups.has(world.sides[side], code) end

local function flag(code, mask) return require("bit").band(powerups.flags(code), mask) ~= 0 end

-- Who can get drunk: non-hero dwarves, Minotaurs and Axe Throwers.
---@param u Unit
---@return boolean
function M.canGetDrunk(u)
    return (flag(u.code, 0x2) and not u.hero) or u.code == "AMIX" or u.code == "AMNX"
end

-- FUN_004ce210
---@param u Unit
---@return boolean
function M.canSacrifice(u)
    local t = gamedata.army(u.code)
    if not t or u.hero or t.hero or t.general then return false end
    return t.tagSet.infantry == true and not t.tagSet.undead and not t.tagSet.planar
end

-- FUN_004ce120: only wisps, at least four, all within 30 cells of each other.
---@param units Unit[]
---@return boolean
function M.canMerge(units)
    if #units < 4 then return false end
    local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
    for _, u in ipairs(units) do
        if u.code ~= "AEBX" then return false end
        x0, y0, x1, y1 = math.min(x0, u.gx), math.min(y0, u.gy), math.max(x1, u.gx), math.max(y1, u.gy)
    end
    return x1 - x0 <= M.MERGE_RANGE and y1 - y0 <= M.MERGE_RANGE
end

local function canPay(world, side, res, amount, n)
    local eco = world.eco
    return world.sides[side][res] >= n * eco:price(side, amount)
end

-- The special buttons of the selection: { id, icon, tip, disabled } in the original's order. `taken` = buttons the
-- caller already put in the three special slots (convert, spells, build).
---@param world World
---@param side integer
---@param units Unit[] the selection
---@param taken integer?
---@return {id: string, icon: integer, tip: string, disabled: boolean?}[]
function M.buttons(world, side, units, taken)
    local out = {}
    local n = #units
    if n == 0 then return out end
    local sd = world.sides[side]
    local race = sd.race
    local homogeneous, characters = true, false
    local allSacrifice, allDrunk, allFanatic = true, true, true
    local first = units[1].code
    for _, u in ipairs(units) do
        if u.hero or (rules.armyInfo(u.code) or {}).hero then characters = true end
        if u.code ~= first then homogeneous = false end
        if allSacrifice and not M.canSacrifice(u) then allSacrifice = false end
        if allDrunk and not M.canGetDrunk(u) then allDrunk = false end
        if allFanatic and u.fx and u.fx.fanatic then allFanatic = false end
        if race == RACE.MINOTAUR then
            if allFanatic and not (u.code == "AMIX" or u.code == "AMNX") then allFanatic = false end
        elseif race == RACE.BARBARIAN then
            if allFanatic and not (u.code == "ABIX" or u.code == "ABGX") then allFanatic = false end
        else
            allFanatic = false
        end
    end
    local count = taken or 0
    local function add(e)
        if count < 3 then
            out[#out + 1] = e
            count = count + 1
        end
    end
    local function drunk()
        local pu = has(world, side, "PDRU")
        if (pu or race == RACE.DWARF) and allDrunk then
            add({ id = "drunkenness", icon = 22, tip = text("0096"), disabled = not (pu and sd.gold >= M.DRUNK_COST * n) })
        end
    end
    local function sacrifice()
        local pu = has(world, side, "PSAC")
        if (pu or race == RACE.DARKELF) and allSacrifice then
            add({ id = "sacrifice", icon = 26, tip = text("0123"),
                  disabled = not (pu and sd.crystal >= M.SACRIFICE_COST * n) })
        end
    end
    local function fanaticism()
        if allFanatic then
            add({ id = "fanaticism", icon = 50, tip = text("0142"), disabled = not has(world, side, "PFAN") })
        end
    end
    if not homogeneous then
        drunk()
        sacrifice()
        fanaticism()
        if count <= 1 then
            add({ id = "rotateLeft", icon = ICON.rotateLeft, tip = "Rotate formation" })
            add({ id = "rotateRight", icon = ICON.rotateRight, tip = "Rotate formation" })
        end
        return out
    end
    if race == RACE.UNDEAD and not characters then
        for _, id in ipairs(M.MORPH_ORDER[first] or {}) do
            local m = M.MORPHS[id]
            local ok = canPay(world, side, m.res, m.amount, n)
            for _, b in ipairs(m.need) do ok = ok and world.eco:hasBuilt(side, b) end
            add({ id = id, icon = m.icon, tip = ("%s (%d %s)"):format(text(m.name), m.amount, m.res), disabled = not ok })
        end
    end
    -- the troop's own spellcasting buttons (mana-cost); shown for a single type, disabled without enough mana
    local abil = {}
    for _, id in ipairs(ABIL_BY_CODE[first] or {}) do abil[#abil + 1] = id end
    table.sort(abil, function(a, b) return M.ABILITIES[a].order < M.ABILITIES[b].order end)
    for _, id in ipairs(abil) do
        local a = M.ABILITIES[id]
        -- without its power-up (Earthpower, Blending, Feast) the button is there but disabled; Earthpower and Feast only
        -- for their race (FUN_004d3200)
        local need = a.power and a.power[first]
        local ownRace = a.race and a.race[first]
        if not (ownRace and race ~= RACE[ownRace]) then
            local ok = a.mana == 0
            if a.mana > 0 then
                for _, u in ipairs(units) do if (u.mana or 0) >= a.mana then ok = true break end end
            end
            if need and not has(world, side, need) then ok = false end
            add({ id = id, icon = a.icon, tip = (text(a.name) or ""):gsub("%s*%(Shift%+%w+%)", ""), disabled = not ok })
        end
    end
    drunk()
    fanaticism()
    sacrifice()
    if M.canMerge(units) then
        add({ id = "mergeWisps", icon = 13, tip = text("0062"),
              disabled = not (has(world, side, "PWSP") and sd.crystal >= world.eco:price(side, M.MERGE_COST)) })
    end
    return out
end

-- Changes `u` into another type, keeping the fraction of hit points (the original's new army starts with the old one's
-- life percentage).
---@param u Unit
---@param code string
---@return boolean
function M.morphUnit(u, code)
    local world = u.world
    if not status.morph(u, code) then return false end
    u.name = rules.unitName(code, u.type)
    local sd = world.sides[u.side]
    u.rule = sd and rules.override(sd.race, code)
    if u.rule and u.rule.hits then
        local ratio = u.hp / u.maxHp
        u.maxHp = u.rule.hits
        u.hp = math.max(1, u.maxHp * ratio)
    end
    u.move = u.type and u.type.moveType or u.move
    return true
end

local function ring(world, u, r, g, b)
    world.effects = world.effects or {}
    world.effects[#world.effects + 1] = { kind = "ring", x = u.x, y = u.y, r = 40, col = { r, g, b }, t0 = world.time, dur = 700 }
end

local function morph(world, side, units, id)
    local m = M.MORPHS[id]
    if not m or world.sides[side].race ~= RACE.UNDEAD then return 0 end
    for _, b in ipairs(m.need) do
        if not world.eco:hasBuilt(side, b) then return 0 end
    end
    local cost = { gold = 0, metal = 0, stone = 0, crystal = 0 }
    cost[m.res] = m.amount
    local done = 0
    for _, u in ipairs(units) do
        if u.code == m.from and not u.hero and done < 32 then
            if not world.eco:canAfford(side, cost) then break end
            world.eco:pay(side, cost)
            if M.morphUnit(u, m.to) then
                done = done + 1
                ring(world, u, 0.6, 0.4, 0.8)
            end
        end
    end
    return done
end

local function drink(world, side, units, free)
    local sd = world.sides[side]
    local done = 0
    for _, u in ipairs(units) do
        if M.canGetDrunk(u) and not (u.fx and u.fx.drunk) and (free or sd.gold >= M.DRUNK_COST) then
            if not free then
                sd.gold = sd.gold - M.DRUNK_COST
                world:battleStats():resource(side, "gold", M.DRUNK_COST, "spent")
            end
            status.add(u, "drunk", M.DRUNK_TIME)
            done = done + 1
        end
    end
    return done
end

local function fanaticism(world, units)
    local done = 0
    for _, u in ipairs(units) do
        if not (u.fx and u.fx.fanatic) then
            status.remove(u, "immol")      -- Immolate(2) replaces a weaker immolation
            local f = status.add(u, "fanatic", M.FANATIC_TIME)
            f.oldAttitude, f.nextTick = u.attitude, world.time + 1000
            u.attitude = "rampant"
            ring(world, u, 1, 0.7, 0.2)
            done = done + 1
        end
    end
    return done
end

local function sacrifice(world, side, units)
    local sd = world.sides[side]
    if sd.sacrificeAt and world.time < sd.sacrificeAt + M.SACRIFICE_PAUSE then return 0 end
    for _, u in ipairs(units) do
        if not M.canSacrifice(u) then return 0 end
    end
    local n = #units
    if n == 0 or sd.crystal < M.SACRIFICE_COST * n then return 0 end
    sd.sacrificeAt = world.time
    sd.crystal = sd.crystal - M.SACRIFICE_COST * n
    world:battleStats():resource(side, "crystal", M.SACRIFICE_COST * n, "spent")
    local success = math.random(100) <= n * M.SACRIFICE_PERCENT
    local gx, gy = units[1].gx, units[1].gy
    for _, u in ipairs(units) do
        ring(world, u, 0.8, 0.1, 0.1)
        u:vanish(true)
    end
    if success then
        local d = world:addUnit("AADE", side, gx, gy)
        if d then ring(world, d, 1, 0.3, 0.1) end
    end
    return n
end

local function mergeWisps(world, side, units)
    if not has(world, side, "PWSP") or not M.canMerge(units) then return 0 end
    local sd = world.sides[side]
    local groups = 0
    for i = 1, math.floor(#units / 4) do
        local price = world.eco:price(side, M.MERGE_COST)
        if sd.crystal < price then break end
        sd.crystal = sd.crystal - price
        world:battleStats():resource(side, "crystal", price, "spent")
        local leader = units[(i - 1) * 4 + 1]
        leader.merge = { arrived = 0 }
        for k = 2, 4 do
            local u = units[(i - 1) * 4 + k]
            u.merge = { into = leader }
            u:clearOrders()
            u.target, u.task, u.path = nil, nil, nil
        end
        groups = groups + 1
    end
    return groups
end

-- The caster codes the KeyMap.txt key of a spell ability takes (its keyFirst / keyUnits / keyLoop, else its units).
---@param a table the ability record
---@return table<string, boolean>
function M.keyCodes(a)
    local set = {}
    for _, list in ipairs({ a.keyFirst or {}, a.keyUnits or a.units, a.keyLoop or {} }) do
        for _, code in ipairs(list) do set[code] = true end
    end
    return set
end

-- Applies a button press (command { t = "army", ids, ability }); returns the number of units / groups affected.
-- `key`: pressed with its KeyMap.txt key (game/abilitykeys.lua), which has already picked the casters as ids: they may
-- be of the key's own caster codes, and Earthpower's key needs no power-up (FUN_00426350 case 0x18).
---@param world World
---@param side integer
---@param units Unit[]
---@param id string the ability (a MORPHS / ABILITIES id or a button id)
---@param key boolean?
---@return integer
function M.use(world, side, units, id, key)
    if M.MORPHS[id] then return morph(world, side, units, id)
    elseif M.ABILITIES[id] then
        -- One caster per press (the 1.04 handler FUN_00426350: the first selected unit of the ability's types, tried in
        -- the order of `units`, that has the mana; `cost` is what it needs and takes there). Invisibility (`all`, case 0xd)
        -- casts with every selected caster that has the mana. Feast and Scavenge (no mana) take the first selected unit
        -- and work once a second (the static timers of FUN_004cfc90 / FUN_004cfce0, kept per side here).
        local a = M.ABILITIES[id]
        local spells = require("src.game.spells")
        local cost = a.cost or a.mana
        local codes = key and M.keyCodes(a) or nil
        local function ready(u, code)
            local need = a.power and a.power[code]
            if key and a.keyNoPower then need = nil end
            return u.code == code and u:alive() and (u.mana or 0) >= cost and not (need and not has(world, side, need))
        end
        local function caster(u)
            if codes then return codes[u.code] == true and ready(u, u.code) end
            for _, code in ipairs(a.units) do if ready(u, code) then return true end end
            return false
        end
        if a.mana == 0 then
            local u = units[1]
            if not (u and caster(u)) then return 0 end
            world.abilityAt = world.abilityAt or {}
            local key = side .. id
            if world.abilityAt[key] and world.time < world.abilityAt[key] then return 0 end
            world.abilityAt[key] = world.time + 1000
            return spells.unitCast(u, a.spell, 0) and 1 or 0
        end
        if a.all then
            local done = 0
            for _, u in ipairs(units) do
                if caster(u) and spells.unitCast(u, a.spell, cost, nil, a.limit) then done = done + 1 end
            end
            return done
        end
        for _, code in ipairs(a.units) do
            for _, u in ipairs(units) do
                if ready(u, code) then
                    local ok, why = spells.unitCast(u, a.spell, cost, nil, a.limit)
                    if ok then return 1 end
                    if why == "limit" then return 0 end         -- the army limit refuses the press (FUN_005776c0)
                end
            end
        end
        return 0
    elseif id == "drunkenness" then
        if not has(world, side, "PDRU") then return 0 end
        local n = 0
        for _, u in ipairs(units) do if M.canGetDrunk(u) then n = n + 1 end end
        if n > 0 and world.sides[side].gold < M.DRUNK_COST * n then
            world:event("needmore", side, "gold")        -- the original's "need more gold"
            return 0
        end
        return drink(world, side, units, false)
    elseif id == "fanaticism" then
        if not has(world, side, "PFAN") then return 0 end
        return fanaticism(world, units)
    elseif id == "sacrifice" then return sacrifice(world, side, units)
    elseif id == "mergeWisps" then return mergeWisps(world, side, units) end
    return 0
end

-- Per-unit update of a merging wisp (called from Unit:update). Followers walk next to the leader and disappear into it;
-- the leader becomes an Ancient Wisp when all three have arrived. The original's leader waits with a wait counter that
-- is never finished, so there is no timeout (not traced in the 1.04 binary yet).
---@param u Unit
---@param t number
function M.updateMerge(u, t)
    local m = u.merge
    -- (only called for a merging wisp)
    ---@cast m -nil
    local world = u.world
    if m.into then
        local leader = m.into
        if not leader:alive() or not leader.merge then
            u.merge = nil
            return
        end
        if u.state ~= "step" and u:cellDistance(leader) <= 1 then
            leader.merge.arrived = leader.merge.arrived + 1
            u.merge = nil
            u:vanish(true)
        elseif t >= (m.next or 0) then
            m.next = t + 1000
            if u.state ~= "step" then
                local x, y = world:nearestFree(leader.gx, leader.gy, u.move, 3)
                if x then u:orderMove(x, y --[[@as integer]]) end
            end
        end
    elseif m.arrived >= 3 then
        u.merge = nil
        if M.morphUnit(u, "AEAX") then ring(world, u, 0.7, 0.9, 1) end
    end
end

-- Computer players ---------------------------------------------------------------------------

-- A computer unit that was hit and could drink does so (the army hit routine FUN_00522860 marks it when the side owns
-- PDRU, the special ability sweep FUN_005001d0 applies it; the computer pays nothing).
---@param u Unit
function M.onHit(u)
    local world = u.world
    local sd = world.sides[u.side]
    if sd and sd.ai and not u.hero and M.canGetDrunk(u) and not (u.fx and u.fx.drunk) and has(world, u.side, "PDRU") then
        u.aiDrunk = true
    end
end

-- The original's morph missions (FUN_004fd940 / FUN_004f8dc0 / FUN_004cf690):
-- the targets of a unit's own type (FUN_004fd8c0), one unit morphed per mission, and a target type only considered
-- M.MORPH_PAUSE after the last morph of that type (the army data's time between builds, FUN_004f8600 / FUN_004f8750,
-- which stamps it even when the resources were short). Which candidate is tried first is openwbc3's own choice - the
-- original picks one out of its resource list by priority plus a dice roll.
local function aiMorph(world, side)
    local sd = world.sides[side]
    if sd.race ~= RACE.UNDEAD then return end
    sd.aiMorphAt = sd.aiMorphAt or {}
    for _, from in ipairs({ "AUIX", "AUJX", "AUKX", "AULX" }) do
        for _, id in ipairs(M.MORPH_ORDER[from] or {}) do
            local m = M.MORPHS[id]
            local last = sd.aiMorphAt[m.to]
            if not last or world.time >= last + M.MORPH_PAUSE then
                local ready = true
                for _, b in ipairs(m.need) do if not world.eco:hasBuilt(side, b) then ready = false break end end
                if ready then
                    for _, u in ipairs(world.units) do
                        if u.side == side and u.code == m.from and not u.hero and u:alive() then
                            morph(world, side, { u }, id)
                            sd.aiMorphAt[m.to] = world.time
                            break
                        end
                    end
                end
            end
        end
    end
end

-- The wisp merge (FUN_004f8290), the drunkenness sweep and the Undead morph missions, called every think of a computer
-- side.
---@param world World
---@param side integer
function M.aiThink(world, side)
    local list, wisps = {}, {}
    for _, u in ipairs(world.units) do
        if u.side == side and u:alive() then
            if u.aiDrunk then
                u.aiDrunk = nil
                list[#list + 1] = u
            end
            if u.code == "AEBX" and u.state == "idle" and not u.merge and #wisps < 4 then wisps[#wisps + 1] = u end
        end
    end
    if #list > 0 then drink(world, side, list, true) end
    local eco = world.eco
    if #wisps == 4 and has(world, side, "PWSP") and eco:requirementsMet(side, "AEAX") then
        local leader = wisps[1]
        leader.merge = { arrived = 0 }
        for k = 2, 4 do
            wisps[k].merge = { into = leader }
        end
        -- the original starts the merge and pays only when it can afford it
        local price = eco:price(side, M.MERGE_COST)
        local sd = world.sides[side]
        if sd.crystal >= price then sd.crystal = sd.crystal - price end
    end
    aiMorph(world, side)
end

return M
