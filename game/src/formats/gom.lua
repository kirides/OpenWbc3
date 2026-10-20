-- Random map pieces: .GOM files of RandomData.xcr (read by the 1.04 binary's piece gluing FUN_00582310).
--
-- A GOM is a 3x3 block of terrain tiles (30x30 cells) that the random map generator glues together, left to right and
-- top to bottom, wherever the edge terrain types match. Layout (checked on all 647 shipped files):
--   0    u16 123 (the file magic), 2 bytes padding (garbage)
--   4    char tile[9][4]   terrain tile codes (TGX0 ...), row by row: 0 1 2 / 3 4 5 / 6 7 8
--   40   u16 part[9]       which quadrant of a big tile the slot shows (0 = the tile's own slot, 1..3 = the rest)
--   58   u16 edge[4]       terrain type of the north, east, south and west edge (EDGE_* below)
--   66   2 bytes padding   -> 68 bytes of header
--   68   7 x 44 bytes      the seven sides' start locations: all shipped GOMs hold -1 / -1 (the generator draws its own)
--   376  chunks like a scenario: FTRH (32 bytes: 8-byte header + char code[4], i32 anim, dir, frame, x, y) for every
--        feature, positions in pixels relative to the GOM (0..959 x 0..719), then ENDX (8 bytes)
-- The .WRM water layouts and the SCN pieces the islands variant of the generator reads are not in the shipped
-- RandomData.xcr (only the 635 .GOM files are), and the binary never calls the islands variant, so they are not read.
local bin = require("src.core.bin")

local M = {}

M.HEADER = 123
M.CHUNKS_AT = 376

-- Edge terrain types (the numbers are the files').
M.EDGE = { DIRT = 0, SAND = 1, GRASS = 2, WATER = 3, SNOW = 4, ROAD = 5, HIGHGRASS = 6, HIGHDIRT = 7, HIGHROCK = 8,
           DIRTSPECIAL1 = 9, DIRTSPECIAL2 = 10, DIRTSPECIAL3 = 11, DIRTSPECIAL4 = 12 }

-- Terrain sets of the random map settings (the dropdown's 0..9): file prefix and number of pieces
-- (the piece name list FUN_00582e10; the counts equal the files in the archive, which the self test checks).
M.TERRAINS = {
    [0] = { name = "Plains", prefix = "clear", count = 61 },
    { name = "Outland", prefix = "grass", count = 81 },
    { name = "Highland", prefix = "HighGrass", count = 81 },
    { name = "Desert", prefix = "oasis", count = 61 },
    { name = "Lava", prefix = "lava", count = 41, blocking = true },
    { name = "Wasteland", prefix = "sand", count = 68 },
    { name = "Caverns", prefix = "cavern", count = 34, blocking = true },
    { name = "Snow", prefix = "snow", count = 61 },
    { name = "Wetlands", prefix = "water", count = 55, blocking = true },
    { name = "Jungle", prefix = "jungle", count = 73 },
}
M.ARCHIVE = "RandomData.xcr"

---@class GomFeature
---@field code string
---@field anim integer
---@field dir integer
---@field frame integer
---@field x integer   pixels relative to the piece
---@field y integer

---@class GomPiece
---@field tiles string[]      nine terrain tile codes, row by row
---@field parts integer[]     nine quadrant numbers
---@field edges integer[]     north, east, south, west (M.EDGE)
---@field features GomFeature[]
---@field other integer       chunks skipped
---@field complete boolean?   ENDX was reached

-- Parses one file; returns nil and a reason when it is not a GOM.
---@param data string
---@return GomPiece? piece
---@return string? err
function M.parse(data)
    if #data < M.CHUNKS_AT + 8 then return nil, "too short" end
    if bin.u16(data, 0) ~= M.HEADER then return nil, "bad header id" end
    local g = { tiles = {}, parts = {}, edges = {}, features = {}, other = 0 }
    for i = 0, 8 do
        g.tiles[i + 1] = data:sub(5 + i * 4, 8 + i * 4)
        g.parts[i + 1] = bin.u16(data, 40 + i * 2)
    end
    for i = 0, 3 do g.edges[i + 1] = bin.u16(data, 58 + i * 2) end   -- north, east, south, west
    local pos = M.CHUNKS_AT
    while pos + 8 <= #data do
        local id, size = data:sub(pos + 1, pos + 4), bin.u32(data, pos + 4)
        if size < 8 then return nil, "bad chunk size" end
        if id == "ENDX" then g.complete = true break end
        if id == "FTRH" and size >= 32 and pos + 32 <= #data then
            g.features[#g.features + 1] = { code = data:sub(pos + 9, pos + 12), anim = bin.i32(data, pos + 12),
                                            dir = bin.i32(data, pos + 16), frame = bin.i32(data, pos + 20),
                                            x = bin.i32(data, pos + 24), y = bin.i32(data, pos + 28) }
        else
            g.other = g.other + 1          -- the generator skips whatever it does not know
        end
        pos = pos + size
    end
    return g
end

local cache = {}

-- GOM number `index` of a terrain set (0..9) from the archive, cached; nil when it is missing or broken.
---@param terrain integer 0..9
---@param index integer
---@return GomPiece?
function M.load(terrain, index)
    local set = M.TERRAINS[terrain]
    if not set then return nil end
    local name = set.prefix .. index .. ".GOM"
    local key = name:lower()
    local g = cache[key]
    if g == nil then
        local data = require("src.vfs.vfs").read(M.ARCHIVE, name)
        g = data and M.parse(data) or false
        cache[key] = g
    end
    return g or nil
end

return M
