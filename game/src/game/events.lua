-- Scenario events (EVSH chunk): a condition and up to four effects per event. The numbers follow the original
-- event system; the effect of each slot is its own number (`ef.effect`), the event's 4-letter code only names the
-- first one in the editor.
--
-- Conditions (owner 6 = any side that plays; `flags` = event flags that must all be set; `target` = a unit or
-- building type, a side, a counter or a key depending on the condition; shots 0 = repeat):
--   0   timer: the game clock reached `seconds` (absolute; repeats every `seconds` + 1 s)
--   1   an army of side `owner` (type `target`, any if none) stands in the square of `radius` cells around (x, y)
--   2   the same for a hero;  31  the same for the character named by the text of the fourth effect
--   3   side `owner` has built `number` buildings of the type `target` (any type if none)
--   4   side `owner` has produced `number` armies of the type `target` (any type if none)
--   5   side `owner` has killed `number` armies of the type `target`;  6  armies of the side `target`
--   7   (never fires: items are not counted by the original either)
--   8   side `owner` has razed `number` buildings of the type `target`;  9  buildings of the side `target`
--   10  standard victory: side `owner` is alive and every enemy is out;  12 all enemy buildings razed,
--   13  all enemy units killed,  14 all enemy heroes slain,  17 the enemy keeps are gone (fortress)
--   15, 16  after 30 minutes `owner` has razed (killed) the most;  19  `owner` holds 2500 of every resource
--   18  `owner` holds a level 5 keep (king of the castle);  30  `owner` (with its allies) owns every flag (BMFL)
--   11, 20, 21, 22  (increment games, the horde, titans, pitched battle: the original's event system has no code for
--   them, so they never fire)
--   23  the character named by the text of the first effect is dead or missing (defeat for `owner`)
--   24  `owner` has selected `number` armies (of the type `target`);  25  a building of the type `target`
--   26  its selected hero is converting (a building of the type `target`, any if none)
--   27  side `owner` has converted `number` buildings;  28  its hero has learned `number` skill levels
--   29  side `owner` has `number` of the resource `target` (0 gold, 1 metal, 2 crystal, 3 stone, -1 all)
--   32  the key `target` was pressed (Events:keypress)
--   33  side `target` is defeated;  34  the counter of side `target` reached `number`
--   35  the hero of side `target` is dead
-- The kill, production, building, razing and conversion counts are fed by World:event (Events:note).
--
-- Effects (owner types: 0 everybody, 1 the side that triggered, 2 everybody else, 3 side `ownerData`,
-- 4 everybody but `ownerData`):
--   0 damage in the square of `location` cells around (x, y)   1 resources (`type`: gold, metal, crystal, stone)
--   2 set (type 1: clear) flag `number`   3 victory   4 defeat   5 give `number` armies of `type` at (x, y)
--   6 explosion `type` (ring of fire, ring of ice, lightning, sparkle, fireball, whirlwind)   7 sound `text`
--   8 music, 10 video, 11 pause, 19 place item: the original does nothing either   9 text message
--   12 add / 13 remove the feature `type` at (x, y)   14 mana   15 storm (`number` = level, `type` 1 = with
--   lightning)   16 storm off   17 night (type 0) or day (`number` = seconds the change takes)   18 defeat (character lost)
--   20 create the character `text` (army `type`, side `ownerData`)   21, 22, 29 tutorial popup / overlay
--   23 scroll to (x, y) (`type` 1 slides)   24 give the character `text` to side `number`
--   25 uncover the map around (x, y) with radius `number`   26 conversation (.nis file `text`)
--   27 clock of `location` minutes that sets flag `number` when it runs out   28 remove the character `text`
--   30 change the AI level of side `location` to `number`   31-34 activate, deactivate, set, add to the counter
--   of side `location`
-- Tutorial popups show the text of Tutorial.cfg as a message.
local bit = require("bit")
local log = require("src.core.log")
local gamedata = require("src.game.gamedata")

local M = {}

-- An event of the scenario and how often it fired.
---@class EventState
---@field def ScnEvent
---@field fired integer
---@field next number?              a timer's next time
---@field done boolean?
---@field was boolean?              an edge condition held at the last check

-- What happened in the battle, keyed "<side>:<code>" ("*" any).
---@class EventStats
---@field kills table<string, integer>
---@field killed table<string, integer>
---@field produced table<string, integer>
---@field built table<string, integer>
---@field razed table<string, integer>
---@field razedSide table<string, integer>
---@field converted table<string, integer>

-- The scenario's triggers of a battle (world.events).
---@class Events
---@field world World
---@field list EventState[]
---@field flags table<integer, boolean> the event flags that are set
---@field flagMask integer          the same as a bit mask
---@field counters table<integer, {active: boolean, value: number}> side -> its event counter
---@field nextCheck number
---@field stats EventStats
---@field usesSelection boolean?    a condition looks at what a side has selected
---@field clock {total: number, t0: number, flag: integer?}? the running event clock
local Events = {}
Events.__index = Events

---@param v integer?
---@return string?
local function codeOf(v)
    if not v or v == 0 or v == 0xFFFFFFFF then return nil end
    local s = string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256)
    return s:match("^%w%w%w%w$") and s or nil
end

-- conditions that fire when they turn true, so a repeating event can fire again
local EDGE = { [1] = true, [2] = true, [24] = true, [25] = true, [26] = true, [31] = true }
local RESOURCES = { [0] = "gold", "metal", "crystal", "stone" }

---@param world World
---@param list ScnEvent[]?
---@return Events
function M.new(world, list)
    ---@type Events
    local self = setmetatable({ world = world, list = {}, flags = {}, flagMask = 0, counters = {}, nextCheck = 0,
                                stats = { kills = {}, killed = {}, produced = {}, built = {}, razed = {}, razedSide = {},
                                          converted = {} } }, Events)
    for _, e in ipairs(list or {}) do
        local ev = { def = e, fired = 0, next = nil }
        if e.cond.condition == 24 or e.cond.condition == 25 or e.cond.condition == 26 then self.usesSelection = true end
        if e.cond.condition == 0 then ev.next = math.max(0, (e.seconds or 0)) * 1000 end
        self.list[#self.list + 1] = ev
        for _, ef in ipairs(e.effects) do
            if ef.effect == 3 then world.scriptedVictory = true end
        end
    end
    return self
end

-- Helpers ---------------------------------------------------------------------------------

local function typeMatch(u, code)
    return not code or u.code == code
end

local function bump(t, key)
    t[key] = (t[key] or 0) + 1
end

-- The square the original ties a movement event to: `radius` cells wide around the cell, one cell if radius <= 1.
local function inSquare(u, x, y, radius)
    local h = radius > 1 and math.floor(radius / 2) or 0
    return math.abs(u.gx - x) <= h and math.abs(u.gy - y) <= h
end

-- Sides that take part in an event with this owner.
---@param owner integer
---@return integer[]
function Events:sidesOf(owner)
    local out = {}
    for i = 0, 5 do
        local sd = self.world.sides[i]
        if sd.used and not sd.defeated and (owner == 6 or owner == i) then out[#out + 1] = i end
    end
    return out
end

---@param e ScnEvent
---@param slot integer
---@return string
local function effectText(e, slot)
    for _, ef in ipairs(e.effects) do
        if ef.slot == slot then return ef.text end
    end
    return ""
end

local function counted(tbl, side, key)
    return tbl[side .. ":" .. key] or 0
end

-- Counts what happens in the battle for the conditions that count it.
---@param kind string a world event
---@param a any
---@param b any
function Events:note(kind, a, b)
    local st = self.stats
    if kind == "kill" and a and b then
        bump(st.kills, a.side .. ":" .. b.code)
        bump(st.kills, a.side .. ":*")
        bump(st.killed, a.side .. ":" .. tostring(b.side))
    elseif kind == "produced" and a then
        bump(st.produced, a.side .. ":" .. a.code)
        bump(st.produced, a.side .. ":*")
    elseif kind == "built" and a then
        bump(st.built, a.side .. ":" .. a.code)
        bump(st.built, a.side .. ":*")
    elseif (kind == "destroyed" or kind == "pillaged") and a then
        -- the side that razed it (nothing if it fell for another reason, e.g. its owner was defeated)
        local i = kind == "pillaged" and b or a.razedBy
        if i and i ~= a.side and i <= 5 then
            bump(st.razed, i .. ":" .. a.code)
            bump(st.razed, i .. ":*")
            bump(st.razedSide, i .. ":" .. tostring(a.side))
        end
    elseif kind == "converted" and a then
        bump(st.converted, a.side .. ":*")
    end
end

---@param n integer
---@param on boolean? false clears it
function Events:setFlag(n, on)
    if on == false then
        self.flags[n] = nil
        self.flagMask = bit.band(self.flagMask, bit.bnot(bit.lshift(1, n)))
    else
        self.flags[n] = true
        self.flagMask = bit.bor(self.flagMask, bit.lshift(1, n))
    end
end

-- Conditions ---------------------------------------------------------------------------------

local function skillLevels(world, side)
    local hero = world.eco:heroAlive(side)
    local n = 0
    if hero and hero.h then
        for _, v in pairs(hero.h.skill) do n = n + v end
    end
    return n
end

-- What a side has selected (set by the "select" command), as units and buildings that are still there.
---@param side integer
---@return (Unit|Building)[]
function Events:selection(side)
    local out = {}
    local ids = self.world.selected and self.world.selected[side] or {}
    for _, id in ipairs(ids) do
        local found
        for _, u in ipairs(self.world.units) do
            if u.id == id then found = u:alive() and u or nil break end
        end
        if not found then
            for _, b in ipairs(self.world.buildings) do
                if b.id == id then found = b.hp > 0 and b or nil break end
            end
        end
        if found then out[#out + 1] = found end
    end
    return out
end

local function enemiesOut(self, side, rule)
    local any
    for i = 0, 5 do
        local sd = self.world.sides[i]
        if i ~= side and sd.used and self.world:enemies(side, i) then
            any = true
            if self.world.eco:sideAlive(i, rule) then return false end
        end
    end
    return any == true and self.world.eco:sideAlive(side, rule)
end

-- Total of a per-side count over every key ("*" entries only).
local function mostOf(self, side, tbl)
    local mine = counted(tbl, side, "*")
    if mine == 0 then return false end
    for i = 0, 5 do
        if i ~= side and self.world.sides[i].used and counted(tbl, i, "*") >= mine then return false end
    end
    return true
end

-- Whether condition `n` of the event holds for `side`.
---@param ev EventState
---@param n integer the condition
---@param side integer
---@return boolean
function Events:test(ev, n, side)
    local world = self.world
    local e = ev.def
    local c = e.cond
    local code = codeOf(c.target)
    local number = math.max(1, c.number or 1)
    if n == 1 or n == 2 or n == 31 then
        local name = n == 31 and effectText(e, 4) or nil
        for _, u in ipairs(world.units) do
            if u:alive() and u.side == side and inSquare(u, e.x, e.y, c.radius or 1)
                and ((n == 1 and typeMatch(u, code)) or (n == 2 and u.hero) or (n == 31 and name ~= "" and u.name == name)) then
                return true
            end
        end
        return false
    elseif n == 3 then
        return counted(self.stats.built, side, code and code:sub(1, 4) or "*") >= number
    elseif n == 4 then
        return counted(self.stats.produced, side, code or "*") >= number
    elseif n == 5 then
        return counted(self.stats.kills, side, code or "*") >= number
    elseif n == 6 then
        return counted(self.stats.killed, side, tostring(c.target)) >= number
    elseif n == 8 then
        return code ~= nil and counted(self.stats.razed, side, code) >= number
    elseif n == 9 then
        return counted(self.stats.razedSide, side, tostring(c.target)) >= number
    elseif n == 23 then
        local name = effectText(e, 1)
        if name == "" then return false end
        for _, u in ipairs(world.units) do
            if u.side == side and u.name == name and u:alive() then return false end
        end
        for _, b in ipairs(world.buildings) do
            if b.side == side and b.name == name and b.hp > 0 then return false end
        end
        return true
    elseif n == 10 then
        return enemiesOut(self, side, "standard")
    elseif n == 12 then
        return enemiesOut(self, side, "raze all")
    elseif n == 13 then
        return enemiesOut(self, side, "kill all")
    elseif n == 14 then
        return enemiesOut(self, side, "assassins")
    elseif n == 17 then
        return enemiesOut(self, side, "fortress")
    elseif n == 18 or n == 30 then
        for _, w in ipairs(require("src.game.victory").winners(world, n == 18 and "king of the castle" or "capture the flag") or {}) do
            if w == side then return true end
        end
        return false
    elseif n == 15 or n == 16 then
        return world.time >= 30 * 60000 and mostOf(self, side, n == 15 and self.stats.razed or self.stats.kills)
    elseif n == 19 then
        local sd = world.sides[side]
        for _, r in pairs(RESOURCES) do
            if (sd[r] or 0) < 2500 then return false end
        end
        return true
    elseif n == 24 or n == 25 then
        local list = self:selection(side)
        local first = list[1]
        if not first then return false end
        if n == 24 then
            if first.kind ~= "unit" or not typeMatch(first, code) then return false end
            local count = 0
            for _, s in ipairs(list) do if s.kind == "unit" then count = count + 1 end end
            return (c.number == 1 and count == 1) or ((c.number or 0) > 1 and count >= c.number)
        end
        return first.kind == "building" and typeMatch(first, code)
    elseif n == 26 then
        local first = self:selection(side)[1]
        if not (first and first.kind == "unit" and first.converting) then return false end
        if not code then return true end
        for _, b in ipairs(world.eco:conversionTargets(first)) do
            if b.code == code then return true end
        end
        return false
    elseif n == 27 then
        return counted(self.stats.converted, side, "*") >= number
    elseif n == 28 then
        return skillLevels(world, side) >= number
    elseif n == 29 then
        local sd = world.sides[side]
        local want = c.number or 0
        if c.target == 0xFFFFFFFF then
            for _, r in pairs(RESOURCES) do
                if (sd[r] or 0) < want then return false end
            end
            return true
        end
        local r = RESOURCES[c.target]
        return r ~= nil and (sd[r] or 0) >= want
    elseif n == 33 then
        local sd = world.sides[c.target]
        return sd ~= nil and sd.used and sd.defeated == true
    elseif n == 34 then
        local ct = self.counters[c.target]
        return ct ~= nil and ct.active and ct.value >= (c.number or 0)
    elseif n == 35 then
        local sd = world.sides[c.target]
        return sd ~= nil and sd.used and not world.eco:heroAlive(c.target)
    end
    return false
end

-- Returns the side the event triggers for, or nil.
---@param ev EventState
---@param t number
---@return integer?
function Events:condition(ev, t)
    local e = ev.def
    local c = e.cond
    local need = c.flags or 0
    if need ~= 0 and bit.band(self.flagMask, need) ~= need then return nil end
    local n = c.condition
    if e.onMap == false and n ~= 0 then return nil end    -- only timers and the victory rules have no location
    if n == 0 then
        if not (ev.next and t >= ev.next) then return nil end
        return self:sidesOf(c.owner)[1] or self.world.player
    end
    if n == 7 or n == 32 or n == 11 or (n >= 20 and n <= 22) then return nil end
    for _, side in ipairs(self:sidesOf(c.owner)) do
        if self:test(ev, n, side) then return side end
    end
    return nil
end

-- A command button was pressed (the original's control panel icon number, e.g. 7 production, 31 build):
-- fires the button events (condition 32, the tutorial uses them).
---@param icon integer
function Events:button(icon)
    for _, ev in ipairs(self.list) do
        local c = ev.def.cond
        local need = c.flags or 0
        if c.condition == 32 and not ev.done and bit.band(self.flagMask, need) == need and c.target == icon then
            self:run(ev, self.world.player)
        end
    end
end

-- Effects ---------------------------------------------------------------------------------

-- Sides an effect applies to (original owner types).
---@param ef ScnEventEffect
---@param side integer the side the event fired for
---@param onlyLive boolean?
---@return integer[]
function Events:owners(ef, side, onlyLive)
    local out = {}
    for i = 0, 5 do
        local sd = self.world.sides[i]
        local pick
        local t = ef.ownerType
        if t == 0 then pick = true
        elseif t == 1 then pick = i == side
        elseif t == 2 then pick = i ~= side
        elseif t == 3 then pick = i == ef.ownerData
        elseif t == 4 then pick = i ~= ef.ownerData end
        if pick and sd.used and not (onlyLive and sd.defeated) then out[#out + 1] = i end
    end
    return out
end

---@param world World
---@param side integer
---@param code string?
---@param count integer
---@param gx integer
---@param gy integer
---@param name string?
local function spawn(world, side, code, count, gx, gy, name)
    if not code or not gamedata.army(code) then return end
    for i = 1, math.max(1, count) do
        local x, y = world:nearestFree(gx + (i % 3) - 1, gy + math.floor(i / 3), 0, 8)
        if x then
            ---@cast y -nil
            local u = world:addUnit(code, side, x, y, name and { name = name } or nil)
            if u and name then u.name = name end
        end
    end
end

local function uncover(world, gx, gy, radius, pick)
    local r = math.max(1, radius)
    require("src.game.fog").uncoverSim(world, gx, gy, r, pick)      -- the simulation's fog of every side that qualifies
    local fog = world.fog
    if not fog then return end
    for y = math.max(0, gy - r), math.min(fog.h - 1, gy + r) do
        for x = math.max(0, gx - r), math.min(fog.w - 1, gx + r) do
            fog.explored[y * fog.w + x] = 1
        end
    end
    fog.dirty = true
    fog.uncovered = true
end

local function ring(world, ef, r, col, dur)
    world.effects = world.effects or {}
    world.effects[#world.effects + 1] = { kind = "ring", x = ef.x * 32 + 16, y = ef.y * 24 + 12, r = r, col = col,
                                          t0 = world.time, dur = dur or 800 }
end

local function defeat(self)
    local world = self.world
    if not world.over then
        world.sides[world.player].defeated = true
        world.over = { winners = {} }
        world:event("gameover", {})
    end
end

local function named(world, name, fn)
    for _, u in ipairs(world.units) do
        if u:alive() and u.name == name then fn(u) end
    end
    for _, b in ipairs(world.buildings) do
        if b.hp > 0 and b.name == name then fn(b) end
    end
end

-- The effect handlers by effect number.
---@type table<integer, fun(self: Events, e: ScnEvent, ef: ScnEventEffect, side: integer)>
local H = {}

H[0] = function(self, e, ef, side)
    local world = self.world
    local half = ef.location or 0
    local owner = {}
    for _, s in ipairs(self:owners(ef, side)) do owner[s] = true end
    local function inside(o) return math.abs(o.gx - ef.x) <= half and math.abs(o.gy - ef.y) <= half end
    for _, u in ipairs(world.units) do
        if u:alive() and owner[u.side] and inside(u) then u:takeDamage(ef.number, nil) end
    end
    for _, b in ipairs(world.buildings) do
        if b.hp > 0 and owner[b.side] and inside(b) then world:damageBuilding(b, ef.number, nil) end
    end
end

H[1] = function(self, e, ef, side)
    local res = RESOURCES[ef.type or 0]
    if not res then return end
    for _, s in ipairs(self:owners(ef, side)) do
        local sd = self.world.sides[s]
        local cap = math.max(self.world.eco:cap(s), 100)
        if ef.number >= 0 then sd[res] = math.min(math.max(cap, sd[res]), sd[res] + ef.number)
        else sd[res] = math.max(0, sd[res] + ef.number) end
    end
end

H[2] = function(self, e, ef) self:setFlag(ef.number, ef.type ~= 1) end

H[3] = function(self)
    local world = self.world
    if not world.over then
        world.over = { winners = { world.player } }
        world:event("gameover", { world.player })
    end
end

H[4] = defeat
H[18] = defeat

H[5] = function(self, e, ef, side)
    for _, s in ipairs(self:owners(ef, side, true)) do
        spawn(self.world, s, codeOf(ef.type), ef.number, ef.x, ef.y)
    end
end

H[6] = function(self, e, ef)
    local world = self.world
    local kind = ef.type or 0
    if kind == 2 then
        local x, y = ef.x * 32 + 16, ef.y * 24 + 12
        world.effects = world.effects or {}
        world.effects[#world.effects + 1] = { kind = "bolt", x0 = x + 20, y0 = y - 260, x1 = x, y1 = y, col = { 0.9, 0.9, 1 },
                                              t0 = world.time, dur = 500, seed = ef.x * 31 + ef.y }
        ring(world, ef, 40, { 0.9, 0.9, 1 }, 500)
    elseif kind == 1 then ring(world, ef, 100, { 0.5, 0.8, 1 })
    elseif kind == 3 then ring(world, ef, 40, { 1, 1, 0.6 }, 1000)
    elseif kind == 4 then ring(world, ef, 70, { 1, 0.3, 0.1 }, 700)
    elseif kind == 5 then ring(world, ef, 80, { 0.8, 0.8, 0.8 }, 1200)
    else ring(world, ef, 100, { 1, 0.55, 0.15 }) end
end

H[7] = function(self, e, ef, side)
    self.world:event("sound", ef.text, side, ef)
end

H[9] = function(self, e, ef)
    if ef.text and ef.text:find("%s") then self.world:event("message", ef.text) end
end

H[12] = function(self, e, ef)
    local code = codeOf(ef.type)
    if code then self.world:addFeature({ code = code, x = ef.x * 32 + 16, y = ef.y * 24 + 12, anim = 0, dir = 0, frame = 0 }) end
end

H[13] = function(self, e, ef)
    local world = self.world
    local code = codeOf(ef.type)
    local best, bd
    for _, f in ipairs(world.features) do
        if f.code == code then
            local d = (f.gx - ef.x) ^ 2 + (f.gy - ef.y) ^ 2
            if not bd or d < bd then best, bd = f, d end
        end
    end
    if best then world:removeFeature(best) end
end

H[14] = function(self, e, ef, side)
    for _, s in ipairs(self:owners(ef, side)) do
        local hero = self.world.eco:heroAlive(s)
        if hero and hero.h then hero.h.mana = math.min(hero.h.mod.mana, (hero.h.mana or 0) + ef.number) end
    end
end

-- the storm event (network handler FUN_004ae220): level 0 / 1 / 2 (anything else does nothing), type 1 with lightning
H[15] = function(self, e, ef)
    local level = ef.number
    if level and level >= 0 and level <= 2 then require("src.game.weather").setRain(self.world, level, ef.type == 1) end
end

H[16] = function(self) require("src.game.weather").finishRain(self.world) end

-- the time-of-day event (network handler FUN_004ae290): type 0 goes to night (when it is day), else to day (when it is night); `number` is
-- the length of the change in seconds
H[17] = function(self, e, ef)
    local world, weather = self.world, require("src.game.weather")
    if ef.type == 0 then
        if not world.night then weather.dayToNight(world, ef.number or 0) end
    elseif world.night then
        weather.nightToDay(world, ef.number or 0)
    end
end

H[20] = function(self, e, ef)
    spawn(self.world, ef.ownerData, codeOf(ef.type), 1, ef.x, ef.y, ef.text ~= "" and ef.text or nil)
end

-- 21 / 22: the tutorial dialog (picture <name>.bmp of DialogData.xcr, text [<name>_TEXT] of Tutorial.cfg; type 1 plays a
-- bing); 22 sets flag `number` when the player closes it. 29: a text box with a pointer line over the open
-- production / construction dialog (the text is "At(x,y) Corner(c) To(x,y) "..."").
local function popup(self, e, ef)
    if ef.text == "" then return end
    local text = require("src.game.strings").get("Tutorial.cfg", ef.text .. "_TEXT")
    if not text then return end
    if ef.effect == 29 then
        self.world:event("overlay", text, ef.type == 1)
    else
        self.world:event("tutorial", ef.text, text, ef.type == 1, ef.effect == 22 and ef.number or nil)
    end
end
H[21], H[22], H[29] = popup, popup, popup

H[23] = function(self, e, ef, side)
    self.world:event("scroll", ef.x, ef.y, ef.type ~= 0, side)
end

H[24] = function(self, e, ef)
    if ef.text == "" or ef.text == "Null" then return end
    named(self.world, ef.text, function(o) o.side = ef.number end)
end

H[25] = function(self, e, ef, side)
    local player = self.world.player
    -- the local player's screen fog, and the simulation's fog of every human side the same test lets through
    local function owns(s) return not (ef.ownerData >= 0 and ef.ownerData ~= s and ef.ownerData ~= 6 and side ~= s) end
    if not owns(player) then
        require("src.game.fog").uncoverSim(self.world, ef.x, ef.y, math.max(1, ef.number), owns)
        return
    end
    uncover(self.world, ef.x, ef.y, ef.number, owns)
end

H[26] = function(self, e, ef)
    if ef.text and ef.text ~= "" then self.world:event("conversation", ef.text) end
end

H[27] = function(self, e, ef)
    self.clock = { total = math.min(99 * 60, (ef.location or 0) * 60) * 1000, t0 = self.world.time, flag = ef.number }
    self.world.clock = self.clock
end

H[28] = function(self, e, ef)
    local name = ef.text:lower()
    for _, u in ipairs(self.world.units) do
        if u:alive() and not u.hero and u.name:lower() == name then u:vanish(true) end
    end
end

H[30] = function(self, e, ef)
    local sd = self.world.sides[ef.location]
    if sd then sd.aiLevel = ef.number end
end

local function counter(self, side)
    local c = self.counters[side]
    if not c then
        c = { active = false, value = 0 }
        self.counters[side] = c
    end
    return c
end
H[31] = function(self, e, ef) counter(self, ef.location).active = true end
H[32] = function(self, e, ef) counter(self, ef.location).active = false end
H[33] = function(self, e, ef) counter(self, ef.location).value = ef.number end
H[34] = function(self, e, ef) local c = counter(self, ef.location) c.value = c.value + ef.number end

-- Running ---------------------------------------------------------------------------------

---@param ev EventState
---@param side integer
function Events:run(ev, side)
    local e = ev.def
    for _, ef in ipairs(e.effects) do
        local h = H[ef.effect]
        if h then
            local ok, err = pcall(h, self, e, ef, side)
            if not ok then log.warn("event %s effect %d: %s", tostring(e.code), ef.effect, tostring(err)) end
        end
    end
    ev.fired = ev.fired + 1
    local limit = e.shots
    local n = e.cond.condition
    if n == 0 and limit ~= 1 and (limit == 0 or ev.fired < limit) then
        ev.next = self.world.time + ((e.seconds or 0) + 1) * 1000
    elseif limit == 1 or (limit > 0 and ev.fired >= limit) then
        ev.done = true
    elseif n ~= 0 and not EDGE[n] then
        ev.done = true
    end
    -- the counts of built buildings and produced armies start over after the event has been served
    if n == 3 or n == 4 then
        local code = codeOf(e.cond.target)
        local st = n == 3 and self.stats.built or self.stats.produced
        st[side .. ":" .. (code and (n == 3 and code:sub(1, 4) or code) or "*")] = nil
    end
end

-- Armies that scripted events are about to add soon (a side without units yet is not defeated).
---@return boolean
function Events:pendingSpawns()
    for _, ev in ipairs(self.list) do
        local e = ev.def
        if not ev.done and (e.cond.condition == 0 or e.cond.condition == 1 or e.cond.condition == 2) then
            for _, ef in ipairs(e.effects) do
                if (ef.effect == 5 or ef.effect == 20)
                    and (e.cond.condition ~= 0 or ((e.seconds or 0) * 1000 <= 30000 and ev.fired == 0)) then
                    return true
                end
            end
        end
    end
    return false
end

---@param t number world time
function Events:update(t)
    if t < self.nextCheck then return end
    self.nextCheck = t + 250
    local clock = self.clock
    if clock and t - clock.t0 >= clock.total then
        if clock.flag and clock.flag >= 0 then self:setFlag(clock.flag) end
        self.clock, self.world.clock = nil, nil
    end
    for _, ev in ipairs(self.list) do
        if not ev.done then
            local side = self:condition(ev, t)
            if EDGE[ev.def.cond.condition] then
                -- fires when the condition turns true
                local was = ev.was
                ev.was = side ~= nil
                if side and was then side = nil end
            end
            if side then self:run(ev, side) end
        end
    end
end

return M
