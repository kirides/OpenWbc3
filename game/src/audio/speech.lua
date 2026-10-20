-- The rules behind the announcer ("system speech") and the unit speech: which lines may play when. No audio
-- calls here (battle.lua / voices.lua play the files), so the rules can be tested headless.
--
-- Where the numbers come from:
--  * The announcer request (FUN_0050f1b0 in the 1.04 binary, decompiled): a message plays only when its timer has
--    passed 10; the nine messages in PRIORITY set the timer to 11 first, so they always get through; every message
--    that passes resets the timer to 0, also when the file is then refused. The timer counts display ticks, one per
--    call of the per-tick sound update FUN_0050ea10, i.e. per 25 ms frame tick (the start-up routine FUN_00457190
--    starts a 25 ms multimedia timer at 0x457fae); it starts at 40 (FUN_00546480).
--  * The "attack" announcements (0, 1, 3, 5, 28) are loaded with the check-time flag: a sound already in the cache
--    plays again only when its use counter is above 20 (FUN_00510f90). The counter of every cached sound goes up
--    once per 18 calls of the global timer routine at 0x00458d20 (the `cmp eax, 0x12` at 0x458d6d, then a jump to
--    0x511bd0). FUN_00457190 installs that routine at 0x457ac7 as the interface's timer callback, which the window
--    procedure FUN_00459c60 runs on every timer message (0x113) of the 50 ms window timer (push 0x32 at 0x45a837 in
--    FUN_0045a7b0), so 21 steps of 18 x 50 ms = 18.9 s must pass. The step phase is anchored at the start of the
--    battle here.
--  * "Too many men" (2) plays only when the side's army limit changed since it last played (FUN_0050f1b0 keeps the
--    last limit; the spell code FUN_005776c0 resets it first through FUN_0050f190).
--  * Unit speech (1.04 binary): select, order and deathblow lines share one counter that starts at 80 and goes up by
--    two per tick (the display update FUN_005468e0 and the sound update FUN_0050ea10 both add one); select and order
--    need it above 90 (46 ticks, 1.15 s; FUN_0050c2e0 / FUN_0050c530), a deathblow above 30 (16 ticks, 0.4 s;
--    FUN_0050cae0), and each line that plays resets it. The "Ready" line of a produced army has its own timer, above
--    15 ticks (0.4 s; FUN_0050c790).
--    With "Sometimes" the select / order request only gets through with 2 chances in 5. Which variant of
--    Select<n> / Order<n> plays depends on the unit's number of speech files, a dice roll and the variant played
--    last (pickVariant).
local M = {}

M.TICK = 0.025          -- seconds of one display tick
M.STEP = 18 * 0.05      -- seconds between two steps of the sound cache's use counters (18 x the 50 ms window timer)

-- The system speech numbers: the n in System[F]<n>.wav
M.SYSTEM = {
    baseUnderAttack = 0, troopsUnderAttack = 1, tooManyMen = 2, heroUnderAttack = 3, heroFallen = 4, heroNearDeath = 5,
    enemyHeroDestroyed = 6, upgradeComplete = 7, researchComplete = 8, learnedNewSpell = 9, allyVanquished = 10,
    enemyVanquished = 11, victory = 12, defeat = 13, heroicEffort = 14, questReceived = 15, questCompleted = 16,
    needGold = 17, needStone = 18, needMetal = 19, needCrystal = 20, questExpired = 21, newArmies = 22,
    newBuildings = 23, newArmiesBuildings = 24, alliedHeroDestroyed = 25, enemyTitan = 26, alliedTitan = 27,
    buildingsUnderAttack = 28,
}
local S = M.SYSTEM

local PRIORITY = {
    [S.victory] = true, [S.defeat] = true, [S.heroNearDeath] = true, [S.heroUnderAttack] = true,
    [S.heroFallen] = true, [S.enemyHeroDestroyed] = true, [S.alliedHeroDestroyed] = true, [S.allyVanquished] = true,
    [S.enemyVanquished] = true,
}
local CHECKED = {
    [S.troopsUnderAttack] = true, [S.baseUnderAttack] = true, [S.heroNearDeath] = true, [S.heroUnderAttack] = true,
    [S.buildingsUnderAttack] = true,
}
M.PRIORITY, M.CHECKED = PRIORITY, CHECKED

-- The resource a "need more ..." line belongs to.
M.NEED = { gold = S.needGold, stone = S.needStone, metal = S.needMetal, crystal = S.needCrystal }

-- Announcer ----------------------------------------------------------------------------------------------------

---@class Announcer
---@field t0 number              real time of the start of the battle
---@field resetTick integer?     tick of the last message that passed
---@field last table<integer, number>   message -> time it last played (the checked ones)
---@field previousLimit integer? army limit at the last "too many men"
local Announcer = {}
Announcer.__index = Announcer

-- `now` is the real time (seconds) of the start of the battle.
---@param now number?
---@return Announcer
function M.announcer(now)
    return setmetatable({ t0 = now or 0, resetTick = nil, last = {}, previousLimit = 0 }, Announcer)
end

local function tickOf(self, now) return math.floor((now - self.t0) / M.TICK + 1e-9) end

-- The announcer request (FUN_0050f1b0): returns the number of the file to play, or nil when the message is held back.
-- `armyLimit` is the side's army limit maximum (only used by "too many men").
---@param id integer M.SYSTEM number
---@param now number
---@param armyLimit integer?
---@return integer?
function Announcer:request(id, now, armyLimit)
    local tick = tickOf(self, now)
    if PRIORITY[id] then self.resetTick = tick - 11 end
    local timer = self.resetTick and (tick - self.resetTick) or 40
    if timer <= 10 then return nil end
    self.resetTick = tick
    if id == S.tooManyMen then
        if self.previousLimit == armyLimit then return nil end
        self.previousLimit = armyLimit
    end
    if CHECKED[id] then
        local last = self.last[id]
        if last and math.floor((now - self.t0) / M.STEP) - math.floor((last - self.t0) / M.STEP) < 21 then return nil end
    end
    self.last[id] = now
    return id
end

-- FUN_0050f190 with message 2 ("too many men"): the next "too many men" plays whatever the limit is.
function Announcer:forceTooManyMen() self.previousLimit = -1 end

-- Unit speech ----------------------------------------------------------------------------------------------------

---@class Speaker
---@field t0 number
---@field selReset integer?   tick the shared select / order / deathblow counter was reset
---@field prodReset integer?  tick of the last "Ready" line
local Speaker = {}
Speaker.__index = Speaker

---@param now number?
---@return Speaker
function M.speaker(now)
    return setmetatable({ t0 = now or 0, selReset = nil, prodReset = nil }, Speaker)
end

-- "Sometimes" (option 1) lets a select / order request through with probability 2 / 5: `roll` is 1..5 (the speech
-- request FUN_0050be80 accepts a roll below 3). Level 0 is "never".
---@param level integer
---@param kind string
---@param roll integer
---@return boolean
function M.allowed(level, kind, roll)
    if level <= 0 then return false end
    if level == 1 and (kind == "Select" or kind == "Order") then return roll < 3 end
    return true
end

-- The shared select / order / deathblow counter (two per tick; 80 at the start of the game).
---@param now number
---@return integer
function Speaker:counter(now)
    if not self.selReset then return 80 + 2 * math.floor((now - self.t0) / M.TICK + 1e-9) end
    return 2 * (math.floor((now - self.t0) / M.TICK + 1e-9) - self.selReset)
end

-- Checks and consumes the shared counter for a select / order (limit 90) or deathblow (limit 30) line.
---@param kind string
---@param now number
---@return boolean
function Speaker:take(kind, now)
    local limit = kind == "Deathblow" and 30 or 90
    if self:counter(now) <= limit then return false end
    self.selReset = math.floor((now - self.t0) / M.TICK + 1e-9)
    return true
end

-- The production timer (starts at 40, line when above 15).
---@param now number
---@return boolean
function Speaker:takeReady(now)
    local tick = math.floor((now - self.t0) / M.TICK + 1e-9)
    local timer = self.prodReset and (tick - self.prodReset) or 40
    if timer <= 15 then return false end
    self.prodReset = tick
    return true
end

-- Which Select<n> / Order<n> plays: `files` is the unit type's number of speech files (a hero or a special character
-- has four), `roll` is 1..100, `last` the number played last for this unit (0 / nil: none). Returns the number
-- and the new `last`. The thresholds differ between select and order (FUN_0050c2e0 /
-- FUN_0050c530).
local THRESHOLDS = {
    Select = { [2] = { 55 }, [3] = { 70, 40 }, [4] = { 72, 60, 40 } },
    Order = { [2] = { 55 }, [3] = { 90, 50 }, [4] = { 92, 80, 45 } },
}

---@param kind "Select"|"Order"
---@param files integer
---@param roll integer
---@param last integer?
---@return integer n
---@return integer last
function M.pickVariant(kind, files, roll, last)
    last = last or 0
    local th = THRESHOLDS[kind]
    local n
    if files <= 1 then
        n = 1
    elseif files == 2 then
        if (roll > th[2][1] and last ~= 2) or last == 1 then n = 2 else n = 1 end
    elseif files == 3 then
        local t = th[3]
        if roll > t[1] and last ~= 3 then n = 3
        elseif (roll > t[2] and last ~= 2) or last == 1 then n = 2
        else n = 1 end
    else
        local t = th[4]
        if roll > t[1] and last ~= 4 then n = 4
        elseif roll > t[2] and last ~= 3 then n = 3
        elseif (roll > t[3] and last ~= 2) or last == 1 then n = 2
        else n = 1 end
    end
    -- a single-file unit does not touch the memory in the original
    if files <= 1 then return n, last end
    return n, n
end

-- Voice priority (FUN_00528cd0): the unit that speaks for a group is the selected one with the highest (FUN_00531730).
-- A hero is 10000, others combat x 4 + speed x 2 + hits, a general 500 more.
---@param u Unit
---@param general boolean?
---@return number
function M.voicePriority(u, general)
    if u.hero then return 10000 end
    local t = u.type or {}
    local p = (t.combat or 0) * 4 + (t.speed or 0) * 2 + math.floor(u.maxHp or t.hits or 0)
    if general then p = p + 500 end
    return p
end

-- A small generator of its own so the speech never touches math.random (network games reseed that every tick).
local state = 0x2545F491
---@param n integer
---@return integer 1..n
function M.dice(n)
    state = (state * 69069 + 1) % 4294967296
    return 1 + math.floor(state / 65536) % n
end

function M.seed(v) state = (tonumber(v) or 1) % 4294967296 end

return M
