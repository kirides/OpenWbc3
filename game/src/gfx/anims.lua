-- Animation registry: loads sprite sets by 4-letter code from the archives and
-- caches GPU images per (animation, side colour, palette).
local vfs = require("src.vfs.vfs")
local sprite = require("src.formats.sprite")
local log = require("src.core.log")

---@class AnimsModule
---@field sets table<string, AnimSet|false>   upper-case code -> set (false: none)
---@field paltype integer                     default palette (time of day) 0..7
local M = { sets = {}, paltype = 0 }

-- The graphics options that change how a sheet is rendered (the sprite frame draw FUN_00487f20): with shadows off the palette
-- ranges whose effect is "shadow" (1) become transparent (11), with lighting effects off the coloured light ranges
-- (the lighting effects 2..7) do. The images are cached per setting; a change clears the cache.
local opts = require("src.core.gameopts")
local shadowsOn, lightingOn, optVersion = true, true, -1
local function syncOptions()
    optVersion = opts.version
    local s, l = opts.on("shadows"), opts.level("lighting") > 0
    if s ~= shadowsOn or l ~= lightingOn then
        shadowsOn, lightingOn = s, l
        M.clear()
    end
end

-- A sheet rendered to the GPU for one side colour and palette, cut into frames of w x h.
---@class AnimImage
---@field image love.Image
---@field additive boolean     drawn with additive blending (effect 16)
---@field w integer            frame size
---@field h integer
---@field cols integer         frames per row
---@field rows integer         direction rows
---@field quads table<integer, love.Quad>   dir * 256 + frame -> quad
---@field ox integer           anchor inside the frame
---@field oy integer

-- A sprite set: the animations of one code (the install's .ani + sheets; src/gfx/pngset.lua makes PNG ones).
---@class AnimSet
---@field code string
---@field archive XcrArchive?  where the .ani was found (nil for PNG sets)
---@field info table<integer, AniRecord>   anim 0..8 -> its record
---@field sheets table<integer, SpriteSheet|false>   anim -> decoded sheet (false if missing)
---@field images table<integer, AnimImage>   key -> rendered image
local AnimSet = {}
AnimSet.__index = AnimSet
M.AnimSet = AnimSet

-- The install's sprite set of a code (4 letters, upper case): from `<code>.ani` and its sheets, or nil.
---@param code string
---@return AnimSet?
local function installSet(code)
    local data, arch = vfs.find(code .. ".ani")
    if not data then
        log.debug("anim %s: no .ani", code)
        return nil
    end
    return setmetatable({
        code = code,
        archive = arch,
        info = sprite.parseAni(data),
        sheets = {},     -- anim -> decoded sheet (false if missing)
        images = {},     -- key -> {image, additive}
    }, AnimSet)
end

local warned = {}
local function warnOnce(key, ...)
    if warned[key] then return end
    warned[key] = true
    log.warn(...)
end

-- The set a unit or building record's `sprite` reference names (docs/data-driven/05-assets.md 5.2): "AHBX" or { orig = "AHBX" } (the
-- install's set), { png = "gfx/shaman", mod = "shaman" } (a PNG set in a mod folder, src/gfx/pngset.lua). A record without a sprite, or
-- one that cannot be found, gets the placeholder (logged once): a missing asset never keeps a unit out of the battle.
---@param code string
---@return AnimSet?
local function recordSet(code)
    local gamedata = require("src.game.gamedata")
    local rec = gamedata.army(code) or gamedata.building(code)
    if not rec then return nil end
    local ref = rec.sprite
    if type(ref) == "string" then ref = { orig = ref } end
    if type(ref) == "table" and ref.orig then
        local set = installSet(ref.orig:upper())
        if set then return set end
        warnOnce(code, "asset: sprite set %s of %s is missing, using the placeholder", ref.orig, tostring(rec.id or code))
    elseif type(ref) == "table" and ref.png then
        local assets = require("src.assets")
        local prefix = ref.png:gsub("/+$", "") .. "/"
        local read
        for i = #assets.mounts(), 1, -1 do
            local m = assets.mounts()[i]
            if not ref.mod or m.id == ref.mod then
                local text = m.dir:read(prefix .. "anim.lua")
                if text then read = function(rel) return m.dir:read(rel) end break end
            end
        end
        if read then
            local set, err = require("src.gfx.pngset").load(read, prefix, tostring(rec.id or code))
            if set then return set end
            warnOnce(code, "asset: %s of %s: %s, using the placeholder", prefix, tostring(rec.id or code), tostring(err))
        else
            warnOnce(code, "asset: %sanim.lua of %s not found in any mod, using the placeholder", prefix, tostring(rec.id or code))
        end
    else
        warnOnce(code, "asset: %s has no sprite, using the placeholder", tostring(rec.id or code))
    end
    return require("src.gfx.pngset").placeholder()
end

-- The sprite set of a code (case-insensitive), cached; nil when there is none.
---@param code string
---@return AnimSet?
function M.get(code)
    local key = code:upper()
    local cached = M.sets[key]
    if cached ~= nil then return cached or nil end
    local set = installSet(key) or recordSet(code)
    M.sets[key] = set or false
    return set
end

---@param anim integer
---@return boolean
function AnimSet:has(anim)
    local a = self.info[anim]
    return a and a.used and a.frames > 0 and self:sheet(anim) ~= nil
end

---@param anim integer
---@return integer
function AnimSet:frames(anim)
    local a = self.info[anim]
    return a and a.used and a.frames or 0
end

-- The box an animation's frames are drawn in, relative to the sprite's anchor (the
-- unit's x, y): originX/originY is the anchor inside the frame, width/height the frame
-- size. The original builds each item's picking rectangle from this same frame
-- (the army rectangle routine 0x00539ce0, a vtable-only method), so a flyer's tall
-- frame reaches up to its floating body and down to its shadow. Falls back to the stand animation.
---@param anim integer
---@return integer? ox nil when the set has no usable frame
---@return integer? oy
---@return integer? w
---@return integer? h
function AnimSet:pickRect(anim)
    local a = self.info[anim]
    if not a or not a.used or a.width == 0 or a.height == 0 then a = self.info[0] end
    if not a or a.width == 0 or a.height == 0 then return nil end
    return a.originX, a.originY, a.width, a.height
end

-- The point effects and status icons hang from: the .ani's effect origin of the stand
-- animation, relative to the sprite's anchor, as the original draws it. The field is a
-- signed short, so values above 0x7fff are negative.
---@return integer x
---@return integer y
function AnimSet:effectCentre()
    local a = self.info[0]
    if not a then return 0, 0 end
    local function signed(v) return v >= 0x8000 and v - 0x10000 or v end
    return signed(a.effectOriginX or 0), signed(a.effectOriginY or 0)
end

---@param anim integer
---@return SpriteSheet?
function AnimSet:sheet(anim)
    local s = self.sheets[anim]
    if s == nil then
        local name = self.code .. sprite.SUFFIX[anim]
        local archive = self.archive      -- an install set always has one (PNG sets have their own `sheet`)
        ---@cast archive -nil
        local data = archive:read(name .. ".rle") or archive:read(name .. ".bmp")
            or vfs.find(name .. ".rle") or vfs.find(name .. ".bmp")
        if data then
            local ok, res = pcall(sprite.decodeSheet, data)
            s = ok and res or false
            if not ok then log.warn("anim %s/%d: %s", self.code, anim, tostring(res)) end
        else
            s = false
        end
        self.sheets[anim] = s
    end
    return s or nil
end

-- Returns the cached GPU image record for an animation in a side colour.
---@param anim integer
---@param team integer?
---@param paltype integer?
---@return AnimImage?
function AnimSet:image(anim, team, paltype)
    if optVersion ~= opts.version then syncOptions() end
    paltype = paltype or M.paltype
    local key = anim * 1000 + (team or 99) * 10 + paltype
    local rec = self.images[key]
    if rec then return rec end
    local s = self:sheet(anim)
    if not s then return nil end
    local a = self.info[anim]
    local effects = a.effect
    if effects and not (shadowsOn and lightingOn) then
        effects = { effects[1], effects[2] }
        for i = 1, 2 do
            local e = effects[i]
            if (e == 1 and not shadowsOn) or (e >= 2 and e <= 7 and not lightingOn) then effects[i] = 11 end
        end
    end
    local img, additive = sprite.render(s, team, paltype, effects)
    local image = love.graphics.newImage(img)
    image:setFilter("nearest", "nearest")
    local fw, fh = a.width > 0 and a.width or s.w, a.height > 0 and a.height or s.h
    rec = {
        image = image,
        additive = additive,
        w = fw, h = fh,
        cols = math.max(1, math.floor(s.w / fw)),
        rows = math.max(1, math.floor(s.h / fh)),
        quads = {},
        ox = a.originX, oy = a.originY,
    }
    self.images[key] = rec
    return rec
end

---@param rec AnimImage
---@param dir integer
---@param frame integer
---@return love.Quad
local function quad(rec, dir, frame)
    local k = dir * 256 + frame
    local q = rec.quads[k]
    if not q then
        q = love.graphics.newQuad(frame * rec.w, dir * rec.h, rec.w, rec.h, rec.image:getDimensions())
        rec.quads[k] = q
    end
    return q
end

-- Draws frame `frame` of animation `anim` facing `dir` with its origin at (x, y).
---@param anim integer
---@param dir integer
---@param frame integer
---@param x number
---@param y number
---@param team integer?
---@param paltype integer?
---@return boolean drawn
function AnimSet:draw(anim, dir, frame, x, y, team, paltype)
    local rec = self:image(anim, team, paltype)
    if not rec then return false end
    if dir >= rec.rows then dir = rec.rows - 1 end
    if frame >= rec.cols then frame = frame % rec.cols end
    if rec.additive then love.graphics.setBlendMode("add") end
    love.graphics.draw(rec.image, quad(rec, dir, frame), x - rec.ox, y - rec.oy)
    if rec.additive then love.graphics.setBlendMode("alpha") end
    return true
end

-- Draws one sheet cell with its top-left at (x, y) (no origin offset).
---@param anim integer
---@param dir integer
---@param frame integer
---@param x number
---@param y number
---@param team integer?
---@param sx number?
---@param sy number?
---@return boolean drawn
function AnimSet:drawCell(anim, dir, frame, x, y, team, sx, sy)
    local rec = self:image(anim, team)
    if not rec then return false end
    if dir >= rec.rows or frame >= rec.cols then return false end
    love.graphics.draw(rec.image, quad(rec, dir, frame), x, y, 0, sx or 1, sy or 1)
    return true
end

-- Interface ('I') sheet: frame 0 = big picture (drawn minus origin at x, y);
-- 1/2 = 32x50 icon colour/grey, 3/4 = 90x90 colour/grey, 5 = small group icon.
local iquads = setmetatable({}, { __mode = "k" })
---@param frame integer
---@return integer x
---@return integer y
---@return integer w
---@return integer h
function AnimSet:interfaceRect(frame)
    local a = self.info[sprite.ANIM.INTERFACE]
    local H = a.height
    if frame == 1 then return 0, H, 32, 50 end
    if frame == 2 then return 33, H, 32, 50 end
    if frame == 3 then return 0, H + 50, 90, 90 end
    if frame == 4 then return 0, H + 140, 90, 90 end
    if frame == 5 then
        local et = a.effectType
        local w = et <= 1 and 22 or 50
        local h = et <= 0 and 19 or 47
        return 90, H + 50, w, h
    end
    return 0, 0, a.width, a.height
end

---@param frame integer
---@param x number
---@param y number
---@param team integer?
---@param scale number?
---@return boolean drawn
function AnimSet:drawInterface(frame, x, y, team, scale)
    local A = sprite.ANIM.INTERFACE
    if not self:has(A) then return false end
    local rec = self:image(A, team, 0)
    if not rec then return false end
    local qs = iquads[rec] or {}
    iquads[rec] = qs
    local q = qs[frame]
    if not q then
        local sx, sy, w, h = self:interfaceRect(frame)
        local iw, ih = rec.image:getDimensions()
        if sx + w > iw or sy + h > ih then return false end
        q = love.graphics.newQuad(sx, sy, w, h, iw, ih)
        qs[frame] = q
    end
    if frame == 0 then x, y = x - rec.ox, y - rec.oy end
    love.graphics.draw(rec.image, q, x, y, 0, scale or 1, scale or 1)
    return true
end

-- Forgets every set (the content changed: a record's sprite reference may name something else now).
function M.forget()
    M.clear()
    M.sets, warned = {}, {}
end

function M.clear()
    for _, set in pairs(M.sets) do
        if set then
            for _, rec in pairs(set.images) do rec.image:release() end
            set.images = {}
        end
    end
end

return M
