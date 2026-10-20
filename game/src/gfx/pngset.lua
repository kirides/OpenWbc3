-- Sprite sets from PNG files (docs/data-driven/05-assets.md 5.4): the animation set a mod brings with its own art. The folder (a mod's
-- `gfx/<name>/`) holds
--   anim.lua          return { size = { w = 64, h = 64 }, origin = { 32, 56 }, dirs = 8,
--                              frames = { stand = 1, walk = 8, fight = 6, die = 8 },
--                              effectOrigin = { 32, 10 }, selection = { 32, 56, 1 }, hit = 3 }
--   stand.png walk.png fight.png die.png ambient.png special.png convert.png spell.png    one sheet per animation: frame f of direction
--                     d at (f * w, d * h), directions clockwise from north; `dirs` 8 (default), 5 (north to south, the west half is
--                     mirrored) or 1 (the same picture all round)
--   <name>_team.png   optional team colour mask for a sheet: where it is bright the pixel takes the side's colour ramp (white = lightest);
--                     without a mask the sheet is not recoloured
-- It behaves like the install's AnimSet (src/gfx/anims.lua): `has`, `frames`, `image`, `draw`, `drawCell`, `pickRect`, `effectCentre`, `info`.
-- A missing file never crashes a battle: the set simply lacks that animation; `placeholder()` is the magenta checker shown for a unit
-- whose sprite could not be found at all.
local sprite = require("src.formats.sprite")
local log = require("src.core.log")

local M = {}

local NAMES = { [0] = "stand", "walk", "fight", "die", "ambient", "special", "convert", "spell" }
-- A PNG sprite set; behaves like the install's AnimSet (its draw helpers are AnimSet's own, see below).
---@class PngSet: AnimSet
---@field read fun(rel: string): string?   reads a file of the set's folder
---@field prefix string                    the set's folder ("gfx/shaman/")
---@field dirs integer                     direction rows of the files (8, 5 or 1)
---@field w integer                        default frame size
---@field h integer
---@field raw table<integer, love.ImageData|false>   anim -> 8-direction sheet (false: missing)
local Set = {}
Set.__index = Set

---@param bytes string
---@param name string
---@return love.ImageData?
local function imageData(bytes, name)
    local ok, data = pcall(function() return love.image.newImageData(love.filesystem.newFileData(bytes, name)) end)
    if ok then return data end
    log.warn("png sprite %s: %s", name, tostring(data))
    return nil
end

-- Builds the 8-direction sheet of a sheet that has `dirs` rows: 5 rows are N NE E SE S, the rest is the mirror image.
---@param src love.ImageData
---@param w integer
---@param h integer
---@param dirs integer
---@return love.ImageData
local function expand(src, w, h, dirs)
    if dirs == 8 then return src end
    local cols = math.floor(src:getWidth() / w)
    local dst = love.image.newImageData(cols * w, 8 * h)
    local function copyRow(from, to, mirror)
        for f = 0, cols - 1 do
            if not mirror then
                dst:paste(src, f * w, to * h, f * w, from * h, w, h)
            else
                for y = 0, h - 1 do
                    for x = 0, w - 1 do
                        local r, g, b, a = src:getPixel(f * w + (w - 1 - x), from * h + y)
                        dst:setPixel(f * w + x, to * h + y, r, g, b, a)
                    end
                end
            end
        end
    end
    if dirs == 1 then
        for d = 0, 7 do copyRow(0, d, false) end
    else
        for d = 0, 4 do copyRow(d, d, false) end
        copyRow(3, 5, true) copyRow(2, 6, true) copyRow(1, 7, true)
    end
    return dst
end

-- `read(rel)` returns the bytes of a file of the folder (or nil); `desc` is the evaluated anim.lua.
---@param read fun(rel: string): string?
---@param desc table
---@param label string
---@return PngSet
function M.new(read, desc, label)
    local w, h = desc.size and desc.size.w or 64, desc.size and desc.size.h or 64
    local ox, oy = desc.origin and desc.origin[1] or math.floor(w / 2), desc.origin and desc.origin[2] or h - 4
    local dirs = desc.dirs or 8
    local set = setmetatable({ code = label, info = {}, sheets = {}, images = {}, read = read, dirs = dirs, w = w, h = h, raw = {} }, Set)
    ---@cast set PngSet
    for anim = 0, 7 do
        local name = NAMES[anim]
        local frames = desc.frames and desc.frames[name] or 0
        local own = desc.anims and desc.anims[name] or {}
        local a = {
            used = frames > 0, frames = frames, effect = { 1, 0 },
            width = own.size and own.size.w or w, height = own.size and own.size.h or h,
            originX = own.origin and own.origin[1] or ox, originY = own.origin and own.origin[2] or oy,
            effectOriginX = desc.effectOrigin and desc.effectOrigin[1] or 0, effectOriginY = desc.effectOrigin and desc.effectOrigin[2] or 0,
            -- `selection` = { x, y, size } fills the .ani record's selOriginX / selOriginY / selSize (formats/sprite.lua), read by the
            -- building ring of screens/battle.lua
            selOriginX = desc.selection and desc.selection[1] or ox, selOriginY = desc.selection and desc.selection[2] or oy,
            selSize = desc.selection and desc.selection[3] or 0, effectType = 0,
            effectActivation = (anim == 2 and (desc.hit or math.floor(frames / 2))) or 0,
        } --[[@as AniRecord]]
        set.info[anim] = a
    end
    set.info[8] = { used = false, frames = 0, effect = { 0, 0 }, width = 0, height = 0, originX = 0, originY = 0, effectOriginX = 0,
                    effectOriginY = 0, selOriginX = 0, selOriginY = 0, selSize = 0, effectType = 0, effectActivation = 0 }
        --[[@as AniRecord]]
    return set
end

-- The decoded sheet (an ImageData, 8 direction rows) of an animation, or nil.
---@param anim integer
---@return love.ImageData?
function Set:data(anim)
    local d = self.raw[anim]
    if d ~= nil then return d or nil end
    local name = NAMES[anim]
    local bytes = name and self.read(self.prefix .. name .. ".png")
    local src = bytes and imageData(bytes, name .. ".png")
    if src then
        local a = self.info[anim]
        d = expand(src, a.width, a.height, self.dirs)
    end
    self.raw[anim] = d or false
    return d
end

---@param anim integer
---@return boolean
function Set:has(anim)
    local a = self.info[anim]
    return a ~= nil and a.used and a.frames > 0 and self:data(anim) ~= nil
end

---@param anim integer
---@return integer
function Set:frames(anim)
    local a = self.info[anim]
    return a and a.used and a.frames or 0
end

---@return nil
function Set:sheet() return nil end        -- the palette sheet of the install's sets; lighting and the like skip a set without one

-- The side colour of a team mask: the ramp index follows the mask's brightness.
---@param data love.ImageData
---@param mask love.ImageData?
---@param team integer
---@return love.ImageData
local function tinted(data, mask, team)
    local ramp = sprite.teamColors[team]
    if not (ramp and mask and mask:getWidth() == data:getWidth() and mask:getHeight() == data:getHeight()) then return data end
    local out = data:clone() --[[@as love.ImageData]]
    out:mapPixel(function(x, y, r, g, b, a)
        local mr, mg, mb = mask:getPixel(x, y)
        local lum = (mr + mg + mb) / 3
        if lum > 0.02 and a > 0 then
            local c = ramp[math.max(0, math.min(14, math.floor(lum * 14 + 0.5)))]
            return c[1] / 255, c[2] / 255, c[3] / 255, a
        end
        return r, g, b, a
    end)
    return out
end

---@param anim integer
---@param team integer?
---@return AnimImage?
function Set:image(anim, team)
    local key = anim * 100 + (team or 99)
    local rec = self.images[key]
    if rec then return rec end
    local data = self:data(anim)
    if not data then return nil end
    if team then
        local maskBytes = self.read(self.prefix .. NAMES[anim] .. "_team.png")
        local mask = maskBytes and imageData(maskBytes, "mask")
        if mask then
            mask = expand(mask, self.info[anim].width, self.info[anim].height, self.dirs)
            data = tinted(data, mask, team)
        end
    end
    local image = love.graphics.newImage(data)
    image:setFilter("nearest", "nearest")
    local a = self.info[anim]
    rec = { image = image, additive = false, w = a.width, h = a.height, cols = math.max(1, math.floor(data:getWidth() / a.width)),
            rows = 8, quads = {}, ox = a.originX, oy = a.originY }
    self.images[key] = rec
    return rec
end

local anims = nil
---@return AnimSet
local function base()
    anims = anims or require("src.gfx.anims")
    return anims.AnimSet
end

-- draw / drawCell / pickRect / effectCentre / drawInterface are the install's set's methods: they only use `info`, `has` and `image`.
for _, name in ipairs({ "draw", "drawCell", "pickRect", "effectCentre", "drawInterface", "interfaceRect" }) do
    Set[name] = function(self, ...) return base()[name](self, ...) end
end

function Set:release()
    for _, rec in pairs(self.images) do rec.image:release() end
    self.images = {}
end

-- Loads the set at `prefix` ("gfx/shaman/") of a folder; returns nil and a message when there is no anim.lua.
---@param read fun(rel: string): string?
---@param prefix string
---@param label string
---@return PngSet? set
---@return string? err
function M.load(read, prefix, label)
    local text = read(prefix .. "anim.lua")
    if not text then return nil, ("%sanim.lua is missing"):format(prefix) end
    local chunk, err = loadstring(text, "@" .. prefix .. "anim.lua")
    if not chunk then return nil, err end
    setfenv(chunk, {})
    local ok, desc = pcall(chunk)
    if not ok or type(desc) ~= "table" then return nil, "anim.lua must return a table" end
    local set = M.new(read, desc, label)
    set.prefix = prefix
    return set
end

-- The magenta checker of a sprite that could not be found: one frame of every basic animation, all eight directions.
---@type PngSet?
local placeholder
---@return PngSet
function M.placeholder()
    if placeholder then return placeholder end
    local w, h = 32, 40
    local files = {}
    for _, name in ipairs({ "stand", "walk", "fight", "die" }) do
        local frames = 1
        local img = love.image.newImageData(w * frames, h * 8)
        for d = 0, 7 do
            for y = 0, h - 1 do
                for x = 0, w - 1 do
                    local on = (math.floor(x / 4) + math.floor(y / 4)) % 2 == 0
                    local edge = x < 2 or y < 2 or x >= w - 2 or y >= h - 2
                    img:setPixel(x, d * h + y, on and 1 or 0.15, 0, on and 1 or 0.15, (y > 6 and not edge) and 1 or (edge and 1 or 0.9))
                end
            end
        end
        files[name .. ".png"] = img:encode("png"):getString()
    end
    local read = function(rel) return files[rel] end
    placeholder = M.new(read, { size = { w = w, h = h }, origin = { 16, 36 }, frames = { stand = 1, walk = 1, fight = 1, die = 1 } }, "placeholder")
    placeholder.prefix = ""
    return placeholder
end

return M
