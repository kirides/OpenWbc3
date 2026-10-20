-- Weather: the original's display-overlay weather (day / night, rain, storms), its random changes and the combat
-- modifiers every unit gets from it. Everything below was checked in the 1.04 binary (the addresses are FUN_ names of
-- the Ghidra project, the program has no symbols):
--   weather state 0049e320, random weather timer 0049e360 (chances, tables), state setter 0049e690, night to day
--   004998e0, day to night 00499970, is night 00499a50, is day 00499a00, rain start 00499aa0, heavy rain 0049bf10
--   (medium 0049bf60, light 0049bfb0, heavy / medium / light storm 0049c000 / 0049c050 / 0049c0a0), transition
--   0049b070, lightning 0049b1d0, the weather spell effect (case 4 of FUN_004ac0e0), army combat value 0051bd10.
-- In the 1.04 binary High Elves and Dark Elves get +1 (not +2), the fine-weather bonus is +1, and fire spells have no
-- rain penalty at all, so none is implemented here.
--
-- State on the world (all saved by savegame.lua):
--   night       the day / night switch. A change (day to night / night to day) first runs a transition of
--               `3 * 18 / 4 * 4 / 18` s (about 2.9 s for the usual 3); the flag flips when it ends.
--   shift       { to = "night" | "day", t0, t1 } while a transition runs (weather spells are refused meanwhile)
--   raining     the rain flag; rainTarget the number of drops the rain grows to (the first rain setter only starts it
--               with 300 drops whatever the level, later calls set 80 / 150 / 512); lightning is the storm flag
--   rainDrops   the current drop count: 30 when a rain starts, one more per overlay frame up to the target
--   rainBase    the base rain level (the rain start's second argument: 80 / 150 / 512 by level, never above the
--               target): the drop count at which a rain that the rain finish has marked really ends
--   rainEnding  the rain-ending flag, set by the rain finish (FUN_0049bd90), cleared only by the rain start
--   rainFrame   the overlay frame (1000 / 18 ms) up to which the drops have been stepped
--   The rain finish does not stop the rain: the rain flag stays set until the drops have thinned out to the base level
--   (the combat modifiers, the weather buttons and the spells' rain tests see the rain meanwhile). A rain that is
--   marked while it still has fewer drops than the base level never ends (see stepRain).
--   weatherAt   the time of the last weather update
--   randomWeather  the advanced option of the same name (changes the chances and allows leaving "day, fine")
local bit = require("bit")

local M = {}

M.MIN_TIME = 100000                  -- at most one random weather change per 100 s (ms)
M.TICK = 1000 / 18                   -- the overlay runs per frame of an 18 per second display
M.RAIN = { [0] = 80, 150, 512 }      -- the rain levels low / medium / high
M.NEW_RAIN = 300                     -- the drop count the rain start aims every new rain at
M.PHASES = 4                         -- the phases of a day / night transition

-- Weather states: 0 day fine, 1-3 day light / medium / heavy rain, 4-6 day light / medium / heavy
-- storm, 7 night fine, 8-10 night rain, 11-13 night storm.
M.NAMES = { [0] = "Daytime & Fine", "Daytime & Raining", "Nighttime & Fine", "Nighttime & Raining" }   -- the dialog

-- The random weather timer's transition tables, read from the jump tables of FUN_0049e360 (index = current state).
-- A state that is not listed stays as it is (a missing entry is "no change"). The first state of WORSEN is chosen by a
-- roll.
local FINE = { [0] = 0, 0, 0, 1, 0, 0, 1, 0, 0, 1, 8, 1, 8, 8 }
local IMPROVE = { [0] = 0, 0, 1, 1, 0, 4, 4, 0, 0, 8, 8, 8, 11, 11 }
local WORSEN = { [0] = false, 2, 5, 6, 5, 6, 13, 8, 9, 10, 13, 12, 13, 6 }
local HELL = { [0] = 13, 6, 6, 13, 6, 6, 13, 10, 10, 13, 13, 13, 13, 6 }
M.TRANSITIONS = { fine = FINE, improve = IMPROVE, worsen = WORSEN, hell = HELL }   -- for the self test

local function rand(n) return math.random(1, n) end    -- dice FUN_00458e70(1, n, 0); seeded per tick in network games

-- Resets the weather of a new battle: `night` is the start option.
---@param world World
---@param opts {night: boolean?, randomWeather: boolean?}
function M.init(world, opts)
    world.night = opts.night == true
    world.raining, world.rainTarget, world.lightning = false, 0, false
    world.rainDrops, world.rainBase, world.rainEnding = 0, 0, false
    world.rainFrame = math.floor((world.time or 0) / M.TICK)
    world.shift = nil
    world.weatherAt = world.time or 0
    world.randomWeather = opts.randomWeather == true or (world.advanced and world.advanced.randomWeather) or false
end

-- The weather state (FUN_0049e320): only the day / night, the rain flag and the storm flag count, not the number of
-- drops, so the states the timer ever sees are 0, 1, 4, 7, 8 and 11.
---@param world World
---@return integer 0 .. 13
function M.state(world)
    local s = world.night and 7 or 0
    if world.raining then
        s = s + 1
        if world.lightning then s = s + 3 end
    end
    return s
end

---@param world World
---@return boolean
function M.transitioning(world) return world.shift ~= nil end

-- Transition lengths: the duration per phase is secs * 18 / 4 (at least 1) frames, four phases, 18 frames a second.
local function startShift(world, to, secs)
    local per = math.max(1, math.floor(secs * 18 / M.PHASES))
    local len = per * M.PHASES * M.TICK
    world.shift = { to = to, t0 = world.time, t1 = world.time + len, per = per }
    world.weatherAt = world.time
end

---@param world World
---@param secs number?
function M.nightToDay(world, secs) startShift(world, "day", secs or 3) end
---@param world World
---@param secs number?
function M.dayToNight(world, secs) startShift(world, "night", secs or 3) end

-- The night tint of the display, 0 (day) .. 1 (night): during a transition the four palette phases 0, 1/3, 2/3, 1.
---@param world World
---@return number 0 day .. 1 night
function M.nightLevel(world)
    local sh = world.shift
    if not sh then return world.night and 1 or 0 end
    local phase = math.min(M.PHASES - 1, math.floor((world.time - sh.t0) / M.TICK / sh.per))
    local k = phase / (M.PHASES - 1)
    return sh.to == "night" and k or 1 - k
end

-- Light rain .. heavy storm: level 0 / 1 / 2, `storm` adds the lightning.
-- (FUN_0049bf10 .. FUN_0049c0a0: a rain that is not falling runs the rain start FUN_00499aa0 with the level's drop
-- count as the base level, which sets 30 drops, the target 300, growth 1 and clears the ending flag; one that is
-- falling only gets the new target.)
---@param world World
---@param level integer 0 light, 1 medium, 2 heavy
---@param storm boolean?
function M.setRain(world, level, storm)
    if not world.raining then
        world.raining, world.rainTarget = true, M.NEW_RAIN
        world.rainDrops, world.rainBase, world.rainEnding = 30, M.RAIN[level], false
    else
        world.rainTarget = M.RAIN[level]
    end
    world.lightning = storm and true or false
    world.weatherAt = world.time
end

-- The rain finish (FUN_0049bd90) only sets the ending flag; the rain frame (FUN_0049b6d0, stepRain) thins the rain out
-- and ends it. The state setter and the spells call it when the rain test (FUN_0049bb10) is true; the rain start clears
-- the flag again.
---@param world World
function M.finishRain(world)
    if world.raining then world.rainEnding = true end
end

-- One rain frame (FUN_0049b6d0): the base level is capped at the target; unless the rain is ending, the drops grow by 1
-- towards the target; ending (or above the target) they shrink by 1 down to the base level; an ending rain whose drops
-- equal the base level stops (no longer raining, the loop sound closed). With fewer drops than the base level at the
-- time of the rain finish the drops neither grow nor shrink, so such a rain never ends (the binary does the same).
local function stepRain(world)
    local drops, target = world.rainDrops or 30, world.rainTarget or M.NEW_RAIN
    local base = math.min(world.rainBase or target, target)
    world.rainBase = base
    if not world.rainEnding and drops < target then
        drops = math.min(target, drops + 1)
    elseif (world.rainEnding or drops > target) and drops > base then
        drops = drops - 1
    end
    world.rainDrops = drops
    if world.rainEnding and drops == base then
        world.raining, world.lightning, world.rainDrops, world.rainTarget = false, false, 0, 0
    end
end

-- The overlay frames (18 a second of game time) that have passed since the last call.
local function stepRainFrames(world)
    local frame = math.floor(world.time / M.TICK)
    local n = frame - (world.rainFrame or frame)
    world.rainFrame = frame
    while n > 0 and world.raining do
        stepRain(world)
        n = n - 1
    end
end

-- The state setter (FUN_0049e690, the message the host sends): the day / night part first, then the rain.
---@param world World
---@param s integer 0 .. 13
function M.setState(world, s)
    if s < 0 or s > 13 then return end
    local night = s >= 7
    if night then
        if not world.night then M.dayToNight(world, 3) end
    elseif world.night then
        M.nightToDay(world, 3)
    end
    local k = night and s - 7 or s
    if k == 0 then
        if world.raining then M.finishRain(world) end
    else
        M.setRain(world, (k - 1) % 3, k >= 4)          -- 1-3 light / medium / heavy rain, 4-6 the storms
    end
end

-- The weather spell effect (case 4 of FUN_004ac0e0): 0 day / fine, 1 day / rain, 2 night / fine,
-- 3 night / rain, 4 day / storm, 5 night / storm. Refused while a day / night transition runs (the host's pre-check
-- of the spell message). Rain that is already falling is left alone for the rain kinds. Returns whether it ran.
---@param world World
---@param kind integer 0 .. 5
---@return boolean
function M.spell(world, kind)
    if world.shift then return false end
    local toNight = kind == 2 or kind == 3 or kind == 5
    if toNight then
        if not world.night then M.dayToNight(world, 3) end
    elseif world.night then
        M.nightToDay(world, 3)
    end
    if kind == 0 or kind == 2 then
        if world.raining then M.finishRain(world) end
    elseif kind == 1 or kind == 3 then
        if not world.raining then M.setRain(world, 0, false) end
    elseif kind == 4 or kind == 5 then
        if not world.raining then
            M.setRain(world, 1, false)          -- medium rain, then light storm: the first call starts the rain,
            M.setRain(world, 0, true)           -- the second only lowers the target to light and adds lightning
        end
    end
    return true
end

-- The spell kind Light / Darkness sends: it flips the night and keeps the rain (FUN_0057c8c0).
---@param world World
---@return integer
function M.lightDarkKind(world)
    if world.night then return world.raining and 1 or 0 end
    return world.raining and 3 or 2
end

-- The kind Storm sends (the Storm spell FUN_0057be40): rain at night 3 / 5, by day 1 / 4; `lvl` is the success level.
---@param world World
---@param lvl integer
---@return integer
function M.stormKind(world, lvl)
    if world.night then return lvl >= 2 and 5 or 3 end
    return lvl >= 2 and 4 or 1
end

-- The random weather timer (FUN_0049e360). Runs on every peer (the original's host broadcasts the new state; the
-- random numbers are seeded per tick in network games so every peer reaches the same one).
---@param world World
function M.update(world)
    local t = world.time
    local sh = world.shift
    if sh and t >= sh.t1 then                   -- transition FUN_0049b070: day / night flips when phase 4 is reached
        world.night = sh.to == "night"
        world.shift = nil
    end
    stepRainFrames(world)
    if (world.speed or 1) <= 0 then return end
    if t < world.weatherAt + M.MIN_TIME then return end
    world.weatherAt = t + M.MIN_TIME
    local state = M.state(world)
    local random = world.randomWeather
    if state == 0 and not random then return end

    local chance = { random and 12 or 15, random and 25 or 30, random and 20 or 18, random and 10 or 8 }
    local amount
    if rand(100) < chance[1] then amount = FINE
    elseif rand(100) < chance[2] then amount = IMPROVE
    elseif rand(100) < chance[3] then amount = WORSEN
    elseif rand(100) < chance[4] then amount = HELL end
    local roll = rand(100)
    if not amount then return end
    local new
    if amount == WORSEN and state == 0 then new = roll < 75 and 7 or 1
    else new = amount[state] or state end
    if new ~= state then M.setState(world, new) end
end

-- Combat -------------------------------------------------------------------------------------------------

local HUMAN, DWARF, UNDEAD, HIGHELF, WOODELF, DARKELF, BARBARIAN, ORC = 0x1, 0x2, 0x4, 0x8, 0x10, 0x20, 0x40, 0x100
local FEY, DAEMON, SSRATHI = 0x80000, 0x800000, 0x1000000
local SHADOW = "AUXX"                  -- the Shadow's unit code (0x58585541 in the binary)

-- The weather part of the army combat value (FUN_0051bd10, real value): day High Elves and Ssrathi +1; night Orcs and
-- Undead +2, Dark Elves +1, Humans and Horselords / Barbarians -1, the Shadow +5 (the hero's Shadow Strength is added
-- by hero.lua); rain Dwarves -1, Daemons and Undead +1; no rain Wood Elves and Fey +1. The caller keeps the result at 1
-- or more.
---@param world World
---@param code string
---@return integer
function M.combatMod(world, code)
    local f = require("src.game.powerups").flags(code)
    local band = bit.band
    local mod = 0
    if not world.night then
        if band(f, HIGHELF + SSRATHI) ~= 0 then mod = 1 end
    else
        if band(f, ORC + UNDEAD) ~= 0 then mod = 2
        elseif band(f, DARKELF) ~= 0 then mod = 1
        elseif band(f, HUMAN + BARBARIAN) ~= 0 then mod = -1 end
        if code == SHADOW then mod = mod + 5 end
    end
    if world.raining then
        if band(f, DWARF) ~= 0 then mod = mod - 1
        elseif band(f, DAEMON + UNDEAD) ~= 0 then mod = mod + 1 end
    elseif band(f, FEY + WOODELF) ~= 0 then
        mod = mod + 1
    end
    return mod
end

-- Saving -------------------------------------------------------------------------------------------------

---@param world World
---@return table
function M.save(world)
    local sh = world.shift
    return { night = world.night or false, raining = world.raining or false, target = world.rainTarget or 0,
             lightning = world.lightning or false, last = world.weatherAt - world.time,
             drops = world.rainDrops or 0, base = world.rainBase or 0, ending = world.rainEnding or false,
             random = world.randomWeather or false,
             shift = sh and { to = sh.to, done = world.time - sh.t0, per = sh.per } or nil }
end

---@param world World
---@param d table
function M.load(world, d)
    world.night, world.raining = d.night or false, d.raining or false
    world.rainTarget, world.lightning = d.target or 0, d.lightning or false
    -- a save without the drop record (older): a rain that had run its course
    world.rainDrops = d.drops or (world.raining and world.rainTarget or 0)
    world.rainBase, world.rainEnding = d.base or world.rainTarget, d.ending or false
    world.rainFrame = math.floor(world.time / M.TICK)
    world.weatherAt = world.time + (d.last or 0)
    world.randomWeather = d.random or false
    local sh = d.shift
    if sh then
        local t0 = world.time - sh.done
        world.shift = { to = sh.to, t0 = t0, t1 = t0 + sh.per * M.PHASES * M.TICK, per = sh.per }
    else
        world.shift = nil
    end
end

return M
