-- Progress of one hero in the campaign: where you are on the world map, the date, crowns,
-- variables, diplomacy, journal, bonuses, item stash and the hired mercenary companies. Saved to campaign/<hero>.lua.
-- The campaign options (difficulty 0..2, scrollRate, menuSounds, resolution; campaignrun.options) are plain fields, unset = default.
-- The retinue and the graveyard belong to the hero (game/retinue.lua, the hero record); older campaign saves that kept
-- them here are moved over when they are loaded.
local serialize = require("src.core.serialize")
local data = require("src.game.campaigndata")
local log = require("src.core.log")
local hate = require("src.game.campaignhate")

local M = {}

local START = "LOC_SUNDEREDISLE"
local DAYS_PER_YEAR = 365

-- One hero's campaign progress (campaign/<hero>.lua).
---@class CampaignState
---@field heroId string
---@field location string           the LOC_* code where the hero is
---@field year integer
---@field day integer               1..365
---@field crowns integer
---@field vars table<string, number> campaign variables (lower-case ids)
---@field diplomacy table<integer, number> race -> standing
---@field journal {year: integer, day: integer, important: boolean?, text: string, title: string?, video: string?}[]
---@field bonuses table<integer, boolean> bonus index -> owned
---@field stash (integer|string)[]  ids of the items kept for the hero
---@field mercs integer[]           hired mercenary companies waiting for a battle
---@field difficulty integer        0..2 (campaignrun.options)
---@field scrollRate integer?
---@field menuSounds integer?
---@field resolution integer?
---@field visited table<string, boolean>
---@field done table<string, integer> action code -> how often it was finished
---@field hintLevel table<integer, integer>
---@field introSeen boolean
---@field finished boolean
---@field standingsSeeded boolean?  the standings got the hero's row of the hate table
---@field pendingTravel string?     where the hero goes after the ambush on the way
---@field pendingVideo string?      a video reward the world map plays next
---@field lastRewardText string?
---@field retinue table[]?          (older saves: moved to the hero record)
---@field graveyard table[]?
local State = {}
State.__index = State

local function path(heroId) return ("campaign/%s.lua"):format(heroId) end

---@param heroId string
---@return boolean
function M.exists(heroId)
    return love.filesystem.getInfo(path(heroId)) ~= nil
end

---@param heroId string
---@return CampaignState
function M.new(heroId)
    local D = data.load()

    ---@type CampaignState
    local s = setmetatable({
        heroId = heroId, location = START, year = 3800, day = 1, crowns = 0,
        vars = {}, diplomacy = {}, journal = {}, bonuses = {}, stash = {}, mercs = {}, difficulty = 1,
        visited = { [START] = true }, done = {}, hintLevel = {}, introSeen = false, finished = false,
    }, State)
    for _, v in ipairs(D.globals) do s.vars[v.id] = v.value end
    for _, loc in pairs(D.locations) do
        for _, v in ipairs(loc.variables) do s.vars[v.id] = v.value end
    end
    s:seedStandings()
    return s
end

---@param heroId string
---@return CampaignState?
function M.load(heroId)
    local text = love.filesystem.read(path(heroId))
    local t = text and serialize.decode(text)
    if not t then return nil end
    local s = M.new(heroId)
    for k, v in pairs(t) do s[k] = v end
    s.heroId = heroId
    s:migrateRetinue()
    s:seedStandings()
    return s
end

-- Older saves kept the retinue and the graveyard of the campaign here: they go to the hero's record (the retinue as far
-- as the Charisma has slots, the rest is dropped like a full retinue drops its weakest), once.
function State:migrateRetinue()
    if not self.retinue and not self.graveyard then return end
    local profile = require("src.game.profile")
    local retinue = require("src.game.retinue")
    local rec = profile.get(self.heroId)
    if rec then
        local enabled = retinue.slotsOf(rec)
        for _, r in ipairs(self.retinue or {}) do
            retinue.give(rec, { code = r.code, name = r.name, level = r.level }, enabled)
        end
        local gy = retinue.graveyard(rec)
        for i, g in ipairs(self.graveyard or {}) do
            if i <= retinue.GRAVEYARD and not gy[i] then
                gy[i] = { code = g.code, name = g.name, level = g.level or 0, xp = retinue.xpFor(g.level or 0), battles = 1,
                          scenario = "", since = i }
            end
        end
        profile.update(rec)
    end
    self.retinue, self.graveyard = nil, nil
    if rec then self:save() end          -- so that it happens once
end

function State:save()
    love.filesystem.createDirectory("campaign")
    local copy = {}
    for k, v in pairs(self) do copy[k] = v end
    local ok, err = love.filesystem.write(path(self.heroId), serialize.encode(copy))
    if not ok then log.warn("campaign not saved: %s", tostring(err)) end
end

---@param heroId string
function M.delete(heroId)
    love.filesystem.remove(path(heroId))
end

-- Variables, diplomacy ----------------------------------------------------------------------------

---@param id string?
---@return number
function State:var(id) return self.vars[id and id:lower()] or 0 end
---@param id string
---@param v number
function State:setVar(id, v) self.vars[id:lower()] = v end

-- The standings with the 16 races start as the hero's row of the original's table (campaignhate.lua, `FUN_005939a0`). A
-- campaign saved before that kept only the changes made by actions, counted from 0: its standings get the row added once
-- (`standingsSeeded` marks a state that has it; a hero that is not there leaves the standings alone and unmarked).
function State:seedStandings()
    if self.standingsSeeded then return end
    local rec = require("src.game.profile").get(self.heroId)
    if not rec or not rec.race then return end
    for race = 0, 15 do self.diplomacy[race] = (self.diplomacy[race] or 0) + hate.initial(rec.race, race) end
    self.standingsSeeded = true
end

---@param side integer
---@return number
function State:rating(side) return self.diplomacy[side] or 0 end

-- enemy below -4, neutral below 5, friend below 15, else ally (`FUN_00595470`, campaignhate.lua)
---@param side integer
---@return "enemy"|"neutral"|"friend"|"ally"
function State:relation(side) return hate.relation(self:rating(side)) end

local function compare(a, op, b)
    if op == "eq" then return a == b
    elseif op == "ge" then return a >= b
    elseif op == "gt" then return a > b
    elseif op == "le" then return a <= b
    elseif op == "lt" then return a < b end
    return true
end

---@param c CampaignCondition
---@return boolean
function State:condition(c)
    if c.type == "check" then return compare(self:var(c.id), c.action, c.value or 0) end
    if c.type == "diplomacy" then return compare(self:rating(c.side), c.action, c.rating or 0) end
    return true      -- victory / defeat conditions are effects
end

---@param list CampaignCondition[]?
---@return boolean
function State:conditionsMet(list)
    for _, c in ipairs(list or {}) do
        if (c.type == "check" or c.type == "diplomacy") and not self:condition(c) then return false end
    end
    return true
end

-- Effects of a victory / defeat condition.
---@param list CampaignCondition[]?
---@param kind "victory"|"defeat"
function State:applyEffects(list, kind)
    for _, c in ipairs(list or {}) do
        if c.type == kind and c.id then
            if c.action == "assign" then self:setVar(c.id, c.value or 0)
            elseif c.action == "add" then self:setVar(c.id, self:var(c.id) + (c.value or 0))
            elseif c.action == "sub" then self:setVar(c.id, self:var(c.id) - (c.value or 0)) end
        end
    end
end

-- What an action does to the standings (`FUN_005955a0`: the battle's victory, the chosen answer of a choice), see
-- campaignhate.apply for the exact steps.
---@param list CampaignDiplomacy[]?
---@param choice integer?
function State:applyDiplomacy(list, choice)
    for _, d in ipairs(list or {}) do
        if d.choice == nil or d.choice == choice then
            self.diplomacy[d.side] = hate.apply(self:rating(d.side), d.mod, d.max, d.min)
        end
    end
end

-- Time ----------------------------------------------------------------------------------------------

---@param days integer
function State:advance(days)
    self.day = self.day + days
    while self.day > DAYS_PER_YEAR do
        self.day = self.day - DAYS_PER_YEAR
        self.year = self.year + 1
    end
end

-- `video` (a Video/ name without the extension) is what the journal's play button replays: the original writes the
-- first video reward of the action into the entry (the journal entry writer `FUN_005a1040`).
---@param text string?
---@param important boolean?
---@param title string?
---@param video string?
function State:addJournal(text, important, title, video)
    if not text or text == "" then return end
    self.journal[#self.journal + 1] = { year = self.year, day = self.day, important = important, text = text, title = title,
                                        video = video }
end

-- Map ------------------------------------------------------------------------------------------------

---@param code string
---@return boolean?
function State:locationOpen(code)
    local loc = data.load().locations[code]
    return loc and self:conditionsMet(loc.conditions)
end

-- Locations to show: visited ones and those linked from a visited location.
---@return table<string, boolean>
function State:visible()
    local D = data.load()
    local out = {}
    for code in pairs(self.visited) do
        local loc = D.locations[code]
        if loc then
            out[code] = true
            for _, l in ipairs(loc.links) do
                if self:locationOpen(l.to) then out[l.to] = true end
            end
        end
    end
    return out
end

---@param act CampaignAction
---@return boolean
function State:actionAvailable(act)
    if not self:conditionsMet(act.conditions) then return false end
    if act.type == "battle" and not act.replayable and self.done[act.code] then
        -- a battle without a variable of its own can only be fought once
        local gated = false
        for _, c in ipairs(act.conditions) do if c.type == "victory" then gated = true end end
        if not gated then return false end
    end
    return true
end

-- Actions offered at the current location.
---@param code string?
---@return CampaignAction[]
function State:actions(code)
    local D = data.load()
    local loc = D.locations[code or self.location]
    local out = {}
    for _, ac in ipairs(loc and loc.actions or {}) do
        local act = D.actions[ac]
        if act and self:actionAvailable(act) then out[#out + 1] = act end
    end
    return out
end

-- Moves to a linked location; returns the ambush that strikes on the way, if any.
---@param link {to: string, days: integer}
---@param rng (fun(n: integer): integer)?
---@return CampaignAction? ambush
function State:travel(link, rng)
    local D = data.load()
    rng = rng or math.random
    local from, to = D.locations[self.location], D.locations[link.to]
    self:advance(link.days)
    local ambush
    local function roll(loc, kind, owner)
        for _, a in ipairs(loc.ambushes) do
            if a.type == kind and not ambush then
                local amb = D.ambushes[a.code]
                if amb and self:conditionsMet(amb.conditions) then
                    local chance = amb.chances[self:relation(owner or 0)] or 0
                    if rng(100) <= chance then ambush = amb end
                end
            end
        end
    end
    roll(from, "leave", from.owner)
    if not ambush then roll(to, "enter", to.owner) end
    if ambush then
        self.pendingTravel = link.to
    else
        self.location = link.to
        self.visited[link.to] = true
    end
    return ambush
end

---@param survived boolean
function State:finishTravel(survived)
    if self.pendingTravel then
        if survived then
            self.location = self.pendingTravel
            self.visited[self.pendingTravel] = true
        end
        self.pendingTravel = nil
    end
end

-- Hints: the current hints with their revealed text lines.
---@return {index: integer, lines: string[], more: boolean}[]
function State:hints()
    local D = data.load()
    local out = {}
    for i, h in ipairs(D.hints) do
        if self:conditionsMet(h.conditions) then
            local revealed = math.min(h.levels, (self.hintLevel[i] or 0) + 1)
            local lines = {}
            for l = 0, revealed - 1 do if h.texts[l] then lines[#lines + 1] = h.texts[l] end end
            out[#out + 1] = { index = i, lines = lines, more = revealed < h.levels }
        end
    end
    return out
end

---@param index integer
function State:moreHint(index)
    local h = data.load().hints[index]
    if h then self.hintLevel[index] = math.min(h.levels - 1, (self.hintLevel[index] or 0) + 1) end
end

-- Campaign end. The original counts the provinces still to conquer and offers to resign once fewer than twenty
-- remain; openwbc3 has no province ownership, so the analogue is the campaign's one-off battle missions - the
-- campaign can be finished once they are all done. The reward is openwbc3's own choice.
---@return integer
function State:missionsLeft()
    local D = data.load()
    local left = 0
    for _, act in pairs(D.actions) do
        if act.type == "battle" and not act.replayable and not self.done[act.code] then left = left + 1 end
    end
    return left
end

---@return boolean
function State:finishable() return self:missionsLeft() < 20 end

return M
