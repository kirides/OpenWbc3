-- Custom AI scripts: the loose `CustomAI/*.ai` files the skirmish screens offer to computer players
-- (the original's loader FUN_004f76d0 / the editor's and side selection's file listbox). The
-- layout is verified from the 14 shipped files and the 1.04 loader; see docs/formats.md.
-- The shipped files were written with 20 army slots; the 1.04 loader FUN_004f76d0 expects the record sizes of 30 army
-- slots (8440 / 8372 bytes against the files' 6360 / 6292), so it would reject them; openwbc3 reads them as they are
-- (docs/formats.md has the layout).
-- The custom groups of a script (10 records of 556 bytes) are read for completeness but nothing uses them: the
-- 1.04 binary never creates a group of the custom type (docs/todo/not-in-original.md).
local fs = require("src.core.fs")
local config = require("src.core.config")
local bin = require("src.core.bin")
local strings = require("src.game.strings")

local M = {}

-- One 556-byte custom group record: 5 sub groups of 104 bytes (20 army codes, name[20], min, max, used,
-- 1 pad), then the group name[30], used and the attack priorities army production / power-up production / keeps /
-- mines / towers.
local function groupRecord(d, o)
    local function cstr(from, len) return (d:sub(o + from + 1, o + from + len):gsub("%z.*", "")) end
    local sub = {}
    for s = 0, 4 do
        local so = s * 104
        local armies = {}
        for k = 0, 19 do
            local code = d:sub(o + so + k * 4 + 1, o + so + k * 4 + 4)
            if code ~= "\xff\xff\xff\xff" and code ~= "\0\0\0\0" then armies[#armies + 1] = code end
        end
        sub[s + 1] = { name = cstr(so + 80, 20), min = d:byte(o + so + 101), max = d:byte(o + so + 102),
                       used = d:byte(o + so + 103) ~= 0, armies = armies }
    end
    return { name = cstr(520, 30), used = d:byte(o + 551) ~= 0, sub = sub,
             attack = { armyProduction = d:byte(o + 552), powerupProduction = d:byte(o + 553), keeps = d:byte(o + 554),
                        mines = d:byte(o + 555), towers = d:byte(o + 556) } }
end

-- The folder the original reads them from (the string `CustomAI` at 0x00608244, used by FUN_0040ddd0 / FUN_0040e270).
M.dir = "CustomAI"

-- The parameters of one script.
---@class AIParams
---@field race integer                  the header's race, -1 any
---@field raceData integer              the race part's race number, -1 = no race-specific part
---@field desc string
---@field army table<string, integer>   army code -> priority
---@field powerup table<string, integer>
---@field building table<string, integer>
---@field main {armyUpgrades: integer, powerupUpgrades: integer, armyProduction: integer, defenseTowers: integer}
---@field flags AIParamFlags
---@field defense {mines: integer, keeps: integer, armyProduction: integer, powerupProduction: integer}
---@field groups {min: integer[], max: integer[]} group sizes per group type 1..6
---@field customGroups boolean
---@field numberOfGroups integer
---@field custom table[]                the custom group records (unused)

---@class AIParamFlags
---@field heroBoldness integer
---@field armiesInTowers integer        percent of the land army sent into towers
---@field buildersInMines integer
---@field randomness integer
---@field baseRelocation boolean
---@field heroRetreat boolean
---@field toughUnitsInTowers boolean

-- Reads one script: a file name inside CustomAI/ or a full path. Returns the parameters or nil.
---@param name string
---@return AIParams?
function M.load(name)
    local d = (name:match("[/\\]") and fs.read(name)) or fs.read(config.gamedir .. "/" .. M.dir .. "/" .. name)
    if not d or #d < 6416 then return nil end
    local r = bin.Reader.new(d)
    local aiSize, grpSize, defSize, mainSize, raceSize = r:i32(), r:i32(), r:i32(), r:i32(), r:i32()
    if d:sub(21, 29) ~= "AIED_V1.0" or aiSize ~= 6360 or grpSize ~= 48 or defSize ~= 4 or mainSize ~= 4
        or raceSize ~= 6292 then return nil end
    local desc = d:sub(31, 50):gsub("%z.*", "")
    r:seek(52)
    local race = r:i16()          -- the header's race word: high 16 bits = race, -1 = any race
    local p = 56
    local army, powerup, building = {}, {}, {}
    for k = 0, 19 do
        local o = p + 8 + k * 8
        local code = d:sub(o + 1, o + 4)
        if code ~= "\xff\xff\xff\xff" and code ~= "\0\0\0\0" and d:byte(o + 5) == 1 then
            army[code] = d:byte(o + 6)
        end
    end
    for k = 0, 39 do
        local o = p + 168 + k * 8
        local code = d:sub(o + 1, o + 4)
        if code ~= "\xff\xff\xff\xff" and code ~= "\0\0\0\0" and d:byte(o + 5) == 1 then
            powerup[code] = d:byte(o + 6)
        end
    end
    for k = 0, 29 do
        local o = p + 488 + k * 8
        local code = d:sub(o + 1, o + 4)
        if code ~= "\xff\xff\xff\xff" and code ~= "\0\0\0\0" then
            building[code] = d:byte(o + 5)
        end
    end
    -- the race part's race number: -1 = the script has no race-specific part (the default priorities apply, see ai.lua)
    r:seek(p + 4)
    local raceData = r:i16()
    r:seek(p + 6294)
    local main = { armyUpgrades = r:u8(), powerupUpgrades = r:u8(), armyProduction = r:u8(), defenseTowers = r:u8() }
    local flags = { heroBoldness = d:byte(p + 6298), armiesInTowers = d:byte(p + 6299),
                    buildersInMines = d:byte(p + 6300), randomness = d:byte(p + 6301),
                    baseRelocation = d:byte(p + 6302) ~= 0, heroRetreat = d:byte(p + 6303) ~= 0,
                    toughUnitsInTowers = d:byte(p + 6304) ~= 0 }
    r:seek(p + 6308)
    local defense = { mines = r:u8(), keeps = r:u8(), armyProduction = r:u8(), powerupProduction = r:u8() }
    r:seek(p + 6312)
    local min, max = {}, {}
    for k = 1, 6 do min[k] = r:i32() end
    for k = 1, 6 do max[k] = r:i32() end
    local custom = {}
    for g = 0, 9 do custom[g + 1] = groupRecord(d, p + 732 + g * 556) end
    return { race = race, raceData = raceData, desc = desc, army = army, powerup = powerup, building = building,
             main = main, flags = flags, defense = defense, groups = { min = min, max = max },
             customGroups = d:byte(p + 729) ~= 0, numberOfGroups = d:byte(p + 6293), custom = custom }
end

-- The scripts on offer: every `*.ai` in the folder, sorted by display name (Names.cfg [CAI_*] of the
-- file's root, else the header description), each with the race it was written for (-1 = any).
-- Cached: the folder does not change while the game runs.
---@return {file: string, name: string, race: integer}[]
function M.list()
    if M.files then return M.files end
    local out = {}
    for _, f in ipairs(fs.fileList(config.gamedir .. "/" .. M.dir, "%.ai$")) do
        local params = M.load(f)
        if params then
            local root = f:gsub("%.[a-zA-Z]+$", "")
            out[#out + 1] = { file = f, name = strings.get("Names.cfg", "CAI_" .. root:upper())
                                                or params.desc ~= "" and params.desc or root,
                              race = params.race }
        end
    end
    table.sort(out, function(a, b) return a.name:lower() < b.name:lower() end)
    M.files = out
    return out
end

-- The scripts a side may take: the original's skirmish filter compares the whole header word against a side index
-- (not traced in the 1.04 binary yet), so openwbc3 offers the scripts written for the side's race plus the generic
-- ones.
---@param race integer
---@return {file: string, name: string, race: integer}[]
function M.forRace(race)
    local out = {}
    for _, f in ipairs(M.list()) do
        if f.race == -1 or f.race == race then out[#out + 1] = f end
    end
    return out
end

return M
