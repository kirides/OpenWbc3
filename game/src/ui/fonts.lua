-- Interface fonts from <Lang>/Font.ini: [FONT.n] with File (a TrueType .fnt in
-- Fonts/), PointSize (pixel size), Baseline, Color*, Key* (outline/shadow
-- colour) and Style (Normal, DropShadow, KeyLine, DropShadowCenter, DropShadowLeft).
local ini = require("src.core.ini")
local fs = require("src.core.fs")
local log = require("src.core.log")

---@class FontDef          a [FONT.n] section of Font.ini
---@field file string          TrueType file in Fonts/
---@field size number          pixel size
---@field baseline number
---@field color number[]       r, g, b (0..1)
---@field key number[]         outline / shadow colour
---@field style string         lower case: normal, dropshadow, keyline, dropshadowcenter, dropshadowleft

---@class FontsModule
---@field defs table<integer, FontDef>
---@field faces table<string, love.Font|false>  "file@size x dpi" -> face
---@field gamedir string?
---@field dpi number?          the density the faces are rasterised at
---@field custom string|false? the custom font's path (false: none), resolved on first use
local M = { defs = {}, faces = {} }

local STYLE_OFFSETS = {
    dropshadow = { { 1, 1 } },
    keyline = { { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 } },
    dropshadowcenter = { { 0, 1 } },
    dropshadowleft = { { -1, 1 } },
}

---@param gamedir string
---@param lang string
function M.init(gamedir, lang)
    M.gamedir = gamedir
    local data = ini.load(gamedir .. "/" .. lang .. "/Font.ini") or ini.load(gamedir .. "/English/Font.ini") or {}
    for name, sec in pairs(data) do
        local n = tonumber(name:match("^font%.(%d+)$"))
        if n then
            M.defs[n] = {
                file = sec.file or "MainFont.fnt",
                size = tonumber(sec.pointsize) or 13,
                baseline = tonumber(sec.baseline) or 10,
                color = { (tonumber(sec.colorred) or 255) / 255, (tonumber(sec.colorgreen) or 255) / 255,
                          (tonumber(sec.colorblue) or 255) / 255 },
                key = { (tonumber(sec.keyred) or 0) / 255, (tonumber(sec.keygreen) or 0) / 255,
                        (tonumber(sec.keyblue) or 0) / 255 },
                style = (sec.style or "normal"):lower(),
            }
        end
    end
end

-- Custom font (openwbc3's own option, `[game] customfont=` in openwbc3.ini): replaces the original's TrueType fonts
-- by a font file or an installed system font, given as a path, a file name ("arial.ttf", "arial") or on Windows
-- the name shown in the font list ("Segoe UI"). The sizes and baselines of Font.ini are kept.
local function systemFontDirs()
    local dirs = {}
    local win, local_ = os.getenv("WINDIR"), os.getenv("LOCALAPPDATA")
    if win then dirs[#dirs + 1] = win .. "/Fonts" end
    if local_ then dirs[#dirs + 1] = local_ .. "/Microsoft/Windows/Fonts" end
    local home = os.getenv("HOME")
    for _, d in ipairs({ "/usr/share/fonts", "/usr/local/share/fonts", "/Library/Fonts", "/System/Library/Fonts",
                         home and (home .. "/.fonts"), home and (home .. "/.local/share/fonts") }) do
        if d then dirs[#dirs + 1] = d end
    end
    return dirs
end

local function findFile(dir, name, depth)
    for _, ext in ipairs({ "", ".ttf", ".otf", ".ttc" }) do
        if fs.exists(dir .. "/" .. name .. ext) and (ext ~= "" or name:match("%.%w+$")) then return dir .. "/" .. name .. ext end
    end
    if depth > 0 then
        for _, sub in ipairs(fs.list(dir) or {}) do
            local found = not sub:find("%.") and findFile(dir .. "/" .. sub, name, depth - 1)
            if found then return found end
        end
    end
end

-- Windows: the font list's display name ("Segoe UI") to its file, from the registry's Fonts keys.
local function registryFile(name)
    if love.system.getOS() ~= "Windows" then return nil end
    for _, root in ipairs({ "HKLM", "HKCU" }) do
        local p = io.popen(('reg query "%s\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Fonts" 2>nul'):format(root))
        if p then
            local out = p:read("*a")
            p:close()
            for key, file in out:gmatch("\n%s+(.-)%s+REG_SZ%s+([^\r\n]+)") do
                if key:gsub("%s*%(%a+%)$", ""):lower() == name:lower() then
                    if not file:find("[/\\]") then
                        file = (root == "HKLM" and (os.getenv("WINDIR") or "C:/Windows") .. "/Fonts/"
                            or (os.getenv("LOCALAPPDATA") or "") .. "/Microsoft/Windows/Fonts/") .. file
                    end
                    return file:gsub("\\", "/")
                end
            end
        end
    end
end

local function customFontPath()
    local name = require("src.core.config").get("game", "customfont", "")
    if not name or name == "" then return nil end
    if fs.exists(name) then return name end
    for _, dir in ipairs(systemFontDirs()) do
        local found = findFile(dir, name, 1)
        if found then return found end
    end
    local found = registryFile(name)
    if found and fs.exists(found) then return found end
    log.warn("custom font %s not found", name)
end

-- Glyphs are rasterised at the window's pixels-per-virtual-pixel (rounded up to quarter steps, 1..4) while Font
-- metrics stay in virtual units (LÖVE's dpiscale), so scaled-up UI text is sharp instead of a stretched small bitmap.
local function density()
    local w, h = love.graphics.getDimensions()
    local s = math.min(w / 800, h / 600)
    return math.max(1, math.min(4, math.ceil(s * 4 - 1e-6) / 4))
end

---@param file string
---@param size number
---@return love.Font
function M.face(file, size)
    local dpi = density()
    if M.dpi ~= dpi then M.dpi, M.faces = dpi, {} end -- window resized: drop faces rasterised for the old size
    local key = file:lower() .. "@" .. size .. "x" .. dpi
    local f = M.faces[key]
    if f == nil then
        if M.custom == nil then M.custom = customFontPath() or false end
        local data = fs.read(M.custom or (M.gamedir .. "/Fonts/" .. file))
        if data then
            local ok, res = pcall(function()
                -- the love2d library lacks newFont's (FileData, size, hinting, dpiscale) overload
                ---@diagnostic disable-next-line: param-type-mismatch
                return love.graphics.newFont(love.filesystem.newFileData(data, file), size, "light", dpi)
            end)
            f = ok and res or false
            if not ok then log.warn("font %s: %s", file, tostring(res)) end
        else
            f = false
        end
        if not f then f = love.graphics.newFont(size, "light", dpi) end
        M.faces[key] = f
    end
    return f --[[@as love.Font]]
end

-- A plain face of the game's own text font (that of Font.ini entry 5, FO_MEDIUM) at a pixel size, for the screens that
-- are laid out in window pixels instead of Font.ini slots (shop, quest dialog, save slots, spell bar); follows the
-- `customfont` option like every other face. Falls back to LÖVE's default font when the game font is unavailable.
---@param size number
---@return love.Font
function M.plain(size)
    local d = M.defs and M.defs[5]
    if not d then return love.graphics.newFont(size) end
    return M.face(d.file, size)
end

-- The definition of font n (font 2 when n has none) and its face; nil when Font.ini gave neither.
---@param n integer
---@return FontDef?
---@return love.Font?
function M.get(n)
    local d = M.defs[n] or M.defs[2]
    if not d then return nil end
    return d, M.face(d.file, d.size)
end

---@param n integer
---@param s string
---@return number
function M.width(n, s)
    local _, f = M.get(n)
    return f and f:getWidth(s) or 0
end

-- Offset from the top of a box of height h at which to pass y to print() so the
-- capitals (about 0.7 em tall, standing on the baseline) sit vertically centred.
---@param n integer
---@param h number
---@return number
function M.middleY(n, h)
    local d = M.get(n)
    if not d then return 0 end
    return math.floor(h / 2 + d.size * 0.35 - d.baseline + 0.5)
end

-- Draws `s` with font n so the font's baseline sits at y + Baseline.
-- align: "left" | "center" | "right" within width w.
---@param n integer
---@param s string
---@param x number
---@param y number
---@param align? "left"|"center"|"right"
---@param w? number
---@param alpha? number
function M.print(n, s, x, y, align, w, alpha)
    local d, f = M.get(n)
    if not d then return end
    -- a definition always comes with its face
    ---@cast f love.Font
    local g = love.graphics
    g.setFont(f)
    local tw = f:getWidth(s)
    if align == "center" and w then x = x + math.floor((w - tw) / 2)
    elseif align == "right" and w then x = x + w - tw end
    local by = math.floor(y + d.baseline - f:getBaseline())
    alpha = alpha or 1
    local offs = STYLE_OFFSETS[d.style]
    if offs then
        g.setColor(d.key[1], d.key[2], d.key[3], alpha)
        for _, o in ipairs(offs) do g.print(s, x + o[1], by + o[2]) end
    end
    g.setColor(d.color[1], d.color[2], d.color[3], alpha)
    g.print(s, x, by)
    g.setColor(1, 1, 1)
end

return M
