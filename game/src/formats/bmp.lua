-- Windows BMP decoder (8-bit paletted, 16-bit 555, 24-bit, 32-bit) to RGBA.
-- The original engine renders in 16-bit 565 and treats pure magenta
-- (0xF81F after 565 conversion) as transparent; `opts.key` enables that.
local ffi = require("ffi")
local bin = require("src.core.bin")
local bit = require("bit")

local M = {}

local function is565Magenta(r, g, b)
    return r >= 248 and g < 4 and b >= 248
end
M.isKey = is565Magenta

---@class BmpInfo
---@field w integer
---@field h integer          always positive (see topDown)
---@field bpp integer
---@field data string        the source bytes
---@field topDown boolean    rows stored top to bottom (negative height)
---@field palette table<integer, integer[]>?   [0..255] = { r, g, b } (bpp <= 8 only)
---@field stride integer     bytes per row
---@field offset integer     byte offset of the pixel data

-- Returns the header of a BMP: size, depth, palette, row layout (pixels are read through M.row).
---@param data string
---@return BmpInfo? bmp
---@return string? err
function M.parse(data)
    if data:sub(1, 2) ~= "BM" then return nil, "not a BMP" end
    local r = bin.reader(data)
    r:seek(10)
    local off = r:u32()
    local hdrSize = r:u32()
    local w = r:i32()
    local h = r:i32()
    r:u16()
    local bpp = r:u16()
    local compression = r:u32()
    if compression ~= 0 and compression ~= 3 then return nil, "compressed BMP not supported" end
    r:seek(46)
    local ncol = r:u32()
    local bmp = { w = w, h = math.abs(h), bpp = bpp, data = data, topDown = h < 0 }
    if bpp <= 8 then
        ncol = ncol > 0 and ncol or 2 ^ bpp
        local pal = {}
        local p = 14 + hdrSize
        for i = 0, ncol - 1 do
            local b, g, rr = data:byte(p + i * 4 + 1, p + i * 4 + 3)
            pal[i] = { rr, g, b }
        end
        for i = ncol, 255 do pal[i] = { 0, 0, 0 } end
        bmp.palette = pal
    end
    bmp.stride = math.floor((w * bpp + 31) / 32) * 4
    bmp.offset = off
    return bmp
end

-- Byte offset (0-based, into bmp.data) of image row y (0 = top).
---@param bmp BmpInfo
---@param y integer
---@return integer
function M.row(bmp, y)
    local sy = bmp.topDown and y or (bmp.h - 1 - y)
    return bmp.offset + sy * bmp.stride
end

-- Decodes into a LÖVE ImageData. opts.key: magenta transparency.
---@param data string
---@param opts { key: boolean? }?
---@return love.ImageData? img
---@return BmpInfo|string? bmpOrErr the parsed header, or the error
function M.decode(data, opts)
    opts = opts or {}
    local bmp, err = M.parse(data)
    if not bmp then return nil, err end
    local w, h = bmp.w, bmp.h
    local img = love.image.newImageData(w, h, "rgba8")
    local dst = ffi.cast("uint8_t*", img:getFFIPointer())
    local src = ffi.cast("const uint8_t*", data)
    local key = opts.key
    local bpp = bmp.bpp
    local pr, pg, pb, pa
    if bpp == 8 then
        local palette = bmp.palette
        ---@cast palette -nil
        pr, pg, pb, pa = {}, {}, {}, {}
        for i = 0, 255 do
            local c = palette[i]
            pr[i], pg[i], pb[i] = c[1], c[2], c[3]
            pa[i] = (key and is565Magenta(c[1], c[2], c[3])) and 0 or 255
        end
    end
    for y = 0, h - 1 do
        local row = M.row(bmp, y)
        local o = y * w * 4
        for x = 0, w - 1 do
            local r, g, b
            if bpp == 8 then
                local i = src[row + x]
                r, g, b = pr[i], pg[i], pb[i]
                dst[o + 3] = pa[i]
            elseif bpp == 24 or bpp == 32 then
                local p = row + x * (bpp / 8)
                b, g, r = src[p], src[p + 1], src[p + 2]
                dst[o + 3] = (key and is565Magenta(r, g, b)) and 0 or 255
            elseif bpp == 16 then
                local v = src[row + x * 2] + src[row + x * 2 + 1] * 256
                local r5 = bit.band(bit.rshift(v, 10), 31)
                local g5 = bit.band(bit.rshift(v, 5), 31)
                local b5 = bit.band(v, 31)
                r, g, b = r5 * 8 + r5 / 4, g5 * 8 + g5 / 4, b5 * 8 + b5 / 4
                dst[o + 3] = (key and r5 == 31 and g5 == 0 and b5 == 31) and 0 or 255
            else
                error("unsupported BMP depth " .. bpp)
            end
            dst[o], dst[o + 1], dst[o + 2] = r, g, b
            o = o + 4
        end
    end
    if key then M.bleed(dst, w, h) end
    return img, bmp
end

-- Keyed pixels are transparent but still hold magenta, which linear filtering (scaled UI) blends into the
-- edges as a magenta outline. Give every transparent pixel the average colour of its opaque neighbours
-- (black when it has none) so the blend stays within the sprite's own colours.
---@param dst ffi.cdata* uint8_t* RGBA pixels
---@param w integer
---@param h integer
function M.bleed(dst, w, h)
    for y = 0, h - 1 do
        for x = 0, w - 1 do
            local o = (y * w + x) * 4
            if dst[o + 3] == 0 then
                local r, g, b, n = 0, 0, 0, 0
                for dy = -1, 1 do
                    local yy = y + dy
                    if yy >= 0 and yy < h then
                        for dx = -1, 1 do
                            local xx = x + dx
                            if xx >= 0 and xx < w then
                                local p = (yy * w + xx) * 4
                                if dst[p + 3] ~= 0 then
                                    r, g, b, n = r + dst[p], g + dst[p + 1], b + dst[p + 2], n + 1
                                end
                            end
                        end
                    end
                end
                if n > 0 then
                    dst[o], dst[o + 1], dst[o + 2] = r / n, g / n, b / n
                else
                    dst[o], dst[o + 1], dst[o + 2] = 0, 0, 0
                end
            end
        end
    end
end

-- Convenience: decode straight to a LÖVE Image.
---@param data string
---@param opts { key: boolean? }?
---@return love.Image? image
---@return love.ImageData|BmpInfo|string? imgOrErr the image data, or the error
function M.image(data, opts)
    local img, err = M.decode(data, opts)
    if not img then return nil, err end
    local image = love.graphics.newImage(img)
    image:setFilter("nearest", "nearest")
    return image, img
end

return M
