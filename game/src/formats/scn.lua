-- Scenario (.SCN) reader.
--
-- A scenario is a list of chunks {char id[4]; u32 size (incl. this 8-byte header)}:
--   SCNH header, SIDH sides, SAIH AI heroes, SM24 minimap (128x128 BGR),
--   MAPH terrain tile grid, ARMH/BLDH/FTRH/ITMH/EFFH placed objects,
--   EVSH events, ENDX end.
-- Object positions are world pixels (cell centre = gx*32+16, gy*24+12).
local bin = require("src.core.bin")
local evt = require("src.formats.evt")
local bit = require("bit")

local M = {}

---@class ScnOptions
---@field fog integer
---@field fogLocked boolean
---@field hiddenMap boolean
---@field hiddenLocked boolean
---@field combatRandom boolean
---@field handicapping boolean
---@field handicapLocked boolean
---@field resourcesCustom boolean
---@field quests boolean
---@field questsLocked boolean
---@field environment integer
---@field victory integer
---@field techLevel integer
---@field techLocked boolean
---@field standardData boolean
---@field baseSetup integer
---@field chooseCity boolean
---@field armySetupPoints integer
---@field pointsLocked boolean
---@field mods table<string, boolean>      game modifiers by name (noDragons, noFliers ... noHeroes)
---@field modLocks table<string, boolean>

-- SCNH.
---@class ScnHeader
---@field version string?   (nil in a scenario made by the editor)
---@field code string?
---@field name string
---@field numPlayers integer
---@field width integer       cells
---@field height integer
---@field description string
---@field options ScnOptions
---@field type integer
---@field firstSideOnly boolean
---@field produceHeroes boolean
---@field standardVictory boolean
---@field showMap boolean
---@field raw string?         the chunk as read

-- A SIDH side record.
---@class ScnSide
---@field used boolean
---@field race integer
---@field raceLocked boolean
---@field color integer
---@field team integer
---@field teamLocked boolean
---@field resources integer
---@field resourcesLocked boolean
---@field aiLevel integer
---@field aiLocked boolean
---@field startX integer      start cell, -1 = none
---@field startY integer
---@field random boolean
---@field startGold integer?    (the four start resources are nil in a side made by the editor)
---@field startMetal integer?
---@field startCrystal integer?
---@field startStone integer?
---@field mustBeHuman boolean
---@field mustBeOn boolean
---@field aiFile string?      the side's custom AI script (from SAIH)
---@field aiHero table?       race / class / level of the computer's hero (set by the setup screens, game/aihero.lua)

-- A SAIH record: a computer side's hero and AI.
---@class ScnAIHero
---@field race integer
---@field portrait integer
---@field level integer
---@field personality integer
---@field class integer
---@field file string         CustomAI/*.ai script, "" for none

-- A MAPH terrain tile slot (10 x 10 cells).
---@class ScnTile
---@field id string           four-letter tile code
---@field raw string          the 16 bytes as read
---@field part integer
---@field animated boolean?   (the rest is nil in a slot made by the editor or the random map: `raw` holds it)
---@field frame integer?
---@field maxFrames integer?
---@field flags integer?
---@field size integer?

-- ARMH: a placed unit.
---@class ScnArmy
---@field code string
---@field owner integer
---@field x integer           world pixels
---@field y integer
---@field level integer
---@field xp integer
---@field behaviour integer
---@field script string
---@field globalIndex integer
---@field name string
---@field tag string
---@field alive boolean
---@field useDefault boolean
---@field character boolean
---@field combat integer
---@field speed integer
---@field resistance integer
---@field hits integer
---@field view integer
---@field curHits integer
---@field damage integer
---@field damageType integer
---@field range integer
---@field armor integer
---@field strong integer
---@field weak integer
---@field hero boolean
---@field side integer
---@field raw string?

-- BLDH: a placed building.
---@class ScnBuilding
---@field code string
---@field anim integer
---@field dir integer
---@field frame integer
---@field x integer
---@field y integer
---@field globalIndex integer
---@field useDefault boolean
---@field name string
---@field tag string
---@field character boolean
---@field combat integer
---@field speed integer
---@field resistance integer
---@field hits integer
---@field view integer
---@field armor integer
---@field strong integer
---@field weak integer
---@field damage integer
---@field damageType integer
---@field range integer
---@field curHits integer
---@field side integer
---@field level integer
---@field resources integer[]
---@field raw string?

-- FTRH: a placed feature.
---@class ScnFeature
---@field code string
---@field anim integer
---@field dir integer
---@field frame integer
---@field x integer
---@field y integer
---@field raw string?

---@class ScnChestSlot
---@field index integer       item table index, -2 = random
---@field resource boolean
---@field data integer        resource type
---@field itemIndex integer
---@field x integer
---@field y integer

---@class ScnChest
---@field items ScnChestSlot[]   four slots (unused ones as read)
---@field count integer
---@field opened boolean
---@field resource boolean
---@field x integer
---@field y integer

-- ITMH: a placed item (chest).
---@class ScnItem: ScnFeature
---@field chest ScnChest

-- EFFH: a placed effect.
---@class ScnEffect
---@field code string
---@field x integer
---@field y integer
---@field raw string?

-- A parsed scenario. Every chunk's bytes are kept (`raw`) for src/formats/scnwrite.lua.
---@class Scenario
---@field header ScnHeader
---@field width integer       cells (from the header)
---@field height integer
---@field sides table<integer, ScnSide>      [0..6] (SIDH; every shipped scenario has SIDH and MAPH, the code relies on them)
---@field rawSides string?
---@field ai table<integer, ScnAIHero>?     [0..5]
---@field rawAI string?
---@field minimap string?     128 x 128 BGR
---@field tiles table<integer, ScnTile>     [ty * tilesW + tx], 0-based
---@field tilesW integer      tile slots across
---@field tilesH integer
---@field armies ScnArmy[]
---@field buildings ScnBuilding[]
---@field features ScnFeature[]
---@field items ScnItem[]
---@field effects ScnEffect[]
---@field events ScnEvent[]   the used slots, in slot order

---@param r BinReader
---@return string
local function fourcc(r)
    return r:bytes(4)
end

---@param r BinReader
---@param base integer
---@return ScnHeader
local function parseHeader(r, base)
    local h = {}
    ---@cast h ScnHeader
    r:seek(base + 8)
    h.version = r:fixstr(16)
    h.code = r:fixstr(16)
    h.name = r:fixstr(32)
    h.numPlayers = r:i32()
    h.width = r:i32()
    h.height = r:i32()
    h.description = r:fixstr(200)
    local o = base + 284
    r:seek(o)
    local options = {
        fog = r:i16(),
        fogLocked = r:u8() ~= 0,
        hiddenMap = r:u8() ~= 0,
        hiddenLocked = r:u8() ~= 0,
        combatRandom = r:u8() ~= 0,
        handicapping = r:u8() ~= 0,
        handicapLocked = r:u8() ~= 0,
        resourcesCustom = r:u8() ~= 0,
        quests = r:u8() ~= 0,
        questsLocked = r:u8() ~= 0,
    }
    ---@cast options ScnOptions
    h.options = options
    r:seek(o + 12)
    h.options.environment = r:i16()
    h.options.victory = r:i16()
    r:seek(o + 18)
    h.options.techLevel = r:i16()
    h.options.techLocked = r:u8() ~= 0
    r:seek(o + 16)
    h.options.standardData = r:u8() ~= 0
    r:seek(o + 22)
    h.options.baseSetup = r:i16()
    h.options.chooseCity = r:u8() ~= 0
    r:seek(o + 26)
    h.options.armySetupPoints = r:i16()
    h.options.pointsLocked = r:u8() ~= 0
    -- game modifiers: seven (flag, locked) byte pairs after the army setup points
    h.options.mods, h.options.modLocks = {}, {}
    for i, name in ipairs({ "noDragons", "noFliers", "noLords", "toughTowers", "noTowers", "noWalls", "noHeroes" }) do
        r:seek(o + 29 + (i - 1) * 2)
        h.options.mods[name] = r:u8() ~= 0
        h.options.modLocks[name] = r:u8() ~= 0
    end
    r:seek(base + 328)
    h.type = r:i16()
    h.firstSideOnly = r:u8() ~= 0
    h.produceHeroes = r:u8() ~= 0
    h.standardVictory = r:u8() ~= 0
    h.showMap = r:u8() ~= 0
    return h
end

---@param r BinReader
---@param base integer
---@return table<integer, ScnSide>
local function parseSides(r, base)
    local sides = {}
    for i = 0, 6 do
        local o = base + 8 + i * 44
        r:seek(o)
        local s = { used = r:u8() ~= 0 }
        ---@cast s ScnSide
        r:seek(o + 2)
        s.race = r:i16()
        s.raceLocked = r:u8() ~= 0
        r:seek(o + 6)
        s.color = r:i16()
        s.team = r:i16()
        s.teamLocked = r:u8() ~= 0
        r:seek(o + 12)
        s.resources = r:i16()
        s.resourcesLocked = r:u8() ~= 0
        r:seek(o + 16)
        s.aiLevel = r:i16()
        s.aiLocked = r:u8() ~= 0
        r:seek(o + 20)
        s.startX = r:i32()
        s.startY = r:i32()
        s.random = r:u8() ~= 0
        r:seek(o + 32)
        s.startGold, s.startMetal, s.startCrystal, s.startStone = r:i16(), r:i16(), r:i16(), r:i16()
        s.mustBeHuman = r:u8() ~= 0
        s.mustBeOn = r:u8() ~= 0
        sides[i] = s
    end
    return sides
end

-- SAIH: six 42-byte records (a computer side's hero and AI): race, portrait, level, personality, class (i16 each) and the name of
-- the side's custom AI script (a CustomAI/*.ai file, "" for none)
---@param r BinReader
---@param base integer
---@return table<integer, ScnAIHero>
local function parseAI(r, base)
    local ai = {}
    for i = 0, 5 do
        local o = base + 8 + i * 42
        r:seek(o)
        ai[i] = { race = r:i16(), portrait = r:i16(), level = r:i16(), personality = r:i16(), class = r:i16(),
                  file = r:fixstr(32) }
    end
    return ai
end

---@param r BinReader
---@param base integer
---@param w integer
---@param h integer
---@param data string
---@return table<integer, ScnTile> tiles
---@return integer tw
---@return integer th
local function parseMap(r, base, w, h, data)
    local tw = math.floor((w - 1) / 10) + 1
    local th = math.floor((h - 1) / 10) + 1
    local tiles = {}
    r:seek(base + 8)
    for ty = 0, th - 1 do
        for tx = 0, tw - 1 do
            local o = r:tell()
            local t = { id = fourcc(r), raw = data:sub(o + 1, o + 16) }
            ---@cast t ScnTile
            r:seek(o + 6)
            t.part = r:u8()
            t.animated = r:u8() ~= 0
            t.frame = r:u8()
            t.maxFrames = r:u8()
            t.flags = r:u8()
            t.size = r:u8()
            r:seek(o + 16)
            tiles[ty * tw + tx] = t
        end
    end
    return tiles, tw, th
end

---@param r BinReader
---@param base integer
---@return ScnArmy
local function parseArmy(r, base)
    r:seek(base + 8)
    local a = { code = fourcc(r), owner = r:i32(), x = r:i32(), y = r:i32() }
    ---@cast a ScnArmy
    local o = base + 8 + 16
    r:seek(o)
    a.level = r:i16()
    r:seek(o + 4)
    a.xp = r:i32()
    a.behaviour = r:i16()
    a.script = r:fixstr(30)
    a.globalIndex = r:i16()
    a.name = r:fixstr(20)
    a.tag = r:fixstr(20)
    a.alive = r:u8() ~= 0
    r:seek(o + 84)
    a.useDefault = r:u8() ~= 0
    a.character = r:u8() ~= 0
    a.combat, a.speed, a.resistance, a.hits, a.view = r:i16(), r:i16(), r:i16(), r:i16(), r:i16()
    a.curHits = r:i16()
    a.damage, a.damageType, a.range = r:i16(), r:i16(), r:i16()
    a.armor, a.strong, a.weak = r:i16(), r:i16(), r:i16()
    r:seek(o + 120)
    a.hero = r:u8() ~= 0
    r:seek(o + 132)
    a.side = r:i16()
    return a
end

---@param r BinReader
---@param base integer
---@return ScnBuilding
local function parseBuilding(r, base)
    r:seek(base + 8)
    local b = { code = fourcc(r), anim = r:i32(), dir = r:i32(), frame = r:i32(), x = r:i32(), y = r:i32() }
    ---@cast b ScnBuilding
    local o = base + 8 + 24
    r:seek(o)
    b.globalIndex = r:i16()
    b.useDefault = r:u8() ~= 0
    b.name = r:fixstr(20)
    b.tag = r:fixstr(20)
    r:seek(o + 43)
    b.character = r:u8() ~= 0
    b.combat, b.speed, b.resistance, b.hits, b.view = r:i16(), r:i16(), r:i16(), r:i16(), r:i16()
    b.armor, b.strong, b.weak = r:i16(), r:i16(), r:i16()
    r:seek(o + 64)
    b.damage, b.damageType, b.range = r:i16(), r:i16(), r:i16()
    b.curHits = r:i16()
    r:seek(o + 76)
    b.side = r:i16()
    b.level = r:u8()
    r:seek(o + 80)
    b.resources = { r:i16(), r:i16(), r:i16(), r:i16() }
    return b
end

---@param r BinReader
---@param base integer
---@return ScnFeature
local function parseFeature(r, base)
    r:seek(base + 8)
    return { code = fourcc(r), anim = r:i32(), dir = r:i32(), frame = r:i32(), x = r:i32(), y = r:i32() }
end

-- ITMH (112 bytes): the item record { id, animation, direction, frame, x, y } followed by the chest: four item slots
-- (u16 index into the item table, -2 = a random item; u8 resource flag; u16 data = resource type; u16 item index;
-- i32 x, y cell: 16 bytes each), u16 number of items, u8 opened, u8 resource chest, i32 x, y (cell), i32 being viewed.
-- The unused item slots hold whatever was in memory; they are kept as read (`raw`).
---@param r BinReader
---@param base integer
---@return ScnItem
local function parseItem(r, base)
    r:seek(base + 8)
    local it = { code = fourcc(r), anim = r:i32(), dir = r:i32(), frame = r:i32(), x = r:i32(), y = r:i32() }
    ---@cast it ScnItem
    local c = { items = {} }
    ---@cast c ScnChest
    for k = 0, 3 do
        r:seek(base + 32 + k * 16)
        local m = { index = r:i16(), resource = r:u8() ~= 0 }
        ---@cast m ScnChestSlot
        c.items[k + 1] = m
        r:seek(base + 32 + k * 16 + 4)
        m.data, m.itemIndex, m.x, m.y = r:u16(), r:u16(), r:i32(), r:i32()
    end
    c.count = r:u16()
    c.opened = r:u8() ~= 0
    c.resource = r:u8() ~= 0
    c.x, c.y = r:i32(), r:i32()
    it.chest = c
    return it
end

---@param r BinReader
---@param base integer
---@return ScnEffect
local function parseEffect(r, base)
    r:seek(base + 8)
    return { code = r:fixstr(20), x = r:i32(), y = r:i32() }
end

-- The EVSH chunk holds 128 event slots (src/formats/evt.lua); the used ones come first. An event's `index` is its
-- slot (0 = the standard victory event the editor does not show).
---@param r BinReader
---@param base integer
---@param size integer
---@return ScnEvent[]
local function parseEvents(r, base, size)
    local events = {}
    local n = math.floor((size - 8) / evt.SIZE)
    for i = 0, n - 1 do
        local e, used = evt.parseRecord(r, base + 8 + i * evt.SIZE)
        if used then
            e.index = i
            events[#events + 1] = e
        end
    end
    return events
end

-- Parses a scenario (plain or "WB2A" inverted); nil and a reason when it has no header.
---@param data string
---@return Scenario? scn
---@return string? err
function M.parse(data)
    if data:sub(1, 4) == "WB2A" then
        -- "authorised" scenarios: bit-inverted after an 8-byte tag
        local inv = {}
        for i = 9, #data do inv[#inv + 1] = string.char(bit.band(bit.bnot(data:byte(i)), 255)) end
        data = table.concat(inv)
    end
    local r = bin.reader(data)
    -- The raw bytes of every chunk are kept (`raw` fields) so that
    -- src/formats/scnwrite.lua can save an edited scenario without losing what is not parsed.
    local scn = { armies = {}, buildings = {}, features = {}, items = {}, effects = {}, events = {} }
    ---@cast scn Scenario
    local pos = 0
    while pos + 8 <= #data do
        r:seek(pos)
        local id = r:bytes(4)
        local size = r:u32()
        if size < 8 then break end
        local chunk = data:sub(pos + 1, pos + size)
        if id == "SCNH" then
            scn.header = parseHeader(r, pos)
            scn.header.raw = chunk
            scn.width, scn.height = scn.header.width, scn.header.height
        elseif id == "SIDH" then
            scn.sides = parseSides(r, pos)
            scn.rawSides = chunk
        elseif id == "SAIH" then
            scn.rawAI = chunk
            scn.ai = parseAI(r, pos)
        elseif id == "SM24" then
            scn.minimap = data:sub(pos + 9, pos + 8 + 128 * 128 * 3)
        elseif id == "MAPH" then
            scn.tiles, scn.tilesW, scn.tilesH = parseMap(r, pos, scn.width, scn.height, data)
        elseif id == "ARMH" then
            scn.armies[#scn.armies + 1] = parseArmy(r, pos)
            scn.armies[#scn.armies].raw = chunk
        elseif id == "BLDH" then
            scn.buildings[#scn.buildings + 1] = parseBuilding(r, pos)
            scn.buildings[#scn.buildings].raw = chunk
        elseif id == "FTRH" then
            scn.features[#scn.features + 1] = parseFeature(r, pos)
            scn.features[#scn.features].raw = chunk
        elseif id == "ITMH" then
            scn.items[#scn.items + 1] = parseItem(r, pos)
            scn.items[#scn.items].raw = chunk
        elseif id == "EFFH" then
            scn.effects[#scn.effects + 1] = parseEffect(r, pos)
            scn.effects[#scn.effects].raw = chunk
        elseif id == "EVSH" then
            scn.events = parseEvents(r, pos, size)
        elseif id == "ENDX" then
            break
        end
        pos = pos + size
    end
    if not scn.header then return nil, "missing SCNH header" end
    -- the custom AI script of a side comes with the scenario (a side that has one plays with it)
    for i = 0, 5 do
        local ai = scn.ai and scn.ai[i]
        if scn.sides and scn.sides[i] and ai and ai.file ~= "" then scn.sides[i].aiFile = ai.file end
    end
    return scn
end

return M
