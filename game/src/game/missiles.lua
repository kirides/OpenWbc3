-- Missile accuracy: whether a missile of an army, a tower or a spell flies true, and where it lands when it does not.
-- Checked in the 1.04 binary (the two missile constructors: `FUN_0053df60` shoots at an army or
-- building, `FUN_0053e960` at a cell; the roll and the landing offsets are the same in both):
--   * the shooter's chance is a table by the shooter's real combat skill (index 0..25, clipped), 1 .. 99 percent:
--     army `FUN_00523ef0` (table at 0x611294: 1 10 20 25 30 ... 98 99), armed building `FUN_0052d9b0`
--     (table at 0x6114e0: 10 20 25 30 ... 99 99; the tower's combat is `Eco:buildingCombat`);
--   * against an army target the index is halved when the target stands within one cell of the shooter in both axes,
--     then lowered by the target's speed / 6 (rounded towards zero; the real speed, `FUN_0051c460(1)`);
--   * an army shooter's chance is moved by 10 per level of height it stands above the target (+) or below (-)
--     (`FUN_0048f810` of both cells; the building version has no such term) and by -20 for each of fear, awe and terror
--     on the shooter (the psych-effect bits 1 / 4 / 2 at +0xBA), then clipped to 1 .. 99;
--   * the roll is a d100 per attack: an army's comes with its attack message (`FUN_00536e30`: a d100 into the
--     random-factor bits, stored at +0x228 of the army, a spell message carries one roll per cast from the host's
--     spell resolution `FUN_004aa840` case 0x10), a tower rolls afresh for every missile. `chance < roll` is a miss;
--   * a miss moves the end of the flight sideways (the line of fire turned by 90 degrees, to the left when the roll is
--     even, to the right when it is odd) by 1 + ((roll - chance) >> 5) + (distance >> 2) steps, distance being
--     floor(sqrt(dx^2 + dy^2)) in cells (at least 1): 1 moves only the drawn end (8 x 4 pixels), 2 .. 6 one cell (16 x 12
--     .. 48 x 36 pixels), 7 and more two cells (56 x 42, 64 x 48). The cell end is what hits: a missile damages the first
--     occupied cell of the 2 x 2 block (x, y) (x, y + 1) (x + 1, y) (x + 1, y + 1) round its end (the missile frame code
--     at `0x0053fbc0`, no Ghidra function), when an army or building of a side that is neither the shooter's nor an ally
--     stands there.
-- openwbc3's own: the height term reads the scenario's per-cell height byte (`Terrain:heightAt`) for the original's
-- tile height table (`FUN_0048f810`; assumed equal). The d100 comes from the simulation's random numbers.
--
-- Missile flight (the second half of this file): every missile is a simulation object of `world.missiles` that flies
-- the original's pre-computed steps and hits what it meets. Checked in the 1.04 binary (the missile display item):
--   * the constructors `FUN_0053df60` / `FUN_0053e960` and the step table `FUN_00541120` (the flight steps); the flags of
--     a missile picture come from `FUN_0053f180` (the missile setup from the shooter's type, table in `PROFILE`);
--   * a missile has (distance x frames per cell) >> 2 steps, 2 to 80, one every 25 ms (FAST pictures) or 50 ms; the frames
--     per cell are 4 fast / 6 medium / 12 slow / 15 very slow; the distance is the floor of the cell distance (1 at least);
--   * a target that is walking is led: the end moves by (time of flight / the target's time for a cell, table
--     `0x0061178c` = `gamedata.STEP_TIME`) cells and 32 x 24 pixels each in its direction, before the miss offset;
--   * the step heights (arc, curve and high arc tables of `FUN_00541120`) decide what a missile can hit on the way: an
--     army only below height 2 (up to 4 for huge and flying armies), a building below 2 or when the shooter is a
--     building or a flyer, a feature is no obstacle; the first of the four cells (x, y) (x, y + 1) (x + 1, y)
--     (x + 1, y + 1) at the step that holds anything decides, friends and allies are ignored;
--   * the impact `FUN_005427e0`: the damage with hit type 2 and the armour of the victim, times the height
--     percentage of the table at `0x00611e60` (20 30 40 50 60 70 80 100 120 130 140 150 200 250 300, index
--     start height - victim height + 7, 0 .. 14), nothing at all when the shooter has died on the way (unless the
--     missile is a forced one), the same victim twice in a row only once; the splash pictures (catapult rock, sheep, cow,
--     goblin: `FUN_00541e00`) hit the victim, the eight cells round the step at 3/4 and the twelve of the second ring
--     at 9/16; carry-through pictures (spear, bolts, axes) hit everything on the way and fly on;
--   * the titan's balls (EMTF / EMTM) that reach their cell burst for 150 damage (hit type 2, fire / magic armour,
--     no attacker) to every army and building in the box x - 4 .. x + 4, y - 4 .. y + 3 (the tail of the missile frame
--     code at `0x00540bc0`, which is no Ghidra function: read from the bytes); a ball that hits something on its last step
--     does not burst. The collision test of the missile frame code (`0x0053fbc0`, also no Ghidra function) was read from
--     the bytes: four cells, heights 2 and 4, the huge and flyer flag bits 0x40200000.
--   * the frame function (`0x0053fbc0`: the three EMX0 and two EMX1 pushes, the EZ06 / EZ07 ones and the terrain 9
--     test are in the bytes; which push belongs to which case below is not traced in the 1.04 binary yet): a missile that ends against a building without splash
--     puffs (EMX0 at the step), a splash lands with EMX1 (also the ones that land alone), a missile over the void (terrain 9) ends
--     there with EMX0, a lightning ends with EMX0, the Titan's balls burst with EZ06 (fire) / EZ07 (magic); the after-images of a
--     missile (`trail`, 5 for most pictures) live on for that many frames after its landing (`m.landed`, `m.ix, m.iy`);
--   * the building's solid-pixel test (`M.solid`, `0x00539f00` via the sprite test `FUN_00487c60`): only a pixel of the building's picture that is not
--     transparent and not in the shadow range (index 247 and up) can be hit, the frame it is shown in is taken as if the ambient
--     animations were on (the option differs between machines); a missile aims at the effect point of its target (position less
--     the .ani effect origin), which is on a solid pixel of every building picture of the install;
--   * the dragon breath (FUN_00542150): the end cell, the eight cells round it with 3/4 and the twelve of the second ring with 9/16 of
--     the damage, at most eight things in all, the good / evil breath doubles against the opposite alignment, no impact sound; fire,
--     ice and lightning breath always carry their special attack (FUN_0053f180); the thrown goblin gets up again one time in eight
--     (FUN_00541e00: the owner's army limit, an empty cell, attitude 4 = rampant);
--   * the start pixel (`M.startPoint`): the shooter's combat point for the direction it faces (a building: towards the target) from the
--     corner of its selection rectangle (the frame of its current animation), else the middle of that rectangle, heroes always; a ball
--     without a shooter starts in the middle of its cell;
--   * the impact skips the armour (raw damage) when the shooter is a titan (army flag `+0x1cd`) or the
--     missile carries the ignore-armour special attack and the victim is an army (`Unit:strike`).
--   * the acid, evil and good breath's special attacks (the second switch of the impact `FUN_005427e0`): `Unit.breathSpecial`, with the numbers in its comment;
-- openwbc3's own / left out: neutral buildings other than lairs are no obstacle, a
-- neutral side's goblin does not get up (its army limit in the original is unknown), the breath's picture is drawn over the map instead of behind or in front of the dragon.
-- The sparks, trails and lights along a missile (the missile-id conversion `FUN_0040f620`) and the good / acid breath's emitters are
-- in gfx/emitters.lua.
local bit = require("bit")
local M = {}

-- A missile in flight (world.missiles).
---@class Missile
---@field code string?         the picture (a `missile` record id; nil: a type without one)
---@field kind string?         the handler (M.handlers) that deals the damage
---@field p any                the handler's saved payload
---@field flags integer        F.* bits
---@field ft integer           ms per frame
---@field shooter (Unit|Building)? nil for a ball, or when the shooter was not saved
---@field target (Unit|Building)?  what it was shot at (for the cast's pictures, gfx/spellfx.lua; not saved)
---@field side integer?        the owner; nil: everybody's enemy
---@field crit boolean?        carries the special attack
---@field dmgMul number?
---@field force boolean        damages even when the shooter is dead
---@field frame integer        frames done
---@field rings integer        splash: 0 the victim, 1 the first ring, 2 the second
---@field instant boolean      lightning and breath: no steps, 8 frames
---@field trail integer        after-image frames after the landing
---@field high boolean?        shot by a building or a flyer
---@field h0 integer?          the start height
---@field roll integer?        the attack's d100
---@field chance integer?      the shooter's chance
---@field gx0 integer          start cell
---@field gy0 integer
---@field gx1 integer          end cell
---@field gy1 integer
---@field x0 number            start pixel
---@field y0 number
---@field x1 number            end pixel
---@field y1 number
---@field gx integer           the cell it is on
---@field gy integer
---@field t0 number            launch time (world time, ms)
---@field nextT number         time of the next frame
---@field n integer            steps of the flight
---@field maxSteps integer     the frame the flight ends at (lowered by a collision)
---@field steps table<integer, MissileStep>? 0 .. n - 1 (not for instant missiles)
---@field hitDone boolean?     an instant missile has struck
---@field landed boolean?
---@field ix number?           where it landed (pixels)
---@field iy number?
---@field done boolean?        finished: removed at the next update
---@field lastHit (Unit|Building)? the same victim twice in a row is hit once
---@field dbl any              the breath's double damage against an alignment (Unit:strike)
---@field attack any           the breath's special attack (Unit.breathSpecial)

-- One step of a flight (buildSteps).
---@class MissileStep
---@field gx integer
---@field gy integer
---@field px number            drawn position
---@field py number
---@field change boolean       moved to another cell
---@field h integer            the height it flies at (what it can hit)

-- The accuracy of one shot (M.aim).
---@class MissileAim
---@field miss boolean
---@field chance integer
---@field roll integer
---@field gx integer?          miss: the landing cell
---@field gy integer?
---@field px integer?          miss: pixels the drawn end moves by
---@field py integer?

-- What M.launch takes.
---@class MissileSpec
---@field code string?
---@field kind string?
---@field p any
---@field shooter (Unit|Building)?
---@field side integer?
---@field target (Unit|Building)?
---@field gx0 integer?
---@field gy0 integer?
---@field gx1 integer?
---@field gy1 integer?
---@field x0 number?
---@field y0 number?
---@field ex number?
---@field ey number?
---@field roll integer?
---@field crit boolean?
---@field dmgMul number?
---@field force boolean?

-- chance by combat index 0 .. 25
M.ARMY = { [0] = 1, 10, 20, 25, 30, 35, 40, 45, 50, 55, 60, 65, 70, 75, 78, 81, 84, 87, 90, 92, 94, 95, 96, 97, 98, 99 }
M.BUILDING = { [0] = 10, 20, 25, 30, 35, 40, 45, 50, 55, 60, 65, 70, 75, 78, 81, 84, 87, 90, 92, 94, 95, 96, 97, 98, 99, 99 }

-- the eight directions of DAT_00611e20 / DAT_00611e40: 0 north, clockwise
local DX = { [0] = 0, 1, 1, 1, 0, -1, -1, -1 }
local DY = { [0] = -1, -1, 0, 1, 1, 1, 0, -1 }

-- landing offsets by the inaccuracy 1 .. 8+: cells, pixels in x, pixels in y (the pixels only move the drawn end)
local OFFSET = {
    { 0, 8, 4 }, { 1, 16, 12 }, { 1, 24, 18 }, { 1, 32, 24 }, { 1, 40, 30 }, { 1, 48, 36 }, { 2, 56, 42 }, { 2, 64, 48 },
}

-- the 8-way direction routine FUN_0040a8f0: the direction of a line between two cells
---@param x0 integer
---@param y0 integer
---@param x1 integer
---@param y1 integer
---@return integer 0 north, clockwise
function M.dir8(x0, y0, x1, y1)
    local dx, dy = x1 - x0, y1 - y0
    local adx, ady = math.abs(dx), math.abs(dy)
    if dx == 0 then
        return dy > 0 and 4 or 0
    elseif dy == 0 then
        return dx > 0 and 2 or 6
    elseif dx > 0 and dy > 0 then
        if adx <= ady * 2 then return (adx * 2 < ady) and 4 or 3 end
        return 2
    elseif dx < 0 and dy > 0 then
        if adx <= ady * 2 then return (ady <= adx * 2) and 5 or 4 end
        return 6
    elseif dx < 0 then
        if adx <= ady * 2 then return (ady <= adx * 2) and 7 or 0 end
        return 6
    end
    if ady * 2 < adx then return 2 end         -- dx > 0, dy < 0
    return (ady <= adx * 2) and 1 or 0
end

local function clamp(v, lo, hi) return v < lo and lo or (v > hi and hi or v) end

local function hostile(world, a, b)
    if a == b then return false end
    if a == 6 or b == 6 then return true end
    return world:enemies(a, b)
end

-- The table index of a shooter's combat against `target` (nil: no target, a spell at a cell): halved next to an army
-- target, less the target's speed / 6.
local function index(world, shooter, target, combat)
    local idx = combat
    if target and target.kind == "unit" then
        if math.abs(target.gx - shooter.gx) <= 1 and math.abs(target.gy - shooter.gy) <= 1 then
            idx = math.floor(idx / 2)
        end
        idx = idx - math.floor(target:stats(true).speed / 6)
    end
    return clamp(idx, 0, 25)
end

-- The percentage chance that a missile of `shooter` (a unit, a hero casting a spell, or an armed building) flies true
-- against `target` (a unit or building; nil for none).
---@param world World
---@param shooter Unit|Building
---@param target (Unit|Building)?
---@return integer
function M.chance(world, shooter, target)
    if shooter.kind == "building" then
        return M.BUILDING[index(world, shooter, target, world.eco:buildingCombat(shooter))]
    end
    local chance = M.ARMY[index(world, shooter, target, shooter:stats().combat)]
    if target then
        local terrain = world.terrain
        chance = chance + (terrain:heightAt(shooter.gx, shooter.gy) - terrain:heightAt(target.gx, target.gy)) * 10
    end
    local fx = shooter.fx
    if fx then
        if fx.fear then chance = chance - 20 end
        if fx.awe then chance = chance - 20 end
        if fx.terror then chance = chance - 20 end
    end
    return clamp(chance, 1, 99)
end

-- The flight of one missile: { miss = false } or { miss = true, gx, gy = the cell it lands in, px, py = pixels the
-- drawn end moves by }. `roll` is the d100 of the attack (a building rolls for every missile). `egx, egy` is the end
-- cell the missile flies to when that is not the target's own (a walking target's lead moves it first).
---@param world World
---@param shooter Unit|Building
---@param target Unit|Building
---@param roll integer?
---@param egx integer?
---@param egy integer?
---@return MissileAim
function M.aim(world, shooter, target, roll, egx, egy)
    if shooter.kind == "building" or not roll then roll = math.random(100) end
    local chance = M.chance(world, shooter, target)
    if chance >= roll then return { miss = false, chance = chance, roll = roll } end
    local dx, dy = target.gx - shooter.gx, target.gy - shooter.gy
    local dist = math.max(1, math.floor(math.sqrt(dx * dx + dy * dy)))
    local inaccuracy = 1 + math.floor((roll - chance) / 32) + math.floor(dist / 4)
    egx, egy = egx or target.gx, egy or target.gy
    local d = M.dir8(shooter.gx, shooter.gy, egx, egy)
    d = (d + (roll % 2 == 0 and 6 or 2)) % 8
    local o = OFFSET[math.min(inaccuracy, 8)]
    return {
        miss = true, chance = chance, roll = roll,
        gx = clamp(egx + DX[d] * o[1], 0, world.w - 1), gy = clamp(egy + DY[d] * o[1], 0, world.h - 1),
        px = DX[d] * o[2], py = DY[d] * o[3],
    }
end

-- The building whose footprint covers a cell, if any
local function buildingAt(world, gx, gy)
    for _, b in ipairs(world.buildings) do
        if b.hp > 0 and b.shape and math.abs(b.gx - gx) <= 16 and math.abs(b.gy - gy) <= 16 then
            for _, c in ipairs(world:shapeCells(b.gx, b.gy, b.shape)) do
                if c[1] == gx and c[2] == gy then return b end
            end
        end
    end
    return nil
end

-- What a missile that missed hits, if anything: the first occupied cell of the 2 x 2 block at its landing cell, when
-- that is an army or building of a hostile side (of the shooter's `side`).
---@param world World
---@param side integer
---@param aim MissileAim a miss
---@return (Unit|Building)?
function M.victim(world, side, aim)
    for _, c in ipairs({ { 0, 0 }, { 0, 1 }, { 1, 0 }, { 1, 1 } }) do
        local gx, gy = aim.gx + c[1], aim.gy + c[2]
        if gx < world.w and gy < world.h then
            local u = world:unitAt(gx, gy)
            if u and u:alive() then
                return hostile(world, side, u.side) and u or nil
            end
            local b = buildingAt(world, gx, gy)
            if b then return hostile(world, side, b.side) and b or nil end
        end
    end
    return nil
end

-- The missile's drawn end for a target at pixel (x, y)
---@param aim MissileAim
---@param x number
---@param y number
---@return number x
---@return number y
function M.drawnEnd(aim, x, y)
    if aim.miss then return x + aim.px, y + aim.py end
    return x, y
end

-- Flight --------------------------------------------------------------------------------------------------------------

local band, rshift = bit.band, bit.rshift
local CW, CH = 32, 24
local VOID = require("src.game.terrain").TYPE.VOID
local F = { INSTANT = 0x1, FAST = 0x2, MEDIUM = 0x4, SLOW = 0x8, VERYSLOW = 0x10, LINEAR = 0x20, CURVED = 0x40, ARC = 0x80,
            HIGHARC = 0x100, CARRY = 0x200, SPLASH = 0x400, LOWSHOT = 0x800, HIGHSHOT = 0x1000, LIGHTNING = 0x2000 }
M.F = F

-- What FUN_0053f180 (the missile setup from the shooter's type) gives every missile picture: the DIMN flags, the `missile` records of
-- content/base/missiles.lua (the breath's 0x21 comes from the shared tail of that function).
M.PROFILE = require("src.content").missile:idView("flags")

---@param code string?
---@return integer
function M.flagsOf(code) return M.PROFILE[code] or 0 end

-- the pictures of the titan's balls are the fireball and the magic sphere (the `sprite` of their records)
M.SPRITE = require("src.content").missile:idView("sprite")

-- the picture's own animation frames (default 1), its direction rows (16) and the after-image frames behind it (0): the
-- `frames`, `dirs` and `trail` of the records
M.FRAMES = require("src.content").missile:idView("frames")
M.DIRS = require("src.content").missile:idView("dirs")
M.TRAIL = require("src.content").missile:idView("trail")
M.SPINNER = require("src.content").missile:idView("spinner")

-- the colours of a lightning's five lines (FUN_0053f180): the `lightning` ramp of the record, value = base + step * i
function M.lightningColour(code, i)
    local rec = require("src.content").missile._recs[code]
    local ramp = rec and rec.lightning or { { 0, 10 }, { 0, 10 }, { 0, 10 } }
    return ramp[1][1] + ramp[1][2] * i, ramp[2][1] + ramp[2][2] * i, ramp[3][1] + ramp[3][2] * i
end

local HEIGHT_PCT = { [0] = 20, 30, 40, 50, 60, 70, 80, 100, 120, 130, 140, 150, 200, 250, 300 }   -- table at 0x00611e60

-- The percentage of its damage a missile does to `target`: start height minus the height of the target's cell (+ 7).
---@param world World
---@param m Missile?
---@param target Unit|Building
---@return integer
function M.heightPercent(world, m, target)
    if not (m and m.h0) then return 100 end
    return HEIGHT_PCT[clamp(m.h0 - world.terrain:heightAt(target.gx, target.gy) + 7, 0, 14)]
end

local function frameTime(flags) return band(flags, F.FAST) ~= 0 and 25 or 50 end

local function framesPerCell(flags)
    if band(flags, F.MEDIUM) ~= 0 then return 6 end
    if band(flags, F.SLOW) ~= 0 then return 12 end
    if band(flags, F.VERYSLOW) ~= 0 then return 15 end
    return 4
end

-- C integer division (truncates towards zero)
local function idiv(a, b)
    local q = a / b
    return q < 0 and math.ceil(q) or math.floor(q)
end

local function flyer(u)
    return band(require("src.game.powerups").flags(u.code), 0x200000) ~= 0
end

-- The steps of a flight (FUN_00541120): the cell and pixel of every frame and the height the missile
-- flies at (what it can hit). m.n steps from the start to the end (cells gx0 .. gx1, pixels x0 .. x1).
---@param m Missile
local function buildSteps(m)
    local flags, n, high = m.flags, m.n, m.high
    local highTarget = band(flags, F.HIGHSHOT) ~= 0
    local steps = {}
    local half = rshift(n, 1)
    for i = 0, n - 1 do
        local gx = m.gx0 + idiv((m.gx1 - m.gx0) * (i + 1), n)
        local gy = m.gy0 + idiv((m.gy1 - m.gy0) * (i + 1), n)
        local prev = steps[i - 1]
        steps[i] = {
            gx = gx, gy = gy,
            px = m.x0 + idiv((m.x1 - m.x0) * (i + 1), n), py = m.y0 + idiv((m.y1 - m.y0) * (i + 1), n),
            change = prev ~= nil and (gx ~= prev.gx or gy ~= prev.gy),
            h = ((high and i < half) or highTarget) and 2 or 0,
        }
    end
    steps[0].change = true
    if n > 4 then
        local total = math.abs(idiv((m.x1 - m.x0) + math.floor((m.y1 - m.y0) / 2), n))
        local add = 0
        local function lift(st) st.py = st.py + add end
        if band(flags, F.CURVED) ~= 0 then
            for i = 0, n - 1 do
                local st = steps[i]
                if i < idiv(n, 5) then add = add - rshift(total, 2); lift(st); st.h = high and 2 or 0
                elseif i < idiv(2 * n, 5) then add = add - rshift(total, 3); lift(st); st.h = high and 2 or 1
                elseif i < idiv(3 * n, 5) then lift(st); st.h = (high or highTarget) and 2 or 1
                elseif i < idiv(4 * n, 5) then add = add + rshift(total, 3); lift(st); st.h = highTarget and 2 or 1
                else add = add + rshift(total, 2); lift(st); st.h = highTarget and 2 or 0 end
            end
        elseif band(flags, F.ARC) ~= 0 then
            for i = 0, n - 1 do
                local st = steps[i]
                if i < idiv(n, 5) then add = add - rshift(total, 1); lift(st); st.h = high and 2 or 1
                elseif i < idiv(2 * n, 5) then add = add - rshift(total, 2); lift(st); st.h = 2
                elseif i < idiv(3 * n, 5) then lift(st); st.h = 3
                elseif i < idiv(4 * n, 5) then add = add + rshift(total, 2); lift(st); st.h = 2
                else add = add + rshift(total, 1); lift(st); st.h = highTarget and 2 or 1 end
            end
        elseif band(flags, F.HIGHARC) ~= 0 then
            for i = 0, n - 1 do
                local st = steps[i]
                if i < idiv(n, 7) then add = add - total * 2; lift(st); st.h = 2
                elseif i < idiv(2 * n, 7) then add = add - total; lift(st); st.h = 4
                elseif i < idiv(3 * n, 7) then add = add - rshift(total, 1); lift(st); st.h = 5
                elseif i < idiv(4 * n, 7) then lift(st); st.h = 6
                elseif i < idiv(5 * n, 7) then add = add + rshift(total, 1); lift(st); st.h = 5
                elseif i < idiv(6 * n, 7) then add = add + total; lift(st); st.h = 4
                else add = add + total * 2; lift(st); st.h = 2 end
            end
            steps[n - 1].h = 1
        end
    end
    m.steps = steps
end

-- One-shot pictures (the effect display item, spawned by FUN_0044e8f0): EMX0 where a missile ends against a building or the void, EMX1 where a
-- splash lands, EZ06 / EZ07 where a titan ball bursts, E?B<dir> at a dragon (12 frames). 50 ms a frame; the frame counts are those of the
-- .ani records.
-- Presentation only: the battle view draws `world.effects`.
-- (the setting `missile.effects`: `puff`, `splash` and the frame counts; the balls' own `burst` picture is in their records)
local EFFECTS = require("src.content").setting
local function effect(world, code, x, y)
    world.effects = world.effects or {}
    world.effects[#world.effects + 1] = { kind = "sprite", code = code, x = x, y = y, t0 = world.time,
                                          dur = (EFFECTS:value("missile.effects").frames[code] or 12) * 50 }
end

-- The sheet cell a building shows right now (the logic of the battle view's drawEntity, with the ambient-animation option
-- taken as on so that every peer sees the same picture): the animation and its frame, or nil without pixel data.
local sprite = require("src.formats.sprite")
local function buildingPicture(world, b)
    local set, A = b.set, sprite.ANIM
    if not (set and set.info and set.sheet and set.has) then return nil end
    if not b.complete and set:has(A.SPECIAL) then
        local p = b.site and (world.time - b.site.t0) / (b.site.t1 - b.site.t0) or 1
        return A.SPECIAL, p < 0.34 and 0 or (p < 0.67 and 1 or 2)
    end
    if b.pillaged and not b.mine and set:has(A.SPECIAL) then
        local left = b.pillaged - world.time
        return A.SPECIAL, left < 40000 and 2 or (left < 80000 and 1 or 0)
    end
    if b.pillaged and set:has(A.DIE) then return A.DIE, 0 end
    local anim = b.anim or A.STAND
    if not set:has(anim) then anim = A.STAND end
    if not set:has(anim) then return nil end
    local n, frame = set:frames(anim), 0
    if n > 1 and b.complete then
        local a = set.info[anim]
        local step = a and a.effectActivation or 0
        if step <= 0 then step = 100 end
        frame = math.floor(world.time / step) % n
    end
    return anim, frame
end

-- The "solid pixel" test of a building (`0x00539f00` and the sprite test `FUN_00487c60`, called with the missile's pixel
-- less the corner of the building's sprite rectangle): whether the picture has a pixel there that is neither transparent nor in the
-- shadow range of the palette (index 247 and up). A building whose picture has no pixel data (a PNG set) counts as solid.
---@param world World
---@param b Building
---@param px number
---@param py number
---@return boolean
function M.solid(world, b, px, py)
    local anim, frame = buildingPicture(world, b)
    if not anim then return true end
    local set = b.set
    -- buildingPicture gives no picture without a set
    ---@cast set -nil
    local info, sheet = set.info[anim], set:sheet(anim)
    if not (sheet and sheet.idx and sheet.kind) then return true end
    local fw, fh = info.width, info.height
    if not fw or fw <= 0 or not fh or fh <= 0 then fw, fh = sheet.w, sheet.h end
    local lx, ly = math.floor(px - (b.x - info.originX)), math.floor(py - (b.y - info.originY))
    if lx < 0 or lx >= fw or ly < 0 or ly >= fh then return false end
    local sx, sy = frame * fw + lx, (b.dir or 0) * fh + ly
    if sx >= sheet.w or sy >= sheet.h then return false end
    local i = sy * sheet.w + sx
    return sheet.kind[i] == 1 and sheet.idx[i] < 247
end

-- Obstacles ---------------------------------------------------------------------------------------------------

-- the building on each cell, rebuilt when a footprint is blocked or freed
local function buildingMap(world)
    local c = world.missileCells
    local rev, nb = world.blockRev or 0, #world.buildings
    if c and c.rev == rev and c.nb == nb then return c.map end
    local map = {}
    for _, b in ipairs(world.buildings) do
        if b.shape then
            for _, cell in ipairs(world:shapeCells(b.gx, b.gy, b.shape)) do
                if world.terrain:inside(cell[1], cell[2]) then map[cell[2] * world.w + cell[1]] = b end
            end
        end
    end
    world.missileCells = { rev = rev, nb = nb, map = map }
    return map
end

local FEATURE = {}      -- trees, rocks: a cell with one has "data" but nothing a missile hits

-- What is on a cell: air = the layer of the flying armies, else ground armies, buildings and features
local function cellObj(world, gx, gy, air)
    local i = gy * world.w + gx
    local u = world.occ[i]
    if u and u.hp > 0 and u.state ~= "dead" and not u.hidden then
        if (u.move == 1) == air then return u end
    end
    if air then return nil end
    local b = buildingMap(world)[i]
    if b and b.hp > 0 then return b end
    if world.static[i] ~= 0 then return FEATURE end
    return nil
end

local function hostileTo(world, owner, side)
    if owner == nil then return true end
    return hostile(world, owner, side)
end

-- a neutral building is an obstacle only when it is a lair (openwbc3's choice: shops, mines and shrines are not hurt)
local function blocks(b) return b.side ~= 6 or b.lair ~= nil end

-- What the missile's step holds (the missile frame code at 0x0053fbc0): the first of the four cells (x, y) (x, y + 1) (x + 1, y) (x + 1, y + 1)
-- with anything on it; a shot at a flyer looks at the flyers first, and from height 2 on at the ground only for
-- buildings, huge armies and flyers.
local OFFS = { { 0, 0 }, { 0, 1 }, { 1, 0 }, { 1, 1 } }
local function scan(world, m, step)
    local high = band(m.flags, F.HIGHSHOT) ~= 0
    for k = 1, 4 do
        local cx, cy = m.gx + OFFS[k][1], m.gy + OFFS[k][2]
        if cx < world.w and cy < world.h then
            local o
            if high then
                o = cellObj(world, cx, cy, true)
                if not o then
                    o = cellObj(world, cx, cy, false)
                    if o and step.h >= 2 then
                        if o == FEATURE then o = nil
                        elseif o.kind == "unit" and band(require("src.game.powerups").flags(o.code), 0x40200000) == 0 then o = nil end
                    end
                end
            else
                o = cellObj(world, cx, cy, false)
            end
            if o then return o end
        end
    end
    return nil
end

-- Effects of the step's find: damage (and whether it splashes), collision (the flight ends here).
local function evaluate(world, m, o, step)
    if o == FEATURE then return false, false, false end
    local flags = m.flags
    local damage, collision, splash = false, false, false
    local isSplash = band(flags, F.SPLASH) ~= 0
    if o.kind == "building" then
        if blocks(o) and hostileTo(world, m.side, o.side) and M.solid(world, o, step.px, step.py) then
            if step.h < 2 or m.high then
                damage, collision = true, true
                splash = isSplash
            end
        end
    else
        local pf = require("src.game.powerups").flags(o.code)
        local big = band(pf, 0x40200000) ~= 0
        if step.h < 2 or (step.h <= 4 and big) then
            if hostileTo(world, m.side, o.side) and o.hp > 0 then
                if band(flags, F.CARRY) ~= 0 then
                    if band(pf, 0x40000000) ~= 0 then damage = true
                    elseif band(pf, 0x200000) ~= 0 then damage = band(flags, F.HIGHSHOT) ~= 0
                    else damage = band(flags, F.LOWSHOT) ~= 0 end
                else
                    damage, collision = true, true
                end
                if step.h < 2 then
                    damage = true
                    if band(flags, F.CARRY) == 0 then collision = true end
                end
                splash = isSplash
            end
        end
    end
    return damage, collision, splash
end

-- Impact ----------------------------------------------------------------------------------------------------------

---@type table<string, fun(world: World, m: Missile, victim: Unit|Building)>
M.handlers = {}         -- kind -> function(world, m, victim): the damage, registered by the module that fires the kind

---@param world World
---@param m Missile
---@param victim Unit|Building
---@param quiet boolean? no impact sound
function M.hit(world, m, victim, quiet)
    if victim == m.lastHit then return end
    m.lastHit = victim
    if not quiet then require("src.game.unit").missileImpactSound(m.code, victim) end
    local fn = M.handlers[m.kind]
    if fn then fn(world, m, victim) end
end

local RING2 = { { -1, -2 }, { 0, -2 }, { 1, -2 }, { 2, -1 }, { 2, 0 }, { 2, 1 }, { 1, 2 }, { 0, 2 }, { -1, 2 }, { -2, 1 }, { -2, 0 }, { -2, -1 } }

local function splashVictim(world, m, gx, gy, target)
    if gx < 0 or gy < 0 or gx >= world.w or gy >= world.h then return nil end
    local o = cellObj(world, gx, gy, false)
    if not o or o == FEATURE or o == target then return nil end
    if not hostileTo(world, m.side, o.side) then return nil end
    return o
end

-- Splash (FUN_00541e00): the victim, then the eight cells round the step with 3/4 of the damage, then the twelve of the
-- second ring with 3/4 of that.
---@param world World
---@param m Missile
---@param victim (Unit|Building)?
function M.splash(world, m, victim)
    local step = m.steps[math.min(m.frame, m.n - 1)]
    local quiet = false
    if victim then M.hit(world, m, victim, false); quiet = true end
    m.rings = 1
    for i = 0, 7 do
        local o = splashVictim(world, m, step.gx + DX[i], step.gy + DY[i], victim)
        if o then M.hit(world, m, o, quiet); quiet = true end
    end
    m.rings = 2
    for _, d in ipairs(RING2) do
        local o = splashVictim(world, m, step.gx + d[1], step.gy + d[2], victim)
        if o then M.hit(world, m, o, quiet); quiet = true end
    end
    effect(world, EFFECTS:value("missile.effects").splash, step.px, step.py)
    -- a thrown goblin has a chance of one in eight to get up again on its cell and fight on (FUN_00541e00's tail, read from the
    -- binary): the owner must have room in its army limit and the cell must hold nothing (the original does not look at the terrain, a
    -- water cell would drown the goblin: openwbc3 also asks for a free ground cell, and gives a neutral side's goblin no second life,
    -- the original's limit arrays for it are not known). It comes out rampant (attitude 4).
    local rec = require("src.content").missile._recs[m.code]
    if rec and rec.getsUp and math.random(rec.getsUp) == 1 and m.side and m.side < 6 then
        local gx, gy = step.gx, step.gy
        local cur, max = world.eco:armyLimit(m.side)
        if cur < max and gx > 0 and gy > 0 and gx < world.w - 1 and gy < world.h - 1 and world:free(gx, gy, 0)
            and cellObj(world, gx, gy, false) == nil then
            local u = require("src.game.unitspecials").produce(world, m.code, m.side, gx, gy)
            if u then u.attitude = "rampant" end
        end
    end
end

-- A titan's ball that reaches its cell: 150 damage (hit type 2, fire for the Titan's EMTF, magic for EMTM, the armour of
-- the victim) to every army and building in the box, nobody gets the credit.
local function burst(world, m)
    local Unit = require("src.game.unit")
    local fire = m.code == "EMTF"
    local dtype = fire and 3 or 4
    local x0, y0 = math.max(0, m.gx1 - 4), math.max(0, m.gy1 - 4)
    local x1, y1 = x0 + 8, y0 + 7
    local x, y = m.gx1 * CW + 16, m.gy1 * CH + 12
    effect(world, require("src.content").missile._recs[m.code].burst, x, y)
    require("src.audio.sound").playAt("Assets/SoundFX.xcr", fire and "STEZ47.wav" or "STEZ23.wav", m.gx1, m.gy1)
    for _, u in ipairs(world.units) do
        if u.hp > 0 and u.state ~= "dead" and not u.hidden and not u.remove and u.gx >= x0 and u.gx <= x1
            and u.gy >= y0 and u.gy <= y1 then
            u:takeDamage(Unit.soften(u, 150, dtype, false), nil)
        end
    end
    for _, b in ipairs(world.buildings) do
        if b.hp > 0 and b.gx >= x0 and b.gx <= x1 and b.gy >= y0 and b.gy <= y1 then
            world:damageBuilding(b, Unit.soften(b, 150, dtype, false), nil)
        end
    end
end

-- Dragon breath ---------------------------------------------------------------------------------------------------

-- The dragon breath strike (FUN_00542150, on the missile's 3rd frame): the armies and buildings on the end cell (ground, then the flying
-- layer), then those on the eight cells round it with 3/4 of the damage (ground, then air), then the twelve of the second ring at 9/16
-- (ground only). At most eight things are looked at in all; the ones found on the rings count even when they are allies (they are
-- not hurt). No impact sound (the breath plays DragonBreath0 / 1.wav at its end cell instead, a presentation event), the picture of
-- the breath puts an effect on every walking army it hurts on the end cell, and the evil / good breath does double damage to the
-- good / evil (`missile.dbl`, read by Unit:strike).
local function breath(world, m)
    local rec = require("src.content").missile._recs[m.code] or {}
    local gx, gy = m.gx1, m.gy1
    world:event("breath", gx, gy)
    local seen, count = {}, 0
    m.dbl = rec.doubleVs
    m.attack = rec.attack          -- the acid / evil / good breath's special attack (Unit.breathSpecial)
    local function at(x, y, air)
        if x < 0 or y < 0 or x >= world.w or y >= world.h then return nil end
        local o = cellObj(world, x, y, air)
        if o == FEATURE then return nil end
        return o
    end
    local function hurt(o)
        if o.kind == "building" and not blocks(o) then return false end
        return hostileTo(world, m.side, o.side)
    end
    m.rings = 0
    for _, air in ipairs({ false, true }) do
        local o = at(gx, gy, air)
        if o and hurt(o) then
            seen[o], count = true, count + 1
            M.hit(world, m, o, true)
            if o.kind == "unit" and rec.after and band(require("src.game.powerups").flags(o.code), 0x200000) == 0 then
                world:event("breathhit", o, rec.after.sprite, rec.after.emit)
            end
        end
    end
    local function ring(air, offsets)
        for _, d in ipairs(offsets) do
            local o = at(gx + d[1], gy + d[2], air)
            if o and not seen[o] then
                if count >= 8 then return true end
                seen[o], count = true, count + 1
                if hurt(o) then M.hit(world, m, o, true) end
            end
        end
    end
    local ring1 = {}
    for i = 0, 7 do ring1[i + 1] = { DX[i], DY[i] } end
    m.rings = 1
    if ring(false, ring1) or ring(true, ring1) then return end
    m.rings = 2
    ring(false, RING2)
end

-- Frames -------------------------------------------------------------------------------------------------------------

-- One tick of the missile frame code at 0x0053fbc0 (every 25 / 50 ms)
local function frame(world, m)
    m.frame = m.frame + 1
    local f = m.frame
    local flags = m.flags
    if m.instant then
        -- lightning hits what stands on its end cell once, the breath what its cells hold (2nd frame)
        if not m.hitDone and f >= 2 then
            m.hitDone = true
            if band(flags, F.LIGHTNING) ~= 0 then
                local o = cellObj(world, m.gx1, m.gy1, band(flags, F.HIGHSHOT) ~= 0)
                if o == FEATURE then o = nil end
                if o and o.kind == "building" and not blocks(o) then o = nil end
                if o and not hostileTo(world, m.side, o.side) then o = nil end
                if o then M.hit(world, m, o) end
                effect(world, EFFECTS:value("missile.effects").puff, m.x1, m.y1)
            else
                breath(world, m)
            end
            m.landed, m.ix, m.iy = true, m.x1, m.y1
        end
        if f >= m.maxSteps then m.done = true end
        return
    end
    local steps = m.steps
    local splashed = false
    if f < m.maxSteps then
        local step = steps[f]
        if step.change then m.gx, m.gy = step.gx, step.gy end
        local o = scan(world, m, step)
        if o then
            local damage, collision, splash = evaluate(world, m, o, step)
            if damage then
                if splash then M.splash(world, m, o) else M.hit(world, m, o) end
            end
            if collision then m.maxSteps = f end
            -- a missile that hit a building without splash poofs (EMX0)
            if damage and not splash and o.kind == "building" then effect(world, EFFECTS:value("missile.effects").puff, step.px, step.py) end
            splashed = splash
        elseif world.terrain:typeAt(m.gx, m.gy) == VOID then
            -- the void ends the flight
            m.maxSteps = f
            effect(world, EFFECTS:value("missile.effects").puff, step.px, step.py)
        end
    end
    if f == m.maxSteps - 1 then
        if band(flags, F.SPLASH) ~= 0 and not splashed then M.splash(world, m, nil) end
        if m.code == "EMTF" or m.code == "EMTM" then burst(world, m) end
    end
    -- finished when the last step is reached; the after-images live on for `trail` more frames
    if f >= m.maxSteps - 1 then
        if not m.landed then
            local step = steps[math.min(f, m.n - 1)]
            m.landed, m.ix, m.iy = true, step.px, step.py
        end
        if f >= m.maxSteps - 1 + m.trail then m.done = true end
    end
end

-- Moves every missile on to the frames that are due; removes the finished ones.
---@param world World
---@param t number
function M.update(world, t)
    local list = world.missiles
    local i = 1
    while i <= #list do
        local m = list[i]
        local guard = 0
        while not m.done and t >= m.nextT and guard < 24 do
            guard = guard + 1
            m.nextT = m.nextT + m.ft
            frame(world, m)
        end
        if m.done then table.remove(list, i) else i = i + 1 end
    end
end

-- Launch ------------------------------------------------------------------------------------------------------------

-- The pixel a shot leaves the shooter from (FUN_0053df60 / FUN_0053e960, the start of the constructors; the army's combat
-- offset lookup at 0x00536490 reads the table at 0x006e4024, the selection-centre lookup is not traced in the 1.04 binary
-- yet): the shooter's selection rectangle is the frame of its current animation (the `.ani` origin and size; the stand
-- frame for types with the stand-frames-only flag 0x20) at its position. A type with a combat point for the direction it
-- faces (`.ARM` / `.BUI` combat points, 8 of them, heroes never) shoots from that offset from the rectangle's corner,
-- everything else from the middle of the rectangle. A building faces the target (the 8-way direction FUN_0040a8f0 of the
-- two cells), an army the way it looks. No shooter (the Titan's balls): the middle of the start cell.
---@param shooter (Unit|Building)?
---@param gx0 integer
---@param gy0 integer
---@param gx1 integer
---@param gy1 integer
---@return number x
---@return number y
---@overload fun(shooter: nil, gx0: integer, gy0: integer): number, number
function M.startPoint(shooter, gx0, gy0, gx1, gy1)
    if not shooter then return gx0 * 32 + 16, gy0 * 24 + 12 end
    local t = shooter.type
    local building = shooter.kind == "building"
    local anim, dir = shooter.anim or 0, shooter.dir or 0
    if building then anim, dir = 0, M.dir8(gx0, gy0, gx1, gy1) end
    if not building and t and t.flags and band(t.flags, 0x20) ~= 0 then anim = 0 end
    local info = shooter.set and shooter.set.info and shooter.set.info[anim]
    local left, top, w, h = 0, 0, 0, 0
    if info and info.used then left, top, w, h = -info.originX, -info.originY, info.width, info.height end
    local sx, sy = shooter.x + left, shooter.y + top
    local p = not shooter.hero and t and t.combatPoints and t.combatPoints[dir + 1]
    if p and p[1] ~= 0 then return sx + p[1], sy + p[2] end
    return sx + rshift(w, 1), sy + rshift(h, 1)
end

-- Creates a missile (the constructors FUN_0053df60 for an army or building target, FUN_0053e960 for a
-- cell): `s` has the picture `code`, the handler `kind` (M.handlers) with its saved payload `p`, the `shooter` (unit or
-- building; none for a ball), the owning `side` (nil: everybody's enemy), a `target` (unit or building) or a cell
-- (`gx1`, `gy1` and, for the start, `gx0`, `gy0`), the end pixel `ex`, `ey` (default: the target's; the start pixel comes
-- from the shooter, `M.startPoint`, or is the middle of the cell `gx0`, `gy0`), the attack's `roll` (the d100 of the attack message; omitted: a new one), `crit`, `dmgMul`, `force`
-- (damages even when the shooter is dead).
---@param world World
---@param s MissileSpec
---@return Missile
function M.launch(world, s)
    local flags = M.flagsOf(s.code)
    local shooter, target = s.shooter, s.target
    local m = {
        code = s.code, kind = s.kind, flags = flags, ft = frameTime(flags), p = s.p, shooter = shooter, target = target,
        side = s.side,
        crit = s.crit, dmgMul = s.dmgMul, force = s.force or false, frame = 0, rings = 0,
        instant = band(flags, F.INSTANT) ~= 0, trail = M.TRAIL[s.code] or 0,
    }
    -- the breath of a fire, ice or lightning dragon always carries its special attack (FUN_0053f180 sets it for the picture)
    if require("src.content").missile._recs[s.code] and require("src.content").missile._recs[s.code].special then m.crit = true end
    local gx0, gy0 = s.gx0, s.gy0
    if shooter then gx0, gy0 = shooter.gx, shooter.gy end
    local gx1, gy1
    if target then gx1, gy1 = target.gx, target.gy else gx1, gy1 = s.gx1, s.gy1 end
    -- a shot has a shooter, or its start cell is given
    ---@cast gx0 integer
    ---@cast gy0 integer
    -- a shot has a target, or its end cell is given
    ---@cast gx1 integer
    ---@cast gy1 integer
    -- where the shot starts: the shooter's combat point or the middle of its selection rectangle (see M.startPoint); the
    -- cell's middle for a ball without a shooter. A caller's own x0, y0 only counts for those without a shooter and a cell.
    local sx0, sy0 = M.startPoint(shooter, gx0 or 0, gy0 or 0, gx1, gy1)
    if not shooter and s.x0 then sx0, sy0 = s.x0, s.y0 end
    s.x0, s.y0 = sx0, sy0
    -- the end pixel of a shot at an army or building is its effect point: the position less the `effect origin` of its standing sprite
    -- (the constructor FUN_0053df60 reads +0x4c - +0x96 of the target: the position less the effect centre)
    local ex, ey = s.ex, s.ey
    if target and not ex then
        local cx, cy = 0, 16
        if target.set and target.set.effectCentre then cx, cy = target.set:effectCentre() end
        ex, ey = target.x - cx, target.y - cy
    end
    -- the height the missile starts from: the cell, +1 from a building, +1 from a flyer
    local h0 = 0
    if shooter then
        h0 = world.terrain:heightAt(shooter.gx, shooter.gy)
        if shooter.kind == "building" then h0 = h0 + 1
        elseif flyer(shooter) then h0 = h0 + 1 end
        m.high = shooter.kind == "building" or flyer(shooter)
    end
    m.h0 = h0
    flags = bit.bor(flags, (target and target.kind == "unit" and flyer(target)) and F.HIGHSHOT or F.LOWSHOT)
    m.flags = flags
    local dx, dy = gx1 - gx0, gy1 - gy0
    local dist = math.max(1, math.floor(math.sqrt(dx * dx + dy * dy)))
    local n = clamp(rshift(dist * framesPerCell(flags), 2), 2, 80)
    -- a walking target is led: it covers (time of the flight / its time for a cell) cells meanwhile
    if target and target.kind == "unit" and target.state == "step" and not m.instant and target.dir then
        local hit = m.ft * n
        local cross = require("src.game.gamedata").STEP_TIME[clamp(math.floor(target:stats(true).speed), 0, 30)]
        local d = target.dir
        gx1 = gx1 + DX[d] * idiv(hit, cross)
        gy1 = gy1 + DY[d] * idiv(hit, cross)
        ex = ex + DX[d] * idiv(hit * CW, cross)
        ey = ey + DY[d] * idiv(hit * CH, cross)
        gx1, gy1 = clamp(gx1, 0, world.w - 1), clamp(gy1, 0, world.h - 1)
    end
    -- the shooter's accuracy: a miss moves the end sideways
    if shooter and target then
        local aim = M.aim(world, shooter, target, s.roll, gx1, gy1)
        if aim.miss then
            gx1, gy1 = aim.gx, aim.gy
            ex, ey = ex + aim.px, ey + aim.py
        end
        m.roll, m.chance = aim.roll, aim.chance
    end
    gx1, gy1 = clamp(gx1, 0, world.w - 1), clamp(gy1, 0, world.h - 1)
    m.gx0, m.gy0, m.gx1, m.gy1 = gx0, gy0, gx1, gy1
    m.x0, m.y0, m.x1, m.y1 = s.x0, s.y0, ex, ey
    m.t0 = world.time
    m.nextT = m.t0 + m.ft
    if m.instant then
        m.n, m.maxSteps = 8, 8
        m.gx, m.gy = gx0, gy0
    else
        m.n, m.maxSteps = n, n
        buildSteps(m)
        m.gx, m.gy = m.steps[0].gx, m.steps[0].gy
    end
    -- the breath's own picture: an effect at the shooter, facing the target (the 16-way direction of the two cells, modulo 8), 12 frames
    local rec = require("src.content").missile._recs[s.code]
    if m.instant and rec and rec.picture then
        effect(world, rec.picture .. (M.missileDirection(gx0, gy0, m.gx1, m.gy1) % 8), s.x0, s.y0)
    end
    world.missiles[#world.missiles + 1] = m
    return m
end

-- The 16-way missile direction (FUN_005418a0; the sheets confirm it): the row of a 16-direction sheet for a line
-- from (x0, y0) to (x1, y1) in pixels or cells. Rows 0 .. 7 face north, north east, east ... north west, rows 8 .. 15 lie between them
-- (8 north-north-east, 9 east-north-east, 10 east-south-east ...), so an eighth of a turn is two bins of the original's table.
local DIR16 = {}
for k, row in ipairs({ 6, 14, 7, 15, 0, 8, 1, 9, 2, 10, 3, 11, 4, 12, 5, 13, 6 }) do DIR16[k - 9] = row end
---@param x0 number
---@param y0 number
---@param x1 number
---@param y1 number
---@return integer
function M.missileDirection(x0, y0, x1, y1)
    local k = math.floor(math.atan2(y1 - y0, x1 - x0) / (math.pi / 8) + 0.5)
    return DIR16[k] or 6
end

-- The sheet row a missile picture shows at step `i` (the end of FUN_00541120): a linear flight keeps the row of its whole line, a
-- spinner turns through its rows, the rest follow the step they are on (modulo the rows of the sheet when it has fewer than 16).
---@param m Missile
---@param i integer
---@return integer
function M.direction(m, i)
    local dirs = M.DIRS[m.code] or 16
    if dirs <= 1 or m.instant then return 0 end
    local steps = m.steps
    -- every missile that is not instant has its steps
    ---@cast steps -nil
    if band(m.flags, F.LINEAR) ~= 0 then
        return M.missileDirection(steps[0].px, steps[0].py, steps[m.n - 1].px, steps[m.n - 1].py)
    elseif M.SPINNER[m.code] then
        return i % dirs
    end
    local j = math.max(1, math.min(i, m.n - 1))
    local d = M.missileDirection(steps[j - 1].px, steps[j - 1].py, steps[j].px, steps[j].py)
    if dirs < 16 then d = d % dirs end
    return d
end

-- Where a missile is drawn: x, y and the direction it moves in (dx, dy). Instant missiles (lightning, breath) run from
-- the shooter to the end over their eight frames.
---@param m Missile
---@param time number
---@return number x
---@return number y
---@return number dx
---@return number dy
function M.pose(m, time)
    if m.instant then
        local p = clamp((time - m.t0) / (m.ft * m.maxSteps), 0, 1)
        return m.x0 + (m.x1 - m.x0) * p, m.y0 + (m.y1 - m.y0) * p, m.x1 - m.x0, m.y1 - m.y0
    end
    local steps = m.steps
    -- every missile that is not instant has its steps
    ---@cast steps -nil
    local f = clamp((time - m.t0) / m.ft, 0, m.n - 1)
    local i = math.floor(f)
    local a, b = steps[i], steps[math.min(i + 1, m.n - 1)]
    local fr = f - i
    local dx, dy = b.px - a.px, b.py - a.py
    if dx == 0 and dy == 0 then
        local c = steps[math.max(0, i - 1)]
        dx, dy = a.px - c.px, a.py - c.py
        if dx == 0 and dy == 0 then dx, dy = m.x1 - m.x0, m.y1 - m.y0 end
    end
    return a.px + (b.px - a.px) * fr, a.py + (b.py - a.py) * fr, dx, dy
end

-- Save ---------------------------------------------------------------------------------------------------------------

local function ref(v, uidx, bidx)
    if not v then return nil end
    if v.kind == "unit" then return uidx[v] and { "u", uidx[v] } or nil end
    if v.kind == "building" then return bidx[v] and { "b", bidx[v] } or nil end
    return nil
end

local function deref(r, ulist, blist)
    if not r then return nil end
    return (r[1] == "u" and ulist or blist)[r[2]]
end

-- The missiles in flight as plain data (units and buildings by their index in the saved lists; a shooter that is not
-- saved - it died - makes the missile harmless, as it is in the original).
---@param world World
---@param uidx table<Unit, integer>
---@param bidx table<Building, integer>
---@return table[]
function M.save(world, uidx, bidx)
    local out = {}
    local t = world.time
    for _, m in ipairs(world.missiles) do
        if not m.done then
            out[#out + 1] = {
                code = m.code, kind = m.kind, p = m.p, side = m.side, crit = m.crit, dmgMul = m.dmgMul, force = m.force,
                shooter = ref(m.shooter, uidx, bidx), last = ref(m.lastHit, uidx, bidx), rings = m.rings, high = m.high,
                flags = m.flags, h0 = m.h0, frame = m.frame, n = m.n, maxSteps = m.maxSteps, hitDone = m.hitDone,
                landed = m.landed, ix = m.ix, iy = m.iy,
                gx0 = m.gx0, gy0 = m.gy0, gx1 = m.gx1, gy1 = m.gy1, gx = m.gx, gy = m.gy,
                x0 = m.x0, y0 = m.y0, x1 = m.x1, y1 = m.y1, age = t - m.t0, due = m.nextT - t,
            }
        end
    end
    return out
end

---@param world World
---@param list table[]?
---@param ulist Unit[]
---@param blist Building[]
function M.restore(world, list, ulist, blist)
    world.missiles = {}
    local t = world.time
    for _, r in ipairs(list or {}) do
        local m = {
            code = r.code, kind = r.kind, p = r.p, side = r.side, crit = r.crit, dmgMul = r.dmgMul, force = r.force,
            shooter = deref(r.shooter, ulist, blist), lastHit = deref(r.last, ulist, blist), rings = r.rings or 0,
            high = r.high, flags = r.flags, h0 = r.h0, frame = r.frame, n = r.n, maxSteps = r.maxSteps, hitDone = r.hitDone,
            landed = r.landed, ix = r.ix, iy = r.iy, trail = M.TRAIL[r.code] or 0,
            gx0 = r.gx0, gy0 = r.gy0, gx1 = r.gx1, gy1 = r.gy1, gx = r.gx, gy = r.gy,
            x0 = r.x0, y0 = r.y0, x1 = r.x1, y1 = r.y1, t0 = t - r.age, nextT = t + r.due,
        }
        m.ft = frameTime(m.flags)
        m.instant = band(m.flags, F.INSTANT) ~= 0
        if not m.instant then buildSteps(m) end
        world.missiles[#world.missiles + 1] = m
    end
end

return M
