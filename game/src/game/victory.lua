-- Victory conditions of a battle: the engine side. The conditions themselves (names, timers, what keeps a side alive, set-up,
-- running totals, winners) are `victory` records, content/base/victory.lua, where the rules and their sources are described.

local content = require("src.content")

local M = {}

local function rec(rule) return content.victory._recs[rule] end

-- The rule names by number (the records' ids by slot), read only.
M.NAMES = content.victory:view("id")

-- Which rules show running totals at the right edge, read only.
M.RUNNING = content.victory:idView("running")

local DRAW_EXTENSION = 300

-- Rule name for a number, a name or a campaign name; nil when it is none.
---@param v any a number, a rule name or a campaign alias
---@return string?
function M.rule(v)
    if type(v) == "number" then return M.NAMES[v] end
    if type(v) == "string" then
        if rec(v) then return v end
        for _, r in ipairs(content.victory:all()) do
            for _, a in ipairs(r.alias or {}) do
                if a == v then return r.id end
            end
        end
    end
    return nil
end

---@param rule string|integer|nil
---@return integer
function M.number(rule) local r = rec(rule) return r and r.slot or 0 end

-- Whether the countdown / game length of a timed mode has run out.
---@param world World
---@return boolean
function M.timerDone(world)
    return not world.victoryEnd or world.time >= world.victoryEnd
end

-- A property of a rule (field of its record), e.g. `Victory.get(world.victoryRule, "pitched")`; nil for no rule.
---@param rule string|integer|nil
---@param field string
---@return any
function M.get(rule, field)
    local r = rec(rule or "standard")
    return r and r[field]
end

---@param rule string|integer|nil
---@return boolean
function M.timed(rule) local r = rec(rule) return r ~= nil and r.timer ~= nil end

-- Start of the battle: clock, titans, flags.
---@param world World
function M.setup(world)
    local r = rec(world.victoryRule)
    if not r then return end
    if r.timer then
        local ms = r.timer * 1000
        world.victoryEnd = world.time + ms
        world.clock = { total = ms, t0 = world.time }
    end
    local startSides = {}
    for i = 0, 5 do
        local s = world.sides[i]
        if s.used and s.startX >= 0 then startSides[#startSides + 1] = i end
    end
    if r.setup then r.setup(world, startSides) end
end

-- Running totals shown at the right edge: per side a number or nil (not shown). Counted as in the original's
-- running totals update (FUN_00429c20).
---@param world World
---@return table<integer, integer>?
function M.totals(world)
    local r = rec(world.victoryRule)
    if not (r and r.running and r.total) then return nil end
    local out = {}
    for i = 0, 5 do
        local s = world.sides[i]
        if s.used and not s.defeated then out[i] = math.max(0, math.floor(r.total(world, i))) end
    end
    return out
end

local function undefeated(world)
    local out = {}
    for i = 0, 5 do
        local s = world.sides[i]
        if s.used and not s.defeated then out[#out + 1] = i end
    end
    return out
end

-- The sides that win right now under the mode's own rule (the winner and its allies), or nil. Every other side is
-- defeated by the caller.
---@param world World
---@param rule string|integer|nil
---@return integer[]?
function M.winners(world, rule)
    local r = rec(rule or world.victoryRule)
    if not (r and r.winners) then return nil end
    local alive = undefeated(world)
    return r.winners(world, {
        alive = alive,
        withAllies = function(w)
            local out = {}
            for _, i in ipairs(alive) do
                if i == w or not world:enemies(w, i) then out[#out + 1] = i end
            end
            return out
        end,
        timerDone = function() return M.timerDone(world) end,
        extend = function(seconds)         -- a draw: the game goes on
            world.victoryEnd = world.time + seconds * 1000
            world.clock = { total = seconds * 1000, t0 = world.time }
        end,
    })
end

-- Whether side i is still in the game under `rule`: what keeps a side alive is the record's `defeat` ({ units, buildings }) or its
-- own `alive` function.
---@param world World
---@param i integer
---@param rule string|integer|nil
---@return boolean
function M.sideAlive(world, i, rule)
    local r = rec(rule) or rec("standard")
    local s = world.sides[i]
    if r.alive then return r.alive(world, i) == true end
    local d = r.defeat or {}
    if d.buildings then
        local rules = require("src.game.rules")
        local eco = require("src.game.economy")
        for _, b in ipairs(world.buildings) do
            if b.side == i and b.hp > 0 then
                if d.buildings == "notMines" then
                    if not eco.isMine(b.code) then return true end
                else
                    local info = rules.building(b.code)
                    if info and info.stopDefeat[s.race] then return true end
                end
            end
        end
    end
    if d.units then
        for _, u in ipairs(world.units) do
            -- units hidden inside a garrison or construction site are still alive; mine workers are removed
            if u.side == i and u.state ~= "dead" and not u.remove and (d.units ~= "heroes" or u.hero) then return true end
        end
    end
    return false
end

return M
