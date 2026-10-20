-- The nine built-in attitudes (set up by FUN_00506c40 of the 1.04 binary: wimp FUN_00505cc0 ... standard FUN_00506180), with the
-- original's numbers;
-- src/game/attitude.lua explains the rule engine and the codes: conditions 0 threats, 1 guard threats, 2 alive, 3 attacking a building,
-- 4 attacking an army, 5 damaged, 6 under attack, 7 threats in range, 8 near; actions 0 return to base, 1 follow, 2 protect, 3 stand ground,
-- 4 run from attackers, 5 / 6 handle threats / guard threats, 7 random move, 8 scout, 9 move to the centre, 10 run from threats.
-- The install's CustomUnitAI/*.uai files are added after them by src/import/wbc3/attitudes.lua.
local THREATS, GUARD_THREATS, UNDER_ATTACK, THREATS_IN_RANGE, NEAR = 0, 1, 6, 7, 8
local RETURN_TO_BASE, FOLLOW, STAND_GROUND, RUN_FROM_ATTACKERS, HANDLE_THREATS = 0, 1, 3, 4, 5
local RANDOM_MOVE, MOVE_TO_CENTRE, RUN_FROM_THREATS = 7, 9, 10
local ME, HERO, DESIGNATED = 0, 1, 2
local SIZE = 20        -- the active area of every built-in attitude: 20 cells around the guard point

local function cond(code, unit, area, result, threshold)
    return { code = code, unit = unit or ME, area = area or false, result = result ~= false, extra = { threshold or 0, 0, 0 } }
end

local function act(code, unit, area)
    return { code = code, unit = unit or ME, area = area or false, extra = { 0, 0, 0 } }
end

local function rule(priority, conds, action, overrides)
    return { priority = priority, name = "", overrides = overrides or false, conds = conds, action = action }
end

-- The shared "fight what comes near" rule of standard / aggressive / rampant / defensive
local function fight(area) return rule(100, { cond(THREATS, ME, area) }, act(HANDLE_THREATS)) end

-- the guardians: 100 (overrides the player) follow when more than 20 cells from the designated unit, 90 fight what threatens it,
-- 80 fight what threatens me, 50 follow when more than 5 cells away
local function guardRules()
    return { rule(80, { cond(THREATS, ME) }, act(HANDLE_THREATS)),
             rule(100, { cond(NEAR, DESIGNATED, false, false, 20) }, act(FOLLOW, DESIGNATED), true),
             rule(90, { cond(THREATS, DESIGNATED) }, act(HANDLE_THREATS, DESIGNATED)),
             rule(50, { cond(NEAR, DESIGNATED, false, false, 5) }, act(FOLLOW, DESIGNATED)) }
end

---@param content Content
return function(content)
    -- GS_ATTITUDE_*_1 / _2 are Game.txt 0537 + 2n / 0538 + 2n
    local function add(order, id, text, icon, fields)
        local rec = { id = id, order = order, text = text, icon = icon, size = SIZE, designated = false, spells = false, rules = {} }
        for k, v in pairs(fields or {}) do rec[k] = v end
        content.attitude:add(rec)
    end
    -- cowardly (FUN_00505cc0): flee when hit (100), flee from enemies within 5 cells (90), else go back (80)
    add(1, "cowardly", "0537", 0, { rules = {
        rule(90, { cond(THREATS, ME) }, act(RUN_FROM_THREATS)),
        rule(80, { cond(GUARD_THREATS, ME, true, false) }, act(MOVE_TO_CENTRE)),
        rule(100, { cond(UNDER_ATTACK, ME) }, act(RUN_FROM_ATTACKERS)) } })
    add(2, "standGround", "0539", 1, { rules = { rule(100, { cond(THREATS_IN_RANGE, ME) }, act(STAND_GROUND)) } })
    add(3, "defensive", "0541", 2, { idle = act(MOVE_TO_CENTRE), rules = { fight(true) } })
    add(4, "standard", "0543", 7, { idle = act(MOVE_TO_CENTRE), rules = { fight(false) } })
    add(5, "aggressive", "0545", 3, { rules = { fight(false) } })
    add(6, "rampant", "0547", 4, { idle = act(RANDOM_MOVE), rules = { fight(false) } })
    add(7, "scout", "0549", 9, { idle = act(RANDOM_MOVE) })
    add(8, "guardian", "0551", 5, { designated = true, rules = guardRules() })
    add(9, "magicGuardian", "0553", 6, { designated = true, spells = true, rules = guardRules() })
end
