-- Hero spells. The original game gives the 130 spells (13 spheres of 10) their names and
-- descriptions in <Lang>/Spells.txt. Mana costs, the casting chance, success levels, durations,
-- radii and effect values follow the original engine's rules (see docs/spells.md for what was
-- verified and where); entries marked "own" in the spell table are openwbc3's own approximations.
--
-- Spell id = sphere * 10 + index (0..9). The spheres a hero can cast are its magic skills (classes.lua); the
-- casting skill of a sphere is the skill level, spell i is castable when it is above i.
local config = require("src.core.config")
local content = require("src.content")
local fs = require("src.core.fs")
local text = require("src.core.text")
local status = require("src.game.status")
local rules = require("src.game.rules")
local gamedata = require("src.game.gamedata")
local powerups = require("src.game.powerups")
local weather = require("src.game.weather")
local missiles = require("src.game.missiles")
local psychs = require("src.game.psych")
local strings = require("src.game.strings")
local log = require("src.core.log")

local fx = require("src.game.fx")

local M = {}

-- The spells and spheres live in the content registry (`spell` / `sphere` records, content/base/spells.lua and spheres.lua); the
-- engine looks them up by slot (sphere * 10 + index; the troops' own spells have negative slots).
local function bySlot(slot)
    local index = content.spell.cache.slot
    return index and index[slot]
end

-- Read-only views in the shapes the engine and the screens used before: M.COST[slot], M.SPHERE_NAMES[sphere], M.defs[slot], and the
-- counts M.COUNT / M.SPHERES.
M.COST = setmetatable({}, { __index = function(_, slot) local r = bySlot(slot) return r and r.cost end })
M.defs = setmetatable({}, { __index = function(_, slot) return bySlot(slot) end })
M.SPHERE_NAMES = content.sphere:view("name")
setmetatable(M, { __index = function(_, key)
    if key == "SPHERES" then return content.sphere:count() end
    if key == "COUNT" then return content.sphere:count() * 10 end
end })
M.summonedFor = fx.summonedFor

local names, descs

function M.load()
    if names then return end
    names, descs = {}, {}
    local data = fs.read(config.gamedir .. "/" .. config.language .. "/Spells.txt")
        or fs.read(config.gamedir .. "/English/Spells.txt")
    if not data then
        log.warn("spells: Spells.txt missing")
        return
    end
    data = text.fromCP1252(data)
    for key, value in data:gmatch("%[([%w_]+)%]\t([^\r\n]*)") do
        local kind, n = key:match("^SPELL_(%a+)_(%d+)$")
        if kind == "NAME" then names[tonumber(n)] = value
        elseif kind == "DESC" then descs[tonumber(n)] = value end
    end
end

---@param id integer
---@return string
---@return integer? count a name from Game.txt also returns the gsub count (callers take the first value)
function M.name(id)
    M.load()
    if names[id] then return names[id] end
    local n = M.defs[id] and M.defs[id].name
    if n then return (strings.get("Game.txt", n) or n):gsub("%s*%(Shift%+%w+%)", "") end
    return "Spell " .. id
end
---@param id integer
---@return string
function M.desc(id) M.load() return descs[id] or "" end
---@param id integer
---@return integer
function M.sphere(id) return math.floor(id / 10) end
---@param id integer
---@return integer
function M.level(id) return id % 10 end

-- Mana cost of a cast (binary FUN_00529fa0): the table cost times (100 - discount) percent, the discount being
-- Mana Flow's 25 (a spell effect of power 0x24, value 0x19 in the cast function FUN_00576250) plus the hero's worn items' "mana
-- discount" powers (the item power sum FUN_0040c380 for 0x24: Disjunction zeroes and Spellforge doubles them like every item
-- power); the percentage is at least 25, integer maths. The mana a cast spends is at least 1 (the cast dispatcher
-- FUN_005777a0), see M.spend.
---@param u Unit
---@param id integer
---@return integer
function M.cost(u, id)
    local c = M.COST[id] or 10
    local sd = u.world.sides[u.side]
    local discount = (u.h and u.h.mod.manaDiscount) or 0
    if sd.manaflow and sd.manaflow > u.world.time then discount = discount + 25 end
    return math.floor(math.max(25, 100 - discount) * c / 100)
end

-- The mana a cast takes: the cost, at least 1 (the pool does not go below 0).
---@param u Unit
---@param id integer
---@return integer
function M.spend(u, id)
    return math.max(1, M.cost(u, id))
end

local sideBuff = fx.sideBuff

-- The casting skill of a sphere is the level of the hero's magic skill (ids 10..22). A spell
-- of index i needs skill > i; the success level is skill/10 + 1, one lower when skill%10 <= i.
---@param h Hero
---@param sphere integer
---@return integer
function M.castSkill(h, sphere)
    local rec = content.sphere:bySlot(sphere)
    return ((rec and h.skill[rec.skill]) or 0) + h:sphereBonus(sphere)
end

---@param h Hero
---@param id integer
---@return integer
function M.castLevel(h, id)
    local sph, idx = M.sphere(id), id % 10
    local skill = M.castSkill(h, sph)
    if skill <= idx then return 0 end
    local lvl = math.floor(skill / 10) + 1
    if skill % 10 <= idx then lvl = lvl - 1 end
    return lvl
end

-- Chance (percent) of the highest success level (FUN_0040aae0): 50 - 50 per level above the first
-- + 3 * Intelligence + Concentration + Gem of Wisdom (+50 for computer players), at most 100.
---@param u Unit a hero unit
---@param id integer
---@return integer percent
function M.chance(u, id)
    local h = u.h
    -- only asked for heroes
    ---@cast h -nil
    local sd = u.world.sides[u.side]
    local lvl = math.max(1, M.castLevel(h, id))
    local c = 50 - (lvl - 1) * 50 + 3 * h.attr.int
    if sideBuff(u.world, u.side, "concentration") then c = c + (sd.concentrationPct or 20) end
    if h.nextBonus then c = c + (type(h.nextBonus) == "number" and h.nextBonus or 20) end
    c = c + (h.mod.ritual or 0)
    if sd.ai then c = c + 50 end
    return math.min(100, math.floor(c))
end

-- The success level of a cast (FUN_005717e0): roll d100 against the chance; every failed roll lowers the
-- level by one and raises the chance by 50. 0 means the spell fizzles.
---@param u Unit a hero unit
---@param id integer
---@return integer level 0 = fizzle
function M.roll(u, id)
    local lvl = M.castLevel(u.h, id)
    local chance = M.chance(u, id)
    while lvl > 0 do
        if math.random(100) <= chance then break end
        lvl = lvl - 1
        chance = chance + 50
    end
    return math.max(0, lvl)
end

-- Castable spells in id order (F1.. hotkeys).
---@param h Hero
---@return integer[]
function M.list(h)
    local out = {}
    for id in pairs(h.spells) do out[#out + 1] = id end
    table.sort(out)
    return out
end


---@param id integer
---@return string "none" | "enemy" | "ground" ...
function M.targetKind(id)
    local def = bySlot(id)
    return def and def.target or "none"
end

-- The four entries of a "choice" spell's dialog (FUN_0055bc90; content/base/spells.lua at Change Weather); a "weather"
-- spell without its own shows Change Weather's. nil for other spells.
---@param id integer
---@return SpellChoice[]?
function M.choices(id)
    local def = bySlot(id)
    if not def then return nil end
    if def.choices then return def.choices end
    if def.target == "weather" then return M.choices(28) end
    return nil
end

-- Casting --------------------------------------------------------------------------------

-- May `u` cast `id` now? Returns true or false, reason.
---@param u Unit
---@param id integer
---@return boolean
---@return string? reason
function M.canCast(u, id)
    local h = u.h
    if not h or not h.spells[id] then return false, "unknown" end
    if not u:alive() then return false, "dead" end
    if (h.mana or 0) < M.cost(u, id) then return false, "mana" end
    if u.recoverUntil and u.world.time < u.recoverUntil then return false, "recovering" end
    if u.fx and u.fx.stun then return false, "stunned" end
    return true
end

-- Orders a cast (the hero casts as soon as it stands still). target depends on targetKind().
---@param u Unit
---@param id integer
---@param target any? a unit, building or {gx, gy}
---@return boolean
---@return string? reason
function M.cast(u, id, target)
    local ok, why = M.canCast(u, id)
    if not ok then return false, why end
    local kind = M.targetKind(id)
    if kind ~= "none" and not target then return false, "target" end
    if kind == "choice" or kind == "weather" then
        -- the pick of the dialog, 0..3 (the dialog's callback sends nothing for Cancel, FUN_0055bc90 / 0x00571df0)
        local i = type(target) == "table" and target.choice
        if type(i) ~= "number" or i ~= math.floor(i) or i < 0 or i > 3 then return false, "target" end
        target = { choice = i }
    end
    u.pendingCast = { id = id, target = target }
    return true
end

---@param u Unit
---@param id integer
---@param target any?
---@return boolean succeeded
function M.perform(u, id, target)
    local ok = M.canCast(u, id)
    if not ok then return false end
    local h, w = u.h, u.world
    -- canCast fails without a hero
    ---@cast h -nil
    local def = bySlot(id)
    h.mana = math.max(0, h.mana - M.spend(u, id))
    local lvl = M.roll(u, id)
    local succeeded = lvl > 0
    -- a Black Portal / Circle of Power near the hero adds a level to the summoning spells that use it
    local portal
    if succeeded and def and def.portal then
        local limit = math.min(19, h.mod.commandRadius)
        for _, b in ipairs(w.buildings) do
            if b.code == def.portal and b.side == u.side and b.hp > 0 and fx.dist(b, u) <= limit then portal = b break end
        end
        if portal then lvl = lvl + 1 end
    end
    h.nextBonus = nil
    -- a hero must recover before it can cast again: the cast dispatcher (FUN_005777a0) sets 10 x (max(5, table cost) x (index + 1)
    -- + 2 x (5 x result + 50)) ms; a fizzle is sent with the result -1, so it recovers 100 ms less than a level 0 would
    u.recoverUntil = w.time + 1000 + math.max(5, M.COST[id] or 10) * (id % 10 + 1) * 10 + (succeeded and lvl or -1) * 100
    -- casting stops the hero and plays its spell animation
    u:stop()
    local A = require("src.formats.sprite").ANIM
    u.state = "cast"
    u.castUntil = w.time + 700
    if u.set:has(A.SPELL) then u:startAnim(A.SPELL, w.time, u.set:frames(A.SPELL) * 100, false) end
    if target and target.x then
        local d = require("src.game.unit").dirTo(target.x - u.x, target.y - u.y)
        if d then u.dir = d end
    end
    if succeeded and def then
        local c = fx.ctx(u, id, target, lvl)
        c.portal = portal
        w:event("spellbegin", u, id, c)
        def.run(c)
        w:event("spellcast", u, id, true, lvl)
    else
        w:event("spellcast", u, id, false)
        local x, y = u.x, u.y
        w.effects = w.effects or {}
        w.effects[#w.effects + 1] = { kind = "ring", x = x, y = y - 20, r = 20, col = { 0.5, 0.5, 0.5 }, t0 = w.time, dur = 500 }
    end
    return succeeded
end

-- The "spellbegin" event goes out before a spell's effect runs and "spellcast" / "itemspell" after it: the battle view compares the
-- world at the two to find the armies and buildings the spell touched and shows the spell's effect pictures on them
-- (pictures of the spell record, gfx/spellfx.lua). It changes nothing.

-- Item spells: the "cast spell" powers of the worn items (binary FUN_00529d20, called by
-- the army's strike at 0x51ab00 for a hero's melee strike at an army or building, before the hit is resolved; a
-- missile's launch or impact does not call it, nor does any timer). The hero of its side, with the No Items option off
-- and not recovering from a cast, walks the 7 worn slots (not the backpack) and their first 3 powers; every cast spell
-- power fires when d100 < its chance (a chance of 5 is 4 %), at the power's level, through the cast dispatcher (FUN_005777a0)
-- without mana cost and without the Gem of Wisdom reset (the original's "use mana" argument is FALSE). The spell needs no
-- spell book entry, the Disjunction and Spellforge effects of the item power sum do not apply (the binary does not test
-- them), and a level below 1 only fizzles. Like any hero cast it starts the spell recovery, 1 s + max(5, mana cost) x
-- (spell number in the sphere + 1) x 10 ms + 100 ms x level, so a second power cannot fire during the same strike and no
-- item spell fires while the hero recovers from a cast. Every item spell of the catalogue (37 powers) acts around the
-- caster; the original hands them the hero's last spell target, which only target spells read.
-- openwbc3's own: the cast runs on every peer for every hero (the original runs it on the owning machine only, FUN_004a5c40);
-- the stand-still animation of a hero's cast is not played (the original plays none for an item cast).
---@param u Unit
---@param id integer
---@param lvl integer
---@return boolean
function M.castItemSpell(u, id, lvl)
    local w = u.world
    if u.recoverUntil and w.time < u.recoverUntil then return false end
    u.recoverUntil = w.time + 1000 + math.max(5, M.COST[id] or 10) * (id % 10 + 1) * 10 + math.max(0, lvl) * 100
    local def = bySlot(id)
    if lvl > 0 and def then
        local c = fx.ctx(u, id, nil, lvl)
        w:event("spellbegin", u, id, c)
        def.run(c)
        w:event("itemspell", u, id, true, lvl)
        return true
    end
    w:event("itemspell", u, id, false)
    return false
end

---@param u Unit
---@return boolean fired
function M.itemCast(u)
    local h, w = u.h, u.world
    if not h or (w.advanced and w.advanced.noItems) or not u:alive() then return false end
    if u.recoverUntil and w.time < u.recoverUntil then return false end
    local fired = false
    for slot = 1, #require("src.game.hero").SLOT_LAYOUT do
        local it = h.equipped[slot]
        if it then
            for i = 1, 3 do
                local p = it.powers[i]
                if p and p.type == "cast spell" and p.chance and math.random(100) < p.chance then
                    M.castItemSpell(u, p.data, p.level or 0)
                    fired = true
                end
            end
        end
    end
    return fired
end

-- A troop casts one of its special abilities. The original calls the ability's cast routine with the unit's
-- casting level, ((level + 1) / 5) + 1 as the result (FUN_00426350; the level is FUN_00526d80: the troop's level,
-- a hero's own), with no success roll. The spell radius is the unit's command value (FUN_005267b0: 8,
-- 9 for computer players) grown by 50 % per level above the first (the spell radius FUN_00529ea0).
local function unitCtx(u, id, lvl)
    local w = u.world
    local sd = w.sides[u.side]
    local base = sd.ai and 9 or 8
    local c = { u = u, w = w, id = id, target = nil, side = u.side, t = w.time, lvl = lvl }
    c.base = base
    c.r = base
    c.rm = math.floor(base + 50 * (lvl - 1) * base / 100)
    c.empPct = sideBuff(w, u.side, "empower") and (sd.empowerPct or 50) or 0
    c.ext = sideBuff(w, u.side, "extend") and 2 or 1
    return c
end

-- `limit` (an ability record's field): the army type whose unit value has to fit the side's army limit before any mana is
-- spent (the army-limit check FUN_005776c0, called by the ability caster FUN_00426350); the spell checks again for the type it makes.
---@param u Unit
---@param id integer
---@param cost number
---@param target any?
---@param limit string? army type code that must fit the army limit
---@return boolean
---@return string? reason
function M.unitCast(u, id, cost, target, limit)
    local w = u.world
    if not u:alive() then return false, "dead" end
    if (u.mana or 0) < cost then return false, "mana" end
    if limit and not w.eco:roomFor(u.side, limit) then return false, "limit" end
    if u.recoverUntil and w.time < u.recoverUntil then return false, "recovering" end
    if u.fx and u.fx.stun then return false, "stunned" end
    u.mana = u.mana - cost
    local lvl = math.floor(((u.h and u.h.level or u.level or 0) + 1) / 5) + 1
    local c = unitCtx(u, id, lvl)
    c.target = target
    u:stop()
    local A = require("src.formats.sprite").ANIM
    u.state = "cast"
    u.castUntil = w.time + 700
    local anim = u.set:has(A.SPECIAL) and A.SPECIAL or (u.set:has(A.SPELL) and A.SPELL or nil)
    if anim then u:startAnim(anim, w.time, u.set:frames(anim) * 100, false) end
    if target and target.x then
        local d = require("src.game.unit").dirTo(target.x - u.x, target.y - u.y)
        if d then u.dir = d end
    end
    local def = bySlot(id)
    w:event("spellbegin", u, id, c)
    if def then def.run(c) end
    w:event("spellcast", u, id, true, lvl)
    u.recoverUntil = w.time + 1000 + (cost or 10) * 20
    return true
end

-- Mana from kills (the army's death handler and its mana leech amount, binary FUN_005210b0 / FUN_00526de0): a hero that
-- kills an army of another side (not a critter) gets the Leech skill's effect plus the Mana Leech spell's amount, at most
-- once a second (1000 ms); a Black Mage (AHGB, not a hero) gets 5 on the same terms. The mana leech
-- effect (EMLE, gfx/emitters.lua) shows when something was added.

---@param killer Unit|Building
---@param victim (Unit|Building)?
function M.onKill(killer, victim)
    if killer.kind ~= "unit" then return end
    local h = killer.h
    local troopLeech = not h and content.setting:value("unit.troopManaLeech")[killer.code]
    if not h and not troopLeech then return end
    local w = killer.world
    if victim then
        local critter = victim.kind == "unit" and require("src.game.unit").isCritter(victim.code)
        if victim.side == killer.side or critter then return end
    end
    local amount
    if h then
        amount = h:effect(require("src.game.heroskills").ids.Leech)
        if h.manaLeech and h.manaLeech > w.time then amount = amount + (h.manaLeechAmount or 5) end
    else
        amount = troopLeech
    end
    local timer = h or killer
    if amount <= 0 or (timer.lastLeech and w.time <= timer.lastLeech + 1000) then return end
    timer.lastLeech = w.time
    local before = h and (h.mana or 0) or (killer.mana or 0)
    local max = h and h.mod.mana or killer.maxMana or 0
    local after = math.min(max, before + amount)
    if after <= before then return end
    if h then h.mana = after else killer.mana = after end
    w:event("emit", killer, "EMLE")
end

-- Computer heroes -------------------------------------------------------------------------

---@param u Unit
---@param t number
function M.aiThink(u, t)
    local h = u.h
    -- computer heroes only
    ---@cast h -nil
    if u.nextSpell and t < u.nextSpell then return end
    u.nextSpell = t + 2500 + math.random(0, 1500)
    if u.state == "cast" or u.pendingCast or (u.fx and u.fx.stun) then return end
    local w = u.world
    local enemies = 0
    local nearest
    for _, o in ipairs(w.units) do
        if o:alive() and w:enemies(u.side, o.side) and o.side ~= 6 then
            local d = fx.dist(o, u)
            if d <= 8 then
                enemies = enemies + 1
                if not nearest or d < fx.dist(nearest, u) then nearest = o end
            end
        end
    end
    local hurtFrac = u.hp / u.maxHp
    local cands = {}
    for _, id in ipairs(M.list(h)) do
        local def = bySlot(id)
        local ok = def and def.ai and M.canCast(u, id)
        if ok then
            local use
            if def.ai == "heal" then use = hurtFrac < 0.6
            elseif def.ai == "attack" then use = enemies > 0
            elseif def.ai == "summon" then use = enemies > 0
            elseif def.ai == "buff" then use = enemies > 1 and math.random() < 0.5 end
            if use then cands[#cands + 1] = id end
        end
    end
    if #cands == 0 then return end
    local id = cands[math.random(#cands)]
    local kind = M.targetKind(id)
    local target
    if kind == "enemy" then target = nearest
    elseif kind == "ground" then target = nearest and { gx = nearest.gx, gy = nearest.gy } end
    if kind ~= "none" and not target then return end
    M.cast(u, id, target)
end

return M
