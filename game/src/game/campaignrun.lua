-- Campaign battles: turns a MAP_*.map definition into a battle setup, and applies the outcome of
-- actions and ambushes (rewards, diplomacy, journal, variables) to the campaign state.
local data = require("src.game.campaigndata")
local config = require("src.core.config")
local fs = require("src.core.fs")
local scnMod = require("src.formats.scn")
local profile = require("src.game.profile")
local heroMod = require("src.game.hero")
local items = require("src.game.items")
local log = require("src.core.log")

local M = {}

---@param file string
---@return table? scn
---@return string? path
local function loadScenario(file)
    for _, dir in ipairs({ "CampaignScenario", "Scenario" }) do
        local d = fs.read(("%s/%s/%s.SCN"):format(config.gamedir, dir, file))
        if d then
            local s = scnMod.parse(d)
            if s then return s, dir .. "/" .. file .. ".SCN" end
        end
    end
end

-- A random skirmish map for "random" battles with room for `players` sides.
---@param players integer
---@param rng fun(n: integer): integer
---@return table? scn
---@return string path
local function randomScenario(players, rng)
    local list = {}
    for _, name in ipairs(fs.list(config.gamedir .. "/Scenario", "%.scn$")) do list[#list + 1] = name end
    for _ = 1, 40 do
        local name = list[rng(#list)]
        local s = scnMod.parse(fs.read(config.gamedir .. "/Scenario/" .. name) --[[@as string]])   -- (listed: it exists)
        if s and (s.header.numPlayers or 0) >= players then return s, "Scenario/" .. name end
    end
    local name = list[1]
    return scnMod.parse(fs.read(config.gamedir .. "/Scenario/" .. name) --[[@as string]]), "Scenario/" .. name
end

---@param state CampaignState
---@return table? rec the hero record (profile.lua)
function M.heroRecord(state)
    return profile.get(state.heroId)
end

-- Battle visibility from the map's two flags: `hidden` = the map starts unexplored (black), `fog` = explored
-- ground goes dark again when out of sight. Modes: 1 fog of war, 2 explored map, 3 no fog, 4 hidden map
-- whose explored ground stays lit. On the Easy campaign difficulty there is no fog of war (the campaign
-- battle start `FUN_005a1880` of the 1.04 binary: "difficulty == 0" clears the scenario's fog of war flag).
---@param b {hidden: boolean, fog: boolean}
---@param difficulty integer
---@return integer
function M.fogMode(b, difficulty)
    local fog = b.fog and difficulty ~= 0
    if b.hidden then return fog and 1 or 4 end
    return fog and 2 or 3
end

-- The campaign difficulty option: 0 Easy, 1 Moderate (the default), 2 Hard (the campaign options dialog
-- `FUN_005a4070`, the word at 0x060d37bc; where 1.04 sets the default is not traced in the binary yet).
M.DIFFICULTY_DEFAULT = 1

-- The level of a computer hero in a campaign (the computer hero routine `FUN_0042a0d0`): half on Easy, 2 per step
-- above Moderate.
---@param difficulty integer
---@param level integer
---@return integer
function M.computerHeroLevel(difficulty, level)
    if difficulty == 0 then level = math.floor(level / 2)
    elseif difficulty > 1 then level = level + difficulty * 2 end
    return math.max(1, level)
end

-- The AI level of the campaign for a hero playing `race` (`FUN_005a1790` of the 1.04 binary): 0..5 from the hero's
-- victories and games with that race, his level and the difficulty option. `rec` is the hero record (`rec.raceWins[race]`, `rec.raceGames[race]`, `rec.hero.level`).
---@param rec table? the hero record
---@param race integer
---@param difficulty integer
---@return integer
function M.aiLevel(rec, race, difficulty)
    local wins = rec and rec.raceWins and rec.raceWins[race] or 0
    local games = rec and rec.raceGames and rec.raceGames[race] or 0
    local level = rec and rec.hero and rec.hero.level or 1
    local lvl = 2
    if difficulty == 0 then lvl = 1 elseif difficulty == 2 then lvl = 3 elseif difficulty == 3 then lvl = 4 end
    if wins < 1 then lvl = 0
    elseif wins < 3 then lvl = lvl - 1
    elseif wins > 75 then lvl = lvl + 1 end
    if wins <= math.floor(2 * games / 3) then lvl = lvl - 1 end
    if wins <= math.floor(3 * games / 8) then lvl = lvl - 1 end
    if level > 19 then lvl = lvl + 1 end              -- strong heroes face stronger computer sides
    if level > 39 then lvl = lvl + 1 end
    lvl = math.max(0, math.min(5, lvl))
    if difficulty == 0 then lvl = math.min(lvl, 2)    -- the cap of the difficulty: Easy 2, Moderate 3, Hard 4
    elseif difficulty == 1 then lvl = math.min(lvl, 3)
    elseif difficulty == 2 then lvl = math.min(lvl, 4) end
    return lvl
end

-- The level a computer side of a campaign battle plays at (the battle start `FUN_005a1880`; `FUN_005a1790` = aiLevel).
-- A scenario file keeps its own side levels: a side that is neither Passive (0) nor Rampant (7) moves by `difficulty - 1`
-- (clamped to 1..6), the map's `relativeai` adds on top of the scenario's level, the map's `ai` (0 or 7) replaces it.
-- A random map has no levels of its own: the base is aiLevel + 1 (the table at 0x0061c9d8 reads 1..6) and the difficulty
-- only shifts a side that has a `relativeai`; a side with neither attribute plays the base level. `set` is the map's
-- <Side> record, `scnLevel` the scenario side's level (nil for a random map).
---@param set CampaignMapSide?
---@param scnLevel integer?
---@param base integer
---@param difficulty integer
---@return integer
function M.sideLevel(set, scnLevel, base, difficulty)
    local function shift(v) return math.max(1, math.min(6, difficulty - 1 + v)) end
    if set and set.ai ~= nil then return set.ai end
    if scnLevel ~= nil then
        if scnLevel == 0 or scnLevel == 7 then return scnLevel end
        return shift(scnLevel + (set and set.relativeai or 0))
    end
    if set and set.relativeai ~= nil then return shift(base + set.relativeai) end
    return base
end

-- The "Difficulty:" line of the battle dialog (the campaign difficulty rating `FUN_005966a0`, shown by `FUN_005a3450` as
-- Game.txt [0700 + rating]: Easy, Average, Hard, Very Hard, Insane, Suicidal): the AI level for the hero's race, less one,
-- moved by the sides of the map. Allies (a team the hero shares) of a computer level above the base make the battle
-- easier, enemies in teams, three or more enemies make it harder; passive sides do not count, a relative level counts one
-- more or less. The 1.04 binary takes the "allies" deduction twice (3 less in all, not 2).
-- `scnSides` are the sides of the scenario file (nil for a random map).
---@param map CampaignMap
---@param aiLevel integer
---@param scnSides table<integer, table>?
---@return integer
function M.difficultyRating(map, aiLevel, scnSides)
    local team0 = map.sides[0] and map.sides[0].team or 0
    local allies, enemyAllies, enemies = 0, 0, 0
    for i = 1, 7 do
        local set = map.sides[i]
        if set then
            local count = 0
            if set.ai == 0 then count = count - 1 end
            if set.relativeai ~= nil then
                if set.relativeai > 0 then count = count + 1 elseif set.relativeai < 0 then count = count - 1 end
            end
            if set.team ~= 0 and set.team == team0 then
                allies = allies + 1 + count
            else
                if set.team ~= 0 then enemyAllies = enemyAllies + 1 end
                enemies = enemies + 1 + count
            end
        elseif scnSides and scnSides[i] and scnSides[i].used then
            local team = scnSides[i].team or 0
            if team ~= 0 and team == team0 then allies = allies + 1 else enemies = enemies + 1 end
        end
    end
    local rating = aiLevel - 1
    if allies > enemyAllies then rating = aiLevel - 3 end
    if enemyAllies > allies + 1 then rating = rating + 1 end
    if enemies > 2 then rating = rating + 1 end
    return math.max(0, math.min(5, rating))
end

-- The races the hero can play a campaign battle with, in the order of the new-battle dialog's list (`FUN_005a2fc0` fills
-- 0x0610c8f8): his own race first, then the other races (slots 0 .. 15) whose standing is Ally (`FUN_00595470` returns 0).
-- Ambushes use the same list (`FUN_005a2ca0`, for the ambush dialog) but openwbc3's ambush dialog has no race pick.
---@param state CampaignState
---@return integer[]
function M.battleRaces(state)
    local rec = M.heroRecord(state)
    local own = rec and rec.race or 0
    local list = { own }
    for race = 0, 15 do
        if race ~= own and state:relation(race) == "ally" then list[#list + 1] = race end
    end
    return list
end

-- The rating of an action's map for the hero of `state` playing `race` (default his own; nil when the map is unknown): the
-- dialog recomputes it for the picked race (`FUN_005a3390` -> `FUN_005966a0`(action, race) -> `FUN_005a1790`(race)).
---@param state CampaignState
---@param mapCode string
---@param race integer?
---@return integer?
function M.mapDifficulty(state, mapCode, race)
    local D = data.load()
    local map = D.maps[mapCode]
    local rec = M.heroRecord(state)
    if not map or not rec then return nil end
    local scn
    if map.file and map.file ~= "random" then scn = loadScenario(map.file) end
    local level = M.aiLevel(rec, race or rec.race, state.difficulty or M.DIFFICULTY_DEFAULT)
    return M.difficultyRating(map, level, scn and scn.sides)
end

-- Returns scn, battleOptions (for screens/battle) or nil, reason. `race` is the race the hero plays the battle with (the
-- dialog's pick, default his own): it becomes the race of side 0 (the battle start `FUN_005a1880`: DAT_00a47a38 = param_2)
-- and picks the AI level (`FUN_005a1790`(param_2)); the hero himself stays what he is (opts.heroRace, as in a skirmish).
---@param state CampaignState
---@param mapCode string
---@param rng (fun(n: integer): integer)?
---@param race integer?
---@return table? scn
---@return table|string opts the battle options, or why there is no battle
function M.setup(state, mapCode, rng, race)
    rng = rng or math.random
    local D = data.load()
    local map = D.maps[mapCode]
    if not map then return nil, "unknown battle map " .. tostring(mapCode) end
    local rec = M.heroRecord(state)
    if not rec then return nil, "the hero of this campaign is gone" end
    race = race or rec.race
    local players = 0
    for _ in pairs(map.sides) do players = players + 1 end
    local scn, path
    if map.file and map.file ~= "random" then scn, path = loadScenario(map.file) end
    local fromFile = scn ~= nil
    if not scn then scn, path = randomScenario(math.max(2, players), rng) end
    if not scn then return nil, "no scenario for " .. mapCode end
    scn.sides = scn.sides or {}
    local level = rec.hero and rec.hero.level or 1
    local difficulty = state.difficulty or M.DIFFICULTY_DEFAULT
    local sidesGiven = next(map.sides) ~= nil
    -- the scenario file's own side levels count only when the battle comes from a file (not a random map)
    local base = M.aiLevel(rec, race, difficulty) + 1
    for i = 0, 5 do
        local sd = scn.sides[i]
        local set = map.sides[i]
        if sd and not sidesGiven then
            if i == 0 then sd.race = race          -- the scenario defines the sides itself
            elseif sd.used and fromFile then sd.aiLevel = M.sideLevel(nil, sd.aiLevel or 2, base, difficulty) end
        elseif sd then
            if set then
                sd.used = true
                sd.resources = set.resources
                sd.team = set.team
                if i == 0 then sd.race = race
                else
                    if set.race then sd.race = set.race end
                    -- the original's levels (see sideLevel); a random map plays at the hero's aiLevel + 1
                    sd.aiLevel = M.sideLevel(set, fromFile and (sd.aiLevel or 2) or nil, base, difficulty)
                    if set.ai == 0 then sd.passive = true end
                    sd.noRetinue = set.noretinue
                end
            else
                sd.used = false
            end
        end
    end
    local sideHeroes = {}
    for _, h in ipairs(map.heroes) do
        local lvl = h.level or math.max(1, level + (h.relative or 0))
        sideHeroes[#sideHeroes + 1] = { side = h.side, name = h.name, level = M.computerHeroLevel(difficulty, lvl) }
    end
    local bonuses = {}
    for index in pairs(state.bonuses) do
        if D.bonuses[index] then bonuses[#bonuses + 1] = D.bonuses[index] end
    end
    local b = map.battle
    local opts = {
        campaign = true, profile = true, scnPath = path, victory = b.victory, startPoints = b.points, quests = b.quests,
        fogMode = M.fogMode(b, difficulty), bonuses = bonuses, sideHeroes = sideHeroes, advanced = require("src.game.advanced").campaign(),
        noRetinue = map.sides[0] and map.sides[0].noretinue or false,
        difficulty = difficulty, heroLevel = level,       -- the computer sides' extra points and mercenaries
        heroRace = rec.race,                              -- the hero keeps his own race whatever race side 0 plays
        race = race,                                      -- the race of side 0 (the army setup lists its troops)
    }
    return scn, opts
end

-- Results ----------------------------------------------------------------------------------------------

local function addXp(state, amount)
    local rec = M.heroRecord(state)
    if not rec then return end
    local h = heroMod.new(nil, rec.hero)
    h:addXp(amount)
    rec.hero = h:save()
    profile.update(rec)
end

-- Applies the rewards of an action / ambush; returns a list of text lines.
---@param state CampaignState
---@param act CampaignAction
---@param lines string[]
local function giveRewards(state, act, lines)
    for _, r in ipairs(act.rewards or {}) do
        if r.type == "crowns" then
            local n = tonumber(r.data) or 0
            state.crowns = state.crowns + n
            lines[#lines + 1] = r.short or (n .. " Crowns")
        elseif r.type == "xp" then
            local n = tonumber(r.data) or 0
            addXp(state, n)
            lines[#lines + 1] = r.short or (n .. " XP")
        elseif r.type == "bonus" then
            local index = tonumber(r.data)
            ---@cast index -nil
            state.bonuses[index] = true
            local b = data.load().bonuses[index]
            lines[#lines + 1] = b and b.name or r.short or "A bonus"
        elseif r.type == "item" then
            local it = items.get(tonumber(r.data))
            if it then
                state.stash[#state.stash + 1] = it.id
                lines[#lines + 1] = it.name
            end
        elseif r.type == "video" then
            state.pendingVideo = (r.data or ""):gsub("%.[bB][iI][kK]$", "")
        end
        if r.text and r.text ~= "" then state.lastRewardText = r.text end
    end
end

-- What the victory screen shows of an action's rewards before the world map applies them (the result of the
-- original's action finish `FUN_00595ee0` and the reward text `FUN_00596650`): the extra experience and the text of
-- the last crowns / bonus / item reward. Nothing on a defeat.
---@param act CampaignAction
---@param won boolean
---@return number xp
---@return string? text
function M.victoryExtra(act, won)
    if not won then return 0, nil end
    local xp, text = 0, nil
    for _, r in ipairs(act.rewards or {}) do
        if r.type == "xp" then
            xp = xp + (tonumber(r.data) or 0)
        elseif (r.type == "crowns" or r.type == "bonus" or r.type == "item") and r.text and r.text ~= "" then
            text = r.text
        end
    end
    return xp, text
end

-- The first video reward of an action goes into its journal entries (victory and defeat alike), so the journal can
-- replay it (the journal entry writer `FUN_005a1040`: the first video reward only).
local function firstVideo(act)
    for _, r in ipairs(act.rewards or {}) do
        if r.type == "video" and r.data and r.data ~= "" then return (r.data:gsub("%.[bB][iI][kK]$", "")) end
    end
end

local function journal(state, act, kind, choice)
    for _, j in ipairs(act.journals or {}) do
        if (choice ~= nil and j.choice == choice) or (choice == nil and j.type == kind) then
            state:addJournal(j.text, j.important, act.name, firstVideo(act))
        end
    end
end

-- A battle action or ambush ended (the fallen of the retinue went to the hero's graveyard when the battle ended).
---@param state CampaignState
---@param act CampaignAction
---@param won boolean
---@return string[]
function M.finishBattle(state, act, won)
    local lines = {}
    state:advance(1)
    state.done[act.code] = (state.done[act.code] or 0) + 1
    if won then
        state:applyEffects(act.conditions, "victory")
        state:applyDiplomacy(act.diplomacy, nil)
        giveRewards(state, act, lines)
        journal(state, act, "victory")
    else
        state:applyEffects(act.conditions, "defeat")
        journal(state, act, "defeat")
    end
    state:finishTravel(won)
    state:save()
    return lines
end

---@param state CampaignState
---@param act CampaignAction
---@param choice integer
function M.chooseOption(state, act, choice)
    state:applyDiplomacy(act.diplomacy, choice)
    journal(state, act, nil, choice)
    state:save()
end

-- Mercenaries ---------------------------------------------------------------------------------------------

-- The mercenary companies on offer in a guild (stable for the date and place).
---@param state CampaignState
---@param act CampaignAction
---@return CampaignMercenary[]
function M.offers(state, act)
    local D = data.load()
    local seed = state.year * 400 + state.day + #act.code * 31
    local rng = function(n) seed = (seed * 1103515245 + 12345) % 2147483648 return math.floor(seed / 2147483648 * n) + 1 end
    local out, used = {}, {}
    for _, m in ipairs(act.mercenaries or {}) do
        if rng(100) <= m.chance then
            local merc
            if m.type == "fixed" and m.index > 0 and D.mercenaries[m.index] then
                merc = D.mercenaries[m.index]
            else
                local pool = {}
                for _, c in pairs(D.mercenaries) do
                    if (m.side < 0 or c.race == m.side) and c.quality >= m.minq and c.quality <= m.maxq and not used[c.id] then
                        pool[#pool + 1] = c
                    end
                end
                table.sort(pool, function(a, b) return a.id < b.id end)
                if #pool > 0 then merc = pool[rng(#pool)] end
            end
            if merc and not used[merc.id] then
                used[merc.id] = true
                out[#out + 1] = merc
            end
        end
    end
    return out
end

-- A hired company waits in one of the two mercenary slots until the player brings it to a battle (the original's
-- hire / disband `FUN_00596590` and mercenary placement `FUN_004403a0`). Before a battle with army setup points the
-- selection dialog (screens/campaignmercs) asks which of the waiting companies come along.
M.MERC_SLOTS = 2

---@param state CampaignState
---@param merc CampaignMercenary
---@return boolean
function M.hire(state, merc)
    if state.crowns < merc.cost or #state.mercs >= M.MERC_SLOTS then return false end
    state.crowns = state.crowns - merc.cost
    state.mercs[#state.mercs + 1] = merc.id
    state:save()
    return true
end

-- The troops of the selected companies (`selected`: slot number -> true; each unit starts at the level the company names,
-- the levels count from 1 there) as entries of a battle army (placed by `FUN_004406b0`); the companies that go are disbanded,
-- the others stay in their slots for a later battle.
---@param state CampaignState
---@param selected table<integer, boolean>?
---@return {code: string, name: string?, level: integer, xp: number}[]
function M.takeMercenaries(state, selected)
    local out, stay = {}, {}
    local retinue = require("src.game.retinue")
    local D = data.load()
    for slot, id in ipairs(state.mercs) do
        if selected and selected[slot] then
            local merc = D.mercenaries[id]
            for _, u in ipairs(merc and merc.units or {}) do
                local level = math.max(0, (u.level or 1) - 1)
                for _ = 1, u.number do out[#out + 1] = { code = u.code, name = u.name, level = level, xp = retinue.xpFor(level) } end
            end
        else
            stay[#stay + 1] = id
        end
    end
    state.mercs = stay
    return out
end

-- Extra army points bought with crowns before a battle (`FUN_005a8330` / `FUN_005a86e0` -> `FUN_00445780`: 4 points for
-- 10 crowns, 10 points for 30 crowns; the dialog is only offered with 10 crowns or more). `option` is the radio button of
-- the dialog: 0 nothing, 1 the small, 2 the large package. Returns the points added.
M.EXTRA_POINTS = { { points = 4, crowns = 10 }, { points = 10, crowns = 30 } }

---@param state CampaignState
---@return boolean
function M.extraPointsAvailable(state)
    return state.crowns >= M.EXTRA_POINTS[1].crowns
end

---@param state CampaignState
---@param option integer
---@return integer
function M.buyExtraPoints(state, option)
    local pack = M.EXTRA_POINTS[option]
    if not pack or state.crowns < pack.crowns then return 0 end
    state.crowns = state.crowns - pack.crowns
    state:save()
    return pack.points
end

-- The campaign options of the hero (the words at 0x060d37ba that the dialog `FUN_005a4070` edits): difficulty 0..2,
-- map scroll rate 0..2, game resolution (an index of the list of the dialog) and campaign menu sounds on / off, all
-- kept in the campaign state.
M.OPTION_DEFAULTS = { difficulty = 1, scrollRate = 1, menuSounds = 1, resolution = 0 }

---@param state CampaignState
---@return {difficulty: integer, scrollRate: integer, menuSounds: integer, resolution: integer}
function M.options(state)
    local o = {}
    for k, v in pairs(M.OPTION_DEFAULTS) do o[k] = state[k] or v end
    return o
end

-- The window sizes of the resolution option (the dialog's list, 800 x 600 .. 1600 x 1200). The battle start
-- (`FUN_005a1880`) hands the width of the option (800 / 1024 / 1280 / 1600) to `FUN_004e7230` before every campaign battle,
-- which picks the battle's resolution. openwbc3 has no separate battle resolution, only its window (its skirmish setup does the
-- same with the window, see screens/skirmish.lua), so the option sets the window size when a battle starts, in windowed mode and
-- when the desktop is big enough, and only when the player picked a value (the original's default is the global resolution,
-- which here is whatever the window already is). Returns the size set, or nil.
M.RESOLUTIONS = { { 800, 600 }, { 1024, 768 }, { 1280, 1024 }, { 1600, 1200 } }

---@param state CampaignState
---@return integer[]?
function M.applyResolution(state)
    local size = state.resolution and M.RESOLUTIONS[state.resolution + 1]
    if not size or love.window.getFullscreen() then return nil end
    local dw, dh = love.window.getDesktopDimensions()
    if size[1] > dw or size[2] > dh then return nil end
    local config = require("src.core.config")
    config.set("graphics", "width", size[1])
    config.set("graphics", "height", size[2])
    require("src.screens.options").applyWindow()
    return size
end

---@param state CampaignState
---@param o table
function M.setOptions(state, o)
    for k in pairs(M.OPTION_DEFAULTS) do if o[k] ~= nil then state[k] = o[k] end end
    state:save()
end

-- Item shops ------------------------------------------------------------------------------------------------

---@param state CampaignState
---@param act CampaignAction
---@return (integer|string)[] item ids
function M.shopItems(state, act)
    local seed = state.year * 400 + state.day + #act.code * 17
    local rng = function() seed = (seed * 1103515245 + 12345) % 2147483648 return seed / 2147483648 end
    local out = {}
    for _, e in ipairs(act.items and act.items.list or {}) do
        if rng() * 100 <= e.chance then
            local it
            if e.type == "fixed" and e.index then it = items.get(e.index)
            else it = items.random(math.max(1, math.min(3, (e.maxq or 1) + 1)), rng) end
            if it then out[#out + 1] = it.id end
        end
    end
    return out
end

-- Campaign completion ---------------------------------------------------------------------------------------

-- The end-of-campaign reward. The original hands out crowns, an item or a retinue unit depending on how many
-- provinces were still left; openwbc3 has no province count, so this reward is openwbc3's own choice: a fixed
-- reward of crowns, a fine item and a dragon joining the retinue.
---@param state CampaignState
---@return string[]
function M.completeCampaign(state)
    local lines = {}
    state.crowns = state.crowns + 1000
    lines[#lines + 1] = "1000 Crowns"
    local it = items.random(3)
    if it then
        state.stash[#state.stash + 1] = it.id
        lines[#lines + 1] = it.name
    end
    local rec = M.heroRecord(state)
    if rec then
        local retinue = require("src.game.retinue")
        retinue.give(rec, retinue.fresh("AADR", 5, "Dragon"), retinue.slotsOf(rec))
        profile.update(rec)
    end
    lines[#lines + 1] = "Dragon (level 5)"
    state.finished = true
    state:save()
    return lines
end

return M
