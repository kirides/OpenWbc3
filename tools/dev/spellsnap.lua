-- Golden-master digest of the spells (docs/data-driven/03-spells-effects.md 3.6): every spell of the original table is cast at every
-- success level in a seeded world (a hero, allies, enemies, a neutral critter, corpses) and the state that results (units, buildings,
-- side timers, hero fields, effects) is written as one line per cast. The same script runs at the baseline commit and at the working
-- tree (tools/dev/golden.ps1 -Spells); it only uses the public spell API (`spells.perform`, `spells.unitCast`).
--   pwsh tools/dev/love.ps1 -- --selftest --lua tools/dev/spellsnap.lua <out.txt>
local outPath = ...
local boot = require("src.game.boot")
local worldMod = require("src.game.world")
local spells = require("src.game.spells")

-- The number, boolean and string fields of `t` (minus the keys in `skip`), sorted: "k=v,...".
---@param t table
---@param skip table<string, boolean>?
---@return string
local function scalars(t, skip)
    local keys = {}
    for k, v in pairs(t) do
        local tv = type(v)
        if (tv == "number" or tv == "boolean" or tv == "string") and not (skip and skip[k]) then keys[#keys + 1] = k end
    end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local out = {}
    for _, k in ipairs(keys) do
        local v = t[k]
        if type(v) == "number" then v = ("%.4f"):format(v) end
        out[#out + 1] = tostring(k) .. "=" .. tostring(v)
    end
    return table.concat(out, ",")
end

-- A table one level deep (nested tables through scalars), sorted: "k:v;..."; anything else as tostring.
---@param t any
---@return string
local function sub(t)
    if type(t) ~= "table" then return tostring(t) end
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local out = {}
    for _, k in ipairs(keys) do
        local v = t[k]
        if type(v) == "table" then v = "{" .. scalars(v) .. "}" elseif type(v) == "number" then v = ("%.4f"):format(v) end
        if type(v) ~= "function" then out[#out + 1] = tostring(k) .. ":" .. tostring(v) end
    end
    return table.concat(out, ";")
end

local VOLATILE = { id = false }
-- The state a cast can change: every unit (and hero), building, side, the effects and the world hash.
---@param w World
---@param hero Unit
---@return string
local function digest(w, hero)
    local lines = {}
    lines[#lines + 1] = ("world %d night=%s rain=%s fx=%d missiles=%d hash=%d"):format(w.time, tostring(w.night), tostring(w.raining),
        #(w.effects or {}), #w.missiles, w:hash())
    for _, u in ipairs(w.units) do
        local fx = u.fx and sub(u.fx) or ""
        lines[#lines + 1] = ("u%d %s s%d %d,%d hp=%.2f/%d st=%s lvl=%s xp=%s sum=%s ill=%s rm=%s mm=%s fx[%s] side=%s"):format(u.id, u.code,
            u.side, u.gx, u.gy, u.hp, u.maxHp, tostring(u.state), tostring(u.level), tostring(u.xp), tostring(u.summonUntil),
            tostring(u.illusion), tostring(u.remove), sub(u.morphMod or {}), fx, u.side)
        if u.h then lines[#lines + 1] = "  h " .. scalars(u.h, { id = true }) .. " pot=" .. sub(u.h.potions or {}) end
    end
    for _, b in ipairs(w.buildings) do
        lines[#lines + 1] = ("b%d %s s%d hp=%d/%d exp=%s mm=%s own=%s"):format(b.id, b.code, b.side, b.hp, b.maxHp, tostring(b.expireAt),
            sub(b.morphMod or {}), tostring(b.side))
    end
    for i = 0, 6 do
        lines[#lines + 1] = ("side%d %s"):format(i, scalars(w.sides[i]))
    end
    lines[#lines + 1] = "manaFreeze " .. sub(w.manaFreeze or {})
    return table.concat(lines, "\n")
end

---@param seed integer
---@return World, Unit hero the hero of side 0
local function setup(seed)
    math.randomseed(seed)
    local sc = assert(boot.loadScenario("Bridges"))
    local w = worldMod.new(sc, { player = 0 })
    local hero = assert(w.eco:heroAlive(0))
    local gx, gy = hero.gx, hero.gy
    local function put(code, side, dx, dy)
        local x, y = w:nearestFree(gx + dx, gy + dy, 0, 5)
        return x and w:addUnit(code, side, x, y --[[@as integer]]) or nil
    end
    for i, code in ipairs({ "AHFX", "AHBX", "AUIX", "AHMX", "ADIX", "AHDX" }) do put(code, 0, -2 + i % 3, -3 + i) end
    for i, code in ipairs({ "AOBX", "AUBX", "AOIX", "AHFX", "AOJX", "AUIX", "ABIX" }) do put(code, 1, 2 + i % 3, -3 + i) end
    for i, code in ipairs({ "ACSH", "ACCO" }) do put(code, 6, 4 + i, 2) end
    local dead = {}
    for i, code in ipairs({ "AHFX", "AUIX", "AHBX", "AOBX" }) do
        local u = put(code, i % 2 == 0 and 0 or 1, -4, 1 + i)
        if u then dead[#dead + 1] = u end
    end
    for _, u in ipairs(dead) do u:takeDamage(99999, nil) end
    w.sides[0].gold, w.sides[0].metal, w.sides[0].crystal, w.sides[0].stone = 300, 200, 100, 50
    -- the summon spells refuse an army that does not fit the army limit (selftest checks that); the digest wants their effects
    w.eco.armyLimit = function() return 0, 250 end
    return w, hero
end

local out = {}
-- Casts spell `id` (negative: a troop spell) at success level `lvl` in a fresh world and adds its digest.
---@param id integer
---@param lvl integer
local function cast(id, lvl)
    local w, hero = setup(1000 + (id + 20) * 10 + lvl)
    local h = hero.h --[[@as Hero]]
    local sphere, idx = math.floor(id / 10), id % 10
    h.mana = 5000
    hero.mana = 5000                 -- troops cast with their own mana (unitCast)
    h.spells[id] = true
    h.skill[10 + sphere] = (lvl - 1) * 10 + idx + 1
    h.nextBonus = 1000
    hero.recoverUntil = nil
    local target = { gx = hero.gx + 3, gy = hero.gy + 3, x = (hero.gx + 3) * 32 + 16, y = (hero.gy + 3) * 24 + 12, choice = lvl % 4, kind = "ground" }
    local ok, err = pcall(function()
        if id >= 0 then spells.perform(hero, id, target) else spells.unitCast(hero, id, 0, target) end
        for _ = 1, 45 do w:update(1 / 30) end
    end)
    out[#out + 1] = ("== spell %d level %d ok=%s %s"):format(id, lvl, tostring(ok), ok and "" or tostring(err):gsub("^.-:%d+: ", ""))
    out[#out + 1] = digest(w, hero)
end

for id = 0, 129 do
    for lvl = 1, 4 do cast(id, lvl) end
end
for id = -10, -1 do
    for lvl = 1, 2 do cast(id, lvl) end
end

local f = assert(io.open(outPath, "wb"))
f:write(table.concat(out, "\n"), "\n")
f:close()
print("spell lines " .. #out)
