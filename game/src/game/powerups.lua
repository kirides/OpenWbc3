-- Power-ups: permanent upgrades a side buys in its buildings (production items whose code starts with "P"; the elven
-- runes "R..." work the same way).
-- Cost, research time, the picture order and the army statistic bonuses come from the original game's binary
-- (the `powerup` records of content/base/powerups.lua and the races' `powerupOrder`); names and descriptions from Help.cfg. Behaviour verified against the original:
--  * a power-up is bought once; the levelled ones (PCR0, PCR1 ... = one family, last character a digit) must be bought
--    in order: PCRn is offered once n family members are owned
--  * cost is paid when production starts, the research time is the production time
--  * army bonuses add to the army's statistics for every unit of that type on the side (see `bonus`)
-- Power-ups whose effect the original handles elsewhere (income, view range, building speed, spells ...) are handled by
-- the code that needs them through `has` / `level`.
-- One-shot power-ups (the power-up handler of the 1.04 binary, FUN_00436500): Spell / Arcane Research and the three foreign
-- mercenaries are never added to the side's list, so they can be bought again and again (see `grant`); the Knight's Quest
-- joins the list only once three foes have been chosen.
local content = require("src.content")
local rules = require("src.game.rules")
local gamedata = require("src.game.gamedata")
local strings = require("src.game.strings")

local M = {}

-- Whether the side's race has the flag set (race records, content/base/races.lua).
local function raceFlag(side, flag)
    local race = content.race:bySlot(side.race)
    return race ~= nil and race.flags ~= nil and race.flags[flag] == true
end

-- Research and mercenary power-ups are bought over and over, never owned (the `oneShot` field of the record).
---@param code string
---@return boolean
function M.isOneShot(code)
    local p = content.powerup[code]
    return p ~= nil and p.oneShot == true
end

-- Race picture file ("Powerups<name>.bmp"), by race index.
M.PICTURE = content.race:view("picture")

-- Power-up item codes: "P" ones and the elven runes ("R", researched in the elf keeps like a power-up: the original
-- takes both through the same branch of its cost function, `idStr[0] == 'P' || idStr[0] == 'R'`).
---@param code string
---@return boolean
function M.isPowerup(code)
    local c = code:sub(1, 1)
    return c == "P" or c == "R"
end

---@param code string
---@return boolean
function M.exists(code)
    return M.isPowerup(code) and content.powerup[code] ~= nil
end

-- Base cost { gold, metal, crystal, stone } (a fresh table) and research time in seconds of a power-up, or nil.
---@param code string
---@return table<string, integer>? cost
---@return number? seconds
function M.baseCost(code)
    local p = content.powerup[code]
    if not p then return nil end
    local c = p.cost
    return { gold = c.gold or 0, metal = c.metal or 0, crystal = c.crystal or 0, stone = c.stone or 0 }, p.time
end

-- Hero skill (hero.lua ids) whose levels make a rune 10 % cheaper each (the `runeSkill` field of the rune records), or nil.
---@param code string
---@return integer?
function M.runeSkill(code)
    local p = content.powerup[code]
    return p and p.runeSkill
end

-- Army type flags of a unit code (the status flags of the original's army records, derived from the typed Army.cfg columns of the
-- unit record: `statusFlags`, see kinds/unit.lua).
---@param code string an army type
---@return integer
function M.flags(code)
    local u = gamedata.army(code)
    return u and u.statusFlags or 0
end

-- Ownership ---------------------------------------------------------------------------------

---@param side Side
---@param code string
---@return boolean
function M.has(side, code)
    return side.powerups ~= nil and side.powerups[code] == true
end

-- Level of a family (the power-up test FUN_00437f70 for codes ending in X): the highest owned member PCR0 .. PCR8 + 1.
-- Only members with a digit as fourth character count (PRG0 .. PRG2 are Healing, PRGU is the Royal Guard).
---@param side Side
---@param code string any member of the family
---@return integer
function M.level(side, code)
    local n, stem = 0, code:sub(1, 3)
    for c in pairs(side.powerups or {}) do
        if c:sub(1, 3) == stem then
            local d = tonumber(c:sub(4, 4))
            if d and d + 1 > n then n = d + 1 end
        end
    end
    return n
end

-- Whether the side may start researching `code`.
---@param side Side
---@param code string
---@return boolean
function M.offered(side, code)
    if not M.exists(code) or M.has(side, code) then return false end
    local digit = tonumber(code:sub(4, 4))
    if digit and digit > M.level(side, code) then return false end
    return true
end

-- Called when a power-up finishes (FUN_00436500). `building` is the producing building (its rally point and
-- spawn cell are used by the foreign mercenaries). Returns true when the production is finished normally.
---@param world World
---@param sideIndex integer
---@param code string
---@param building Building? where it was bought
---@return boolean
function M.grant(world, sideIndex, code, building)
    local side = world.sides[sideIndex]
    if not M.exists(code) then return false end
    local rec = content.powerup[code]
    if rec.research then M.research(world, sideIndex, rec.research) return true end
    if rec.mercenaries then
        M.foreignMercenary(world, sideIndex, code, building)
        return true
    end
    if rec.questFoes then return M.knightsQuest(world, sideIndex) end
    if M.has(side, code) then return false end
    side.powerups = side.powerups or {}
    side.powerups[code] = true
    side.powerBonus = nil
    if rec.view then side.visionBonus = (side.visionBonus or 0) + rec.view end
    if code == "PFAR" then
        if world.fog and world.fog.side == sideIndex then world.fog:revealAll() end
        local sight = require("src.game.fog").sightOf(world, sideIndex)      -- the simulation's own fog of that side
        if sight then sight:revealAll() end
    end
    -- the hero's morale, regeneration, casting chance, conversion time, command radius and resistance read power-ups
    for _, u in ipairs(world.units) do
        if u.h and u.side == sideIndex then u.h:recalc() end
    end
    world:event("powerup", sideIndex, code)
    return true
end

-- Research ------------------------------------------------------------------------------------------------------

-- The magic spheres in the order of the original's research bonus rows (13 shorts per side at 0x0070d496; names are the
-- binary's own English table at 0x006156a8, 32 bytes an entry, the one the research FUN_00438180 prints with game string
-- 0x81; it is the same in every language).
M.SPHERE_NAMES = content.sphere:view("researchName")

-- Casting levels a side's research has added to a sphere for this battle (the table at 0x0070d496); the hero's
-- statistics add it to its casting skill (FUN_0054fd50).
---@param side Side?
---@param sphere integer
---@return integer
function M.spellBonus(side, sphere)
    return side and side.spellBonus and side.spellBonus[sphere] or 0
end

-- The research (FUN_00438180): Spell Research n = 1, Arcane Research n = 3, Learn Spell n = 1 (once, whatever the result).
-- One random sphere of the 13 (a roll of 0 .. 12) gets max(1, (n + 1) / 2) casting levels, which needs a living hero; the
-- local player is told with game string 0x81 / 0x83 (event "spellresearch": side, sphere or nil, amount) and hears "learned
-- a new spell". `quiet` leaves out the message and the voice.
---@param world World
---@param sideIndex integer
---@param n integer
---@param quiet boolean?
---@return boolean
function M.research(world, sideIndex, n, quiet)
    local side = world.sides[sideIndex]
    if not world.eco:heroAlive(sideIndex) then
        if not quiet then world:event("spellresearch", sideIndex, nil, 0) end
        return false
    end
    local sphere = math.random(0, content.sphere:count() - 1)
    local amount = math.max(1, math.floor((n + 1) / 2))
    side.spellBonus = side.spellBonus or {}
    side.spellBonus[sphere] = (side.spellBonus[sphere] or 0) + amount
    for _, u in ipairs(world.units) do
        if u.h and u.side == sideIndex then u.h:recalc() end
    end
    if not quiet then world:event("spellresearch", sideIndex, sphere, amount) end
    return true
end

-- Foreign mercenaries ------------------------------------------------------------------------------------------------

-- The units a mercenary power-up can hire (the `mercenaries` list of the record, see content/base/powerups.lua).
---@param code string
---@return string[]?
function M.mercenaries(code)
    local p = content.powerup[code]
    return p and p.mercenaries
end

-- The hired unit appears like a produced army (spawn cell, rally point) but is not held back by the army limit.
---@param world World
---@param sideIndex integer
---@param code string
---@param building Building?
---@return Unit?
function M.foreignMercenary(world, sideIndex, code, building)
    local side = world.sides[sideIndex]
    local list = M.mercenaries(code)
    if not list or not building or side.defeated then return nil end
    local unit = world.eco:spawnNear(building, list[math.random(#list)])
    if unit then world:event("produced", unit) end
    return unit
end

-- Knight's Quest ------------------------------------------------------------------------------------------------------

-- The quest offer (FUN_00438d40): the foes on offer are the first four entries of the `questFoes` table of the PQKN record
-- ({ army code, race id or none }) that fit: a race entry once for every other side of that race in the game, the four
-- elementals always. The original builds the list for the local player; openwbc3 builds it per side (the side itself left
-- out) so that every peer agrees.
M.MAX_QUEST = 4                                   -- FUN_00438d40 stops at four candidates (table at 0x00608938)

---@param world World
---@param sideIndex integer
---@return string[]
function M.questCandidates(world, sideIndex)
    local out = {}
    local foes = content.powerup["PQKN"] and content.powerup["PQKN"].questFoes or {}
    for _, e in ipairs(foes) do
        if #out >= M.MAX_QUEST then break end
        if not e[2] then
            out[#out + 1] = e[1]
        else
            local slot = content.race:slotOf(e[2])
            for i = 0, 5 do
                local s = world.sides[i]
                if #out < M.MAX_QUEST and s and s.used and i ~= sideIndex and s.race == slot then out[#out + 1] = e[1] end
            end
        end
    end
    return out
end

-- Foes the side has chosen so far (the first free slot of the side's four at 0x0070d634 takes the next one).
---@param side Side?
---@return string[]
function M.questFoes(side)
    return side and side.knightsQuest or {}
end

---@param side Side?
---@param code string
---@return boolean
function M.isQuestFoe(side, code)
    for _, c in ipairs(M.questFoes(side)) do
        if c == code then return true end
    end
    return false
end

-- Command chooseFoe: candidate `index` (1-based) goes into the first free slot; a foe already chosen cannot be taken
-- again (its frame is greyed in the dialog).
---@param world World
---@param sideIndex integer
---@param index integer
---@return boolean
function M.chooseFoe(world, sideIndex, index)
    local side = world.sides[sideIndex]
    if not side then return false end
    local code = M.questCandidates(world, sideIndex)[index]
    local list = side.knightsQuest or {}
    if not code or #list >= M.MAX_QUEST or M.isQuestFoe(side, code) then return false end
    list[#list + 1] = code
    side.knightsQuest = list
    return true
end

-- A finished Knight's Quest (FUN_00436500 + FUN_00438de0): it becomes a permanent power-up only when three
-- foes were chosen already; the human side then picks a foe in the "Choose a Foe" dialog (the original opens it for the
-- local player only; a computer side gets nothing, the code path that would hand it a candidate is never reached).
---@param world World
---@param sideIndex integer
---@return boolean
function M.knightsQuest(world, sideIndex)
    local side = world.sides[sideIndex]
    if #M.questFoes(side) >= 3 and not M.has(side, "PQKN") then
        side.powerups = side.powerups or {}
        side.powerups.PQKN = true
    end
    if not side.ai then world:event("knightsquest", sideIndex) end
    return true
end

-- Experience a Knight / Knight Champion / Knight Lord gets for killing a chosen foe (the army's death handler, binary
-- FUN_005210b0: 25, 50 with the Order of the Grail), on top of the normal kill and the Crusade bonus.
---@param killer Unit
---@param victim Unit|Building
---@return integer
function M.questKillXp(killer, victim)
    if killer.hero or victim.hero or victim.kind ~= "unit" or not gamedata.hasTag(killer.code, "knight") then return 0 end
    local side = killer.world.sides[killer.side]
    if not M.isQuestFoe(side, victim.code) then return 0 end
    return M.has(side, "POGL") and 50 or 25
end

-- Cost and build time (seconds) of a unit after the side's power-ups (the cost routine FUN_0040b6b0 of the original): Jihad /
-- Spare Parts / Summoning speed the units up, Summoning II and Fame make them cheaper, Incubation speeds up the
-- Swarm's insects. Only the best cost reduction applies.

---@param side Side
---@param code string
---@param cost table<string, integer>
---@param time number
---@return table<string, integer> cost
---@return number time
function M.unitCost(side, code, cost, time)
    if not side.powerups then return cost, time end
    local speed, scale
    if (code == "ABIX" or code == "ABGX") and M.has(side, "PJIH") then speed = 0.75 end
    if (code == "AAIX" or code == "AAGX" or require("bit").band(M.flags(code), 0x4000) ~= 0) and M.has(side, "PSPP") then
        speed = 0.75
    end
    if gamedata.hasTag(code, "daemon") then
        if M.has(side, "PSU0") then speed = 0.75 end
        if M.has(side, "PSU1") then scale = { 3, 4 } end
    end
    if code == "AHCX" then
        local fame = M.level(side, "PFM0")
        scale = ({ { 3, 4 }, { 2, 3 }, { 1, 2 } })[fame] or scale
    end
    if gamedata.hasTag(code, "insect") and raceFlag(side, "breedsInsects") then
        local n = M.level(side, "PIU0")
        if n > 0 then time = time - math.floor((5 + n * 5) * time / 100) end
    end
    if speed then time = math.floor(time * speed) end
    if scale then
        local c = {}
        for r, v in pairs(cost) do
            c[r] = v > 0 and math.max(1, math.floor(v * scale[1] / scale[2])) or v
        end
        cost = c
    end
    return cost, time
end

-- Statistic bonuses ---------------------------------------------------------------------------

-- { combat = n, armor = n, speed = n, damage = n, range = n, resistance = n } for a unit code, summed over the
-- side's power-ups (nil when it has none).
---@param side Side
---@param code string
---@return table<string, number>?
function M.bonus(side, code)
    if not side.powerups or next(side.powerups) == nil then return nil end
    local cache = side.powerBonus
    if not cache then
        cache = {}
        side.powerBonus = cache
    end
    local b = cache[code]
    if b == nil then
        b = false
        local flags = M.flags(code)
        local bit = require("bit")
        for pc in pairs(side.powerups) do
            local rec = content.powerup[pc]
            for _, e in ipairs(rec and rec.bonus or {}) do
                local hit
                if e.units then
                    hit = false
                    for _, u in ipairs(e.units) do
                        if u == code then hit = true break end
                    end
                else
                    local overlap = bit.band(flags, e.flags) ~= 0
                    if e.without then hit = not overlap else hit = overlap end
                end
                if hit then
                    b = b or {}
                    b[e.stat] = (b[e.stat] or 0) + e.amount
                end
            end
        end
        cache[code] = b
    end
    return b or nil
end

-- Armour power-ups (the original adds them when it computes an army's armour): Mithril +15, else Anthrite +10, else the
-- level of the best of Armorer / Intangibility / Panoply (5 per level), Shield of Sartek for Minotaurs, Magical Tattoos,
-- Iron Bark for treants (at least 10) and Full Plate Armor for knights (20).
local ARMOUR_STEP = { [0] = 0, 5, 10, 15, 20 }

local function armourBonus(side, code)
    if M.has(side, "PMIT") then return 15 end
    if M.has(side, "PANT") then return 10 end
    local level = M.level(side, "PAR0")
    if level == 0 then level = M.level(side, "PIN0") end
    if level == 0 then level = M.level(side, "PPA0") end
    if level == 0 and side.race == content.race:slotOf("minotaur") and require("bit").band(M.flags(code), 0x80) ~= 0 then level = M.level(side, "PSH0") end
    if level == 0 and M.has(side, "PMAG") then level = 1 end
    if level < 2 and gamedata.hasTag(code, "treant") and M.has(side, "PIRB") then level = 2 end
    if level < 4 and gamedata.hasTag(code, "knight") and M.has(side, "PFPA") then level = 4 end
    return ARMOUR_STEP[math.min(level, 4)]
end

---@param unit Unit
---@param st UnitStats
function M.applyStats(unit, st)
    local side = unit.world.sides[unit.side]
    if side and side.powerups then
        st.armor = st.armor + armourBonus(side, unit.code)
        M.damageType(unit, st, side)
    end
    local b = side and M.bonus(side, unit.code)
    if not b then return end
    st.combat = st.combat + (b.combat or 0)
    st.armor = st.armor + (b.armor or 0)
    st.speed = st.speed + (b.speed or 0)
    st.damage = st.damage + (b.damage or 0)
    st.range = st.range + (b.range or 0)
end

-- Effects the original handles inside its army / hero rules (each function below names the 1.04 routine). Levelled
-- families are found with `level`.

-- Morale: Courage (PMO0..2: 3 / 6 / 9), Order of the Lion +2, Warmth +5. Added to the hero's morale; a side without
-- a living hero has just this (the side morale FUN_0040dc80, table at 0x006081e0), and the troops' attack speed reads it.
local COURAGE = { [0] = 0, 3, 6, 9 }
---@param side Side
---@return integer
function M.moraleBonus(side)
    local n = COURAGE[math.min(3, M.level(side, "PMO0"))]
    if M.has(side, "POLI") then n = n + 2 end
    if M.has(side, "PWRM") then n = n + 5 end
    return n
end

-- Regeneration speed in percent of the basic rate: Healing (PRG0..2, life) and Summon Mana (PMR0..2, mana) both use
-- the percentages 100, 150, 200, 300 ... 800 (tables at 0x0061120c, read by FUN_0051b460, and 0x00611220, read by
-- FUN_0051b580).
local PERCENT = { [0] = 100, 150, 200, 300, 400, 500, 600, 700, 800 }
---@param side Side
---@param stem string
---@return integer
function M.regenPercent(side, stem)
    return PERCENT[math.min(8, M.level(side, stem))]
end

-- Hero abilities from power-ups (casting FUN_0051c2d0: Meditation +10 per level, command FUN_005267b0: Dark Lord +8, the
-- conversion time FUN_00523af0: Holy Relic three quarters, resistance FUN_00526b70: Black Ward +3 per level).
---@param side Side
---@return integer
function M.castingBonus(side) return 10 * M.level(side, "PME0") end
---@param side Side
---@return integer
function M.commandBonus(side) return M.has(side, "PDKL") and 8 or 0 end
---@param side Side
---@return integer
function M.resistanceBonus(side) return 3 * M.level(side, "PRE0") end
---@param side Side
---@param seconds number
---@return number
function M.conversionSeconds(side, seconds)
    if M.has(side, "PHOC") then seconds = math.max(1, math.floor(seconds * 3 / 4)) end
    return seconds
end

-- Build skill of a unit (FUN_00523e10): the building power of its type record (power id 50, data 0 the skill; heroes
-- count as 10) plus the Zombie Feast's +4 for Zombies (flag at 0x0070d58b). The original's construction cost reads the
-- record's value instead (not traced in the 1.04 binary yet), so the power-up bonus feeds the gates and the
-- computer's choice of builder, not the build time.
local BUILD_POWER = "\50\0\0\0"
local function rawBuildSkill(unit)
    if unit.hero then return 10 end
    for _, p in ipairs(unit.type and unit.type.powers or {}) do
        if p.id == BUILD_POWER then return p.data[1] or 0 end
    end
    return 0
end
---@param unit Unit
---@return integer
function M.rawBuildSkill(unit) return rawBuildSkill(unit) end
---@param unit Unit
---@return integer
function M.buildSkill(unit)
    local n = rawBuildSkill(unit)
    if n > 0 and unit.code == "AUBX" then
        local side = unit.world.sides[unit.side]
        if side and M.has(side, "PZOM") then n = n + 4 end
    end
    return n
end

-- Extra experience for a kill (Crusade, +1 per level) and a completed quest (Order of the Grail doubles the 20).
---@param side Side
---@return integer
function M.crusadeXp(side) return M.level(side, "PCR0") end
---@param side Side
---@return integer
function M.questXp(side) return M.has(side, "POGL") and 40 or 20 end

-- Library (PLI0 / PLI1, the High Elf's Library) and Sorcery (PSO0 / PSO1): every unit that has mana gets 15 more
-- maximum and starting mana per level. The army's mana setup (FUN_00528cd0): level = the PLIX family's, else the PSOX
-- family's; maximum mana + level * 15, starting mana + level * 15 - the Library family wins over the Sorcery one, and
-- the power-up handler's +15 mana to existing casters (FUN_004386d0) for the Dark Elf Mage agrees.
---@param side Side?
---@return integer
function M.manaBonus(side)
    if not side or not side.powerups then return 0 end
    local n = M.level(side, "PLI0")
    if n == 0 then n = M.level(side, "PSO0") end
    return 15 * n
end

-- Resistance of a plain unit: the type's value, Black Ward and the resistance bonuses of the statistic list.
---@param unit Unit
---@return number
function M.unitResistance(unit)
    local side = unit.world.sides[unit.side]
    local base = unit.type and unit.type.resistance or 0
    if not side or not side.powerups then return base end
    local b = M.bonus(side, unit.code)
    return base + M.resistanceBonus(side) + (b and b.resistance or 0)
end


-- Flaming Arrows: ranged piercing attacks of plain units (not the ones above) become fire-and-piercing; Faerie Fire:
-- pixies hit with fire. Called from `applyStats` (the army's damage getter at 0x00526310).
---@param unit Unit
---@param st UnitStats
---@param side Side
function M.damageType(unit, st, side)
    if unit.code == "AEXX" and M.has(side, "PFFI") then
        st.damageType = 3
    elseif st.range > 0 and st.damageType == 0 and not unit.hero and not gamedata.hasTag(unit.code, "noFlame") and M.has(side, "PFLA") then
        st.hot = true
    end
end

-- Damage factor of a melee strike (the melee routine FUN_0042ace0; plain attackers only): Paladin doubles a knight's damage, Grand
-- Paladin triples it against the undead, Fallen Knight triples a Slayer / Doom Knight's against humans (else Torture
-- doubles it), Dragon Knight multiplies the high elf cavalry's damage by level + 1 against dragons, Cowards doubles an
-- orc's damage against a side's missile troops.
---@param att Unit
---@param tgt Unit|Building
---@return number
function M.meleeFactor(att, tgt)
    if att.hero or tgt.kind ~= "unit" then return 1 end
    local world = att.world
    local side, tside = world.sides[att.side], world.sides[tgt.side]
    local f, factor = M.flags(tgt.code), 1
    local bit = require("bit")
    local code = att.code
    if side and side.powerups then
        if gamedata.hasTag(code, "knight") then
            if M.has(side, "PGRA") and bit.band(f, 0x4) ~= 0 then factor = factor * 3
            elseif M.has(side, "PPAL") then factor = factor * 2 end
        end
        if gamedata.hasTag(code, "slayerKnight") then
            if M.has(side, "PFAL") and bit.band(f, 0x1) ~= 0 then factor = factor * 3
            elseif M.has(side, "PTOR") then factor = factor * 2 end
        end
        if code == "AECX" and bit.band(f, 0x1000) ~= 0 then factor = factor * (M.level(side, "PDK0") + 1) end
    end
    if code == "AOIX" and tside and M.has(tside, "PCOW") and bit.band(f, 0x40000) ~= 0 then factor = factor * 2 end
    return factor
end

-- Missile picture (FUN_0040ac00 of the original): the Dark Elf Archer's piercing arrows are poison arrows (EMAP) and
-- its hot ones fire-poison arrows (EMFP); any other hot shot is a flaming arrow (EMA2); the Dark Elf Mage's and Spider
-- Priestess's lightning is black lightning (EMM4) with Dark Bolt; otherwise the configured missile.
---@param unit Unit
---@param code string?
---@return string?
function M.missileCode(unit, code)
    local st = unit:stats()
    if st.hot then return unit.code == "AKMX" and "EMFP" or "EMA2" end
    if unit.code == "AKMX" and st.damageType == 0 then return "EMAP" end
    local side = unit.world.sides[unit.side]
    if (unit.code == "AKNX" or unit.code == "AKOX") and st.damageType == 2 and side and M.has(side, "PDAR") then
        return "EMM4"
    end
    return code
end

-- The missile a shot uses: the unit's / building's configured one (Army.cfg shoot column, Building.cfg missile column)
-- put through `missileCode`.
---@param unit Unit
---@return string?
function M.shotCode(unit)
    local info = rules.armyInfo(unit.code)
    local code = info and info.missile
    if not code then
        local b = rules.building(unit.code)
        code = b and b.missile
    end
    return M.missileCode(unit, code)
end

-- Missile resistance (the army's FUN_00527040): piercing missiles do a sixteenth of their damage. Dwarf Lord / Runner,
-- Skeleton, Husk, Skeleton Cavalry and Dragonliche always, Orcs with No Pain, Chameleons with Deflection. Buildings are
-- resistant to the plain piercing missile pictures (FUN_0052e790: EMA0 EMA1 EMA5 EMM3 EMS0 EMAP EMA3 EMA4 EMFP EMA6
-- EMM5; the flaming arrow EMA2 and the black lightning EMM4 are not among them). A shooter whose side has Hunting
-- ignores it (the missile impact FUN_005427e0).
---@param target Unit|Building
---@param shooter (Unit|Building)?
---@param mcode string?
---@return boolean
function M.missileResistant(target, shooter, mcode)
    local world = (shooter and shooter.world) or target.world
    local sside = shooter and world.sides[shooter.side]
    if sside and M.has(sside, "PHUN") then return false end
    if target.kind ~= "unit" then return mcode ~= nil and content.missile._recs[mcode] ~= nil and content.missile._recs[mcode].piercing == true end
    if gamedata.hasTag(target.code, "resistant") then return true end
    local side = world.sides[target.side]
    if not (side and side.powerups) then return false end
    return (target.code == "AOIX" and M.has(side, "PNOP")) or (target.code == "ALBX" and M.has(side, "PDEF"))
end

-- A poison arrow (EMAP) or a fire-poison arrow (EMFP) poisons what it hits (the missile impact FUN_005427e0): the strength is
-- half the shooter's damage, plus half of that again for the fire-poison arrow.
---@param mcode string?
---@param damage number
---@return integer
function M.poisonArrow(mcode, damage)
    if mcode ~= "EMAP" and mcode ~= "EMFP" then return 0 end
    local n = math.floor(damage / 2)
    if mcode == "EMFP" then n = n + math.floor(n / 2) end
    return n
end

-- Assassination chance in percent (binary FUN_00526e70): a plain assassin, gnoll or wasp has 4 (Dark Order 7), Blood Potion
-- +3 and its army level; a hero the Assassin skill's effect (4 + level) plus its items (Hero.mod.assassin).
---@param unit Unit
---@return number
function M.assassin(unit)
    if unit.hero then return unit.h and unit.h.mod.assassin or 0 end
    if not gamedata.hasTag(unit.code, "assassin") then return 0 end
    local side = unit.world.sides[unit.side]
    local n = 4
    if side and M.has(side, "PDAO") then n = 7 end
    if side and M.has(side, "PBLP") then n = n + 3 end
    return n + (unit.level or 0)
end

-- Hit points a plain unit takes back with every hit (FUN_00526f40): vampires 3, giant bats 2 with Vampire Bats.
---@param unit Unit
---@return integer
function M.vampirism(unit)
    if unit.hero then return 0 end
    if unit.code == "AUGX" then return 3 end
    local side = unit.world.sides[unit.side]
    if unit.code == "AABA" and side and M.has(side, "PVAM") then return 2 end
    return 0
end

-- Melkor's Curse: while any active side owns it, poison costs 2 hit points per second instead of 1
-- (the hit point regeneration FUN_0051b820 loops every side, so it is a global effect, not the victim's own).
---@param world World
---@return boolean
function M.melkorCurse(world)
    for i = 0, 6 do
        local s = world.sides[i]
        if s and s.used and not s.defeated and M.has(s, "PMCU") then return true end
    end
    return false
end

-- Doombat: the firebat's fire armour is 50 higher and its weakness is gone (the army's armour getter at 0x00525c80).
---@param target Unit
---@return integer
function M.fireArmour(target)
    if target.code ~= "AAFB" then return 0 end
    local side = target.world.sides[target.side]
    return side and M.has(side, "PDBT") and 50 or 0
end

-- Display ---------------------------------------------------------------------------------------

---@param code string
---@return string
function M.name(code)
    return strings.get("Help.cfg", code .. "_Name") or code
end

---@param code string
---@return string?
function M.description(code)
    return strings.get("Help.cfg", code .. "_Desc")
end

---@param code string
---@return string?
function M.requirementText(code)
    return strings.get("Help.cfg", code .. "_Requ")
end

-- Picture index (0-based) of a power-up in its race's picture, or nil.
---@param raceLetter string
---@param code string
---@return integer?
function M.pictureIndex(raceLetter, code)
    local race = content.race:byLetter(raceLetter)
    for i, c in ipairs(race and race.powerupOrder or {}) do
        if c == code then return i - 1 end
    end
end

return M
