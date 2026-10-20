-- The hero's command radius bonus: troops standing close to their side's (or an ally's) hero fight better.
-- Verified against the original (the once-a-second aura pass FUN_00532a20 and its aura list FUN_005332e0, the army's
-- combat FUN_0051bd10 and speed FUN_0051c460, the army drawing at 0x00538660):
--   * once a second every living army is checked against the living heroes of its own and allied sides; the hero's
--     radius is its command radius, at most 19, and an army is inside when
--     floor(sqrt(dx^2 + dy^2)) < radius (max(dx, dy) < 20)
--   * heroes and armies under fear, terror, awe or chaos never get the bonus; fear etc. cancel it at once
--   * inside the radius: +4 combat and +2 speed, half of that for undead; the status icon (ECM0 cell 0) is shown
--     for the local player's armies
--   * leaving the radius keeps the bonus for max(1, morale of the side's hero) more seconds
-- State on the unit: `cmdIn` (the bonus is on) and `cmdTimer` (seconds left of the lingering bonus, 0 while inside).
local M = {}

local MAX_COMMAND = 19
local UNDEAD = 0x4

---@param u Unit
---@return boolean
function M.isUndead(u)
    return require("bit").band(require("src.game.powerups").flags(u.code), UNDEAD) ~= 0
end

-- The stat bonus the unit gets now (combat, speed).
---@param u Unit
---@return integer combat
---@return integer speed
function M.bonus(u)
    if not u.cmdIn or u.hero then return 0, 0 end
    if M.isUndead(u) then return 2, 1 end
    return 4, 2
end

---@param h Unit a hero unit
---@return number
local function radiusOf(h)
    return math.min(MAX_COMMAND, h.h and h.h.mod.commandRadius or 0)
end

---@param world World
function M.update(world)
    local heroes = {}      -- side -> list of { gx, gy, r }
    local sides = world.sides
    for i = 0, 5 do
        local sd = sides[i]
        if sd and sd.used then
            local h = world.eco:heroAlive(i)
            if h and h:alive() and h.h then
                heroes[i] = { gx = h.gx, gy = h.gy, r = radiusOf(h), unit = h }
            end
        end
    end
    for _, u in ipairs(world.units) do
        if u.state ~= "dead" and u.side ~= 6 then
            if u.hero or u.hidden then
                u.cmdIn, u.cmdTimer = nil, nil
            else
                M.updateUnit(world, u, heroes)
            end
        end
    end
end

---@param world World
---@param u Unit
---@param heroes table<integer, {gx: integer, gy: integer, r: number, unit: Unit}> side -> its hero
function M.updateUnit(world, u, heroes)
    local timer = u.cmdTimer or 0
    if timer > 0 then
        timer = timer - 1
        if timer == 0 then u.cmdIn = nil end
    end
    local fx = u.fx
    local blocked = fx and (fx.fear or fx.awe or fx.terror or fx.chaos)
    local found = false
    if not blocked then
        for side, hero in pairs(heroes) do
            if side == u.side or not world:enemies(u.side, side) then
                local dx, dy = math.abs(u.gx - hero.gx), math.abs(u.gy - hero.gy)
                if math.max(dx, dy) < 20 and math.floor(math.sqrt(dx * dx + dy * dy)) < hero.r then
                    found = true
                    break
                end
            end
        end
    end
    if blocked and u.cmdIn then u.cmdIn, timer = nil, 0 end
    local previously = u.cmdIn and timer == 0
    if found then
        u.cmdIn = true
        if not previously then timer = 0 end
    elseif previously then
        local own = heroes[u.side]
        timer = math.max(1, own and own.unit.h:getMorale() or 0)
    end
    u.cmdTimer = timer > 0 and timer or nil
end

return M
