-- Custom unit attitudes: the loose `CustomUnitAI/*.uai` files (read by the 1.04 binary's FUN_00506c90). Layout (little
-- endian; the original stores booleans in one byte and aligns to two bytes, which gives exactly
-- the 1204 byte body the header announces; checked against the four shipped files):
--   header (254 bytes)  char name[40] @0, char description[200] @40 (both padded with 0xCD after the terminator),
--                       u16 version @240 (1), char fileType[10] @242 ("UnitAIV1"), u16 bodySize @252 (1204)
--   body (1204 bytes, at 254)
--     u16 activeAreaCentre @0 (never set by the editor: 0xCDCD), u16 activeAreaSize @2 (cells), u16 numberOfRules @4
--     (0 in every shipped file; the original ignores it and tests each rule's `used` byte), rule[10] @6 (118 bytes each),
--     idleAction @1186 (14 bytes), u16 icon @1200, u8 designatedUnitUsed @1202, u8 autoSpellCasting @1203
--   rule (118): condition[5] @0 (16 bytes each), action @80 (14), u16 priority @94, u8 used @96, char name[20] @97,
--     u8 overridesPlayerOrders @117
--   condition (16): u16 code @0, u16 unitType @2 (0 me, 1 my hero, 2 designated unit), u8 activeAreaUsed @4,
--     u16 extra[3] @6 (extra[0] = threshold / distance), u8 used @12, u16 expectedResult @14 (1 = TRUE)
--   action (14): u8 used @0, u16 code @2, u8 activeAreaUsed @4, u16 unitType @6 (-1 = none), u16 extra[3] @8
-- The files were written by a text mode fwrite: every 0x0A byte of the data was stored as 0x0D 0x0A (Fallback25.uai has
-- 1459 bytes, its icon 10 stored as 0D 0A), and the original reads them back in text mode ("r"), which undoes it. So
-- the reader replaces CR LF by LF before decoding. Condition / action code names and what they do: game/attitude.lua.
local fs = require("src.core.fs")
local config = require("src.core.config")

local M = {}

M.dir = "CustomUnitAI"
local HEADER, BODY = 254, 1204

local function cstr(d, o, n)
    local s = d:sub(o + 1, o + n)
    return (s:gsub("%z.*", ""))
end

---@class UaiAction
---@field code integer
---@field unit integer       -1 = none
---@field area boolean       uses the active area
---@field extra integer[]    three numbers

---@class UaiCondition
---@field code integer
---@field unit integer       0 me, 1 my hero, 2 designated unit
---@field area boolean
---@field extra integer[]    extra[1] = threshold / distance
---@field result boolean     expected result

---@class UaiRule
---@field priority integer
---@field name string
---@field overrides boolean  overrides player orders
---@field conds UaiCondition[]
---@field action UaiAction

-- A custom unit attitude (.uai).
---@class UaiAttitude
---@field name string
---@field description string
---@field size integer       active area size (cells)
---@field centre integer
---@field icon integer
---@field designated boolean
---@field spells boolean     auto spell casting
---@field rules UaiRule[]
---@field idle UaiAction?

-- Decodes the bytes of one file; returns the attitude table or nil, reason.
--   { name, description, size, centre, icon, designated, spells, rules = { { priority, name, overrides, conds = {
--     { code, unit, area, extra = { a, b, c }, result } }, action = { code, unit, area, extra } } }, idle = action | nil }
---@param d string
---@return UaiAttitude? attitude
---@return string? err
function M.parse(d)
    d = d:gsub("\r\n", "\n")
    if #d < HEADER + BODY then return nil, "too short" end
    local function u8(o) return d:byte(o + 1) end
    local function u16(o) return d:byte(o + 1) + d:byte(o + 2) * 256 end
    local function i16(o) local v = u16(o) return v >= 32768 and v - 65536 or v end
    if u16(240) ~= 1 or cstr(d, 242, 10) ~= "UnitAIV1" or u16(252) ~= BODY then return nil, "bad header" end
    ---@type UaiAttitude
    local ai = { name = cstr(d, 0, 40), description = cstr(d, 40, 200), size = u16(HEADER + 2), centre = u16(HEADER),
                 icon = u16(HEADER + 1200), designated = u8(HEADER + 1202) ~= 0, spells = u8(HEADER + 1203) ~= 0,
                 rules = {} }
    ---@return UaiAction action
    ---@return boolean used
    local function action(o)
        return { code = u16(o + 2), unit = i16(o + 6), area = u8(o + 4) ~= 0,
                 extra = { i16(o + 8), i16(o + 10), i16(o + 12) } }, u8(o) ~= 0
    end
    for r = 0, 9 do
        local o = HEADER + 6 + r * 118
        if u8(o + 96) == 1 then
            local rule = { priority = u16(o + 94), name = cstr(d, o + 97, 20), overrides = u8(o + 117) ~= 0, conds = {} }
            for c = 0, 4 do
                local p = o + c * 16
                if u8(p + 12) == 1 then
                    rule.conds[#rule.conds + 1] = { code = u16(p), unit = u16(p + 2), area = u8(p + 4) ~= 0,
                                                    extra = { i16(p + 6), i16(p + 8), i16(p + 10) },
                                                    result = u16(p + 14) ~= 0 }
                end
            end
            rule.action = action(o + 80)
            ai.rules[#ai.rules + 1] = rule
        end
    end
    local idle, used = action(HEADER + 1186)
    if used then ai.idle = idle end
    return ai
end

-- Reads one file (a name inside CustomUnitAI/ or a full path).
---@param name string
---@return UaiAttitude? attitude
---@return string? err
function M.load(name)
    local d = (name:match("[/\\]") and fs.read(name)) or fs.read(config.gamedir .. "/" .. M.dir .. "/" .. name)
    if not d then return nil, "unreadable" end
    return M.parse(d)
end

-- Every `*.uai` of the folder as { file, root } sorted by file name (the original's file list keeps the directory
-- order; sorted here so that every machine of a network game lists them alike).
---@return { file: string, root: string }[]
function M.files()
    local out = {}
    for _, f in ipairs(fs.fileList(config.gamedir .. "/" .. M.dir, "%.[uU][aA][iI]$")) do
        out[#out + 1] = { file = f, root = (f:gsub("%.[a-zA-Z]+$", "")) }
    end
    table.sort(out, function(a, b) return a.file:lower() < b.file:lower() end)
    return out
end

return M
