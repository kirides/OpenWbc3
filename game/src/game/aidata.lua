-- Computer player: static per-race data (what the computer player's set-up reads from Building.cfg: the building,
-- army and power-up tables, the dependencies and the building categories; FUN_004fcfa0, FUN_004fd060, FUN_004fd140,
-- FUN_004fd1b0, FUN_004ff900, called in that order from the constructor FUN_004f7830).
--
-- The original (those routines of the 1.04 binary, decompiled; see ai.lua) keeps one list of "dependencies" per race:
-- the [DEPENDENCIES] lines (armies, power-ups) followed by the [PRODUCTION] lines (buildings). From it the AI takes
--  * buildings: the [PRODUCTION] entries that start with B, walls skipped (BW?? except the towers BWT?), in file order,
--    so that the levels of a multi-level building (BAV0, BAV1, BAV2, keeps BKK0 .. BKK4) are neighbours;
--  * armies: [DEPENDENCIES] entries that start with A and whose second letter is not C;
--  * power-ups: entries that start with P or R;
--  * "builder of X": the first [PRODUCTION] line of the race (file order, slots 0..8) that lists X
--    (FUN_00587a30); the Undead skeleton is the one exception (builder lookup FUN_004f7f20: the graveyard).
-- From these it derives which buildings / power-ups an army (or power-up) needs, directly or through requirements
-- (FUN_004fd2f0 for an army, FUN_004fd560 for a power-up), and the army build order (FUN_004ff5f0: the builder
-- first, then the armies that need the fewest buildings, a keep level counting 10 and a normal building 1, a power-up 1;
-- an army that needs a building no builder can construct is left out).
local vfs = require("src.vfs.vfs")
local rules = require("src.game.rules")

local M = {}

---@type table<string, AIRaceData>
local cache = {}

local function sections(text)
    local out, cur = {}, nil
    for line in (text .. "\n"):gmatch("(.-)\r?\n") do
        local name = line:match("^%[(.-)%]")
        if name then
            cur = {}
            out[name:upper()] = cur
        elseif cur and line ~= "" and not line:match("^%s*//") then
            cur[#cur + 1] = line
        end
    end
    return out
end

local function codes(s)
    local out = {}
    for c in (s or ""):gmatch("(%u%w%w%w)") do out[#out + 1] = c end
    return out
end

-- Digit of a multi-level building / power-up code ('0'..'9' as last character), or nil.
---@param code string
---@return integer?
function M.level(code)
    return tonumber(code:sub(4, 4))
end

---@param code string
---@return boolean
function M.isKeep(code) return code:sub(1, 1) == "B" and code:sub(2, 2) == "K" end
---@param code string
---@return boolean
function M.isTower(code) return code:sub(1, 3) == "BWT" or (code:sub(1, 2) == "BW" and code:sub(3, 3) == "T") end

-- Static data of a race (cached).
---@param race integer
---@return AIRaceData
function M.forRace(race)
    local letter = rules.RACE_LETTER[race] or "H"
    if cache[letter] then return cache[letter] end
    -- The static data of one race (shared by every computer side of that race).
    ---@class AIRaceData
    ---@field letter string                 the race letter of Building.cfg
    ---@field buildings {code: string, index: integer}[]   in [PRODUCTION] order (levels of a building are neighbours)
    ---@field buildingIndex table<string, integer>
    ---@field armies {code: string, index: integer}[]
    ---@field aIndex table<string, integer>
    ---@field powerups {code: string, index: integer, pri: integer?}[]
    ---@field pIndex table<string, integer>
    ---@field builderOf table<string, string> army / power-up / building code -> the building that makes it
    ---@field req table<string, string[]>     the requirements of a code
    ---@field production table<string, string[]> building -> what it lists
    ---@field slotLevel table<string, table<string, string>> building -> item -> the slot's level character
    ---@field morphFrom table<string, string[]> an Undead morph -> its source units
    ---@field needB table<string, table<string, boolean>> army / power-up -> the buildings it needs
    ---@field needP table<string, table<string, boolean>> army / power-up -> the power-ups it needs
    local D = { letter = letter, buildings = {}, buildingIndex = {}, armies = {}, aIndex = {}, powerups = {},
                pIndex = {}, builderOf = {}, req = {}, production = {}, slotLevel = {} }
    cache[letter] = D
    local text = vfs.read("System.xcr", "Building.cfg")
    if not text then return D end
    local sec = sections(text)
    for _, line in ipairs(sec.PRODUCTION or {}) do
        local code, l, rest = line:match("^(%u%u%w%w)%s+(%u)%s+(.*)$")
        if code and l == letter then
            local left, right = rest:match("^(.-)|(.*)$")
            left = left or rest
            local items = {}
            for lvl, item in left:gmatch("(%S):(%S%S%S%S)") do
                if item ~= "----" then
                    items[#items + 1] = item
                    D.slotLevel[code] = D.slotLevel[code] or {}
                    D.slotLevel[code][item] = lvl
                    if not D.builderOf[item] then D.builderOf[item] = code end
                end
            end
            D.production[code] = items
            local req = {}
            for _, r in ipairs(codes(right)) do req[#req + 1] = r end
            D.req[code] = req
            if code:sub(1, 1) == "B" and not (code:sub(2, 2) == "W" and code:sub(3, 3) ~= "T") then
                D.buildings[#D.buildings + 1] = { code = code, index = #D.buildings + 1 }
                D.buildingIndex[code] = #D.buildings
            end
        end
    end
    for _, line in ipairs(sec.DEPENDENCIES or {}) do
        local l, code, rest = line:match("^(%u)%s+(%u%w%w%w)%s*:%s*(.*)$")
        if code and l == letter then
            local req = codes(rest:gsub("%s+%d+%s*$", ""))
            D.req[code] = D.req[code] or req
            local k = code:sub(1, 1)
            if k == "A" and code:sub(2, 2) ~= "C" then
                D.armies[#D.armies + 1] = { code = code, index = #D.armies + 1 }
                D.aIndex[code] = #D.armies
            elseif k == "P" or k == "R" then
                D.powerups[#D.powerups + 1] = { code = code, index = #D.powerups + 1,
                                                pri = tonumber(rest:match("(%d+)%s*$")) }
                D.pIndex[code] = #D.powerups
            end
        end
    end
    -- the builder lookup FUN_004f7f20: the skeleton is made in the graveyard (the gravestone lists it as well)
    if letter == "U" then D.builderOf["AUIX"] = "BAGY" end
    -- the dependency set-up FUN_004fd1b0: an Undead morph (wight, wraith, shadow, slayer knight, liche, doom knight)
    -- has no building of its own; it depends on what its source units depend on
    D.morphFrom = letter == "U" and {
        AUJX = { "AUIX" }, AUKX = { "AUIX" }, AUXX = { "AUKX", "AUIX" }, AULX = { "AUJX", "AUIX" },
        AUMX = { "AUJX", "AUIX" }, AUAX = { "AULX", "AUJX", "AUIX" } } or {}
    -- what every army / power-up needs
    D.needB, D.needP = {}, {}
    local function collect(code, bset, pset, seen)
        if seen[code] then return end
        seen[code] = true
        local k = code:sub(1, 1)
        if k == "B" then
            local d = M.level(code)
            if d then
                for lv = d, 0, -1 do
                    local c = code:sub(1, 3) .. lv
                    bset[c] = true
                    seen[c] = true
                    for _, r in ipairs(D.req[c] or {}) do collect(r, bset, pset, seen) end
                end
            else
                bset[code] = true
                for _, r in ipairs(D.req[code] or {}) do collect(r, bset, pset, seen) end
            end
        elseif k == "P" or k == "R" then
            pset[code] = true
            for _, r in ipairs(D.req[code] or {}) do collect(r, bset, pset, seen) end
            local b = D.builderOf[code]
            if b then collect(b, bset, pset, seen) end
        elseif k == "A" then
            local b = D.builderOf[code]
            if b then collect(b, bset, pset, seen) end
            for _, r in ipairs(D.req[code] or {}) do collect(r, bset, pset, seen) end
            for _, m in ipairs(D.morphFrom[code] or {}) do collect(m, bset, pset, seen) end
            if code == "AUIX" then collect("BAGR", bset, pset, seen) end      -- the gravestone, too
        end
    end
    for _, a in ipairs(D.armies) do
        local bs, ps = {}, {}
        collect(a.code, bs, ps, {})
        D.needB[a.code], D.needP[a.code] = bs, ps
    end
    for _, p in ipairs(D.powerups) do
        local bs, ps = {}, {}
        collect(p.code, bs, ps, {})
        ps[p.code] = nil
        D.needB[p.code], D.needP[p.code] = bs, ps
    end
    return D
end

-- Armies that no building produces and that are not an Undead morph can never be built by a computer player.
---@param D AIRaceData
---@param code string
---@return boolean
function M.producible(D, code)
    return D.builderOf[code] ~= nil
end

-- Army build order (FUN_004ff5f0): `buildable[code]` says whether a builder may construct the building (the entries
-- of the race's construction lists that the tech level allows, and every upgrade level).
---@param D AIRaceData
---@param builderCode string?
---@param buildable table<string, boolean>
---@return string[]
function M.armyOrder(D, builderCode, buildable)
    local deps, ok = {}, {}
    for i, a in ipairs(D.armies) do
        if a.code == builderCode then
            deps[i], ok[i] = 1, true
        else
            local n, valid = 0, true
            for bcode in pairs(D.needB[a.code]) do
                if buildable[bcode] then
                    n = n + (M.isKeep(bcode) and 10 or 1)
                else
                    valid = false
                end
            end
            if valid then
                for _ in pairs(D.needP[a.code]) do n = n + 1 end
            end
            deps[i], ok[i] = n, valid
        end
    end
    -- pairs() has no defined order but only the sums matter here
    local order, used = {}, {}
    local first = D.aIndex[builderCode]
    if first then
        order[1] = builderCode
        used[first] = true
    end
    while true do
        local best
        for i, a in ipairs(D.armies) do
            if ok[i] and not used[i] and (not best or deps[i] < deps[best]) then best = i end
        end
        if not best then break end
        used[best] = true
        order[#order + 1] = D.armies[best].code
    end
    return order
end

-- Power-up build order (FUN_004ff790): fewest prerequisites first (a keep level counts 10).
---@param D AIRaceData
---@return string[]
function M.powerupOrder(D)
    local deps = {}
    for i, p in ipairs(D.powerups) do
        local n = 0
        for bcode in pairs(D.needB[p.code]) do n = n + (M.isKeep(bcode) and 10 or 1) end
        for _ in pairs(D.needP[p.code]) do n = n + 1 end
        deps[i] = n
    end
    local order, used = {}, {}
    while true do
        local best
        for i in ipairs(D.powerups) do
            if not used[i] and (not best or deps[i] < deps[best]) then best = i end
        end
        if not best then break end
        used[best] = true
        order[#order + 1] = D.powerups[best].code
    end
    return order
end

return M
