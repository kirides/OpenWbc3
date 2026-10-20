-- Animated sprite sheets: <CODE>.ani (metadata) + <CODE><suffix>.rle/.bmp (frames).
--
-- .ani: 9 records of 26 bytes, one per animation type (stand, walk, fight, die,
--   ambient, special, convert, spell, interface):
--   u8 used, u8 frames, u8 effect[2], u16 originX, originY, width, height,
--   effectOriginX, effectOriginY, selectionOriginX, selectionOriginY,
--   selectionSize, effectType, effectActivation
-- Sheet layout: frame f of direction d is at (f*width, d*height).
--
-- .rle ("RL", or "RS" with shadow runs):
--   char tag[2], u32 dataSize, u16 w, u16 h, u16 palettes[8][256] (565),
--   u32 blockSize, u32 blockTotal, u16 numBlocks, (pad) -> data at 4118.
--   data begins with h u32 row offsets (relative to data); each row is a
--   stream of: 255,n = skip n transparent pixels (n=255: rest of row),
--   250,n = n shadow pixels ("RS" only), otherwise a palette index.
-- 8-bit .bmp sheets use index 255 as transparent.
--
-- Palette indices 224..238 are replaced by the side colour ramp; 239..246 and
-- 247..254 are "effect" ranges driven by effect[1] and effect[0].
local ffi = require("ffi")
local bit = require("bit")
local bin = require("src.core.bin")
local bmp = require("src.formats.bmp")

local M = {}

M.SUFFIX = { [0] = "", "W", "F", "D", "A", "Z", "C", "S", "I" }
M.ANIM = { STAND = 0, WALK = 1, FIGHT = 2, DIE = 3, AMBIENT = 4, SPECIAL = 5, CONVERT = 6, SPELL = 7, INTERFACE = 8 }

-- Side colour ramps (start, increment) per channel, 8-bit RGB, 15 steps.
local RAMPS = {
    [0] = { 40, 7, 0, 3, 0, 3 },   -- red
    { 0, 3, 20, 4, 50, 7 },        -- blue
    { 0, 2, 40, 7, 0, 3 },         -- green
    { 40, 6, 3, 3, 40, 6 },        -- purple
    { 0, 5, 0, 5, 0, 5 },          -- black
    { 50, 6, 40, 5, 0, 0 },        -- white (gold-ish in game)
    { 40, 4, 40, 4, 40, 4 },       -- gray / neutral
    { 60, 11, 60, 11, 0, 0 },      -- yellow
}

local function q565(v, bits)
    -- quantise like the 565 surface did, then expand back to 8 bits
    v = math.min(255, math.max(0, v))
    if bits == 5 then
        v = bit.band(v, 0xF8)
        return v + bit.rshift(v, 5)
    end
    v = bit.band(v, 0xFC)
    return v + bit.rshift(v, 6)
end

---@type table<integer, table<integer, integer[]>>   side 0..7 -> ramp step 0..14 -> { r, g, b }
M.teamColors = {}
for team, r in pairs(RAMPS) do
    local list = {}
    for i = 0, 14 do
        list[i] = { q565(r[1] + i * r[2], 5), q565(r[3] + i * r[4], 6), q565(r[5] + i * r[6], 5) }
    end
    M.teamColors[team] = list
end

-- One animation type of an .ani file.
---@class AniRecord
---@field used boolean
---@field frames integer
---@field effect integer[]       the two effect bytes ({ e1, e2 } for M.render)
---@field originX integer
---@field originY integer
---@field width integer          frame size in the sheet
---@field height integer
---@field effectOriginX integer
---@field effectOriginY integer
---@field selOriginX integer?   (a PNG set fills them from anim.lua's `selection`, gfx/pngset.lua)
---@field selOriginY integer?
---@field selSize integer?
---@field effectType integer
---@field effectActivation integer

---@param data string
---@return table<integer, AniRecord> anims [0..8], indexed by M.ANIM
function M.parseAni(data)
    local r = bin.reader(data)
    local out = {}
    for i = 0, 8 do
        r:seek(i * 26)
        local a = {
            used = r:u8() ~= 0,
            frames = r:u8(),
            effect = { r:u8(), r:u8() },
            originX = r:u16(), originY = r:u16(),
            width = r:u16(), height = r:u16(),
            effectOriginX = r:u16(), effectOriginY = r:u16(),
            selOriginX = r:u16(), selOriginY = r:u16(),
            selSize = r:u16(),
            effectType = r:u16(),
            effectActivation = r:u16(),
        }
        out[i] = a
    end
    return out
end

-- Decoded sheet: indices + per-pixel kind (0 transparent, 1 opaque index, 2 shadow).
---@class SpriteSheet
---@field w integer
---@field h integer
---@field idx ffi.cdata*        uint8_t[w * h] palette indices
---@field kind ffi.cdata*       uint8_t[w * h] 0 transparent, 1 opaque, 2 shadow
---@field palettes ffi.cdata*   uint16_t[8 * 256] 565 colours, one palette per time of day

---@param w integer
---@param h integer
---@return SpriteSheet
local function newSheet(w, h)
    return {
        w = w, h = h,
        idx = ffi.new("uint8_t[?]", w * h),
        kind = ffi.new("uint8_t[?]", w * h),
        palettes = ffi.new("uint16_t[?]", 8 * 256),
    }
end

local function decodeRle(data)
    local tag = data:sub(1, 2)
    local shadowRuns = tag == "RS"
    local p = ffi.cast("const uint8_t*", data)
    local size = bin.u32(data, 2)
    local w, h = bin.u16(data, 6), bin.u16(data, 8)
    local s = newSheet(w, h)
    ffi.copy(s.palettes, p + 10, 4096)
    local base = 4118
    if base + size > #data then size = #data - base end
    local mem = p + base
    local idx, kind = s.idx, s.kind
    for y = 0, h - 1 do
        local o = y * 4
        local q = mem[o] + mem[o + 1] * 256 + mem[o + 2] * 65536 + mem[o + 3] * 16777216
        local x = 0
        local rowBase = y * w
        while x < w and q < size do
            local c = mem[q]
            if c == 255 then
                local n = mem[q + 1]
                q = q + 2
                if n == 255 then break end
                x = x + n
            elseif c == 250 and shadowRuns then
                local n = mem[q + 1]
                q = q + 2
                for i = x, math.min(w, x + n) - 1 do kind[rowBase + i] = 2 end
                x = x + n
            else
                idx[rowBase + x] = c
                kind[rowBase + x] = 1
                x = x + 1
                q = q + 1
            end
        end
    end
    return s
end

local function decodeBmp(data)
    local b = assert(bmp.parse(data))
    assert(b.bpp == 8, "sprite BMP must be 8-bit")
    local w, h = b.w, b.h
    local s = newSheet(w, h)
    local pal = {}
    local palette = b.palette
    ---@cast palette -nil
    for i = 0, 255 do
        local c = palette[i]
        local v = bit.bor(bit.lshift(bit.rshift(c[1], 3), 11), bit.lshift(bit.rshift(c[2], 2), 5), bit.rshift(c[3], 3))
        pal[i] = v
    end
    for t = 0, 7 do
        for i = 0, 255 do s.palettes[t * 256 + i] = pal[i] end
    end
    local src = ffi.cast("const uint8_t*", data)
    for y = 0, h - 1 do
        local row = bmp.row(b, y)
        for x = 0, w - 1 do
            local c = src[row + x]
            if c ~= 255 then
                s.idx[y * w + x] = c
                s.kind[y * w + x] = 1
            end
        end
    end
    return s
end

-- Decodes a .rle or 8-bit .bmp sheet.
---@param data string
---@return SpriteSheet? sheet
---@return string? err
function M.decodeSheet(data)
    local tag = data:sub(1, 2)
    if tag == "RL" or tag == "RS" then return decodeRle(data) end
    if tag == "BM" then return decodeBmp(data) end
    return nil, "unknown sheet format"
end

local SHADOW_ALPHA = {}
for lvl = 1, 8 do
    local keep = lvl == 8 and 15 / 16 or lvl / 8
    SHADOW_ALPHA[lvl] = math.floor(255 * (1 - keep))
end
local LIGHT_TINT = {
    [2] = { 255, 255, 255 }, [3] = { 255, 0, 0 }, [4] = { 0, 255, 0 },
    [5] = { 0, 0, 255 }, [6] = { 255, 0, 255 }, [7] = { 255, 255, 0 },
}

local function translucency(effect, c)
    if effect == 8 or effect == 12 then return 11 / 16 end
    if effect == 9 or effect == 13 then return 8 / 16 end
    if effect == 10 or effect == 14 then return 5 / 16 end
    if effect == 15 then
        local n = math.max(0, math.min(15, c - 239))
        return (16 - n) / 16
    end
    if effect >= 17 and effect <= 30 then return (16 - (effect - 16)) / 16 end
    return 1
end

-- Renders a sheet to RGBA ImageData.
-- team: 0..7 or nil (keep the sheet's own colours), paltype: 0..7 (time of day),
-- effects: {e1, e2} from the .ani record.
-- Returns the image and whether the sheet uses the additive effect 16.
---@param s SpriteSheet
---@param team integer?
---@param paltype integer?
---@param effects integer[]?
---@return love.ImageData img
---@return boolean additive
function M.render(s, team, paltype, effects)
    local w, h = s.w, s.h
    local img = love.image.newImageData(w, h, "rgba8")
    local dst = ffi.cast("uint8_t*", img:getFFIPointer())
    local e1, e2 = effects and effects[1] or 1, effects and effects[2] or 0
    local glob = 0
    if (e1 >= 8 and e1 <= 10) or e1 >= 17 then glob = e1
    elseif (e2 >= 8 and e2 <= 10) or e2 >= 17 then glob = e2 end
    local globAlpha = glob ~= 0 and math.floor(255 * translucency(glob, 0)) or 255

    -- precompute RGBA for all 256 indices
    local cr, cg, cb, ca = {}, {}, {}, {}
    local pal = s.palettes + (paltype or 0) * 256
    local teamCols = team and M.teamColors[team]
    for c = 0, 255 do
        local r, g, b
        if teamCols and c >= 224 and c <= 238 then
            local t = teamCols[c - 224]
            r, g, b = t[1], t[2], t[3]
        else
            local v = pal[c]
            local r5, g6, b5 = bit.rshift(v, 11), bit.band(bit.rshift(v, 5), 63), bit.band(v, 31)
            r, g, b = r5 * 8 + bit.rshift(r5, 2), g6 * 4 + bit.rshift(g6, 4), b5 * 8 + bit.rshift(b5, 2)
        end
        local eff, lvl = nil, 0
        if c >= 247 and c <= 254 then eff, lvl = e1, c - 246
        elseif c >= 239 and c <= 246 then eff, lvl = e2, c - 238 end
        local a = globAlpha
        if eff == 1 then
            r, g, b, a = 0, 0, 0, SHADOW_ALPHA[lvl]
        elseif eff and LIGHT_TINT[eff] then
            local t = LIGHT_TINT[eff]
            r, g, b, a = t[1], t[2], t[3], math.floor(255 * lvl / 32)
        elseif eff == 11 then
            a = 0
        elseif eff and eff >= 12 and eff <= 15 then
            a = math.floor(255 * translucency(eff, c))
        end
        cr[c], cg[c], cb[c], ca[c] = r, g, b, a
    end
    local shadowA = (e1 == 1) and 128 or 0
    local idx, kind = s.idx, s.kind
    for i = 0, w * h - 1 do
        local k = kind[i]
        local o = i * 4
        if k == 1 then
            local c = idx[i]
            dst[o], dst[o + 1], dst[o + 2], dst[o + 3] = cr[c], cg[c], cb[c], ca[c]
        elseif k == 2 then
            dst[o + 3] = shadowA
        end
    end
    return img, (e1 == 16 or e2 == 16)
end

return M
