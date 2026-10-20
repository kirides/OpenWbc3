-- Unit attitudes (stances): how a unit behaves while nothing orders it around. An attitude is a rule set, as in the
-- original (the attitude system of the 1.04 binary): an active area (cells around the unit's guard point), up
-- to 10 rules and an idle action, an icon, "needs a designated unit" and "casts spells on its own". A rule is up to 5
-- conditions, one action and a priority; the rule with the highest priority whose conditions all hold runs, and when no
-- rule holds the idle action runs (the per-army update FUN_005070f0, the rule test FUN_00507560, the conditions and
-- actions). The nine built-in attitudes (FUN_00505cc0 wimp ... FUN_00506180 standard) are written down below with
-- the original's numbers, the custom ones come from CustomUnitAI/*.uai (formats/uai.lua) and are listed after them under the file's root name.
--
-- Conditions (code): 0 has immediate threats (enemies in a box of max(12, range) cells around the subject), 1 has guard
-- threats (the same box around the subject's guard point), 2 is alive, 3 / 4 is attacking an enemy building / army,
-- 5 damaged below threshold %, 6 under attack (hit list), 7 has threats in attack range, 8 is within threshold cells of
-- me; the subject is me (0), my hero (1) or the designated unit (2), and a missing subject fails the rule. "Active area"
-- additionally limits the boxes to the area around the guard point. Actions: 0 return to base, 1 follow the unit,
-- 2 protect the unit, 3 stand ground, 4 run from attackers, 5 / 6 handle immediate / guard threats, 7 random movement
-- (in the active area or over the whole map), 8 scout the perimeter of the area, 9 move to the guard point, 10 run from
-- threats (enemies within 5 cells of the subject).
--
-- When units are evaluated (checked in the 1.04 binary): the timer of the main loop (a 25 ms multimedia timer set up
-- in FUN_00457190) sends a frame message and every 10th one runs the AI slice (FUN_00429ec0: counter DAT_0074c590 mod
-- 10) = every 250 ms: FUN_00505310 gives ONE computer side its turn, round robin over the seven side slots, and that
-- side's think (FUN_004fa120) starts with the side's threat handling (FUN_00532530); then the threat handling of the
-- local side and, except in the tutorial, of the neutral side. The threat handling walks the side's list, skips armies
-- that are off the map (garrisoned) and calls the attitude update (FUN_005070f0) for every army, whatever it does, and
-- the buildings' own threat search for buildings. Nothing evaluates a unit between those slices: a hit unit only gets
-- its "has been hit" flag (army +0x1b8; the damage intake 0x00522af0 sets no order), it reacts at its next evaluation.
-- M.update marks the sides whose turn it is, a unit evaluates once per mark as soon as it is idle / walking / attacking (unit.lua).
--
-- Threats are found by the threat search (FUN_005334f0 with the threat priority FUN_00533c40, checked in the 1.04
-- binary): the enemy army (neutral armies too, critters never)
-- or building (not the neutral ones, except towers at priority 21) of the box with the highest priority - 50 + (11 -
-- distance) when within 25 cells, +30 when it goes after my side (a tower: after my own side), -40 when it cannot
-- attack - the first one in the original's scan order winning a tie. Mines, lairs, shops (building codes BR / BL / BS)
-- and the flag in capture the flag are never threats. A human side only finds what its fog shows (fog.lua) and skips
-- buildings under conversion (walls are targets: the 1.04 binary has no wall test). The animals are prey for
-- a few hunters (huntPriority): wounded Minotaurs, the Troll, the Catapult, the daemons with little mana. The critters
-- themselves rest and wander as the critter reaction FUN_0051a230 does (critterRest).
--
-- How openwbc3 differs from the original (own choices, not verified in the game):
--  * the fog test uses a fog of every human side that the simulation computes itself at the attitude slices (the original
--    asks the screen's fog of its one local player at every frame, with the smoothed edge cells of the picture); the
--    building "has been visible" flag is set from the same fog at the slices instead of by the drawing code;
--  * a unit is found by its own cell (the original's map holds a big army in every cell it covers);
--  * the hit list entries of every human side are kept (the original notes the hits on the local side's units only,
--    here every side without a computer player is "the local one"), entries live 4 s and are saved;
--  * an order of the player is not touched by rules that do not override player orders (the original's player
--    order priority that nothing may divert); the 'Magic' attitudes cast through spells.aiThink, which only heroes have.
-- The original's active area box (FUN_00508d00) is max(mapHeight - 1, y + size) at the bottom (a typo for min, kept:
-- the area then runs down to the map edge) and the "has guard threats" box of a unit without guard point uses the position of the
-- evaluating unit, not of the subject.
local strings = require("src.game.strings")
local fogs = require("src.game.fog")

local M = {}

M.CONDITION = { THREATS = 0, GUARD_THREATS = 1, ALIVE = 2, ATTACKING_BUILDING = 3, ATTACKING_ARMY = 4, DAMAGED = 5,
                UNDER_ATTACK = 6, THREATS_IN_RANGE = 7, NEAR = 8 }
M.ACTION = { RETURN_TO_BASE = 0, FOLLOW = 1, PROTECT = 2, STAND_GROUND = 3, RUN_FROM_ATTACKERS = 4, HANDLE_THREATS = 5,
             HANDLE_GUARD_THREATS = 6, RANDOM_MOVE = 7, SCOUT = 8, MOVE_TO_CENTRE = 9, RUN_FROM_THREATS = 10 }
-- attitude icons: the icons of SkillIcons.bmp (80 + 16 * index, 40), flag first
M.ICONS = { "flag", "tower", "statue", "swords", "chaos", "cross", "staff", "key", "boot", "spyglass", "question", "scroll" }

local C, A = M.CONDITION, M.ACTION
local ME, HERO, DESIGNATED = 0, 1, 2

M.DEFAULT = "standard"

-- The attitudes are `attitude` records (content/base/attitudes.lua for the nine built-in ones, src/import/wbc3/attitudes.lua for the install's
-- CustomUnitAI/*.uai files, mods): M.LIST is the ids in the order of the interface, M.def maps an id to
-- { ai = the record { size, rules, idle, icon, designated, spells }, text, title, desc, designated, spells, icon, custom, hitRules }.
-- Both tables are refilled whenever the registry has been built.
-- An attitude as the interface and the update use it.
---@class AttitudeDef
---@field ai AttitudeRecord          the record (size, rules, idle, icon, designated, spells)
---@field text string?               Game.txt key of the name (built-in attitudes)
---@field title string?              a custom attitude's own name
---@field desc string?
---@field designated boolean         guards a designated unit
---@field spells boolean             the unit casts its spells
---@field icon integer?
---@field custom boolean             from a CustomUnitAI/*.uai file
---@field hitRules boolean?          a rule asks "under attack" (the hit list is kept)

---@type table<string, AttitudeDef>
M.def = {}
---@type string[]
M.LIST = {}

local content = require("src.content")
content.onReady(function()
    for k in pairs(M.def) do M.def[k] = nil end
    for i = #M.LIST, 1, -1 do M.LIST[i] = nil end
    for _, rec in ipairs(content.attitude:all()) do
        local def = { ai = rec, text = rec.text, title = rec.title, desc = rec.desc, designated = rec.designated or false,
                      spells = rec.spells or false, icon = rec.icon, custom = rec.title ~= nil }
        for _, r in ipairs(rec.rules) do
            for _, c in ipairs(r.conds) do
                if c.code == C.UNDER_ATTACK then def.hitRules = true end
            end
        end
        M.def[rec.id] = def
        M.LIST[#M.LIST + 1] = rec.id
    end
end)

-- The attitudes on offer, built-in ones first.
---@return string[]
function M.list()
    return M.LIST
end

---@param a string
---@return string
function M.name(a)
    local d = M.def[a]
    if d and d.custom then return d.title end
    return d and strings.get("Game.txt", d.text) or a
end

---@param a string
---@return string
function M.description(a)
    local d = M.def[a]
    if d and d.custom then return d.desc or "" end
    return d and strings.get("Game.txt", ("%04d"):format(tonumber(d.text) + 1)) or ""
end

-- The SkillIcons.bmp icon index of an attitude (FUN_00585c80)
---@param a string?
---@return integer?
function M.icon(a)
    local d = M.def[a or M.DEFAULT]
    return d and d.icon
end

-- The attitude a unit starts with (the army constructor FUN_00519ae0): a hero Defensive, anything else the army type's
-- default, which the type loader (FUN_0041b3d0, ARM record word at +0x2e) turns into Defensive unless it is 0
-- (Cowardly); in the tutorial the armies of the other sides stand their ground. `unit.attitude` stays nil until the
-- player (or a rule) changes it, so a unit keeps following its type.
---@param unit Unit
---@return string
function M.initial(unit)
    local world = unit.world
    if unit.hero then return "defensive" end
    if world.opts and world.opts.tutorial and unit.side ~= world.player then return "standGround" end
    if unit.type and unit.type.attitude == 0 then return "cowardly" end
    return "defensive"
end

-- The name of the attitude a unit has now.
---@param unit Unit
---@return string
function M.of(unit) return unit.attitude or M.initial(unit) end

---@param unit Unit
---@return AttitudeDef
function M.get(unit) return M.def[M.of(unit)] or M.def[M.DEFAULT] end

-- A side whose units note their hits and whose attitudes are evaluated as "the local side's" (no computer player and not
-- the neutral side). The original runs one process per human player; the simulation runs them all.
---@param world World
---@param side integer
---@return boolean
local function humanSide(world, side)
    return side < 6 and not (world.ai and world.ai.sides and world.ai.sides[side])
end
M.humanSide = humanSide

-- Hit list ------------------------------------------------------------------------------------------------------
-- FUN_00505b90 (called from the army hit routine FUN_00522860, only for armies the local player owns) adds (inflictor,
-- victim, time); entries older than 4 s are dropped, at most once a second (FUN_00505c40). "Under attack" and "run from
-- attackers" read it. Game time, so peers agree. The list is saved (savegame.lua, M.saveHits / M.restoreHits).

---@param world World
---@param inflictor Unit|Building
---@param victim Unit
function M.addHit(world, inflictor, victim)
    if not humanSide(world, victim.side) then return end
    local list = world.hitList
    if not list then list = {} world.hitList = list end
    list[#list + 1] = { inf = inflictor, vic = victim, t = world.time }
end

-- Saved games: the entries by the index of inflictor and victim in the saved lists (an entry whose units or buildings
-- are not saved is dropped), times relative to now.
---@param world World
---@param uidx table<Unit, integer>
---@param bidx table<Building, integer>
---@return table
function M.saveHits(world, uidx, bidx)
    local out = {}
    local function ref(o)
        if o.kind == "building" then return bidx[o] and { "b", bidx[o] } end
        return uidx[o] and { "u", uidx[o] }
    end
    for _, h in ipairs(world.hitList or {}) do
        local inf, vic = ref(h.inf), uidx[h.vic]
        if inf and vic then out[#out + 1] = { inf = inf, vic = vic, t = h.t - world.time } end
    end
    return { list = out, processed = world.hitProcessed and (world.hitProcessed - world.time) or nil }
end

---@param world World
---@param data table?
---@param ulist table<integer, Unit>
---@param blist table<integer, Building>
function M.restoreHits(world, data, ulist, blist)
    if not data then return end
    local list = {}
    for _, h in ipairs(data.list or {}) do
        local inf = h.inf[1] == "b" and blist[h.inf[2]] or h.inf[1] == "u" and ulist[h.inf[2]] or nil
        local vic = ulist[h.vic]
        if inf and vic then list[#list + 1] = { inf = inf, vic = vic, t = world.time + h.t } end
    end
    world.hitList = list
    world.hitProcessed = data.processed and (world.time + data.processed) or nil
end

-- The towers' state: the target (b.target, the tower's target, FUN_0052a410) by index like the hit list's entries, the
-- side it was found on, the shot timer (relative to the clock) and the slice the tower last looked in (towerThink).
---@param world World
---@param uidx table<Unit, integer>
---@param bidx table<Building, integer>
---@return table[]
function M.saveTowers(world, uidx, bidx)
    local out = {}
    for _, b in ipairs(world.buildings) do
        local tg = b.target
        if bidx[b] and (tg or b.nextShot or b.attSlice) then
            local ref = tg and (tg.kind == "building" and bidx[tg] and { "b", bidx[tg] } or uidx[tg] and { "u", uidx[tg] })
            out[#out + 1] = { b = bidx[b], t = ref or nil, side = ref and b.targetSide or nil,
                              shot = b.nextShot and (b.nextShot - world.time) or nil, slice = b.attSlice }
        end
    end
    return out
end

---@param world World
---@param data table[]?
---@param ulist table<integer, Unit>
---@param blist table<integer, Building>
function M.restoreTowers(world, data, ulist, blist)
    for _, r in ipairs(data or {}) do
        local b = blist[r.b]
        if b then
            local tg = r.t and (r.t[1] == "b" and blist[r.t[2]] or ulist[r.t[2]])
            if tg then b.target, b.targetSide = tg, r.side or tg.side end
            b.nextShot = r.shot and (world.time + r.shot) or nil
            b.attSlice = r.slice
        end
    end
end

local function processHits(world)
    local list, t = world.hitList, world.time
    if not list or (world.hitProcessed and t < world.hitProcessed + 1000) then return list end
    world.hitProcessed = t
    local out = {}
    for _, h in ipairs(list) do
        if h.t >= t - 4000 then out[#out + 1] = h end
    end
    world.hitList = out
    return out
end

-- Geometry helpers -------------------------------------------------------------------------------------------------

local function dist(a, b) return math.max(math.abs(a.gx - b.gx), math.abs(a.gy - b.gy)) end

local function allied(world, a, b)
    if a == b then return true end
    local sa, sb = world.sides[a], world.sides[b]
    return sa and sb and sa.team ~= 0 and sa.team == sb.team or false
end

-- the guard point (post): where the unit last stood still of its own accord; the unit's position before there is one
local function guardPoint(me)
    local p = me.post
    if p then return p[1], p[2] end
    return me.gx, me.gy
end

-- FUN_00508d00: the subject stands inside the active area of me (see the header about the bottom edge)
local function inArea(world, def, me, subj)
    if subj == me then return true end
    local gx, gy = guardPoint(me)
    local s = def.ai.size
    local x0, y0 = math.max(0, gx - s), math.max(0, gy - s)
    local x1, y1 = math.min(world.w - 1, gx + s), math.max(world.h - 1, gy + s)
    return subj.gx >= x0 and subj.gx <= x1 and subj.gy >= y0 and subj.gy <= y1
end

local function threatRadius(subj)
    return math.max(12, subj:stats().range or 0)
end

-- The box a threat search covers, clipped to the active area when the condition / action asks for it
local function threatBox(def, me, cx, cy, r, area)
    local x0, x1, y0, y1 = cx - r, cx + r, cy - r, cy + r
    if area then
        local gx, gy = guardPoint(me)
        local s = def.ai.size
        x0, y0, x1, y1 = math.max(x0, gx - s), math.max(y0, gy - s), math.min(x1, gx + s), math.min(y1, gy + s)
    end
    return x0, x1, y0, y1
end

-- unit.lua and aidata.lua are loaded on demand (unit.lua requires this module)
local function isCritter(code) return require("src.game.unit").isCritter(code) end
local function isTower(code) return require("src.game.aidata").isTower(code) end

-- The map position the original reports for an item: an army's cell, a building's bottom middle
-- cell (openwbc3 anchors a building at its top middle cell).
local function mapPos(o)
    if o.kind == "building" then
        return o.gx, o.gy + math.max(1, o.shape and o.shape.h or 1) - 1
    end
    return o.gx, o.gy
end

-- Threat priority (FUN_00533c40): 0 for mines, lairs, shops (building codes BR.., BL.., BS..), the flag of capture the
-- flag and anything more than 25 cells away; otherwise 50 + max(0, 11 - distance), +30 when what the target attacks
-- belongs to my side (an army's target: any ally of mine; a tower's: my own side only), -40 when it cannot hurt. A target
-- that has no target adds nothing (the function returns at once).
local function threatPriority(world, me, o)
    if o.kind == "building" then
        local p = o.code:sub(1, 2)
        if p == "BR" or p == "BL" or p == "BS" then return 0 end
        if require("src.game.gamedata").hasTag(o.code, "flag") and require("src.game.victory").get(world.victoryRule, "flagGame") then return 0 end
    end
    local mx, my = mapPos(me)
    local ox, oy = mapPos(o)
    local d = math.max(math.abs(mx - ox), math.abs(my - oy))
    if d > 25 then return 0 end
    local pr = 50 + math.max(0, 11 - d)
    local tg = o.target
    if o.kind == "unit" then
        if not tg or tg.side == nil then return pr end
        if allied(world, tg.side, me.side) then pr = pr + 30 end
        if (o:stats().damage or 0) <= 0 then pr = pr - 40 end
    elseif tg and (tg.kind == "unit" and tg:alive() or tg.kind == "building" and tg.hp > 0) then
        -- a tower (Eco:buildingAttack keeps the target of the shot in b.target; the tower's target, FUN_0052a410)
        if tg.side == me.side then pr = pr + 30 end
        if (o.type and o.type.damage or 0) <= 0 then pr = pr - 40 end
    end
    return pr
end

-- Buildings a unit is converting right now: human sides do not attack those.
local function converting(world)
    if world.attConvert and world.attConvertT == world.time then return world.attConvert end
    local set = {}
    for _, u in ipairs(world.units) do
        if u.state == "convert" and u.converting then
            for _, b in ipairs(world.eco:conversionTargets(u)) do set[b] = true end
        end
    end
    world.attConvert, world.attConvertT = set, world.time
    return set
end

-- The cells of a building inside the box, as the first one the original's scan reaches (rows, then columns; with
-- `colMajor` columns, then rows) that `ok(x, y)` accepts (nil = any), or nil. Returns row, column.
local function buildingScan(world, b, x0, x1, y0, y1, ok, colMajor)
    local shape = b.shape
    if not shape then
        if b.gx >= x0 and b.gx <= x1 and b.gy >= y0 and b.gy <= y1 and (not ok or ok(b.gx, b.gy)) then return b.gy, b.gx end
        return nil
    end
    local w, h = math.max(1, shape.w), math.max(1, shape.h)
    local bx0 = b.gx - math.floor((w - 1) / 2)
    if bx0 > x1 or bx0 + w - 1 < x0 or b.gy > y1 or b.gy + h - 1 < y0 then return nil end
    local bx, by
    for _, c in ipairs(world:shapeCells(b.gx, b.gy, shape)) do
        if c[1] >= x0 and c[1] <= x1 and c[2] >= y0 and c[2] <= y1 and (not ok or ok(c[1], c[2])) then
            if not colMajor then return c[2], c[1] end
            if not bx or c[1] < bx or c[1] == bx and c[2] < by then bx, by = c[1], c[2] end
        end
    end
    if bx then return by, bx end
    return nil
end

-- The critters' hunters (the critter branch of the threat search FUN_005334f0, checked in the 1.04 binary; the unit
-- records name them: `behaviour.hunts`, content/base/tags.lua, which also lists the prey). The Minotaurs and a Minotaur hero take the animals
-- when they are wounded (priority 1 + a quarter of the missing hits, at most 201: more than a real threat is worth); the
-- Troll and the Catapult a sheep / a cow (priority 1); the daemons a Soul when their mana is low, (7 - level) * 4 + 1.
local preyOf = setmetatable({}, { __mode = "k" })
local function isPrey(hunts, code)
    local set = preyOf[hunts]
    if not set then
        set = {}
        for _, c in ipairs(hunts.prey) do set[c] = true end
        preyOf[hunts] = set
    end
    return set[code]
end

-- Mana level (FUN_0051b2c0): 7 * mana / maximum, 7 at most; a non-hero without mana is level -1 (0xffff read as a short)
local function manaLevel(u)
    local cur, max
    if u.hero and u.h then cur, max = u.h.mana, u.h.mod and u.h.mod.mana else cur, max = u.mana, u.maxMana end
    if not max or max < 1 then return u.hero and 0 or -1 end
    return math.max(0, math.min(7, math.floor(7 * (cur or 0) / max)))
end

local function hunterOf(f)
    local hunts = f.type and f.type.behaviour and f.type.behaviour.hunts
    if hunts and hunts.heroRace then
        if not (f.hero and f.h and f.h.race == require("src.content").race:slotOf(hunts.heroRace)) then return nil end
    end
    return hunts
end

-- 0 = nothing worth a hunt, else the priority of the critter `o` for the hunter `f` (whose `hunts` record is given)
local function huntPriority(f, hunts, o)
    if not isPrey(hunts, o.code) then return 0 end
    if hunts.wounded then
        local missing = math.floor((f.maxHp or 0) - (f.hp or 0))
        if missing > 0 then return 1 + math.min(200, math.floor(missing / 4)) end
        return 0
    elseif hunts.mana then
        local lvl = manaLevel(f)
        if lvl < hunts.mana then return 1 + math.min(200, (hunts.mana - lvl) * 4) end
        return 0
    end
    return 1
end

-- Can the finder (an army, or a tower: its type's attack type 1 ground, 2 air, 3 both) hit `o`? FUN_005334f0 scans the
-- ground layer (ground armies and the buildings) and the air layer (flyers) of the map; a finder that attacks air only
-- passes the ground armies over.
local function reaches(finder, o)
    if finder.kind == "unit" then return finder:canReach(o) end
    if o.kind ~= "unit" then return true end
    local at = finder.type and finder.type.attackType or 0
    if o.move == 1 then return at >= 2 end
    return at % 2 == 1
end

-- Threat search (FUN_005334f0): the army or building of the box with the highest priority; the first one the scan
-- (rows top to bottom, cells left to right, the ground layer before the air) meets wins a tie. `finder` is a unit that
-- can attack at all; critters are no threats (but prey for the hunters above), neutral armies are, neutral buildings
-- only as towers (priority 21). For a human side the fog counts (see fog.lua, the simulation's sight of that side): an
-- army or building of a side has to stand on a visible (or, on a hidden map alone, explored) cell, a building must have
-- been seen before; neutral towers only need to have been seen, critters need neither.
local function bestThreat(world, finder, x0, x1, y0, y1)
    local ftype = finder.type
    local tower = finder.kind == "building"
    if not ftype or (ftype.attackType or 0) == 0 then return nil end
    if tower then
        -- the real damage (0x0052e9e0): the type's damage plus what the garrison adds
        if (ftype.damage or 0) + (world.eco:garrisonBonus(finder)) <= 0 then return nil end
    elseif (finder:stats().damage or 0) <= 0 then
        return nil
    end
    local side = finder.side
    local seeInv = (world.sides[side].seeInvisible or 0) > world.time
    local human = humanSide(world, side)
    local sight = human and fogs.refresh(world, side) or nil
    local hunter = hunterOf(finder)
    local best, bestP, bestKey
    local W = world.w
    x0, y0, x1, y1 = math.max(0, x0), math.max(0, y0), math.min(W - 1, x1), math.min(world.h - 1, y1)
    local function consider(o, p, row, col, layer)
        if p <= 0 then return end
        local key = (row * W + col) * 2 + layer
        if not best or p > bestP or (p == bestP and key < bestKey) then best, bestP, bestKey = o, p, key end
    end
    for _, o in ipairs(world.units) do
        if o ~= finder and o.gx >= x0 and o.gx <= x1 and o.gy >= y0 and o.gy <= y1 and o:alive() then
            if isCritter(o.code) then
                if hunter and reaches(finder, o) then
                    consider(o, huntPriority(finder, hunter, o), o.gy, o.gx, o.move == 1 and 1 or 0)
                end
            elseif o.side ~= side and not allied(world, side, o.side)
                and reaches(finder, o) and not (o.fx and o.fx.invis and not seeInv)
                and (not sight or sight:sees(o.gx, o.gy)) then
                consider(o, threatPriority(world, finder, o), o.gy, o.gx, o.move == 1 and 1 or 0)
            end
        end
    end
    local conv
    local seen = sight and function(x, y) return sight:sees(x, y) end
    for _, b in ipairs(world.buildings) do
        -- "Buildings won't auto-assess other buildings": the tower of the local side (here: of a human side) takes armies only
        if not (tower and human) and b.hp > 0 and not b.rubbleSince and b.side ~= side and not allied(world, side, b.side)
            and not (sight and not (b.seen and b.seen[side])) then
            if b.side ~= 6 then
                local row, col = buildingScan(world, b, x0, x1, y0, y1, seen)
                if row then
                    conv = conv or (human and converting(world))
                    if not (human and conv[b]) then consider(b, threatPriority(world, finder, b), row, col, 0) end
                end
            elseif b.type and (b.type.damage or 0) > 0 and isTower(b.code) and not world.opts.tutorial then
                local row, col = buildingScan(world, b, x0, x1, y0, y1)
                if row then consider(b, 21, row, col, 0) end        -- a neutral tower
            end
        end
    end
    return best
end

-- The box of the "stand ground" action and the "threats in attack range" condition (checked in the 1.04 binary,
-- FUN_00508300 / FUN_00507e40): the army's shape (width x height cells, the map position being its bottom middle cell)
-- grown by one cell all round and by its range - 1 (at least 0): [x - (w - 1) div 2 - 1 - k .. x - (w - 1) div 2 + w + k] by
-- [y - (h - 1) - 1 - k .. y + 1 + k]; a single cell army gets the 3 x 3 cells round it (k = 0).
local function shapeBox(world, u)
    local sh = u.type and u.type.shape
    local w, h = sh and math.max(1, sh.w or 1) or 1, sh and math.max(1, sh.h or 1) or 1
    local k = math.max(0, (u:stats().range or 0) - 1)
    local xs, ys = u.gx - math.floor((w - 1) / 2), u.gy - (h - 1)
    return math.max(0, xs - 1 - k), math.min(world.w - 1, xs + w + k), math.max(0, ys - 1 - k), math.min(world.h - 1, ys + h + k)
end

-- A tower's turn (FUN_0052d0d0, called for the buildings of a side by the side's threat handling FUN_00532530 in the
-- same slices as the armies, see M.update): once per slice of its side a building with a base damage above 0 asks the
-- threat search for the best target in the box threat centre +- range (the centre is the middle column and the middle
-- row of the shape; the range is the real damage 0x0052e9e0: the type's plus the garrison's), with the
-- minimum priority 255 = any. A building that carries out an order (production, research) does not look. The target is
-- kept, whatever happens to it, until the next turn: the shot cadence in Eco:buildingAttack fires at it every interval,
-- even when it has left the range meanwhile. Same target: nothing changes; another one: the shot timer runs on; none:
-- the target is dropped and the next target is shot at once (`b.nextShot = nil`, the next attack time 0).
-- `b.attSlice` is the slice the tower last looked in (saved with `b.target` and the shot timer, M.saveTowers).
-- Not done: the original's repair of a target farther than range + 2 (a map inconsistency, cannot happen here) and the
-- orders of the player to a tower (FUN_0052d060: attack a chosen target), which openwbc3 has no command for.
---@param world World
---@param b Building
function M.towerThink(world, b)
    local bt = b.type
    if not bt or b.hp <= 0 or (bt.damage or 0) <= 0 then return end
    local mark = world.attSide and world.attSide[b.side]
    if mark == nil or b.attSlice == mark then return end
    b.attSlice = mark
    if b.current or b.waiting or (b.queue and #b.queue > 0) then return end
    local _, gRange = world.eco:garrisonBonus(b)
    local range = (bt.range or 0) + gRange
    local shape = b.shape
    local cx, cy = b.gx, b.gy + math.floor((math.max(1, shape and shape.h or 1) - 1) / 2)
    local best = bestThreat(world, b, cx - range, cx + range, cy - range, cy + range)
    if best then
        if b.target ~= best then b.target, b.targetSide = best, best.side end
    else
        b.target, b.targetSide, b.nextShot = nil, nil, nil
    end
end

-- Conditions -------------------------------------------------------------------------------------------------------
-- Each returns the truth of the condition as such, or nil, forced when the original returns a fixed answer whatever
-- the expected result is.

local CHECK = {}

local handleThreats      -- the army threat handling (FUN_0051a470), below the actions

CHECK[C.THREATS] = function(world, def, me, subj, c)
    local x0, x1, y0, y1 = threatBox(def, me, subj.gx, subj.gy, threatRadius(subj), c.area)
    return handleThreats(world, subj, x0, x1, y0, y1, "check") ~= nil
end

CHECK[C.GUARD_THREATS] = function(world, def, me, subj, c)
    local cx, cy
    if subj.post then cx, cy = subj.post[1], subj.post[2] else cx, cy = me.gx, me.gy end
    local x0, x1, y0, y1 = threatBox(def, me, cx, cy, threatRadius(subj), c.area)
    return handleThreats(world, subj, x0, x1, y0, y1, "check") ~= nil
end

CHECK[C.ALIVE] = function(world, def, me, subj, c)
    if c.area and not inArea(world, def, me, subj) then return nil, false end
    return subj.state ~= "dead"
end

local function attacking(kind)
    return function(world, def, me, subj, c)
        if c.area and not inArea(world, def, me, subj) then return nil, false end
        local tg = subj.target
        return tg ~= nil and tg.kind == kind and not allied(world, me.side, tg.side) and (tg.kind ~= "unit" or tg:alive())
    end
end
CHECK[C.ATTACKING_BUILDING] = attacking("building")
CHECK[C.ATTACKING_ARMY] = attacking("unit")

CHECK[C.DAMAGED] = function(world, def, me, subj, c)
    if c.area and not inArea(world, def, me, subj) then return nil, false end
    local maxHp = math.max(1, subj.maxHp or 1)
    return math.floor(math.max(0, subj.hp) * 100 / maxHp) < c.extra[1]
end

CHECK[C.UNDER_ATTACK] = function(world, def, me, subj)
    for _, h in ipairs(processHits(world) or {}) do
        if h.vic == subj then return true end
    end
    return false
end

-- "Threats in attack range" (FUN_00507e40): anything standing in the cells around the subject out to its range (the
-- box starts one cell off its shape, see shapeBox): a neutral army or building that can hurt (base damage), or an army or
-- building of a side that is no ally of the subject's. No test of what the subject can reach.
CHECK[C.THREATS_IN_RANGE] = function(world, def, me, subj, c)
    if c.area and not inArea(world, def, me, subj) then return nil, false end
    local x0, x1, y0, y1 = shapeBox(world, subj)
    for _, o in ipairs(world.units) do
        if o ~= subj and o:alive() and o.gx >= x0 and o.gx <= x1 and o.gy >= y0 and o.gy <= y1 then
            if o.side == 6 then
                if o.type and (o.type.damage or 0) > 0 then return true end
            elseif not allied(world, subj.side, o.side) then
                return true
            end
        end
    end
    for _, b in ipairs(world.buildings) do
        if b.hp > 0 and not b.rubbleSince and buildingScan(world, b, x0, x1, y0, y1) then
            if b.side == 6 then
                if b.type and (b.type.damage or 0) > 0 then return true end
            elseif not allied(world, subj.side, b.side) then
                return true
            end
        end
    end
    return false
end

CHECK[C.NEAR] = function(world, def, me, subj, c)
    if subj == me then return nil, true end
    if c.area and not inArea(world, def, me, subj) then return nil, false end
    return dist(me, subj) < c.extra[1]
end

local function subjectOf(unit, which)
    if which == ME then return unit end
    if which == HERO then
        local h = unit.world.eco:heroAlive(unit.side)
        return h
    end
    return unit.guarding
end

-- Rule test (FUN_00507560): do all used conditions hold (a rule without any, or with a missing subject, does not)
local function ruleHolds(world, def, me, r)
    if #r.conds == 0 then return false end
    for _, c in ipairs(r.conds) do
        local subj = subjectOf(me, c.unit)
        if not subj then return false end
        local check = CHECK[c.code]
        if check then
            local value, forced = check(world, def, me, subj, c)
            if forced ~= nil then
                if not forced then return false end
            elseif value ~= c.result then
                return false
            end
        end
    end
    return true
end

-- Actions ----------------------------------------------------------------------------------------------------------
-- `sys` is true for orders with the system as issuer (the rule does not override the player): the unit remembers them
-- as its own (autoChase), so rules may replace them, the way the original's overridable system orders can be.

local DIRS = { { 0, -1 }, { 1, -1 }, { 1, 0 }, { 1, 1 }, { 0, 1 }, { -1, 1 }, { -1, 0 }, { -1, -1 } }
local FAN = { 0, 1, -1, 2, -2, 3, -3, 4 }

-- FUN_0040a8f0: the compass direction (0 = up, clockwise) from (x1, y1) to (x2, y2)
local function dir8(x1, y1, x2, y2)
    local dx, dy = x2 - x1, y2 - y1
    local ax, ay = math.abs(dx), math.abs(dy)
    if dx == 0 then return dy > 0 and 4 or 0 end
    if dy == 0 then return dx > 0 and 2 or 6 end
    if dx > 0 and dy > 0 then return ax > ay * 2 and 2 or (ay > ax * 2 and 4 or 3) end
    if dx < 0 and dy > 0 then return ax > ay * 2 and 6 or (ay > ax * 2 and 4 or 5) end
    if dx < 0 and dy < 0 then return ax > ay * 2 and 6 or (ay > ax * 2 and 0 or 7) end
    return ax > ay * 2 and 2 or (ay > ax * 2 and 0 or 1)
end

local function passable(world, unit, x, y)
    if x < 0 or y < 0 or x >= world.w or y >= world.h then return false end
    if not world.terrain:passable(x, y, unit.move) then return false end
    return unit.move == 1 or world.static[world:index(x, y)] == 0
end

-- Run away (FUN_00522f40): two steps of 4 cells away from the inflictor, each in the first free direction of the fan
-- straight away, then 1 / -1 / 2 / -2 ... turns (the first step failing gives no flight, the second only the first
-- step). The run is an order nothing but the end of the run interrupts (the original gives it NODIVERSION priority).
local function doRun(unit, from)
    local world = unit.world
    if allied(world, unit.side, from.side) then return false end
    local mx, my = unit.gx, unit.gy
    local dir = dir8(from.gx, from.gy, mx, my)
    for step = 1, 2 do
        local found
        for _, f in ipairs(FAN) do
            local d = DIRS[(dir + 8 + f) % 8 + 1]
            local nx, ny = mx + d[1] * 4, my + d[2] * 4
            if passable(world, unit, nx, ny) then found = { nx, ny } break end
        end
        if not found then
            if step == 1 then return false end
            break
        end
        mx, my = found[1], found[2]
    end
    local x, y = world:nearestFree(mx, my, unit.move, 4)
    if not x then return false end
    unit:orderMove(x, y)
    unit.running = true
    return true
end

M.run = doRun      -- a terrified army runs from what it was told to attack (psych.lua, FUN_00522f40)

-- Random move (FUN_00522db0, the original's walk of a hit unit that finds no threat): up to 100 tries of a step of
-- 5 .. 10 cells (1d6 + 4) in one of the eight directions, the position carried over from one try to the next, kept
-- inside the map margin; the first spot that can be walked to is the goal. The order has the player as its issuer
-- (overridable), so it is not one of the attitude's own.
local function doRandomMove(unit)
    local world = unit.world
    local x, y = unit.gx, unit.gy
    for _ = 1, 100 do
        local d = DIRS[math.random(0, 7) + 1]
        local n = math.random(5, 10)
        x = math.max(1, math.min(x + d[1] * n, world.w - 2))
        y = math.max(1, math.min(y + d[2] * n, world.h - 2))
        if world:free(x, y, unit.move) then
            unit:orderMove(x, y)
            return true
        end
    end
    return false
end

-- Army threat handling (FUN_0051a470): the "has been hit" flag is read and cleared by every call, critters never find
-- threats, FUN_005334f0 looks in the box; a unit that already attacks the best threat is left alone. mode "check" only
-- answers (the conditions), "fight" attacks it (FUN_0051da60, an overridable system order), "run" runs from it
-- (FUN_00522f40). Without
-- a threat, a unit that was hit and has no order at all walks off at random, unless it stands its ground.
-- Returns the threat found.
function handleThreats(world, unit, x0, x1, y0, y1, mode, sys)
    local wasHit = unit.wasHit
    unit.wasHit = nil
    if not unit:alive() or isCritter(unit.code) then return nil end
    local e = bestThreat(world, unit, x0, x1, y0, y1)
    if e and unit.target == e then return e end
    if e then
        if mode == "fight" then
            unit:orderAttack(e, sys)
        elseif mode == "run" then
            doRun(unit, e)
        end
        return e
    end
    if wasHit and unit.state == "idle" and not (unit.target or unit.goalX or unit.task or unit.converting)
        and M.of(unit) ~= "standGround" then
        doRandomMove(unit)
    end
    return nil
end

local function guardedState(unit)
    local s = unit.att
    if not s then s = { action = -1, extra = 0 } unit.att = s end
    return s
end

local function stillDoing(unit, code)
    local s = unit.att
    return s and s.action == code and (unit.goalX or unit.target) and (unit.autoChase or unit.roaming or unit.running)
end

-- the hit list entry for "protect the unit" (FUN_00508260) / "run from attackers": the last inflictor that hit `subj`,
-- or the one the unit already dealt with
local function attackerOf(world, unit, subj)
    local found
    for _, h in ipairs(processHits(world) or {}) do
        if h.vic == subj and h.inf and h.inf.kind then
            found = h.inf
            if unit.att and unit.att.target == h.inf.id then break end
        end
    end
    return found
end

-- Removes the orders the attitude gave (nothing holds and there is no idle action: "stop the unit")
local function dropOwnOrders(unit, t)
    if (unit.autoChase or unit.roaming) and (unit.target or unit.goalX) then
        unit.target, unit.path, unit.goalX, unit.goalY = nil, nil, nil, nil
        unit.autoChase, unit.roaming = false, nil
        if unit.state == "move" or unit.state == "attack" then unit:setIdle(t) end
    end
end

local DO = {}
local critterRest          -- below, with the schedule

DO[A.RETURN_TO_BASE] = function(world, def, me, subj, a, sys)
    local sd = world.sides[me.side]
    if not sd or not sd.startX or sd.startX < 0 then return false end
    local s = guardedState(me)
    if stillDoing(me, A.RETURN_TO_BASE) and s.tx == sd.startX and s.ty == sd.startY then return false end
    local x, y = world:nearestFree(sd.startX, sd.startY, me.move, 6)
    if not x or (x == me.gx and y == me.gy) then return false end
    me:orderMove(x, y)
    s.tx, s.ty = sd.startX, sd.startY
    me.autoChase = sys
    return true
end

DO[A.FOLLOW] = function(world, def, me, subj, a, sys)
    if not subj or subj == me then return false end
    if me.goalX and not me.target and math.max(math.abs(me.goalX - subj.gx), math.abs(me.goalY - subj.gy)) < 5 then
        return false                                    -- already on the way to it
    end
    local x, y = world:nearestFree(subj.gx, subj.gy + 1, me.move, 4)
    if not x then return false end
    me:orderMove(x, y)
    me.autoChase = sys
    return true
end

DO[A.PROTECT] = function(world, def, me, subj, a, sys)
    if not subj then return false end
    local inf = attackerOf(world, me, subj)
    if not inf then return DO[A.FOLLOW](world, def, me, subj, a, sys) end
    if me.target == inf then return false end
    me:orderAttack(inf, sys)
    guardedState(me).target = inf.id
    return true
end

-- Stand ground (FUN_00508300): the first army or building the scan of the box round the unit (shapeBox;
-- columns, then rows, the ground layer before the air) reaches, which the unit then attacks unless it does already. At the
-- first cell with a candidate (a neutral one, or one of a side that is no ally) the layers are walked in turn and the
-- later one replaces the earlier unless the earlier one ends the walk: a neutral army that can hurt, or the army the
-- unit stood against last time. No filter for what the unit can reach: FUN_0051da60 ignores a target it cannot hit, so the
-- unit stands and waits.
DO[A.STAND_GROUND] = function(world, def, me, subj, a, sys)
    local x0, x1, y0, y1 = shapeBox(world, me)
    local H = world.h
    local cells, firstKey = {}, nil
    local function add(o, x, y, layer)
        local key = x * H + y
        local c = cells[key]
        if not c then c = {} cells[key] = c end
        c[layer] = o
        if not firstKey or key < firstKey then firstKey = key end
    end
    for _, o in ipairs(world.units) do
        if o ~= me and o:alive() and o.gx >= x0 and o.gx <= x1 and o.gy >= y0 and o.gy <= y1
            and (o.side == 6 or not allied(world, me.side, o.side)) then
            add(o, o.gx, o.gy, o.move == 1 and 1 or 0)
        end
    end
    for _, b in ipairs(world.buildings) do
        if b.hp > 0 and not b.rubbleSince and (b.side == 6 or not allied(world, me.side, b.side)) then
            if b.shape then
                for _, c in ipairs(world:shapeCells(b.gx, b.gy, b.shape)) do
                    if c[1] >= x0 and c[1] <= x1 and c[2] >= y0 and c[2] <= y1 then add(b, c[1], c[2], 0) end
                end
            elseif b.gx >= x0 and b.gx <= x1 and b.gy >= y0 and b.gy <= y1 then
                add(b, b.gx, b.gy, 0)
            end
        end
    end
    if not firstKey then return false end
    local cur = me.att and me.att.target
    local e
    for layer = 0, 1 do
        local o = cells[firstKey][layer]
        if o then
            e = o
            if o.side == 6 then
                if (o.type and o.type.damage or 0) > 0 then break end
            elseif o.id == cur then
                break
            end
        end
    end
    if not e or me.target == e then return false end
    if not me:canReach(e) then return false end
    me:orderAttack(e, sys)
    guardedState(me).target = e.id
    return true
end

DO[A.RUN_FROM_ATTACKERS] = function(world, def, me, subj, a, sys)
    if not subj or stillDoing(me, A.RUN_FROM_ATTACKERS) then return false end
    local inf = attackerOf(world, me, subj)
    if not inf then return false end
    guardedState(me).target = inf.id
    return doRun(me, inf)
end

local function threatAction(world, me, subj, cx, cy, sys)
    local r = threatRadius(subj)
    local e = handleThreats(world, me, cx - r, cx + r, cy - r, cy + r, "fight", sys)
    return e ~= nil and me.target == e
end

DO[A.HANDLE_THREATS] = function(world, def, me, subj, a, sys)
    if not subj then return false end
    return threatAction(world, me, subj, subj.gx, subj.gy, sys)
end

DO[A.HANDLE_GUARD_THREATS] = function(world, def, me, subj, a, sys)
    if not subj then return false end
    local cx, cy = subj.gx, subj.gy
    if subj.post then cx, cy = subj.post[1], subj.post[2] end
    return threatAction(world, me, subj, cx, cy, sys)
end

DO[A.RANDOM_MOVE] = function(world, def, me, subj, a, sys)
    if stillDoing(me, A.RANDOM_MOVE) then return false end
    local x0, x1, y0, y1 = 1, world.w - 2, 1, world.h - 2
    if a.area then
        local gx, gy = guardPoint(me)
        local s = def.ai.size
        x0, y0 = math.max(0, gx - s), math.max(0, gy - s)
        x1, y1 = math.min(world.w - 1, gx + s), math.max(world.h - 1, gy + s)
    end
    local x, y = world:nearestFree(math.random(x0, math.max(x0, x1)), math.random(y0, math.max(y0, y1)), me.move, 6)
    if not x then return false end
    me:orderMove(x, y)
    me.roaming, me.autoChase = true, false
    return true
end

DO[A.SCOUT] = function(world, def, me, subj, a, sys)
    local gx, gy = guardPoint(me)
    local s = def.ai.size
    local x0, y0 = math.max(0, gx - s), math.max(0, gy - s)
    local x1, y1 = math.min(world.w - 1, gx + s), math.max(world.h - 1, gy + s)
    local st = guardedState(me)
    local corners = { { x0, y0 }, { x0, y1 }, { x1, y1 }, { x1, y0 } }
    local k = (st.extra or 0) % 4
    local c = corners[k + 1]
    if math.max(math.abs(c[1] - me.gx), math.abs(c[2] - me.gy)) < 5 then k = (k + 1) % 4 c = corners[k + 1] end
    st.extra = k
    if stillDoing(me, A.SCOUT) and st.tx == c[1] and st.ty == c[2] then return false end
    local x, y = world:nearestFree(math.min(c[1], world.w - 1), math.min(c[2], world.h - 1), me.move, 6)
    if not x then return false end
    me:orderMove(x, y)
    st.tx, st.ty = c[1], c[2]
    me.autoChase, me.roaming = sys, nil
    return true
end

DO[A.MOVE_TO_CENTRE] = function(world, def, me, subj, a, sys)
    local p = me.post
    if not p then return false end
    if math.max(math.abs(p[1] - me.gx), math.abs(p[2] - me.gy)) <= 1 then
        dropOwnOrders(me, world.time)       -- a move (FUN_0051d6b0) to where it stands only removes the overridable order
        return false
    end
    if me.goalX and math.max(math.abs(me.goalX - p[1]), math.abs(me.goalY - p[2])) <= 1 then return false end
    local x, y = world:nearestFree(p[1], p[2], me.move, 4)
    if not x then return false end
    me:orderMove(x, y)
    me.autoChase = sys
    return true
end

DO[A.RUN_FROM_THREATS] = function(world, def, me, subj, a, sys)
    if not subj then return false end
    local x0, x1, y0, y1 = subj.gx - 5, subj.gx + 5, subj.gy - 5, subj.gy + 5
    return handleThreats(world, me, x0, x1, y0, y1, "run") ~= nil and me.running == true
end

-- The evaluator ----------------------------------------------------------------------------------------------------

-- Does the unit carry out an order of the player (or of a rule that overrides the player): any order that is not one of
-- its own attitude's (autoChase / roaming), a task, a conversion or a flight. An attack-move is not one: the
-- Attack button on open ground sends the group move without "ignore threats" (the right-click map action 0x00421190,
-- command mode 2 without a target: actions 0x1a / 0x37 / 0x38 / 0x39 / 0x3a / 0x3b, FUN_0041f0b0 -> FUN_00530870 with
-- the last argument 0), so every move order (FUN_0051d6b0) gets the override level 1 at +0x1c, which the system orders
-- of the rules (FUN_0051da60 / FUN_0051d6b0 with the system flag) insert themselves ahead of; a plain move has level 0,
-- which they refuse. The second result: the unit is busy all the same (FUN_005070f0 gives the idle action only to an
-- army without an order or one carrying out a system order: the attitude's own chase / walk).
---@return boolean mine, boolean? busy
local function playerOrder(unit)
    if unit.attackMove and not unit.task and not unit.converting then return false, not (unit.autoChase or unit.roaming) end
    if unit.task or unit.converting or unit.patrol or unit.running and unit.goalX then return true end
    if unit.queue and #unit.queue > 0 then return true end
    if unit.target or unit.goalX then return not (unit.autoChase or unit.roaming) end
    return false
end

-- The attitude update (FUN_005070f0) for one unit: picks the rule (or the idle action) and carries it out. Returns true
-- when it gave the unit an order.
---@param unit Unit
---@param t number
---@return boolean gave an order
function M.think(unit, t)
    local world = unit.world
    local g = unit.guarding
    if g and not (g:alive() and g.side == unit.side) then unit.guarding = nil g = nil end
    local def = M.get(unit)
    if def.designated and not g then
        -- the designated unit is gone (or the guard order was replaced): back to the standard attitude
        unit.attitude = M.DEFAULT
        def = M.def[M.DEFAULT]
    end
    local idle = unit.state == "idle"
    -- the guard point; on an attack-move the spot where a fight begins (FUN_0051da60 keeps the army's position as the
    -- fight's return point)
    if (idle or unit.attackMove) and not unit.autoChase and not unit.roaming then unit.post = { unit.gx, unit.gy } end
    if def.spells and unit.h then require("src.game.spells").aiThink(unit, t) end

    local mine, busy = playerOrder(unit)
    local best
    for _, r in ipairs(def.ai.rules) do
        -- every rule is looked at, also below the best one found (the conditions have side effects: the "has been hit" flag)
        if (r.overrides or not mine) and ruleHolds(world, def, unit, r) and (not best or r.priority > best.priority) then
            best = r
        end
    end
    local action, from = nil, best
    if best then
        action = best.action
    elseif mine or busy then
        return false                                    -- never the idle action while the player gives orders
    elseif def.ai.idle then
        action = def.ai.idle
    else
        dropOwnOrders(unit, t)
    end
    local gave = false
    if action then
        local fn = DO[action.code]
        if fn then
            local sys = not (from and from.overrides)
            local subj = subjectOf(unit, action.unit)
            gave = fn(world, def, unit, subj, action, sys) and true or false
            if unit.att then unit.att.action = action.code else unit.att = { action = action.code, extra = 0 } end
        end
    end
    if idle and not gave and unit.state == "idle" then
        -- nothing to do and nothing running: the unit stays where it stands, which becomes its guard point
        unit.autoChase, unit.roaming = false, nil
        unit.post = { unit.gx, unit.gy }
    end
    return gave
end

-- Evaluation schedule ----------------------------------------------------------------------------------------------

M.SLICE_MS = 250        -- the AI slice (FUN_00429ec0): every 10th tick of the 25 ms main timer

-- Critter reaction (FUN_0051a230; FUN_00532590 runs it for the neutral side's
-- animals - the Souls excepted - in every slice, but not in the tutorial; the original only on the host, the simulation
-- everywhere). Despite its name the animals do not flee: most of them rest. A roll of 1..100 lets them off - sheep up to
-- 79, camels 86, cows, turtles and seals 99, geese and penguins 9 - and a second roll decides what the others do: one
-- that is busy stops with 2 % (roll 1), an idle one walks to a spot anywhere on the map with 75 %. (The original's
-- guarding branch and the 1 in 200 pick of a unit to guard do nothing in the shipped code.)
---@param world World
---@param u Unit
---@param rest integer
function critterRest(world, u, rest)
    if rest >= math.random(1, 100) then return end
    local roll = math.random(1, 100)
    if u.state ~= "idle" then
        if roll < 2 then u:stop() end
        return
    end
    if roll <= 75 then
        local x, y = world:nearestFree(math.random(1, world.w - 2), math.random(1, world.h - 2), u.move, 6)
        if x then u:orderMove(x, y --[[@as integer]]) end
    end
end

-- One AI slice: marks the sides whose units are evaluated in this slice (`world.attSide[side]` = the slice number):
-- the next computer side after the one that had its turn (FUN_00505310 gives one side a turn, over the seven slots),
-- every side without a computer player (the local side, in the original) and the neutral side, except in the
-- tutorial. A unit evaluates itself once per slice (M.due, called by unit.lua).
---@param world World
---@param t number
function M.update(world, t)
    local nxt = world.attNext
    if not nxt then world.attNext = t + M.SLICE_MS return end
    if t < nxt then return end
    nxt = nxt + M.SLICE_MS
    if nxt <= t then nxt = t + M.SLICE_MS end
    world.attNext = nxt
    local slice = (world.attSlice or 0) + 1
    world.attSlice = slice
    local marks = world.attSide
    if not marks then marks = {} world.attSide = marks end
    local ai = world.ai and world.ai.sides
    if ai then
        for k = 1, 7 do
            local i = ((world.attAi or -1) + k) % 7
            if ai[i] and not world.sides[i].defeated then
                world.attAi = i
                marks[i] = slice
                break
            end
        end
    end
    for i = 0, 5 do
        if humanSide(world, i) then
            marks[i] = slice
            if world.sides[i].used then fogs.refresh(world, i) end      -- the sight of the threat search (fog.lua)
        end
    end
    if not (world.opts and world.opts.tutorial) then
        marks[6] = slice
        for _, u in ipairs(world.units) do
            local rest = u.side == 6 and u.type and u.type.behaviour and u.type.behaviour.critterRest
            if rest and u:alive() then critterRest(world, u, rest) end
        end
    end
end

-- Is the unit's side marked for a slice the unit has not been evaluated in yet?
---@param unit Unit
---@return boolean
function M.due(unit)
    local mark = unit.world.attSide and unit.world.attSide[unit.side]
    return mark ~= nil and unit.attSlice ~= mark
end

-- Saved games: the schedule (the next slice, the number, the computer side that had the last turn and which slice each
-- side was marked for).
---@param world World
---@return table
function M.saveSchedule(world)
    local marks = {}
    for i, v in pairs(world.attSide or {}) do marks[i] = v end
    return { next = world.attNext and (world.attNext - world.time) or nil, slice = world.attSlice, ai = world.attAi,
             marks = marks }
end

---@param world World
---@param data table?
function M.restoreSchedule(world, data)
    if not data then return end
    world.attNext = data.next and (world.time + data.next) or nil
    world.attSlice, world.attAi = data.slice, data.ai
    world.attSide = {}
    for i, v in pairs(data.marks or {}) do world.attSide[tonumber(i)] = v end
end

return M
