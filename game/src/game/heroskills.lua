-- Hero skill effects: the value of a skill at a level (the skill effect function of the 1.04 binary, FUN_00556ea0) and the
-- side-wide lookups the rules use (the side skill lookup FUN_00556b50 of the binary: 0 while the side's hero is dead).
-- Skill numbers are the ids the binary's skill functions take (1 .. 0x65); the per-level multipliers below are read from
-- the 1.04 binary, tuned values included (Constitution 10, Slayers 10, Lords 2, Engineer 20 ...).
-- Where each skill is used is documented in docs/hero.md.
local M = {}

local content = require("src.content")

-- The skills are the `skill` records of content/base/skills.lua: the effect at a level is mul * level + base (mul 1 when the record has
-- none); `ids` maps a skill's name to its number ("Ferocity" -> 1).
M.ids = content.skill:idView("slot")

-- The skill effect of a level (FUN_00556ea0).
---@param id integer the skill slot
---@param level number
---@return number
function M.effect(id, level)
    local r = content.skill:bySlot(id)
    return ((r and r.mul) or 1) * level + ((r and r.base) or 0)
end

-- The racial morale lord of a race (the hero morale function FUN_005269a0): Knight Lord 67 .. Serpent Lord 82; race
-- numbers as in gamedata.RACES (0 Knight .. 15 Plaguelords). Ssrathi, Swarm and Plaguelords are the last three of the list.
-- (the `lordSkill` of the race records)
M.lordOf = function(race) local r = content.race:bySlot(race) return r and r.lordSkill end

-- The side skill lookup (FUN_00556b50): the side's living hero's level of the skill (items count), else 0.
---@param world World
---@param side integer
---@param id integer
---@return integer
function M.level(world, side, id)
    local hero = world.eco:heroAlive(side)
    return hero and hero.h and hero.h:lvl(id) or 0
end

-- The effect of the side's level of a skill (FUN_00556ea0 of FUN_00556b50); 0 without the skill.
---@param world World
---@param side integer
---@param id integer
---@return number
function M.value(world, side, id)
    local n = M.level(world, side, id)
    return n > 0 and M.effect(id, n) or 0
end

-- The plague pile counter (DAT_0070d630): +1 for every plague pile (BPSP, the Plaguelords' building) that is placed or
-- built (remote building creation FUN_004a47b0 / add-building handler FUN_004a7200), -1 when one dies (FUN_0052b3e0), of
-- every side. Derived here from the live buildings (a site counts, as the original building exists from the placement),
-- cached for one game tick. None of the 115 shipped scenarios places one; only the Plaguelords build them.
---@param world World
---@return integer
function M.plaguePiles(world)
    local c = world.pileCache
    if c and c.t == world.time then return c.n end
    local n = 0
    for _, b in ipairs(world.buildings) do
        if b.code == "BPSP" and not b.destroyed and b.hp > 0 then n = n + 1 end
    end
    world.pileCache = { t = world.time, n = n }
    return n
end

-- Disease virulence (FUN_0040d9b0): the plague piles plus the Contamination effect of every living hero. It lengthens
-- a disease by 15 s a point (FUN_0051c060), raises the ceiling of the combat / speed loss to 10 + virulence (at most 100)
-- and shortens the step of that loss to 5 + 2 x (resistance - virulence) seconds (the once-a-second pass FUN_00532a20,
-- status.lua). Only the piles, not the skill, also add to the strength of a disease attack (the army's hit resolution
-- 0x0051abe0, unit.lua).
---@param world World
---@return number
function M.virulence(world)
    local c = world.virulenceCache
    if c and c.t == world.time then return c.v end
    local v = M.plaguePiles(world)
    for i = 0, 5 do
        if world.sides[i].used then v = v + M.value(world, i, M.ids.Contamination) end
    end
    world.virulenceCache = { t = world.time, v = v }
    return v
end

-- Help text of a skill at a level (the skill help of the binary, FUN_00556fc0): the Game.txt template the binary names for
-- each skill, filled with the effect. Spheres (10..22) list the spells instead and are not handled here.
-- (the Game.txt template of a skill is the `help` of its record)

---@param text string
---@param n number
---@return string
local function fill(text, n)
    text = text:gsub("%%%%", "")
    text = text:gsub("%%[%d.]*[df]", function(spec) return spec:find("f") and spec:format(n) or tostring(n) end, 1)
    return (text:gsub("", "%%"))
end

-- nil for the skills the binary has no template for (Trample) and the spheres
---@param id integer
---@param level integer
---@return string?
function M.help(id, level)
    local rec = content.skill:bySlot(id)
    local gs = rec and rec.help
    if not gs then return nil end
    local text = require("src.game.strings").get("Game.txt", ("%04d"):format(gs))
    if not text then return nil end
    local n = M.effect(id, level)
    if id == 9 then
        n = level == 0 and 0 or 100 - 100 * (100 / (n * 2 + 100))           -- the price change of that Merchant effect
    elseif id >= 55 and id <= 58 then
        n = n * 15                                                          -- income per minute: one every four seconds
    elseif id == 59 then
        n = n + 50                                                          -- the trade rate itself
    end
    return fill(text, n)
end

return M
