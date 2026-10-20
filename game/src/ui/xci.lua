-- Interface definitions: War4Gfx.xcg (bitmap/cursor/font/image tables) and
-- War4Int.xci (UI objects, panels, screens, string resources), plus the
-- localised <Lang>/XCIStrings.txt.
--
-- War4Gfx.xcg: char id[20] "xcg File 1.00", i32 nRes, u32 size, i32 nBitmaps,
--   nCursors, nFonts, nImages, char inc[40]; then
--   bitmaps  132 bytes: u32 id, char name[32], char xcr[40], char file[40], i32 w, h, prio, u8 transparent...
--   cursors  284 bytes: u32 id, name[32], u32 bitmap, bitmapName[32], i32 w, h, frames, hotX, hotY, 16x{x,y,ms}
--   fonts   8276 bytes (unused: fonts come from Font.ini)
--   images   280 bytes: u32 id, name[32], u32 bitmap, bitmapName[32], u8 transparent, i32 frames, w, h, 16x{x,y,ms}
-- War4Int.xci: char id[32] "xci File 1.00", i32 counts of objects, UI objects, panels, screens, strings,
--   char xcg[256]; then UI objects (284 bytes), panels (5940), screens (236), string headers (44).
local bin = require("src.core.bin")
local fs = require("src.core.fs")
local text = require("src.core.text")
local log = require("src.core.log")

local M = {}

---@class XcgBitmap         a bitmap record of War4Gfx.xcg
---@field id integer
---@field name string
---@field xcr string          archive the file was in
---@field file string
---@field w integer
---@field h integer
---@field prio integer
---@field transparent boolean

---@class XcgFrame
---@field x integer
---@field y integer
---@field ms integer

---@class XcgCursor          a cursor record of War4Gfx.xcg (frames on a bitmap)
---@field id integer
---@field name string
---@field bitmap integer
---@field w integer
---@field h integer
---@field frames integer
---@field hotX integer
---@field hotY integer
---@field frameList XcgFrame[]

---@class XcgImage
---@field id integer
---@field name string
---@field bitmap integer
---@field transparent boolean
---@field frames integer
---@field w integer
---@field h integer

---@class XcgGfx             War4Gfx.xcg
---@field bitmaps table<integer, XcgBitmap>
---@field cursors table<integer, XcgCursor>
---@field images table<integer, XcgImage>
---@field byName table<string, XcgBitmap|XcgCursor>

---@class XciObject          a UI object of War4Int.xci; the fields after w, h depend on the type (M.TYPE)
---@field id integer
---@field name string
---@field type integer
---@field subtype integer
---@field w integer
---@field h integer
---@field source integer?      bitmap id (button, scroll bar, progress, list box, image)
---@field fonts integer[]?     button: normal / hover / disabled font; list box: normal / selected
---@field text integer?        string resource (0xFFFFFFFF: none)
---@field textSub integer?
---@field group integer?
---@field font integer?        string, editor
---@field maxLen integer?      editor
---@field colors integer[][]?  primitive: three RGBA colours (0..31)
---@field srcRect integer[]?   image: x, y, w, h on the bitmap

---@class XciPlace          position of an object on a panel and its drawing order
---@field x number
---@field y number
---@field z number

---@class XciPanelEntry: XciPlace  an object placed on a panel
---@field ui integer           XciObject id
---@field name string
---@field extra integer

---@class XciPanelDef
---@field id integer
---@field name string
---@field x integer
---@field y integer
---@field objects XciPanelEntry[]

---@class XciScreen
---@field id integer
---@field name string
---@field type integer
---@field source integer[]     bitmap ids

---@class XciStringHeader
---@field id integer
---@field name string
---@field count integer

---@class XciDefs            the records of War4Int.xci
---@field objects table<integer, XciObject>
---@field objByName table<string, XciObject>
---@field panels table<string, XciPanelDef>
---@field panelById table<integer, XciPanelDef>
---@field screens table<string, XciScreen>
---@field strings XciStringHeader[]

---@class XciUI: XciDefs      War4Int.xci with its War4Gfx.xcg and texts (xci.load)
---@field gfx XcgGfx
---@field text table<integer, table<integer, string>>  resource id -> sub index (from 0) -> text

M.TYPE = { BUTTON = 0, EDITOR = 1, SCROLLBAR = 2, LISTBOX = 3, STRING = 4, PROGRESS = 5, PRIMITIVE = 6, IMAGE = 7 }

---@return XcgGfx
local function parseXcg(data)
    local r = bin.reader(data)
    r:seek(20)
    local _, _, nb, nc, nf, ni = r:i32(), r:u32(), r:i32(), r:i32(), r:i32(), r:i32()
    local o = 84
    ---@type XcgGfx
    local g = { bitmaps = {}, cursors = {}, images = {}, byName = {} }
    for _ = 1, nb do
        r:seek(o)
        local b = { id = r:u32(), name = r:fixstr(32), xcr = r:fixstr(40), file = r:fixstr(40) }
        b.w, b.h, b.prio = r:i32(), r:i32(), r:i32()
        b.transparent = r:u8() ~= 0
        g.bitmaps[b.id] = b
        g.byName[b.name] = b
        o = o + 132
    end
    for _ = 1, nc do
        r:seek(o)
        local c = { id = r:u32(), name = r:fixstr(32), bitmap = r:u32() }
        r:seek(o + 72)
        c.w, c.h, c.frames, c.hotX, c.hotY = r:i32(), r:i32(), r:i32(), r:i32(), r:i32()
        c.frameList = {}
        for k = 0, math.max(0, math.min(16, c.frames)) - 1 do
            r:seek(o + 92 + 12 * k)
            c.frameList[k + 1] = { x = r:i32(), y = r:i32(), ms = r:i32() }
        end
        g.cursors[c.id] = c
        g.byName[c.name] = c
        o = o + 284
    end
    o = o + nf * 8276
    for _ = 1, ni do
        r:seek(o)
        local im = { id = r:u32(), name = r:fixstr(32), bitmap = r:u32() }
        r:seek(o + 72)
        im.transparent = r:u8() ~= 0
        r:seek(o + 76)
        im.frames, im.w, im.h = r:i32(), r:i32(), r:i32()
        g.images[im.id] = im
        o = o + 280
    end
    return g
end

---@return XciDefs
local function parseXci(data)
    local r = bin.reader(data)
    r:seek(32)
    local _, nui, npan, nscr, nstr = r:i32(), r:i32(), r:i32(), r:i32(), r:i32()
    local o = 308
    ---@type XciDefs
    local x = { objects = {}, panels = {}, panelById = {}, screens = {}, strings = {}, objByName = {} }
    for _ = 1, nui do
        r:seek(o)
        local ob = { id = r:u32(), name = r:fixstr(32), type = r:i32(), subtype = r:i32() }
        local u = o + 44
        r:seek(u)
        ob.w, ob.h = r:i32(), r:i32()
        local t = ob.type
        if t == M.TYPE.BUTTON then
            r:seek(u + 8) ob.source = r:u32()
            r:seek(u + 44) ob.fonts = { r:u32(), r:u32(), r:u32() }
            r:seek(u + 152) ob.text = r:u32()
            r:seek(u + 188) ob.textSub = r:i32()
            r:seek(u + 236) ob.group = r:i32()
        elseif t == M.TYPE.STRING then
            r:seek(u + 8) ob.text = r:u32()
            r:seek(u + 44) ob.textSub = r:i32()
            ob.font = r:u32()
        elseif t == M.TYPE.SCROLLBAR or t == M.TYPE.PROGRESS then
            r:seek(u + 8) ob.source = r:u32()
        elseif t == M.TYPE.LISTBOX then
            r:seek(u + 8) ob.fonts = { r:u32(), r:u32() }
            r:seek(u + 80) ob.source = r:u32()
        elseif t == M.TYPE.EDITOR then
            -- font number and the longest text the editor takes (the edit box text setter FUN_0045daf0 compares with it)
            r:seek(u + 60) ob.font = r:i32()
            r:seek(u + 136) ob.maxLen = r:i32()
        elseif t == M.TYPE.PRIMITIVE then
            ob.colors = {}
            for k = 0, 2 do
                r:seek(u + 8 + 4 * k)
                ob.colors[k + 1] = { r:u8(), r:u8(), r:u8(), r:u8() }
            end
        elseif t == M.TYPE.IMAGE then
            r:seek(u + 8) ob.source = r:u32()
            r:seek(u + 44) ob.srcRect = { r:i32(), r:i32(), r:i32(), r:i32() }
        end
        x.objects[ob.id] = ob
        x.objByName[ob.name] = ob
        o = o + 284
    end
    for _ = 1, npan do
        r:seek(o)
        local p = { id = r:u32(), name = r:fixstr(32) }
        p.x, p.y = r:i32(), r:i32()
        r:seek(o + 48)
        local n = r:i32()
        p.objects = {}
        for k = 0, n - 1 do
            local po = o + 52 + 92 * k
            r:seek(po)
            local e = { ui = r:u32(), name = r:fixstr(32) }
            e.extra, e.x, e.y, e.z = r:i32(), r:i32(), r:i32(), r:i32()
            p.objects[#p.objects + 1] = e
        end
        x.panels[p.name] = p
        x.panelById[p.id] = p
        o = o + 5940
    end
    for _ = 1, nscr do
        r:seek(o)
        local s = { id = r:u32(), name = r:fixstr(32), type = r:i32() }
        s.source = { r:u32(), r:u32(), r:u32(), r:u32() }
        x.screens[s.name] = s
        o = o + 236
    end
    for _ = 1, nstr do
        r:seek(o)
        local s = { id = r:u32(), name = r:fixstr(32) }
        s.count = r:i32()
        x.strings[#x.strings + 1] = s
        o = o + 44
    end
    return x
end

-- Lines of XCIStrings.txt in resource order, first 9 characters ("[nnnn.n] ") dropped.
-- Falls back to `fallback` (the English/ copy) when `path` is missing.
local function loadStrings(path, fallback, headers)
    local data = fs.read(path) or (path ~= fallback and fs.read(fallback))
    local out = {}
    if not data then
        log.warn("xci: %s missing", path)
        return out
    end
    local lines = {}
    for line in (data .. "\n"):gmatch("(.-)\r?\n") do lines[#lines + 1] = line end
    local i = 1
    for _, h in ipairs(headers) do
        local list = {}
        for k = 0, h.count - 1 do
            local l = lines[i] or ""
            list[k] = text.fromCP1252(l:sub(10))
            i = i + 1
        end
        out[h.id] = list
    end
    return out
end

---@param gamedir string
---@param lang string
---@return XciUI? ui
---@return string? err
function M.load(gamedir, lang)
    local xcg = fs.read(gamedir .. "/War4Gfx.xcg")
    local xci = fs.read(gamedir .. "/War4Int.xci")
    if not xcg or not xci then return nil, "War4Gfx.xcg / War4Int.xci missing" end
    local ui = parseXci(xci) --[[@as XciUI]]       -- gfx and text follow
    ui.gfx = parseXcg(xcg)
    ui.text = loadStrings(gamedir .. "/" .. lang .. "/XCIStrings.txt",
                         gamedir .. "/English/XCIStrings.txt", ui.strings)
    return ui
end

return M
