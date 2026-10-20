-- Scenario (.SCN) writer, the counterpart of scn.lua, used by the editor.
--
-- Parsed scenarios keep the raw bytes of their chunks (`raw` on the header, objects, tiles and
-- events, `rawSides`, `rawAI`); saving patches the fields the editor can change
-- into those bytes, so whatever is not understood (AI hero data, unknown fields)
-- survives a load/save round trip. Events are written from their tables (src/formats/evt.lua). Objects the editor adds start from a zero-filled chunk
-- with sensible defaults. The file is written plain (the bit-inverted "WB2A" form is only read).
-- Chunk sizes: SCNH 352, SIDH 316, SAIH 260, SM24 49160, MAPH 8+16/tile, FTRH 32, ITMH 112,
-- BLDH/ARMH 160, EFFH 36, EVSH 8+1196*128 (every slot, unused ones zero), ENDX 8; positions are world pixels.
local bin = require("src.core.bin")
local evt = require("src.formats.evt")

local M = {}
M.CELL_W, M.CELL_H = 32, 24

local unpack = unpack or table.unpack

local function u32le(v) v = v % 4294967296 return string.char(v % 256, math.floor(v / 256) % 256,
    math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256) end

-- Byte buffer of a chunk with typed setters (offsets from the start of the chunk).
---@class ScnBuf
---@field b integer[]   the bytes, 1-based
local Buf = {}
Buf.__index = Buf

---@param raw string
---@return ScnBuf
local function buf(raw) return setmetatable({ b = { raw:byte(1, -1) } }, Buf) end
---@param id string
---@param size integer
---@return ScnBuf
local function blank(id, size)
    local b = setmetatable({ b = {} }, Buf)
    for i = 1, size do b.b[i] = 0 end
    local head = id .. u32le(size)
    for i = 1, 8 do b.b[i] = head:byte(i) end
    return b
end

-- The setters write v (nil = 0) at offset o, wrapped to the field's width.
---@param o integer
---@param v integer?
function Buf:u8(o, v) self.b[o + 1] = (v or 0) % 256 end
---@param o integer
---@param v any
function Buf:bool(o, v) self.b[o + 1] = v and 1 or 0 end
---@param o integer
---@param v integer?
function Buf:i16(o, v)
    v = (v or 0) % 65536
    self.b[o + 1], self.b[o + 2] = v % 256, math.floor(v / 256)
end
---@param o integer
---@param v integer?
function Buf:i32(o, v)
    v = (v or 0) % 4294967296
    for i = 0, 3 do self.b[o + 1 + i] = math.floor(v / 256 ^ i) % 256 end
end
---@param o integer
---@param n integer field size (the last byte stays 0)
---@param s string?
function Buf:str(o, n, s)
    s = s or ""
    for i = 1, n do self.b[o + i] = i <= #s and i < n and s:byte(i) or 0 end
end
---@param o integer
---@param s string four-letter code (short ones padded with spaces)
function Buf:code(o, s)
    for i = 1, 4 do self.b[o + i] = s:byte(i) or 32 end
end
---@return string
function Buf:string() return string.char(unpack(self.b)) end

local function cellCentre(gx, gy) return gx * M.CELL_W + 16, gy * M.CELL_H + 12 end
M.cellCentre = cellCentre

-- Writes string `s` into the n-byte field at `o` unless the field already holds it (the originals leave garbage
-- behind the terminator, which a round trip keeps).
---@param b ScnBuf
---@param o integer
---@param n integer
---@param s string?
local function keepStr(b, o, n, s)
    s = s or ""
    local cur = {}
    for i = 1, n do
        local c = b.b[o + i] or 0
        if c == 0 then break end
        cur[#cur + 1] = string.char(c)
    end
    if table.concat(cur) ~= s:sub(1, n) then b:str(o, n, s) end
end

-- Sets a 16-bit field only when the record has a value for it (records of older editors and of the random map
-- generator carry none; what the chunk holds stays then).
---@param b ScnBuf
---@param o integer
---@param v integer?
local function opt16(b, o, v) if v ~= nil then b:i16(o, v) end end

-- The general stats (combat, speed, resistance, hits, view), armour (armour, strong, weak) and damage (damage, type,
-- range) of an army / building record at the chunk offsets given.
---@param b ScnBuf
---@param r ScnArmy|ScnBuilding
---@param general integer
---@param armor integer
---@param damage integer
local function statsFields(b, r, general, armor, damage)
    opt16(b, general, r.combat)
    opt16(b, general + 2, r.speed)
    opt16(b, general + 4, r.resistance)
    opt16(b, general + 6, r.hits)
    opt16(b, general + 8, r.view)
    opt16(b, armor, r.armor)
    opt16(b, armor + 2, r.strong)
    opt16(b, armor + 4, r.weak)
    opt16(b, damage, r.damage)
    opt16(b, damage + 2, r.damageType)
    opt16(b, damage + 4, r.range)
end

-- Chunk of a placed army / building / feature / item (rec fields as parsed by scn.lua). The army record starts at +24 of
-- an ARMH chunk (see docs/formats.md for every offset).
---@param a ScnArmy
---@return string
local function armyChunk(a)
    local b = a.raw and buf(a.raw) or blank("ARMH", 160)
    if not a.raw then
        b:i16(24, 1)                 -- level
        b:i32(28, 0)
        b:i16(32, 2)                 -- behaviour: normal
        b:bool(106, true)            -- alive
        b:bool(108, true)            -- use the type's own statistics
    end
    b:code(8, a.code)
    b:i32(12, a.owner or a.side)
    b:i32(16, a.x)
    b:i32(20, a.y)
    b:i16(24, a.level or 0)           -- plain troops count levels from 0, heroes start at 1
    b:i32(28, a.xp or 0)
    opt16(b, 32, a.behaviour)
    if a.script ~= nil then keepStr(b, 34, 30, a.script) end
    opt16(b, 64, a.globalIndex)
    keepStr(b, 66, 20, a.name)
    if a.tag ~= nil then keepStr(b, 86, 20, a.tag) end
    if a.alive ~= nil then b:bool(106, a.alive) end
    if a.useDefault ~= nil then b:bool(108, a.useDefault) end
    if a.character ~= nil then b:bool(109, a.character) end
    statsFields(b, a, 110, 128, 122)
    opt16(b, 120, a.curHits)
    if a.hero ~= nil then b:bool(144, a.hero) end
    b:i16(156, a.side)
    return b:string()
end

-- BLDH: the building record starts at +32.
---@param r ScnBuilding
---@return string
local function buildingChunk(r)
    local b = r.raw and buf(r.raw) or blank("BLDH", 160)
    if not r.raw then b:bool(34, true) end
    b:code(8, r.code)
    b:i32(12, r.anim)
    b:i32(16, r.dir)
    b:i32(20, r.frame)
    b:i32(24, r.x)
    b:i32(28, r.y)
    opt16(b, 32, r.globalIndex)
    if r.useDefault ~= nil then b:bool(34, r.useDefault) end
    if r.name ~= nil then keepStr(b, 35, 20, r.name) end
    if r.tag ~= nil then keepStr(b, 55, 20, r.tag) end
    if r.character ~= nil then b:bool(75, r.character) end
    statsFields(b, r, 76, 86, 96)
    opt16(b, 102, r.curHits)
    b:i16(108, r.side)
    if r.level ~= nil then b:u8(110, r.level) end
    if r.resources then for i = 1, 4 do b:i16(112 + (i - 1) * 2, r.resources[i]) end end
    return b:string()
end

---@param id string
---@param r ScnFeature
---@return string
local function simpleChunk(id, r)
    local b = r.raw and buf(r.raw) or blank(id, 32)
    b:code(8, r.code)
    b:i32(12, r.anim)
    b:i32(16, r.dir)
    b:i32(20, r.frame)
    b:i32(24, r.x)
    b:i32(28, r.y)
    return b:string()
end

-- ITMH (112 bytes): the record of simpleChunk and the chest (see scn.lua). A chest the editor adds starts with zeroed
-- unused slots; one read from a file keeps the bytes of the slots that are not used.
---@param r ScnItem
---@return string
local function itemChunk(r)
    local b = r.raw and buf(r.raw) or blank("ITMH", 112)
    b:code(8, r.code)
    b:i32(12, r.anim)
    b:i32(16, r.dir)
    b:i32(20, r.frame)
    b:i32(24, r.x)
    b:i32(28, r.y)
    local c = r.chest
    if c then
        for k = 1, 4 do
            local m, o = c.items[k], 32 + (k - 1) * 16
            if m and (k <= c.count or not r.raw) then
                -- the file holds item numbers only (editorlib.chestItemId); a mod item's id is a caller's error, said plainly
                if type(m.index) ~= "number" then error(("chest item %q has no item number"):format(tostring(m.index)), 2) end
                b:i16(o, m.index)
                b:bool(o + 2, m.resource)
                b:i16(o + 4, m.data)
                b:i16(o + 6, m.itemIndex)
                b:i32(o + 8, m.x)
                b:i32(o + 12, m.y)
            end
        end
        b:i16(96, c.count)
        b:bool(98, c.opened)
        b:bool(99, c.resource)
        b:i32(100, c.x)
        b:i32(104, c.y)
        if not r.raw then b:i32(108, 0) end
    end
    return b:string()
end

---@param r ScnEffect
---@return string
local function effectChunk(r)
    local b = r.raw and buf(r.raw) or blank("EFFH", 36)
    b:str(8, 20, r.code)
    b:i32(28, r.x)
    b:i32(32, r.y)
    return b:string()
end

-- One 1196-byte event slot (see evt.lua); `e.raw`, when there is one, supplies the bytes that are not edited.
---@param e ScnEvent
---@return string
local function eventRecord(e)
    local b = e.raw and buf(e.raw) or setmetatable({ b = {} }, Buf)
    if not e.raw then for i = 1, evt.SIZE do b.b[i] = 0 end end
    local c = e.cond
    b:i16(0, c.owner)
    b:i16(2, c.condition)
    b:i16(4, c.number)
    b:i32(8, c.target)
    b:i16(12, c.flags)
    b:i16(14, c.radius)
    local bySlot = {}
    for i, ef in ipairs(e.effects) do bySlot[ef.slot or i] = ef end
    for k = 1, evt.EFFECTS do
        local o, ef = 16 + (k - 1) * evt.EFFECT_SIZE, bySlot[k]
        if ef then
            b:bool(o, true)
            b:i16(o + 2, ef.ownerType)
            b:i16(o + 4, ef.ownerData)
            b:i16(o + 6, ef.effect)
            b:i16(o + 8, ef.number)
            b:i16(o + 10, ef.location)
            b:i32(o + 12, ef.type)
            keepStr(b, o + 16, 260, ef.text)
            b:i32(o + 276, ef.x)
            b:i32(o + 280, ef.y)
        elseif b.b[o + 1] ~= 0 then
            for i = 1, evt.EFFECT_SIZE do b.b[o + i] = 0 end      -- an effect that was removed
        end
    end
    b:code(1152, e.code or "    ")
    b:i16(1156, e.loopCount)
    b:i16(1158, e.shots)
    b:bool(1160, e.onMap)
    keepStr(b, 1161, 20, e.name)
    b:i16(1182, e.seconds)
    b:i32(1184, e.x)
    b:i32(1188, e.y)
    b:bool(1192, false)              -- not done
    b:bool(1193, true)
    return b:string()
end
M.eventRecord = eventRecord

-- EVSH: the events in order (at most 128), padded to 128 zero slots.
---@param scn Scenario
---@return string
local function eventsChunk(scn)
    local parts = { "EVSH", u32le(8 + evt.SIZE * evt.MAX) }
    for i = 1, evt.MAX do
        local e = scn.events[i]
        parts[#parts + 1] = e and eventRecord(e) or string.rep("\0", evt.SIZE)
    end
    return table.concat(parts)
end

local MODS = { "noDragons", "noFliers", "noLords", "toughTowers", "noTowers", "noWalls", "noHeroes" }
M.MODS = MODS

---@param scn Scenario
---@return string
local function headerChunk(scn)
    local h = scn.header
    local b = h.raw and buf(h.raw) or blank("SCNH", 352)
    if not h.raw then b:str(8, 16, "WARLORDS 3.00") end
    keepStr(b, 40, 32, h.name)
    b:i32(72, h.numPlayers)
    b:i32(76, scn.width)
    b:i32(80, scn.height)
    keepStr(b, 84, 200, h.description)
    local o = h.options
    if o then
        -- the scenario options at +284 (offsets in docs/formats.md); a field the table lacks stays as the chunk has it
        local function flag(off, v) if v ~= nil then b:bool(284 + off, v) end end
        local function word(off, v) if v ~= nil then b:i16(284 + off, v) end end
        word(0, o.fog)
        flag(2, o.fogLocked)
        flag(3, o.hiddenMap)
        flag(4, o.hiddenLocked)
        flag(5, o.combatRandom)
        flag(6, o.handicapping)
        flag(7, o.handicapLocked)
        flag(8, o.resourcesCustom)
        flag(9, o.quests)
        flag(10, o.questsLocked)
        word(12, o.environment)
        word(14, o.victory)
        flag(16, o.standardData)
        word(18, o.techLevel)
        flag(20, o.techLocked)
        word(22, o.baseSetup)
        flag(24, o.chooseCity)
        word(26, o.armySetupPoints)
        flag(28, o.pointsLocked)
        for i, name in ipairs(MODS) do
            if o.mods then flag(29 + (i - 1) * 2, o.mods[name] == true) end
            if o.modLocks then flag(30 + (i - 1) * 2, o.modLocks[name] == true) end
        end
    end
    if h.type ~= nil then b:i16(328, h.type) end
    if h.firstSideOnly ~= nil then b:bool(330, h.firstSideOnly) end
    b:bool(331, h.produceHeroes)
    b:bool(332, h.standardVictory)
    if h.showMap ~= nil then b:bool(333, h.showMap) end
    return b:string()
end

---@param scn Scenario
---@return string
local function sidesChunk(scn)
    local b = scn.rawSides and buf(scn.rawSides) or blank("SIDH", 316)
    for i = 0, 6 do
        local s = scn.sides[i]
        local o = 8 + i * 44
        b:bool(o, s.used)
        b:i16(o + 2, s.race)
        if s.raceLocked ~= nil then b:bool(o + 4, s.raceLocked) end
        b:i16(o + 6, s.color)
        b:i16(o + 8, s.team)
        if s.teamLocked ~= nil then b:bool(o + 10, s.teamLocked) end
        b:i16(o + 12, s.resources)
        if s.resourcesLocked ~= nil then b:bool(o + 14, s.resourcesLocked) end
        b:i16(o + 16, s.aiLevel)
        if s.aiLocked ~= nil then b:bool(o + 18, s.aiLocked) end
        b:i32(o + 20, s.startX)
        b:i32(o + 24, s.startY)
        if s.random ~= nil then b:bool(o + 28, s.random) end
        if s.startGold ~= nil then
            b:i16(o + 32, s.startGold)
            b:i16(o + 34, s.startMetal)
            b:i16(o + 36, s.startCrystal)
            b:i16(o + 38, s.startStone)
        end
        if s.mustBeHuman ~= nil then b:bool(o + 40, s.mustBeHuman) end
        if s.mustBeOn ~= nil then b:bool(o + 41, s.mustBeOn) end
    end
    return b:string()
end

-- SAIH: the six computer hero / AI records (see scn.lua); the chunk is rebuilt from `scn.ai` when the scenario has it.
---@param scn Scenario
---@return string
local function aiChunk(scn)
    local b = scn.rawAI and buf(scn.rawAI) or blank("SAIH", 260)
    if scn.ai then
        for i = 0, 5 do
            local a, o = scn.ai[i], 8 + i * 42
            if a then
                b:i16(o, a.race)
                b:i16(o + 2, a.portrait)
                b:i16(o + 4, a.level)
                b:i16(o + 6, a.personality)
                b:i16(o + 8, a.class)
                keepStr(b, o + 10, 32, a.file)
            end
        end
    end
    return b:string()
end

---@param scn Scenario
---@return string
local function mapChunk(scn)
    local parts = { "MAPH", u32le(8 + scn.tilesW * scn.tilesH * 16) }
    for i = 0, scn.tilesW * scn.tilesH - 1 do parts[#parts + 1] = scn.tiles[i].raw end
    return table.concat(parts)
end

-- The chunk writers, for the round trip test (every shipped chunk must come out as it went in).
M.chunk = { army = armyChunk, building = buildingChunk, item = itemChunk, header = headerChunk, sides = sidesChunk,
            ai = aiChunk }

---@param scn Scenario
---@return string
function M.write(scn)
    local parts = {}
    local function add(s) parts[#parts + 1] = s end
    add(headerChunk(scn))
    add(sidesChunk(scn))
    add(aiChunk(scn))
    add("SM24" .. u32le(8 + 128 * 128 * 3) .. (scn.minimap or string.rep("\0", 128 * 128 * 3)))
    add(mapChunk(scn))
    for _, f in ipairs(scn.features) do add(simpleChunk("FTRH", f)) end
    for _, b in ipairs(scn.buildings) do add(buildingChunk(b)) end
    for _, a in ipairs(scn.armies) do add(armyChunk(a)) end
    for _, i in ipairs(scn.items) do add(itemChunk(i)) end
    for _, e in ipairs(scn.effects) do add(effectChunk(e)) end
    add(eventsChunk(scn))
    add("ENDX" .. u32le(8))
    return table.concat(parts)
end

-- 16-byte map slot record for a tile type (see terrain.lua for what the bytes mean).
---@param id string
---@param index integer?
---@param part integer
---@param animated boolean?
---@param frames integer?
---@param size integer?
---@return string
function M.tileRecord(id, index, part, animated, frames, size)
    local b = setmetatable({ b = {} }, Buf)
    for i = 1, 16 do b.b[i] = 0 end
    b:code(0, id)
    b:i16(4, index or 0)
    b:u8(6, part)
    b:bool(7, animated)
    b:u8(9, frames or 1)
    b:u8(11, size or 0)
    return b:string()
end

---@class ScnNewTile
---@field id string
---@field index integer?
---@field animated boolean?
---@field frames integer?
---@field size integer?

-- A new scenario: `size` x `size` cells filled with tile `tile` ({ id, index, animated, frames, size }).
---@param opts { size: integer?, name: string?, description: string?, tile: ScnNewTile }
---@return Scenario
function M.new(opts)
    local size = opts.size or 64
    local tw = math.floor((size - 1) / 10) + 1
    local scn = {
        width = size, height = size, tilesW = tw, tilesH = tw,
        armies = {}, buildings = {}, features = {}, items = {}, effects = {}, events = { evt.standardVictory() },
        header = {
            name = opts.name or "", description = opts.description or "", numPlayers = 2, width = size, height = size,
            -- the defaults of the original editor's "new scenario" (handler at 0x004bfb50, not re-checked in the
            -- 1.04 binary: fog 1, hidden map, quests on, tech level 5, choose city setup, no locks, no game mods)
            options = { fog = 1, fogLocked = false, hiddenMap = true, hiddenLocked = false, combatRandom = false,
                        handicapping = false, handicapLocked = false, resourcesCustom = false, quests = true,
                        questsLocked = false, environment = 0, victory = 0, standardData = false, techLevel = 5,
                        techLocked = false, baseSetup = 0, chooseCity = true, armySetupPoints = 0, pointsLocked = false,
                        mods = {}, modLocks = {} },
            produceHeroes = true, standardVictory = true, showMap = true, type = 0, firstSideOnly = false,
        },
        sides = {}, tiles = {},
        ai = {},
    } --[[@as Scenario]]
    for i = 0, 5 do scn.ai[i] = { race = -1, portrait = 0, level = -1, personality = -1, class = -1, file = "" } end
    for i = 0, 6 do
        scn.sides[i] = { used = i < 2, race = 0, color = i, team = 0, resources = 2, aiLevel = 2, startX = -1, startY = -1,
                         raceLocked = false, teamLocked = false, resourcesLocked = false, aiLocked = false,
                         random = false, mustBeHuman = false, mustBeOn = false }
    end
    scn.sides[6].color = 6
    M.fill(scn, opts.tile)
    return scn
end

-- Fills every tile slot with `tile`.
---@param scn Scenario
---@param tile ScnNewTile
function M.fill(scn, tile)
    for i = 0, scn.tilesW * scn.tilesH - 1 do
        scn.tiles[i] = { id = tile.id, raw = M.tileRecord(tile.id, tile.index, 0, tile.animated, tile.frames, 0), part = 0 }
    end
end

return M
