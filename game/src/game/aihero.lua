-- AI hero settings of a computer side: the race, class and level its hero is made with (three numbers of the original's
-- hero data; -1 = not chosen, here a missing field). The host picks them on the hero view panel (screens/aihero.lua,
-- PNL_VIEWHERO) and the computer hero maker (binary FUN_0042a0d0) reads them when the battle starts:
--   level   a chosen level above 0 is the hero's level (an unset one is made from the human heroes' levels, which
--           openwbc3 replaces by the local hero's level, see world.lua); the Battle of Titans and "I am the greatest"
--           rules still raise it afterwards
--   race    the race setter FUN_0054be60 with the chosen race; unset: the side's own race. The hero unit is that race's
--           hero unit
--   class   the class setter FUN_0054bea0 with the chosen class; unset: a random class (openwbc3: a fixed class of the
--           side and race, so that every peer of a network game builds the same hero)
-- The panel's own rules (its fill routine FUN_004ed7e0, its button handler at 0x004ee060): when the panel opens, an unset
-- race becomes the side's race (a random hero race when the side's race is random), an unset level the local hero's level
-- + 1d11 - 6 (at least 1), an unset class a random one of the 28; Okay keeps what the panel shows. The level arrows run
-- through 4..50 and wrap.
local content = require("src.content")

local M = {}

M.LEVEL_MIN, M.LEVEL_MAX = 4, 50
-- how many classes the setup panel offers (the `class` records)
function M.classCount() return content.class:count() end

-- What a side's hero is made with (each nil = not chosen).
---@class AIHeroSettings
---@field race integer?
---@field class integer?
---@field level integer?

-- A clean copy of a settings table (whole numbers in range, anything else dropped); nil when nothing is chosen.
---@param t any
---@return AIHeroSettings?
function M.clean(t)
    if type(t) ~= "table" then return nil end
    local function num(v, lo, hi)
        v = tonumber(v)
        if v and v >= lo and v <= hi then return math.floor(v) end
    end
    local out = { race = content.race:bySlot(tonumber(t.race) or -1) and num(t.race, 0, math.huge) or nil, class = num(t.class, 0, M.classCount() - 1), level = num(t.level, 1, 9999) }
    if out.race == nil and out.class == nil and out.level == nil then return nil end
    return out
end

-- The panel's defaults (FUN_004ed7e0) for what is still unset (sideRace: the side's race number, nil when random).
---@param h any
---@param sideRace integer?
---@param heroLevel integer?
---@return AIHeroSettings
function M.fill(h, sideRace, heroLevel)
    h = M.clean(h) or {}
    if h.race == nil then h.race = sideRace or content.race:playable()[math.random(1, #content.race:playable())].slot end
    if h.level == nil then h.level = math.max(1, (heroLevel or 1) + math.random(1, 11) - 6) end
    if h.class == nil then h.class = math.random(0, M.classCount() - 1) end
    return h
end

-- The level arrows: right adds one (below 4 it jumps to 4, past 50 it wraps to 4), left takes one (below 4 it jumps to 4,
-- but from 4 it wraps to 50).
---@param level integer
---@param dir integer
---@return integer
function M.stepLevel(level, dir)
    level = level + dir
    if dir > 0 then
        if level < M.LEVEL_MIN or level > M.LEVEL_MAX then level = M.LEVEL_MIN end
    elseif level == M.LEVEL_MIN - 1 then
        level = M.LEVEL_MAX
    elseif level < M.LEVEL_MIN then
        level = M.LEVEL_MIN
    end
    return level
end

return M
