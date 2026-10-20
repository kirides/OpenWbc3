-- Death specials, critter pick-ups and ammunition of single unit types: what the original does in the army death, the
-- titan explosion, the explosion, the fight activation and the damage getter for particular army codes. Everything
-- here is simulation (deterministic: world time, the per-tick seeded math.random, ipairs) and is called from unit.lua /
-- world.lua.
--
-- Verified in the 1.04 binary (Battlecry III.exe; the functions have no symbols, addresses are the Ghidra ones):
--   Death                 FUN_005210b0   army codes are compared as 4 characters, the third-letter and counter rules below
--   titan explosion       FUN_00520f20   ten missiles from the table at 0x00608190 (8-byte records: x, y cell delta, speed, height),
--                                         EMTM (magic ball, race letters V A F K U G at the third character of the code,
--                                         STEZ23.wav) or EMTF (fire ball, STEZ47.wav) and STEZ27.wav; FUN_0040f620 turns them
--                                         into the sprites EMM0 / EMF0 with a particle trail. Nothing sets a damage on them: a ball that reaches its cell
--                                         bursts for 150 damage to the 9 x 8 box round it (the missile frame step, code at
--                                         0x00540bc0), see missiles.lua.
--   explosion             FUN_00529a40   damage on the 8 neighbours and the 12 cells of the next ring (tables at 0x00611330 /
--                                         0x00611370), the army or building in each cell takes the damage as a normal-hit fire
--                                         attack through the armour function FUN_0042bbf0, half of it in the outer ring; own side
--                                         spared unless asked; two particle bursts (explode, gfx/emitters.lua) unless an effect
--                                         id was given
--   fight activation      0x00523150     (not a Ghidra function, read from the bytes): Firebomb / Spore die on contact, Troll -> sheep, Catapult -> cow,
--                                         Minotaur -> cow / sheep / goose and daemons -> soul are melee with damage 100, the
--                                         Troll / Catapult throw their ammunition as a x3 crushing missile
--   damage getter         0x00526310 (army vtable slot 20, not a Ghidra function): the best damage spell effect, range 0
--                                         against those targets
--   army limit            FUN_005269a0   a living Knight Lord adds 2, a Warlord 1 to the hero's army limit addition
-- In the binary the Troll picks up only sheep (not seals, turtles or penguins) and the Catapult only cows (not camels);
-- the Minotaur's range 0 list has all seven critters, its damage 100 list cow / sheep / goose. The Spider Eggs hatching
-- (a spell building that expires) is not traced in the 1.04 binary yet; it is labelled so in docs/implemented.md.
local bit = require("bit")
local gamedata = require("src.game.gamedata")
local sound = require("src.audio.sound")
local missiles = require("src.game.missiles")

local M = {}

-- a Soul's mana and experience (both in FUN_005210b0); the Spiders from eggs (not traced in the 1.04 binary yet)
M.SOUL_MANA, M.SOUL_EXPERIENCE, M.EGG_SPIDERS = 25, 20, 4
M.SOUL_LIFETIME, M.EGG_LIFETIME = 120000, 40000                      -- the army death's message durations (ms)
M.KNIGHT_LORD_LIMIT, M.WARLORD_LIMIT = 2, 1                         -- army limit FUN_005269a0: AHEX +2, ABEX +1

local CW, CH = 32, 24

-- the eight neighbours and the twelve cells of the ring behind them, in the original's order (dx, dy)
local EXPLODE_CELLS = {
    { 0, -1 }, { 1, -1 }, { 1, 0 }, { 1, 1 }, { 0, 1 }, { -1, 1 }, { -1, 0 }, { -1, -1 },
    { 0, -2 }, { 1, -2 }, { 2, -1 }, { 2, 0 }, { 2, 1 }, { 1, 2 }, { 0, 2 }, { -1, 2 }, { -2, 1 }, { -2, 0 },
    { -2, -1 }, { -1, -2 },
}

-- the ten titan explosion missiles: x / y delta in cells (the speed field, always 1, and the height field are not read by the
-- binary: the flight is the picture's high arc)
local TITAN_BALLS = {
    { -5, 5, 0 }, { -3, -11, 1 }, { 7, 4, 0 }, { 1, -4, 1 }, { -6, 12, 2 },
    { 11, -8, 1 }, { 1, -12, 0 }, { -11, -4, 0 }, { 2, 8, 1 }, { 4, -3, 2 },
}
local MAGIC_TITANS = { V = true, A = true, F = true, K = true, U = true, G = true }
M.TITAN_BALLS = TITAN_BALLS            -- Couatl's Wrath throws the same ten balls (its titan explosion spell effect)

-- what the activation of a fight and the damage getter make a melee pick-up: attacker code -> victim code -> true
local function set(list) local s = {} for _, c in ipairs(list) do s[c] = true end return s end
local PICKUP = {          -- damage 100, range 0 (the fight activation)
    AOMX = set({ "ACSH" }), ASCA = set({ "ACCO" }),
    AMIX = set({ "ACCO", "ACSH", "ACGO" }), AMMX = set({ "ACCO", "ACSH", "ACGO" }), AMNX = set({ "ACCO", "ACSH", "ACGO" }),
    AADE = set({ "ACSO" }), AVGX = set({ "ACSO" }), AVHX = set({ "ACSO" }), AVJX = set({ "ACSO" }),
}
local MINOTAUR_RANGE0 = set({ "ACCO", "ACSH", "ACGO", "ACCA", "ACTU", "ACSE", "ACPE" })   -- damage getter, Minotaurs
local DAEMONS = set({ "AADE", "AVGX", "AVHX", "AVJX" })
local SUICIDE = set({ "AASX", "AGSP" })                                                     -- Firebomb, Spore

-- Whether `u` meets `target` in melee although its attack is ranged (the damage getter sets the range to 0).
---@param u Unit
---@param target Unit|Building
---@return boolean
function M.meleeOnly(u, target)
    if target.kind ~= "unit" then return false end
    local p = PICKUP[u.code]
    if p and p[target.code] then return true end
    return (u.code == "AMIX" or u.code == "AMMX" or u.code == "AMNX") and MINOTAUR_RANGE0[target.code] or false
end

-- The damage a pick-up strike does (100) or nil for an ordinary attack.
---@param u Unit
---@param target Unit|Building
---@return integer?
function M.pickupDamage(u, target)
    local p = PICKUP[u.code]
    if p and target.kind == "unit" and p[target.code] then return 100 end
    return nil
end

---@param u Unit
---@return boolean
function M.explodesOnContact(u) return SUICIDE[u.code] == true end

-- The side hostility the death rules use: another side that is not in the same team (with alliances on).
local function hostile(world, a, b)
    if a == b then return false end
    local sa, sb = world.sides[a], world.sides[b]
    return not (sa and sb and sa.team ~= 0 and sa.team == sb.team)
end

local function addEffect(world, e)
    world.effects = world.effects or {}
    world.effects[#world.effects + 1] = e
end

-- A particle emitter of the original's effect `code` (src/gfx/emitters.lua) over an army or building: presentation only, the
-- battle view listens for the event.
local function emit(world, e, code) world:event("emit", e, code) end
M.emit = emit

local function sprite(world, code, x, y)
    addEffect(world, { kind = "sprite", code = code, x = x, y = y, t0 = world.time, dur = 1600 })
end

-- The army-produced message: a new army at a free cell near (gx, gy). `lifetime` makes it vanish later (a message duration).
---@param world World
---@param code string
---@param side integer
---@param gx integer
---@param gy integer
---@param effect string? "EZ08" | "ESSP"
---@param lifetime number? ms
---@return Unit?
local function produce(world, code, side, gx, gy, effect, lifetime)
    local u = world:addUnit(code, side, gx, gy)
    if not u then return nil end
    if lifetime then u.summonUntil = world.time + lifetime end
    if effect == "EZ08" then sprite(world, "EZ08", u.x, u.y)
    elseif effect == "ESSP" then emit(world, u, "ESSP") end
    return u
end
M.produce = produce

-- Explode (FUN_00529a40): every army or building on the twenty cells around takes `dmg` as a normal hit of fire damage
-- through its armour; the exploder's own side only when `hitFriends`. Buildings are hit once per cell they cover in
-- the area, like the original, which walks the cells.
---@param world World
---@param u Unit
---@param dmg integer
---@param hitFriends boolean
function M.explode(world, u, dmg, hitFriends)
    local Unit = require("src.game.unit")
    emit(world, u, "explode")
    local cover
    for i, c in ipairs(EXPLODE_CELLS) do
        if i == 9 then dmg = bit.arshift(dmg, 1) end         -- the ring behind the neighbours takes half (SAR at 0x00529bff)
        local gx, gy = u.gx + c[1], u.gy + c[2]
        if gx >= 0 and gy >= 0 and gx < world.w and gy < world.h then
            local o = world:unitAt(gx, gy)
            if o and not o:alive() then o = nil end
            if not o then
                cover = cover or {}
                for _, b in ipairs(world.buildings) do
                    if b.hp > 0 and b.shape then
                        for _, bc in ipairs(world:shapeCells(b.gx, b.gy, b.shape)) do
                            cover[bc[2] * world.w + bc[1]] = b
                        end
                    end
                end
                o = cover[gy * world.w + gx]
            end
            if o and (hitFriends or o.side ~= u.side) then
                local d = Unit.soften(o, dmg, 3, false)
                if o.kind == "unit" then o:takeDamage(d, nil) else world:damageBuilding(o, d, nil) end
            end
        end
    end
end

-- The titan explosion (FUN_00520f20): ten balls (EMTF, or EMTM for the magic titans) fly out from the titan to the cells of the table
-- and burst there for 150 damage to everything in a 9 x 8 box (missiles.lua); the missile has no shooter and nobody gets the
-- credit.
---@param world World
---@param u Unit
function M.explodeTitan(world, u)
    local magic = MAGIC_TITANS[u.code:sub(3, 3)]
    sound.playAt("Assets/SoundFX.xcr", magic and "STEZ23.wav" or "STEZ47.wav", u.gx, u.gy)
    sound.playAt("Assets/SoundFX.xcr", "STEZ27.wav", u.gx, u.gy)
    for _, ball in ipairs(TITAN_BALLS) do
        local gx, gy = u.gx + ball[1], u.gy + ball[2]
        if gx >= 0 and gy >= 0 and gx <= world.w and gy <= world.h then
            missiles.launch(world, { code = magic and "EMTM" or "EMTF", kind = "ball", force = true, gx0 = u.gx, gy0 = u.gy,
                                     gx1 = gx, gy1 = gy, ex = gx * CW + 16, ey = gy * CH + 12 })
        end
    end
end

-- A free-standing pack of armies: n armies of `code` for `side` at the place of `u`.
local function pack(world, u, code, n, effect)
    for _ = 1, n do produce(world, code, u.side, u.gx, u.gy, effect) end
end

-- Spider Eggs (the Queen Spider's kill, a create-building spell message of the killer's side): a building at the victim's
-- cell that lives 40 s.
local function layEggs(world, victim, killer)
    local code = "BMEG"
    local btype = gamedata.building(code)
    if not btype then return end
    local gx, gy = victim.gx, victim.gy
    if not world:fits(gx, gy, btype.shape) then
        local x, y = world:nearestFree(gx, gy, 0, 2)
        if not (x and world:fits(x, y, btype.shape)) then return end
        gx, gy = x, y
    end
    local b = world:addBuilding({ code = code, side = killer.side, x = gx * CW + 16, y = gy * CH + 12, anim = 0, dir = 0,
                                  frame = 0 })
    world.eco:initBuilding(b)
    b.complete = true
    b.expireAt = world.time + M.EGG_LIFETIME
    emit(world, b, "ECHE")                                  -- the spell message's target effect (FUN_005210b0)
end

-- The eggs' timer has run out: min(4, free army slots) Spiders come out (not traced in the 1.04 binary yet).
---@param world World
---@param b Building
function M.hatchEggs(world, b)
    local cur, max = world.eco:armyLimit(b.side)
    local n = math.min(M.EGG_SPIDERS, max - cur)
    for _ = 1, n do
        produce(world, "AKKX", b.side, b.gx, b.gy, "ESSP")
    end
end

-- The Knight Lord and the Warlord add to the hero's army limit while they live (FUN_005269a0).
---@param world World
---@param side integer
---@return integer
function M.armyLimitBonus(world, side)
    local n = 0
    for _, u in ipairs(world.units) do
        if u.side == side and u:alive() then
            if u.code == "AHEX" then n = n + M.KNIGHT_LORD_LIMIT
            elseif u.code == "ABEX" then n = n + M.WARLORD_LIMIT end
        end
    end
    return n
end

-- The army death (FUN_005210b0), the unit's own part and what its killer's type does to it. `killer` is the inflicting army or
-- nil (the unit's own timer, a Firebomb's contact, a building).
---@param world World
---@param u Unit
---@param killer (Unit|Building)?
function M.onDeath(world, u, killer)
    local code = u.code
    if SUICIDE[code] then M.explode(world, u, u:stats().damage, false) end
    if code == "AWKX" then pack(world, u, "AWJX", 2) end                 -- Ancient Treant -> two Treants
    if code == "AKOX" then pack(world, u, "AKKX", 6, "EZ08") end         -- Spider Priestess -> six Spiders
    if killer and killer.kind == "unit" and killer ~= u and hostile(world, killer.side, u.side) then
        local Unit = require("src.game.unit")
        -- Succubi leave a neutral Soul behind (critters only one time in five: dice FUN_00458e70(1,100,0) < 20)
        if killer.code == "AVIX" and (not Unit.isCritter(code) or math.random(1, 100) < 20) then
            produce(world, "ACSO", 6, u.gx, u.gy, "ESSP", M.SOUL_LIFETIME)
        end
        if killer.code == "AKLX" then layEggs(world, u, killer) end         -- Queen Spider -> Spider Eggs
    end
    if require("src.game.unit").isTitanUnit(code) then M.explodeTitan(world, u) end
end

local lastSheep, lastCow = 0, 0      -- the original's 1 s sound throttles (a real-time value, sound only)

-- A critter was killed by the army `killer` (the lower half of the army death, FUN_005210b0): the Minotaur eats it, a daemon eats a
-- Soul, the Troll and the Catapult collect sheep and cows. `now` is the world time.
---@param world World
---@param victim Unit
---@param killer Unit|Building
function M.onCritterKilled(world, victim, killer)
    if killer.kind ~= "unit" or killer == victim then return end
    ---@cast killer Unit
    local Unit = require("src.game.unit")
    if not Unit.isCritter(victim.code) then return end
    local vcode, kcode = victim.code, killer.code
    local x, y = victim.gx, victim.gy
    local function truncate() victim.deadSince = world.time - 19000 end     -- FUN_00537700: the corpse goes at once
    if vcode ~= "ACSO" and killer:isMinotaur() then
        -- a Minotaur eats a real critter: 20 hits back (the Soul does not count as a critter here)
        sound.playAt("Assets/SoundFX.xcr", "Eating.wav", x, y)
        emit(world, victim, "eat")
        killer.hp = math.min(killer.maxHp, killer.hp + 20)
        truncate()
    elseif DAEMONS[kcode] and vcode == "ACSO" then
        if killer.h then
            local h = killer.h
            ---@cast h -nil
            h.mana = math.min(h.mod.mana, (h.mana or 0) + M.SOUL_MANA)     -- a hero's soul mana has no effect picture
        elseif kcode == "AVJX" then
            local gained = killer:addXp(M.SOUL_EXPERIENCE)
            if gained > 0 then world:event("gainedlevel", killer, gained) end
        elseif killer.maxMana then
            local before = killer.mana or 0
            killer.mana = math.min(killer.maxMana, before + M.SOUL_MANA)
            if killer.mana > before then emit(world, killer, "EMLE") end
        end
    end
    if kcode == "AOMX" and vcode == "ACSH" then
        local now = love.timer.getTime()
        if now - lastSheep > 1 then lastSheep = now sound.playAt("Assets/SoundFX.xcr", "GettingSheep.wav", x, y) end
        truncate()
        killer.ammo = (killer.ammo or 0) + 1
    end
    if kcode == "ASCA" and vcode == "ACCO" and math.abs(killer.gx - x) <= 20 and math.abs(killer.gy - y) <= 20 then
        local now = love.timer.getTime()
        if now - lastCow > 1 then lastCow = now sound.playAt("Assets/SoundFX.xcr", "GettingCow.wav", x, y) end
        truncate()
        killer.ammo = (killer.ammo or 0) + 1
        -- the next combat time becomes now: the Catapult may fire again at once
        local a = killer.attack
        if a then a.period = math.max(1, math.min(a.period, world.time - a.t0)) end
    end
end

-- The Troll and the Catapult throw what they carry in place of a crushing missile: x3 damage, the picture becomes a sheep /
-- cow and the counter goes down by one. Returns the missile code and the damage factor, or nil.
---@param u Unit
---@param damageType integer
---@return string? code
---@return integer? factor
function M.throwAmmo(u, damageType)
    if (u.ammo or 0) <= 0 or damageType ~= 5 then return nil end
    local code = u.code == "AOMX" and "ACSH" or u.code == "ASCA" and "ACCO" or nil
    if not code then return nil end
    u.ammo = u.ammo - 1
    return code, 3
end

return M
