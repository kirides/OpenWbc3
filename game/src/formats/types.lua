-- Unit (.ARM, 332 bytes) and building (.BUI, 200 bytes) type records.
local bin = require("src.core.bin")

local M = {}

-- The footprint of a unit or building: w x h cells and a 16 x 16 bit exclusion mask (row i = bit row).
---@class TypeShape: Shape
---@field w integer
---@field h integer
---@field exclusion table<integer, integer>   [0..15] bit rows

---@alias CombatPoints { [1]: integer, [2]: integer }[]   eight (x, y) offsets, one per direction

---@class ArmPower
---@field id string        four-letter ability code
---@field data integer[]   its four numbers
---@field powerUp string   four-letter code ("\0\0\0\0" = none)

-- A unit type record (.ARM).
---@class ArmRecord
---@field id string
---@field useDefault boolean
---@field moveType integer
---@field name string
---@field sideReq integer
---@field buildTime integer
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
---@field shape TypeShape
---@field psych { strength: integer, type: integer, range: integer }
---@field cost { gold: integer, metal: integer, crystal: integer, stone: integer }
---@field powers ArmPower[]
---@field unitValue integer
---@field setupPoints integer
---@field fidget integer
---@field moveSound integer
---@field combatSound integer
---@field ambient boolean
---@field moveAmount table<integer, integer>   [0..31]
---@field bones integer
---@field attitude integer
---@field fineTune integer[]
---@field attackType integer
---@field shadow integer
---@field flags integer
---@field speech integer
---@field skin integer
---@field deathScream integer
---@field combatPoints CombatPoints?

-- A building type record (.BUI).
---@class BuiRecord
---@field id string
---@field useDefault boolean
---@field name string
---@field buildTime integer
---@field cost { gold: integer, metal: integer, crystal: integer, stone: integer }
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
---@field shape TypeShape
---@field sideReq integer
---@field fire { [1]: integer, [2]: integer }[]      three fire points
---@field rubbleType integer
---@field attackType integer
---@field base TypeShape
---@field emitter { [1]: integer, [2]: integer }[]   three emitter points
---@field combatPoints CombatPoints?

---@param r BinReader
---@return TypeShape
local function shape(r)
    local s = { w = r:u8(), h = r:u8(), exclusion = {} }
    for i = 0, 15 do s.exclusion[i] = r:u16() end
    return s
end

-- The eight combat points: where a shot leaves the unit or building, one (x, y) pixel offset from the top left corner of its selection rectangle
-- per direction (0 north, clockwise); nil when every x is 0 (most units: the shot starts at the middle of the rectangle).
---@param r BinReader
---@param offset integer
---@return CombatPoints?
local function combatPoints(r, offset)
    r:seek(offset)
    local pts, any = {}, false
    for i = 1, 8 do
        local x, y = r:i16(), r:i16()
        pts[i] = { x, y }
        if x ~= 0 then any = true end
    end
    return any and pts or nil
end

---@param data string
---@return ArmRecord? record
---@return string? err
function M.parseArmy(data)
    if #data < 332 then return nil, "short .ARM record" end
    local r = bin.reader(data)
    local a = { id = r:bytes(4) }
    ---@cast a ArmRecord
    a.useDefault = r:u8() ~= 0
    a.moveType = r:u8()
    a.name = r:fixstr(20)
    a.sideReq = r:i16()
    a.buildTime = r:i16()
    a.combat, a.speed, a.resistance, a.hits, a.view = r:i16(), r:i16(), r:i16(), r:i16(), r:i16()
    a.armor, a.strong, a.weak = r:i16(), r:i16(), r:i16()
    r:seek(50)
    a.damage, a.damageType, a.range = r:i16(), r:i16(), r:i16()
    a.shape = shape(r)
    r:seek(90)
    a.psych = { strength = r:u8(), type = r:u8(), range = r:i16() }
    a.cost = { gold = r:i16(), metal = r:i16(), crystal = r:i16(), stone = r:i16() }
    a.powers = {}
    for i = 1, 4 do
        r:seek(104 + (i - 1) * 24)
        local id = r:bytes(4)
        local p = { id = id, data = { r:i32(), r:i32(), r:i32(), r:i32() }, powerUp = r:bytes(4) }
        if id ~= "\0\0\0\0" then a.powers[#a.powers + 1] = p end
    end
    r:seek(200)
    a.unitValue = r:i16()
    a.setupPoints = r:i16()
    a.fidget = r:i16()
    a.moveSound = r:i16()
    a.combatSound = r:i16()
    a.ambient = r:u8() ~= 0
    a.moveAmount = {}
    for i = 0, 31 do a.moveAmount[i] = r:u8() end
    r:seek(244)
    a.bones = r:i16()
    a.attitude = r:i16()
    a.fineTune = { r:i16(), r:i16(), r:i16(), r:i16() }
    a.attackType, a.shadow, a.flags, a.speech, a.skin, a.deathScream = r:i16(), r:i16(), r:i16(), r:i16(), r:i16(), r:i16()
    -- the eight combat points at 268 (read by the army display in the 1.04 binary at 0x00536490: `0x006e4024 + (dir + 83 x
    -- type) x 4`)
    a.combatPoints = combatPoints(r, 268)
    return a
end

---@param data string
---@return BuiRecord? record
---@return string? err
function M.parseBuilding(data)
    if #data < 200 then return nil, "short .BUI record" end
    local r = bin.reader(data)
    local b = { id = r:bytes(4) }
    ---@cast b BuiRecord
    b.useDefault = r:u8() ~= 0
    b.name = r:fixstr(20)
    r:seek(26)
    b.buildTime = r:i16()
    b.cost = { gold = r:i16(), metal = r:i16(), crystal = r:i16(), stone = r:i16() }
    b.combat, b.speed, b.resistance, b.hits, b.view = r:i16(), r:i16(), r:i16(), r:i16(), r:i16()
    b.armor, b.strong, b.weak = r:i16(), r:i16(), r:i16()
    r:seek(56)
    b.damage, b.damageType, b.range = r:i16(), r:i16(), r:i16()
    b.shape = shape(r)
    r:seek(100)
    b.sideReq = r:i16()
    -- three fire points at 106: where the fires of a damaged building burn (x, y pixel offsets from the building's anchor)
    r:seek(106)
    b.fire = { { r:i16(), r:i16() }, { r:i16(), r:i16() }, { r:i16(), r:i16() } }
    -- the rubble type at 150: what a destroyed building leaves behind, 0 = nothing at all, 1..3 = a wreck that
    -- stays on the map. The attack type follows at 152.
    r:seek(150)
    b.rubbleType = r:i16()
    b.attackType = r:i16()
    -- the base shape at 154: the cells that get a dirt decal under the building (same record layout as the shape)
    b.base = shape(r)
    -- three emitter points at 188: where a building's particle emitters sit (x, y pixel offsets from the top left corner of the
    -- building's selection rectangle; x == 0 means none, the original only tests the first point's x; gfx/emitters.lua)
    r:seek(188)
    b.emitter = { { r:i16(), r:i16() }, { r:i16(), r:i16() }, { r:i16(), r:i16() } }
    b.combatPoints = combatPoints(r, 118)         -- the eight combat points, after the fire points
    return b
end

return M
