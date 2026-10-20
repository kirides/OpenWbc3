-- Scenario event records (EVSH chunk of a .SCN and the event pool <game dir>\EVENTS\*.EVT).
--
-- An event is one fixed 1196-byte record; a .EVT file is exactly one record, the EVSH chunk of a scenario is
-- 128 of them (the original's event slots per scenario) after the 8-byte chunk header.
-- The first `used` records are the scenario's events; slot 0 is the standard victory event (condition 10).
--   +0     condition: u16 owner, u16 condition, u16 number, (2 bytes padding), u32 target, u16 flags, u16 radius
--   +16    4 effects of 284 bytes each:
--            u8 used, (1 padding), u16 ownerType, u16 ownerData, u16 effect, u16 number, u16 location,
--            u32 type, char text[260] (a file / character name or the message), i32 x, i32 y
--   +1152  char code[4]   the pool template the event came from (names it in the list, see Names.cfg [EVENT_xxxx])
--   +1156  u16 loopCount, +1158 u16 shots (0 = repeat), +1160 u8 onMap (0: a timer, no map position)
--   +1161  char name[20], +1182 u16 seconds (timer), +1184 i32 x, +1188 i32 y (cell of the condition)
--   +1192  u8 done, +1193 u8 used, then 2 bytes of padding
-- What the numbers of the condition and the effects mean is in src/game/events.lua. The .lst files of the EVENTS
-- folder (Army.lst, Building.lst ...) are not read by the 1.04 binary (the dialogs list the type tables), so
-- they are not used here either.
local bin = require("src.core.bin")
local fs = require("src.core.fs")
local config = require("src.core.config")

local M = {}

---@class ScnEventCond
---@field owner integer
---@field condition integer   condition number (src/game/events.lua)
---@field number integer
---@field target integer      u32: a packed type code (M.pack), 0 or M.ANY
---@field flags integer
---@field radius integer

---@class ScnEventEffect
---@field slot integer        1..4: the record's effect slot
---@field ownerType integer
---@field ownerData integer
---@field effect integer      effect number (src/game/events.lua)
---@field number integer
---@field location integer
---@field type integer        u32: a packed type code
---@field text string         a file / character name or the message
---@field x integer
---@field y integer

-- One event record (a scenario's EVSH slot or a pool .EVT file).
---@class ScnEvent
---@field raw string?         the record's 1196 bytes as read (nil for events made from scratch)
---@field cond ScnEventCond
---@field effects ScnEventEffect[]   the used effects only
---@field code string         the pool template's code
---@field loopCount integer
---@field shots integer       0 = repeat
---@field onMap boolean       false: a timer, no map position
---@field name string
---@field seconds integer     timer
---@field x integer           cell of the condition
---@field y integer
---@field index integer?      slot in the scenario (set by scn.parse; 0 = the standard victory event)

-- An entry of the event pool (EVENTS/*.EVT).
---@class EvtPoolEntry
---@field file string
---@field code string         the file's root
---@field name string         display name
---@field event ScnEvent
---@field used boolean

M.SIZE = 1196
M.MAX = 128             -- slots in a scenario
M.EFFECTS = 4           -- effects per event
M.EFFECT_SIZE = 284
M.ANY = 0xFFFFFFFF      -- a `target` of -1: any type

-- A 4-letter type code as the u32 of a condition's `target` / an effect's `type` (first letter in the low byte),
-- and back (nil for 0, -1 and anything that is not four letters).
---@param code string
---@return integer
function M.pack(code)
    local a, b, c, d = code:byte(1, 4)
    return a + b * 256 + c * 65536 + d * 16777216
end

---@param v integer?
---@return string?
function M.unpack(v)
    if not v or v == 0 or v == M.ANY then return nil end
    local s = string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256)
    return s:match("^%w%w%w%w$") and s or nil
end

-- Reads the record at byte `o` of the reader's data; returns the event table and whether the slot is used.
-- `index` is the slot, `raw` the 1196 bytes (kept so that the writer can patch them and lose nothing).
---@param r BinReader
---@param o integer
---@return ScnEvent event
---@return boolean used
function M.parseRecord(r, o)
    local e = { raw = r.data:sub(o + 1, o + M.SIZE) }
    ---@cast e ScnEvent
    r:seek(o)
    local cond = { owner = r:i16(), condition = r:i16(), number = r:i16() }
    ---@cast cond ScnEventCond
    e.cond = cond
    r:seek(o + 8)
    cond.target = r:u32()
    cond.flags = r:i16()
    cond.radius = r:i16()
    e.effects = {}
    for k = 0, M.EFFECTS - 1 do
        local eo = o + 16 + k * M.EFFECT_SIZE
        r:seek(eo)
        if r:u8() ~= 0 then
            r:seek(eo + 2)
            local ef = { slot = k + 1, ownerType = r:i16(), ownerData = r:i16(), effect = r:i16(), number = r:i16(),
                         location = r:i16() }
            r:seek(eo + 12)
            ef.type = r:u32()
            ef.text = r:fixstr(260)
            ef.x, ef.y = r:i32(), r:i32()
            e.effects[#e.effects + 1] = ef
        end
    end
    r:seek(o + 1152)
    e.code = r:bytes(4)
    e.loopCount = r:i16()
    e.shots = r:i16()
    e.onMap = r:u8() ~= 0
    e.name = r:fixstr(20)
    r:seek(o + 1182)
    e.seconds = r:i16()
    e.x, e.y = r:i32(), r:i32()
    r:seek(o + 1193)
    return e, r:u8() ~= 0
end

-- Display name of an event code: Names.cfg [EVENT_<code>] (an unknown code gives [EVENT_EXXX], "Unknown Event",
-- as the 1.04 binary's event name lookup FUN_0058a380 / FUN_0058a3e0 does).
---@param code string?
---@return string
function M.name(code)
    local strings = require("src.game.strings")
    return strings.get("Names.cfg", "EVENT_" .. (code or "EXXX")) or strings.get("Names.cfg", "EVENT_EXXX")
        or "Unknown Event"
end

local poolCache

-- The pool: one entry per EVENTS/*.EVT in directory order (sorted by file name, as the original's find loop sees
-- them): { file, code (the file's root), name (as listed), event }. Empty when the folder is missing.
---@return EvtPoolEntry[]
function M.pool()
    if poolCache then return poolCache end
    poolCache = {}
    local dir = config.gamedir .. "/EVENTS"
    local files = fs.list(dir, "%.[eE][vV][tT]$")
    table.sort(files, function(a, b) return a:lower() < b:lower() end)
    for _, file in ipairs(files) do
        local data = fs.read(dir .. "/" .. file)
        if data and #data >= M.SIZE then
            local e, used = M.parseRecord(bin.reader(data), 0)
            local root = file:gsub("%.[^.]*$", "")
            poolCache[#poolCache + 1] = { file = file, code = root, event = e, used = used,
                                          name = M.name(root:sub(1, 4):upper()) }
        end
    end
    return poolCache
end

-- A copy of the pool template for a new scenario event (the editor's FUN_004b8380): the template's own
-- fields, then position (0, 0), no seconds, not done, loop count 0, radius at least 1.
---@param entry EvtPoolEntry
---@return ScnEvent
function M.fromTemplate(entry)
    local src = entry.event
    local e = { cond = {}, effects = {}, code = src.code, loopCount = 0, shots = src.shots, onMap = src.onMap,
                name = src.name, seconds = 0, x = 0, y = 0, raw = src.raw }
    for k, v in pairs(src.cond) do e.cond[k] = v end
    if (e.cond.radius or 0) < 1 then e.cond.radius = 1 end
    for i, ef in ipairs(src.effects) do
        local c = {}
        for k, v in pairs(ef) do c[k] = v end
        e.effects[i] = c
    end
    return e
end

-- The standard victory event of slot 0 (FUN_00513c30, also used by the editor's "new scenario").
---@return ScnEvent
function M.standardVictory()
    return { cond = { owner = 6, condition = 10, number = 0, target = 0, flags = 0, radius = 1 }, effects = {},
             code = "\0\0\0\0", loopCount = 1, shots = 1, onMap = false, name = "", seconds = 0, x = -1, y = -1 }
end

-- Deep copy of an event table (the editor edits copies so that cancelling leaves the scenario alone).
---@param e ScnEvent
---@return ScnEvent
function M.copy(e)
    local c = {}
    for k, v in pairs(e) do c[k] = v end
    c.cond = {}
    for k, v in pairs(e.cond) do c.cond[k] = v end
    c.effects = {}
    for i, ef in ipairs(e.effects) do
        local d = {}
        for k, v in pairs(ef) do d[k] = v end
        c.effects[i] = d
    end
    return c
end

return M
