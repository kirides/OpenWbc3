-- Experience a hero earns when a battle ends (the original's experience award, checked against
-- the 1.04 binary: FUN_004553f0, the army-kill table at 0x60C2B0, the 300000 ms test of FUN_0041c520). Every used side
-- gets an amount (computer heroes too: it shows in the results statistics); the local player's is added to the hero and
-- printed on the victory / defeat screen ("You have gained a N XP bonus").
--
-- The rules work on a plain summary (`M.summary`), so the numbers can be tested without a battle:
--   time (ms of game time), size (map width in cells), tech, pitched, campaign, fogMode (1 fog of war, 2 explored map,
--   3 no fog, 4 hidden map), greatest ("I am the greatest" advanced option), me, and per side 0..5: used, human, aiLevel
--   (1 Knave .. 6 Emperor), resources (0..4), allies (set of side numbers), defeated, won, quests, heroKills (armies the
--   hero killed), kills (armies the side killed), heroesSlain, heroDied.
-- All divisions are integer divisions in the original's order. A side counts as having won when it is the local player
-- and won, or when it is another side and the local player lost (the original's per-side victory flags).
local M = {}

-- army kills of the side -> XP (x 5), indexed by min(20, kills / 50)
M.KILL_TABLE = { [0] = 0, 5, 8, 10, 15, 20, 20, 25, 25, 30, 30, 30, 30, 30, 40, 40, 40, 40, 40, 50, 50 }

local SHORT_GAME_MS = 300000       -- FUN_0041c520: a game shorter than five minutes earns next to nothing
local MAX_HERO_LEVEL = 999

local function idiv(a, b) return math.floor(a / b) end

-- What the experience of a battle is worked out from (M.summary).
---@class BattleSummary
---@field time number               the game's length (ms)
---@field size integer              the map width
---@field tech integer
---@field pitched boolean
---@field campaign boolean
---@field fogMode integer
---@field greatest boolean
---@field me integer
---@field sides table<integer, BattleSummarySide>

---@class BattleSummarySide
---@field used boolean
---@field human boolean
---@field aiLevel integer
---@field resources integer
---@field allies table<integer, boolean>
---@field defeated boolean
---@field won boolean
---@field quests integer
---@field heroKills integer
---@field kills integer
---@field heroesSlain integer
---@field heroDied boolean

-- XP of one side before the local player's special rules (Ironman, maximum level).
---@param sum BattleSummary
---@param i integer
---@return integer
function M.side(sum, i)
    local s = sum.sides[i]
    local won = s.won
    if sum.time < SHORT_GAME_MS then
        if won then
            return (sum.pitched or sum.tech <= 0 or sum.campaign) and 5 or 1
        end
        return (sum.pitched or sum.tech <= 0) and 3 or 0
    end
    -- the weight of the allies: Prince 2, Warlord 3, Emperor 4, a human or other computer level 2 / 1
    local alliances = 1
    for j = 0, 5 do
        local o = sum.sides[j]
        if o and o.used and s.allies[j] and i ~= j then
            if not o.human then
                if o.aiLevel == 4 then alliances = alliances + 2
                elseif o.aiLevel == 5 then alliances = alliances + 3
                elseif o.aiLevel == 6 then alliances = alliances + 4
                else alliances = alliances + 1 end
            else
                alliances = alliances + 2
            end
        end
    end
    local xp = 0
    if sum.size == 128 then xp = 5 elseif sum.size == 192 then xp = 10 elseif sum.size == 256 then xp = 15 end
    if won then xp = xp + (alliances > 1 and 40 or 80) else xp = xp + 4 end
    xp = xp + (s.quests < 6 and s.quests * 10 or 50)
    xp = xp + (s.heroKills < 250 and idiv(s.heroKills, 10) * 2 or 100)
    xp = xp + M.KILL_TABLE[math.min(20, idiv(s.kills, 50))] * 5
    -- the computer opponents' levels, shifted by how their resources compare to the best human's
    local humanRes = 0
    for j = 0, 5 do
        local o = sum.sides[j]
        if o and o.used and o.human and o.resources > humanRes then humanRes = o.resources end
    end
    local RES_MOD = { [-4] = -5, [-3] = -3, [-2] = -2, [-1] = -1, [0] = 0, 0, 0, 1, 1 }
    local enemyTotal = 0
    for j = 0, 5 do
        local o = sum.sides[j]
        if o and o.used then
            local enemy = won and not s.allies[j] and i ~= j
            if o.defeated or enemy then xp = xp + 10 end
            if enemy then
                if not o.human then
                    local level = o.aiLevel + (RES_MOD[o.resources - humanRes] or 0)
                    if level == 3 then enemyTotal = enemyTotal + 10
                    elseif level == 4 then enemyTotal = enemyTotal + 20
                    elseif level == 5 then enemyTotal = enemyTotal + 40
                    elseif level == 6 then enemyTotal = enemyTotal + 80
                    else enemyTotal = enemyTotal + 5 end
                else
                    enemyTotal = enemyTotal + 5
                end
            end
        end
    end
    xp = xp + idiv(enemyTotal, alliances)
    xp = xp + s.heroesSlain * 10
    -- an easier view of the map earns less: no fog and nothing hidden 80 %, hidden only 90 %, fog and hidden 110 %
    if sum.fogMode == 3 then xp = idiv(xp * 80, 100)
    elseif sum.fogMode == 4 then xp = idiv(xp * 90, 100)
    elseif sum.fogMode == 1 then xp = idiv(xp * 110, 100) end
    if sum.tech <= 0 then
        xp = math.floor(xp / 8)
    else
        xp = idiv(xp * (5 + sum.tech), 10)
    end
    if won and sum.greatest then xp = xp + 100 end
    if s.heroDied then xp = idiv(xp * 3, 4) end
    return xp
end

-- The local player's amount: Ironman (a dead hero is gone and earns nothing, a living winner earns double) and the
-- maximum level (nothing more to gain). `ironman` / `level` describe the player's hero.
---@param xp integer
---@param won boolean
---@param heroDied boolean
---@param ironman boolean?
---@param level integer?
---@return integer xp
---@return boolean removed the ironman hero is gone
function M.local_(xp, won, heroDied, ironman, level)
    local removed = false
    if ironman then
        if heroDied then
            xp, removed = 0, true
        elseif won then
            xp = xp * 2
        end
    end
    if level and level >= MAX_HERO_LEVEL then xp = 0 end
    return xp, removed
end

-- Builds the summary of a finished battle. `won` is the local player's result.
---@param world World
---@param won boolean
---@param fogMode integer?
---@return BattleSummary
function M.summary(world, won, fogMode)
    local stats = world:battleStats()
    local sum = { time = world.time, size = world.w, tech = world.techLevel, pitched = require("src.game.victory").get(world.victoryRule, "pitched") == true,
                  campaign = world.opts.campaign == true, fogMode = fogMode or 1, greatest = world.advanced.greatest == true,
                  me = world.player, sides = {} }
    for i = 0, 5 do
        local sd = world.sides[i]
        local st = stats.sides[i]
        local allies = {}
        for j = 0, 5 do
            if j ~= i and sd.team ~= 0 and world.sides[j].team == sd.team then allies[j] = true end
        end
        sum.sides[i] = {
            used = sd.used, human = world.humans[i] == true, aiLevel = sd.aiLevel or 2, resources = sd.resourceLevel or 2,
            allies = allies, defeated = sd.defeated == true,
            won = (i == world.player) and won or not won,
            quests = sd.questsCompleted or 0, heroKills = st.heroKills, kills = st.unitsKilled,
            heroesSlain = st.heroesSlain or 0, heroDied = st.heroDied == true,
        }
    end
    return sum
end

-- Adds XP to a hero object (alive) or to the saved record of a fallen hero; returns nothing. The local player's hero only
-- collects it: its levels are counted when the victory screen is built and given with Continue (battle.lua `prepareLevels`,
-- binary FUN_00455b40 / 0x004546F0); the other heroes level at once.
---@param world World
---@param i integer
---@param amount integer
local function give(world, i, amount)
    if amount <= 0 then return end
    local heroMod = require("src.game.hero")
    local mine = i == world.player
    local hero = world.eco:heroAlive(i)
    if hero and hero.h then
        if mine then hero.h:gainXp(amount)
        else
            hero.h:addXp(amount, true)
            hero.h:applyLevels(hero.h:levelsDue())     -- another human's hero (its player settles it on their machine): shown levelled
        end
        return
    end
    local sd = world.sides[i]
    if sd.fallenHero then
        local h = heroMod.new(nil, sd.fallenHero)
        if mine then h:gainXp(amount) else h:addXp(amount, true) end
        sd.fallenHero = h:save()
    end
end

-- Computes the amount of every used side and gives it to the heroes. Returns the local player's XP and whether the
-- hero must be removed (a dead Ironman hero). Nothing is given at all in a No Heroes game or while the local player's
-- hero is frozen ("Freeze your hero's level").
---@param world World
---@param won boolean
---@param fogMode integer?
---@return integer xp the local hero's
---@return boolean removed
function M.finish(world, won, fogMode)
    local mods = world.mods or {}
    if mods.noHeroes then return 0, false end
    local me = world.player
    local hero = world.eco:heroAlive(me)
    local mine = hero and hero.h or (world.sides[me].fallenHero and require("src.game.hero").new(nil, world.sides[me].fallenHero))
    if mine and (mine.frozen or mine.tournament) then return 0, false end      -- a Tournament hero is temporary (FUN_004553f0)
    local sum = M.summary(world, won, fogMode)
    local stats = world:battleStats()
    local myXp, removed = 0, false
    for i = 0, 5 do
        local s = sum.sides[i]
        if s.used then
            local amount = M.side(sum, i)
            if i == me then
                amount, removed = M.local_(amount, won, s.heroDied, (mine and mine.ironman) or world.sides[i].ironman,
                                           mine and mine.level)
                myXp = amount
            end
            give(world, i, amount)
            stats.sides[i].xpGained = amount
        end
    end
    return myXp, removed
end

return M
