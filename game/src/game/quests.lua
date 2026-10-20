-- Shrine (BMSH) and mausoleum (BZMA) quests. Texts come from <Lang>/Quest.cfg, the
-- structured part from Quest.xcr/Bmsh.dat and Bzma.dat (208 byte header, 102 byte records):
--
--   +0 u16 time limit (s)     +2 u16 idle time (s)      +4 char[5] quest-giver picture
--   +9 u8 naming set          +10 u16 requirement kind  +12 u16 amount / count
--   +14 char[16] requirement (a resource letter, or a unit / building code)
--   +30..34 reward flags, one byte each: resources, character, armies, power-up, item
--   +36 u16 gold, +38 metal, +40 crystal, +42 stone
--   +44 char[5] character code  +50 u16 character experience
--   +52 u16 army count          +54 char[5] army code   +60 u16 army experience
--   +62 u8 army names, +63 u8 naming set for them       +64 char[5] power-up code
--   +78 u16 item index          +84..101 u16 chances [good/neutral/evil][common/profane/magical]
--
-- The header holds the number of quests at +6 and one used flag per quest from +8.
--
-- Requirement kinds (the +10 field, which FUN_0043dde0 switches on): 0 pay a resource, 1 kill N armies, 2 raze N buildings,
-- 3 convert N buildings, 4 give an answer, 5 kill an enemy hero, 6 kill N units of a type,
-- 7 raze N buildings of a type, 8 build a building type, 9 own a building type (built or
-- converted). The shipped sets only use kinds 0..3, 5, 6, 7 and 9 (checked in all 88 records of
-- both files, used or not, and Quest.cfg has no `_ANSW` keys), so kinds 4 and 8 only run for a
-- replaced Quest.xcr. Both are done anyway, from the 1.04 binary: kind 4 is the record's requirement text
-- (the answer; the original lets `[<set>_<nnn>_ANSW]` of Quest.cfg replace it, so the answer can be
-- localised), typed into the dialog's entry box (up to 15 characters, case-insensitive, the
-- dialog has no Accept button); a wrong answer closes the dialog with Game.txt 0327, a right one
-- turns it into the "quest complete" page; the quest is always legal and never counts. Kind 8
-- counts the buildings the side finishes of that type (legal when the side's race can build it,
-- and never for a temple).
--
-- Quest state belongs to a side, not to a building (the original's per-side quest table at 0x00744db8, 0x818 bytes a side): a side is
-- doing one quest at a time and several sides can be doing the same shrine's quest. A shrine
-- picks a quest the first time a hero visits it, and only among the quests this side could
-- actually finish (FUN_0043dde0); the pick is random and stays with the shrine until it
-- goes into its idle period, which happens when the side's time limit passes or the quest is
-- completed.
local vfs = require("src.vfs.vfs")
local config = require("src.core.config")
local fs = require("src.core.fs")
local text = require("src.core.text")
local gamedata = require("src.game.gamedata")
local rules = require("src.game.rules")
local items = require("src.game.items")
local powerups = require("src.game.powerups")
local log = require("src.core.log")

local M = {}

-- A quest of Quest.xcr (M.list): what it asks, what it gives and its texts.
---@class QuestDef
---@field id integer
---@field prefix string          the building type (BMSH, BZMA)
---@field name string
---@field naming integer         the quest giver's name set
---@field pic string?            the quest giver's picture
---@field newq string            texts: offer, progress, completion, instant completion, repeat
---@field cont string
---@field cmpl string
---@field inst string
---@field rept string
---@field time integer           seconds to do it
---@field idle integer           seconds the shrine rests afterwards
---@field req QuestReq
---@field reward QuestReward

---@class QuestReq
---@field kind integer           0 resource, 1 kill armies, 2 destroy buildings, 3 convert, 4 riddle, 5 kill heroes,
---                              6 kill a type, 7 destroy a type, 8 build, 9 convert / own a type
---@field n integer
---@field res string?            kind 0
---@field amount integer?        kind 0
---@field answer string?         kind 4
---@field code string?           the army / building type

---@class QuestReward
---@field res table<string, integer>?
---@field char {code: string?, xp: integer}?
---@field army {code: string?, count: integer, xp: integer, naming: integer, named: boolean}?
---@field powerup string?
---@field item integer?

-- A shrine's quest (Building.quest): "free", "held" (a quest picked, `expiry` when the offer lapses) or "recovery" (resting
-- until `expiry`).
---@class ShrineQuest
---@field state "free"|"held"|"recovery"
---@field id integer?
---@field prefix string?
---@field name string?           the quest giver's name
---@field expiry number?         world time (ms)

-- The quest a side's hero accepted (Side.quest).
---@class SideQuest
---@field id integer
---@field prefix string
---@field count integer          progress
---@field expiry number          world time (ms)
---@field srcId integer          the shrine (building id and side)
---@field srcSide integer
---@field name string?

-- The quests of one building type, by id, plus the used ids.
---@class QuestList
---@field count integer
---@field ids integer[]
---@field [integer] QuestDef

-- What M.visit returns for the dialog.
---@class QuestVisit
---@field title string
---@field mode "new"|"answer"|"instant"|"complete"|"continue"
---@field naming integer
---@field pic string?
---@field text string?
---@field buttons "accept"|"ok"|"answer"|nil
---@field done string?           the answer mode's completion text
---@field hint string?           the progress line

M.RESOURCES = require("src.content").resource:ids()
local PREFIX = { BMSH = "Bmsh.dat", BZMA = "Bzma.dat" }
local LETTER = { G = "gold", M = "metal", C = "crystal", S = "stone" }
-- (kind 8 may not ask for a temple: the tag `temple`)
local NEUTRAL = 6
local IDLE_FALLBACK = 240000   -- the original's 240 s when a quest building has no data

local cache = {}
local strings

local function dice(n)
    if n <= 0 then return 0 end
    return math.random(n) - 1
end

local function loadStrings()
    if strings then return end
    strings = {}
    local data = fs.read(config.gamedir .. "/" .. config.language .. "/Quest.cfg")
        or fs.read(config.gamedir .. "/English/Quest.cfg")
    if not data then
        log.warn("quests: Quest.cfg missing")
        return
    end
    data = text.fromCP1252(data)
    for key, value in data:gmatch("%[([%w_]+)%]\t([^\r\n]*)") do strings[key] = value end
end

local function u16(d, o) return d:byte(o + 1) + d:byte(o + 2) * 256 end

local function code(d, o)
    local s = d:sub(o + 1, o + 4)
    if s:match("^%u%u%u%u$") then return s end
    return nil
end

-- The quest giver's picture: a sprite code with a digit last ("ELE0", "HUM1").
local function pic(d, o)
    local s = d:sub(o + 1, o + 4)
    if s:match("^%u%u%u[%d%u]$") then return s end
    return nil
end

-- All quests of a building type, indexed from 0; ids lists the ones the set marks used.
---@param prefix string
---@return QuestList
function M.list(prefix)
    if cache[prefix] then return cache[prefix] end
    loadStrings()
    local list = { count = 0, ids = {} }
    cache[prefix] = list
    local d = vfs.read("Quest.xcr", PREFIX[prefix] or "")
    if not d then return list end
    local total = u16(d, 6)
    for id = 0, total - 1 do
        if d:byte(9 + id) ~= 0 then
            local o = 208 + id * 102
            local function s(kind) return strings[("%s_%03d_%s"):format(prefix, id, kind)] or "" end
            local q = { id = id, prefix = prefix, name = s("NAME"), naming = d:byte(o + 10),
                        pic = pic(d, o + 4), newq = s("NEWQ"), cont = s("CONT"), cmpl = s("CMPL"),
                        inst = s("INST"), rept = s("REPT"), time = u16(d, o), idle = u16(d, o + 2) }
            local kind, n = u16(d, o + 10), u16(d, o + 12)
            q.req = { kind = kind, n = math.max(1, n) }
            if kind == 0 then
                q.req.res = LETTER[d:sub(o + 15, o + 15):upper()] or "gold"
                q.req.amount = n
            elseif kind == 4 then
                q.req.answer = strings[("%s_%03d_ANSW"):format(prefix, id)] or d:sub(o + 15, o + 30):match("^[^%z]*")
            else
                q.req.code = code(d, o + 14)
            end
            local r = {}
            if d:byte(o + 31) ~= 0 then
                r.res = {}
                for i, k in ipairs(M.RESOURCES) do r.res[k] = u16(d, o + 36 + (i - 1) * 2) end
            end
            if d:byte(o + 32) ~= 0 then
                r.char = { code = code(d, o + 44), xp = u16(d, o + 50) }
            end
            if d:byte(o + 33) ~= 0 then
                r.army = { code = code(d, o + 54), count = u16(d, o + 52), xp = u16(d, o + 60),
                           naming = d:byte(o + 64), named = d:byte(o + 63) ~= 0 }
            end
            if d:byte(o + 34) ~= 0 then r.powerup = code(d, o + 64) end
            if d:byte(o + 35) ~= 0 then r.item = u16(d, o + 78) end
            q.reward = r
            list[id] = q
            list.ids[#list.ids + 1] = id
            list.count = list.count + 1
        end
    end
    return list
end

---@param prefix string
---@param id integer
---@return QuestDef?
function M.get(prefix, id)
    return M.list(prefix)[id]
end

-- The quest giver's portrait: a 128x160 BMP in Quest.xcr, drawn in the dialog. Only asked for
-- by the dialog, so this is the only place a graphics object is made.
local pictures = {}
---@param pic string?
---@return love.Image?
function M.picture(pic)
    if not pic then return nil end
    if pictures[pic] == nil then
        local bmp = require("src.formats.bmp")
        local data = vfs.read("Quest.xcr", pic .. ".bmp")
        pictures[pic] = data and (bmp.image(data)) or false
    end
    return pictures[pic] or nil
end

-- The quest attached to a building, or nil.
---@param b Building
---@return QuestDef?
function M.def(b)
    local q = b.quest
    return q and q.state == "held" and M.get(q.prefix, q.id) or nil
end

-- A name from a naming set (NamingSets\*.nam, read by FUN_00435060): the [RULES] section lists weighted recipes of
-- sections, e.g. "3 [NAME]" and "100 [SYL1] [SYL2]", and the last recipe always reaches 100.
-- The original (the name picker, 1.04 binary FUN_00434e90) remaps the set index through a 16 entry
-- table for every language but English (its language DAT_00a27d7a is not 0): Evil and Barbarian male / female
-- become GenericEvil, Draconic stays, everything else becomes Standard. The table sits at
-- 0x608618 as u16 values and was read from there. A name file that cannot be read gives "Sirian".
local NAMESETS = { "Standard", "GenericEvil", "KnightlyMale", "KnightlyFemale", "HumanMale", "HumanFemale",
                   "ElvenMale", "ElvenFemale", "DwarvenMale", "DwarvenFemale", "WizardMale", "WizardFemale",
                   "BarbarianMale", "BarbarianFemale", "Draconic", "Fey" }
local LOCALISED = { [0] = 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 14, 0 }
local nameSets = {}

-- The name set index in use: the asked one, remapped for languages other than English.
---@param set integer?
---@param language string?
---@return integer
function M.nameSetIndex(set, language)
    local i = (set or 0) % #NAMESETS
    if (language or config.language) ~= "English" then i = LOCALISED[i] end
    return i
end

-- A fresh name of a set; the parsed file is kept.
---@param set integer?
---@return string?
function M.nameFromSet(set)
    local key = NAMESETS[M.nameSetIndex(set) + 1]
    local parsed = nameSets[key]
    if parsed == nil then
        parsed = false
        local data = fs.read(config.gamedir .. "/NamingSets/" .. key .. ".nam")
            or fs.read(config.gamedir .. "/NamingSets/Standard.nam")
        if data then
            data = text.fromCP1252(data)
            local sections, cur
            for line in (data .. "\n"):gmatch("(.-)\r?\n") do
                local name = line:match("^%[([%w_]+)%]$")
                if name then
                    if not sections then
                        sections = {}
                        cur = {}
                        sections[name:upper()] = cur
                    else
                        cur = sections[name:upper()]
                        if not cur then cur = {}; sections[name:upper()] = cur end
                    end
                elseif cur and line ~= "" then
                    cur[#cur + 1] = line
                end
            end
            local recipes = sections and sections["RULES"]
            if recipes then
                local compiled = {}
                for _, line in ipairs(recipes) do
                    local chance, rest = line:match("^(%d+)%s+(.-)%s*$")
                    if chance then
                        local secs = {}
                        for s in rest:gmatch("%[([%w_]+)%]") do
                            if sections[s:upper()] then secs[#secs + 1] = sections[s:upper()] end
                        end
                        if secs[1] then
                            compiled[#compiled + 1] = { chance = tonumber(chance), secs = secs }
                        end
                    end
                end
                if compiled[1] then
                    compiled[#compiled].chance = 100
                    parsed = compiled
                end
            end
        end
        nameSets[key] = parsed
    end
    if not parsed then return "Sirian" end
    local roll = dice(100)
    local use = parsed[#parsed]
    for _, rec in ipairs(parsed) do
        if rec.chance > roll then use = rec; break end
    end
    local out = ""
    for _, list in ipairs(use.secs) do
        if #list > 0 then out = out .. list[math.random(#list)] end
    end
    if out == "" then return nil end
    return out
end

-- Quests ---------------------------------------------------------------------------------

-- Can this side actually do this quest? (FUN_0043dde0 in the 1.04 binary; it makes no percentage
-- roll against the record's chances, so legality alone decides.) A power-up reward the side
-- already owns makes the quest illegal.
local requirementLegal
---@param world World
---@param side integer
---@param def QuestDef
---@return boolean
local function legal(world, side, def)
    if not requirementLegal(world, side, def) then return false end
    local code = def.reward and def.reward.powerup
    if code and powerups.has(world.sides[side], code) then return false end
    return true
end

---@param world World
---@param side integer
---@param def QuestDef
---@return boolean
function requirementLegal(world, side, def)
    local r = def.req
    local n = r.n
    if r.kind == 0 then
        return true
    elseif r.kind == 1 then
        local count = 0
        for _, u in ipairs(world.units) do
            if u.side ~= side and u:alive() then count = count + 1 end
        end
        return count >= math.floor(8 * n / 10) and count > 0
    elseif r.kind == 2 or r.kind == 3 then
        local count = 0
        for _, b in ipairs(world.buildings) do
            if b.side ~= side and b.hp > 0 then count = count + 1 end
        end
        return count >= n
    elseif r.kind == 4 then
        return true
    elseif r.kind == 5 then
        local count = 0
        for i = 0, NEUTRAL do
            if i ~= side and world.sides[i].used and not world.sides[i].defeated
                and world.eco:heroAlive(i) then count = count + 1 end
        end
        return count >= n and count > 0
    elseif r.kind == 6 then
        if not r.code then return false end
        local count = 0
        for _, u in ipairs(world.units) do
            if u.side ~= side and u:alive() and u.code == r.code then count = count + 1 end
        end
        return count >= math.floor(9 * n / 10) and count > 0
    elseif r.kind == 7 then
        if not r.code then return false end
        local count = 0
        for _, b in ipairs(world.buildings) do
            if b.side ~= side and b.hp > 0 and b.code == r.code then count = count + 1 end
        end
        return count >= n and count > 0
    elseif r.kind == 8 then
        return not gamedata.hasTag(r.code, "temple") and M.buildable(world.sides[side].race or 0, r.code)
    elseif r.kind == 9 then
        if not gamedata.hasTag(r.code, "temple") and M.buildable(world.sides[side].race or 0, r.code) then return true end
        -- (only here the original skips allied sides)
        local count = 0
        for _, b in ipairs(world.buildings) do
            if b.side ~= side and b.hp > 0 and b.code == r.code
                and (b.side == NEUTRAL or world:enemies(side, b.side)) then count = count + 1 end
        end
        return count >= n and count > 0
    end
    return false
end

---@param race integer
---@param code string?
---@return boolean
function M.buildable(race, code)
    if not code then return false end
    for _, e in ipairs(rules.buildList(race)) do
        if e.id == code then return true end
    end
    return false
end

-- Offers a quest at this building if it has none: a random one this side can finish.
local function select(world, side, b)
    if b.quest and b.quest.state == "recovery" then return false end
    local list = M.list(b.code)
    if list.count == 0 then return false end
    local ok = {}
    for _, id in ipairs(list.ids) do
        if legal(world, side, list[id]) then ok[#ok + 1] = id end
    end
    if #ok == 0 then return false end
    local id = ok[dice(#ok) + 1]
    local def = list[id]
    -- the quest giver's name is drawn once, when the shrine picks the quest (the original fills it into
    -- every text then); the character reward carries the same name
    b.quest = { state = "held", id = id, prefix = b.code, name = M.nameFromSet(def.naming),
                expiry = world.time + def.time * 1000 + 20000 }
    return true
end

-- The side's own quest, or nil.
local function held(world, side) return world.sides[side].quest end

---@param world World
---@param side integer
---@param def QuestDef
---@return boolean
local function met(world, side, def)
    local r = def.req
    if r.kind == 0 then
        return (world.sides[side][r.res] or 0) >= r.amount
    elseif r.kind == 9 then
        -- the original asks whether the side owns such a building
        for _, b in ipairs(world.buildings) do
            if b.side == side and b.hp > 0 and b.code == r.code then return true end
        end
        return false
    end
    local q = held(world, side)
    return q ~= nil and r.kind ~= 4 and q.count >= r.n
end
M.met = met

-- A typed answer to a kind 4 quest (the dialog's answer check FUN_0056b740): equal to the answer when case is ignored.
---@param def QuestDef?
---@param text string?
---@return boolean
function M.rightAnswer(def, text)
    return def ~= nil and def.req.kind == 4 and def.req.answer ~= nil and text ~= nil
        and text:lower() == def.req.answer:lower()
end

-- The most characters the answer box takes (the original's buffer holds 16 bytes with the terminator).
M.MAX_ANSWER = 15

-- Counts an event for the sides whose quest it advances (FUN_0043db30). The building events
-- carry the side that did them: "destroyed" a building with a.razedBy, "converted" a building
-- that now belongs to a.side, "built" a building.
---@param world World
---@param kind string
function M.onEvent(world, kind, a, b, c)
    if kind == "visit" and a and a.hero and b and b.quest then M.offer(world, a, b) end
    for side = 0, NEUTRAL do
        local q = world.sides[side].quest
        if q then
            local def = M.get(q.prefix, q.id)
            local r = def and def.req
            if r then
                local k, count = r.kind, false
                if kind == "kill" and a and a.side == side and b then
                    local enemy = b.side ~= side and (b.side == NEUTRAL or world:enemies(side, b.side))
                    if enemy and (k == 1 or (k == 5 and b.hero) or (k == 6 and b.code == r.code)) then
                        count = true
                    end
                elseif kind == "destroyed" and (k == 2 or k == 7) then
                    local by = a and a.razedBy
                    if by == side and a.side ~= side and (a.side == NEUTRAL or world:enemies(side, a.side))
                        and (k == 2 or a.code == r.code) then
                        count = true
                    end
                elseif kind == "converted" and (k == 3 or k == 9) then
                    if a.side == side and a.side ~= NEUTRAL and (k == 3 or a.code == r.code) then
                        count = true
                    end
                elseif kind == "built" and (k == 8 or k == 9) then
                    if a.side == side and a.code == r.code then count = true end
                end
                if count then q.count = q.count + 1 end
            end
        end
    end
end

-- Timers: a quest nobody is doing any more expires and the shrine goes idle; an idle shrine
-- offers one again when its period ends (the building's periodic update FUN_0052c250). A side's quest is
-- dropped when its own time limit passes or when the shrine it came from is gone or changed
-- owner (the army's periodic update FUN_0051c7d0).
---@param world World
---@param t number
function M.update(world, t)
    for _, b in ipairs(world.buildings) do
        local q = b.quest
        if q and b.hp > 0 then
            if q.state == "held" then
                local someone = false
                for side = 0, NEUTRAL do
                    local sd = world.sides[side].quest
                    if sd and sd.srcId == b.id and sd.srcSide == b.side then
                        someone = true
                        break
                    end
                end
                if not someone and t >= q.expiry then
                    local def = M.get(q.prefix, q.id)
                    b.quest = { state = "recovery", expiry = t + (def and def.idle * 1000 or IDLE_FALLBACK) }
                end
            elseif q.state == "recovery" and t >= q.expiry then
                b.quest = { state = "free" }
            end
        end
    end
    for side = 0, NEUTRAL do
        local q = world.sides[side].quest
        if q then
            local src
            for _, b in ipairs(world.buildings) do
                if b.id == q.srcId and b.side == q.srcSide then src = b; break end
            end
            if t > q.expiry or not src then
                world.sides[side].quest = nil
                if side == world.player then world:event("questexpired", side) end
            end
        end
    end
end

-- A hero visits a shrine or mausoleum (the "visit" event, run by every peer): the building picks its quest
-- for the visitor's side if it has none. The pick draws random numbers (the quest, the quest giver's name), so
-- it belongs to the simulation and not to the dialog that shows it. Only human sides take quests (the computer
-- players never visit for one). Returns whether the building now holds a quest.
---@param world World
---@param hero Unit
---@param b Building
---@return boolean
function M.offer(world, hero, b)
    if not b.quest or not world.humans[hero.side] then return false end
    if b.quest.state ~= "held" then return select(world, hero.side, b) end
    return true
end

-- What a visit shows: { title, text, hint, buttons, mode }. Also says why nothing is shown. It only reads the
-- world (the quest was picked by `offer` when the hero arrived). `readonly` is for a hero that is not at the
-- shrine (the quest key): a finished quest then shows its progress page instead of the completion.
---@param world World
---@param hero Unit
---@param b Building
---@param readonly boolean?
---@return QuestVisit?
---@return string? why "none" | "busy"
function M.visit(world, hero, b, readonly)
    local side = hero.side
    if not b.quest or b.quest.state ~= "held" then return nil, "none" end
    local def = M.get(b.quest.prefix, b.quest.id)
    if not def then return nil, "none" end
    local q = held(world, side)
    local here = q ~= nil and q.srcId == b.id and q.srcSide == b.side
    local mode
    if here and met(world, side, def) and not readonly then
        mode = "complete"
    elseif here then
        mode = "continue"
    elseif q then
        return nil, "busy"
    elseif def.req.kind == 0 and met(world, side, def) then
        mode = "instant"
    else
        mode = "new"
    end
    local name = b.quest.name or ""
    local function fill(str)
        return (str:gsub("~NAME~", function() return name end))
    end
    local info = { title = fill(def.name), mode = mode, naming = def.naming, pic = def.pic }
    if mode == "new" and def.req.kind == 4 then
        -- no Accept button: the answer is typed into a box, and a right one shows the "complete" page
        info.text, info.mode, info.buttons, info.done = fill(def.newq), "answer", "answer", fill(def.cmpl)
    elseif mode == "new" then
        info.text, info.buttons = fill(def.newq), "accept"
    elseif mode == "instant" then
        info.text, info.buttons = fill(def.inst), "accept"
    elseif mode == "complete" then
        info.text, info.buttons = fill(def.cmpl), "ok"
    else
        info.text, info.buttons = fill(def.cont), "ok"
        -- the "Your count" line of the dialog (Game.txt 0325): the side's stock for a resource
        -- quest, the counted events otherwise; the original draws no such line for a kind 4 quest
        if def.req.kind ~= 4 then
            local fmt = require("src.game.strings").get("Game.txt", "0325") or "Progress: %d of %d"
            local have = def.req.kind == 0 and (world.sides[side][def.req.res] or 0) or q.count
            info.hint = fmt:format(have, def.req.kind == 0 and def.req.amount or def.req.n)
        end
    end
    return info
end

-- The player accepts the quest (FUN_0043d350).
---@param world World
---@param hero Unit
---@param b Building
---@param quiet boolean?
---@return boolean
function M.accept(world, hero, b, quiet)
    local def = M.def(b)
    if not def or def.req.kind == 4 or held(world, hero.side) then return false end
    local side = hero.side
    world.sides[side].quest = { id = def.id, prefix = def.prefix, count = 0,
                                expiry = world.time + def.time * 1000,
                                srcId = b.id, srcSide = b.side, name = b.quest.name }
    b.quest.expiry = world.time + def.time * 1000 + 20000
    world:event("questaccepted", hero, b, quiet)
    return true
end

-- Hands out the reward and puts the shrine back to idle (FUN_0043d560); returns the
-- lines the dialog shows. `answered` is for a kind 4 quest, which the side never accepts: the dialog
-- has checked the typed answer (the original keeps no side quest for it either).
---@param world World
---@param hero Unit
---@param b Building
---@param answered boolean?
---@return string[]? lines
function M.complete(world, hero, b, answered)
    local side = hero.side
    local sd = world.sides[side]
    local q = sd.quest
    local def = M.def(b)
    if not def then return nil end
    if def.req.kind == 4 then
        if not answered or q then return nil end
        q = { id = def.id, prefix = def.prefix, count = 0, expiry = world.time, srcId = b.id, srcSide = b.side,
              name = b.quest.name }
    elseif not q or not met(world, side, def) then
        return nil
    end
    local lines = {}

    -- everybody else doing this quest at this shrine missed out
    for other = 0, NEUTRAL do
        if other ~= side then
            local oq = world.sides[other].quest
            if oq and oq.srcId == q.srcId and oq.srcSide == q.srcSide then
                world.sides[other].quest = nil
                if other == world.player then world:event("questlost", other) end
            end
        end
    end

    if def.req.kind == 0 then
        sd[def.req.res] = math.max(0, (sd[def.req.res] or 0) - def.req.amount)
    end

    local r = def.reward
    if r.res then
        for _, k in ipairs(M.RESOURCES) do
            local amount = r.res[k] or 0
            if amount > 0 then
                sd[k] = (sd[k] or 0) + amount
                lines[#lines + 1] = ("+%d %s"):format(amount, k)
            end
        end
    end
    local function spawn(what, xp, n, name)
        if not what or not gamedata.army(what) then return 0 end
        local move = (gamedata.army(what) or {}).moveType or 0
        local made = 0
        for i = 1, math.max(1, n) do
            local x, y = world:nearestFree(hero.gx + (i % 3) - 1, hero.gy + 1 + math.floor(i / 3), move, 8)
            -- every army of a named reward gets a fresh name from the set (FUN_00434e90 per army)
            local nm = type(name) == "function" and name() or name
            -- nearestFree gives both coordinates or neither
            ---@cast y integer
            if x and world:addUnit(what, side, x, y, { xp = xp, name = nm }) then made = made + 1 end
        end
        return made
    end
    if r.army then
        local made = spawn(r.army.code, r.army.xp, r.army.count,
                           r.army.named and function() return M.nameFromSet(r.army.naming) end or nil)
        if made > 0 then
            lines[#lines + 1] = ("%d x %s"):format(made, rules.unitName(r.army.code, gamedata.army(r.army.code)))
        end
    end
    if r.char then
        -- the character is named after the quest giver
        local made = spawn(r.char.code, r.char.xp, 1, q.name or M.nameFromSet(def.naming))
        if made > 0 then
            lines[#lines + 1] = rules.unitName(r.char.code, gamedata.army(r.char.code))
        end
    end
    if r.item then
        -- the original leaves it on the ground at the hero, in a chest
        local it = items.get(r.item)
        if it then
            world:dropItem(hero.gx, hero.gy, it)
            lines[#lines + 1] = it.name
        end
    end
    if r.powerup and powerups.grant(world, side, r.powerup) then
        lines[#lines + 1] = "power-up"
    end

    sd.quest = nil
    sd.questsCompleted = (sd.questsCompleted or 0) + 1
    b.quest = { state = "recovery", expiry = world.time + (def.idle * 1000) }
    if hero.h then
        local levels = hero.h:addXp(powerups.questXp(sd))
        if levels > 0 then world:event("levelup", hero, levels) end
    end
    world:event("questdone", hero, b)
    return lines
end

-- The quest commands (commands.lua, { t = "quest", op, bid, hero, answer }): the dialog only asks, the simulation
-- does it, so every peer gives the same reward at the same tick.
--   accept    the hero takes the quest of the shrine; a resource quest the side can already pay is finished at once
--   complete  the hero hands the finished quest in; for a kind 4 quest `answer` is the typed text, which must be
--             right (the dialog has shown the "complete" page for it, but the simulation checks it again)
-- The hero must be alive, the side's own, and standing at the shrine (the visit range plus one cell).
local NEAR = 3

---@param world World
---@param side integer
---@param cmd Command
---@return boolean
function M.command(world, side, cmd)
    local hero, b
    for _, u in ipairs(world.units) do
        if u.id == cmd.hero then hero = u break end
    end
    for _, x in ipairs(world.buildings) do
        if x.id == cmd.bid then b = x break end
    end
    if not hero or hero.side ~= side or not hero.hero or not hero:alive() or not b or b.hp <= 0 or not b.quest then
        return false
    end
    if hero:cellDistance(b) > NEAR then return false end
    local def = M.def(b)
    if not def then return false end
    if cmd.op == "accept" then
        local instant = def.req.kind == 0 and met(world, side, def)
        if not M.accept(world, hero, b, instant) then return false end
        if instant then M.complete(world, hero, b) end
        return true
    elseif cmd.op == "complete" then
        return M.complete(world, hero, b, M.rightAnswer(def, cmd.answer)) ~= nil
    end
    return false
end

return M
