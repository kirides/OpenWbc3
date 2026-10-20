-- Screen help (the original's FUN_00448870, layout FUN_00448cf0): a parchment box at (150,120), 500x360, with the text
-- blocks of <language>/ScreenHelp.txt for one screen. Each screen has a number (S.ID below); its blocks are the keys
-- [SCREENnn_TEXTmm]. A block starting with "<>" is a paragraph, "<x,y>" a paragraph that points at that place of the
-- screen (a line from the block to the point is drawn while the mouse is over the block), anything else is a centred
-- heading. The blocks are wrapped to 369 px and spread over the 290 px tall text area (gaps of at most 23 px). A screen
-- shows its help once, the first time it opens (the original keeps the flags in the registry; here [help] screenNN in
-- openwbc3.ini); F1 on a screen shows it again (the `force` argument). Any key / click closes it after a short safe
-- time.
--
-- S.open(id, force) -> true if the help was opened.
local screens = require("src.core.screens")
local UI = require("src.ui.interface")
local fonts = require("src.ui.fonts")
local widgets = require("src.ui.widgets")
local config = require("src.core.config")
local fs = require("src.core.fs")
local text = require("src.core.text")
local vfs = require("src.vfs.vfs")
local bmp = require("src.formats.bmp")

-- A text block of the help laid out.
---@class HelpBlock
---@field text string
---@field pad boolean?               a paragraph (else a centred heading)
---@field dest { [1]: number, [2]: number }?   the point of the screen it explains
---@field center boolean?
---@field lines string[]
---@field x number
---@field y number
---@field w number
---@field h number
---@field from { [1]: number, [2]: number }?   the block's corner closest to `dest`

---@class ScreenHelpScreen: Screen
---@field ID table<string, integer>  the original's screen numbers
---@field t0 number                  when it opened (the safe time)
---@field blocks HelpBlock[]
---@field lineH number
---@field continue string            "Click to Continue..."
---@field highlight integer?         the block under the mouse
local S = { overlay = true }

-- the original's screen numbers (nn of the ScreenHelp.txt keys)
S.ID = { mainMenu = 0, heroSelection = 1, heroCreation = 2, heroCustomization = 3, heroJournalHint = 4,
         heroReplayable = 5, heroItemStash = 6, campaign = 7, armyPoints = 8, retinue = 9, sideSelection = 10,
         multiplayer = 11, graveyard = 12, results = 13, victoryDefeat = 14 }

local BOX_X, BOX_Y, BOX_W, BOX_H = 150, 120, 500, 360
local TEXT_X, TEXT_Y, TEXT_W, TEXT_H = 58 + BOX_X, 30 + BOX_Y, 375, 290
local MAX_SPACE, MAX_LINES = 23, 16
local CONTINUE_X, CONTINUE_Y = 248 + BOX_X, 310 + BOX_Y
local FONT_LO, FONT_HI = 15, 16          -- small light / large block font
local SAFE_TIME = 5 / 30                 -- 5 ticks of the original's 30 Hz timer

local cache

local function parse()
    if cache then return cache end
    cache = { continue = "Click to Continue...", blocks = {} }
    local data = fs.read(config.gamedir .. "/" .. config.language .. "/ScreenHelp.txt")
        or fs.read(config.gamedir .. "/English/ScreenHelp.txt")
    if not data then return cache end
    for line in (data .. "\n"):gmatch("(.-)\r?\n") do
        local key, rest = line:match("^%[([^%]]+)%]%s*(.-)%s*$")
        if key then
            rest = text.fromCP1252(rest)
            if key == "CLICKTOCONTINUE" then
                cache.continue = rest
            else
                local n, i = key:match("^SCREEN(%d%d)_TEXT(%d%d)$")
                if n then
                    n, i = tonumber(n) --[[@as integer]], tonumber(i)   -- (two digits)
                    cache.blocks[n] = cache.blocks[n] or {}
                    local b = { index = i }
                    if rest:sub(1, 1) == "<" then
                        b.pad = true
                        local x, y, body = rest:match("^<%s*(%d+)%s*,%s*(%d+)%s*>%s*(.*)$")
                        if x then
                            b.dest = { tonumber(x), tonumber(y) }
                            b.text = body
                        else
                            b.text = rest:match("^<>%s*(.*)$") or rest
                        end
                    else
                        b.text, b.center = rest, true
                    end
                    cache.blocks[n][#cache.blocks[n] + 1] = b
                end
            end
        end
    end
    for _, list in pairs(cache.blocks) do table.sort(list, function(a, b) return a.index < b.index end) end
    return cache
end

local box
local function boxImage()
    if box == nil then
        box = false
        local data = vfs.read("Assets/Graphics.xcr", "ScreenHelp.bmp")
        if data then
            -- magenta is transparent; pure black pixels become 50 % transparent (the original's 50 % black blending
            -- mode, used while lighting effects are on, which is the default)
            local ok, d = pcall(bmp.decode, data, { key = true })
            if ok and d then
                d:mapPixel(function(_, _, r, g, b, a)
                    if a > 0 and r == 0 and g == 0 and b == 0 then return 0, 0, 0, 0.5 end
                    return r, g, b, a
                end)
                box = love.graphics.newImage(d)
            end
        end
    end
    return box or nil
end

---@param id integer the screen number
---@param force boolean? show it even when it was shown before (F1)
---@return boolean opened
function S.open(id, force)
    local c = parse()
    if not c.blocks[id] then return false end
    local flag = ("screen%02d"):format(id)
    if not force and config.get("help", flag, false) then return false end
    config.set("help", flag, true)
    config.save()
    screens.push(S, id)
    return true
end

-- Lays the blocks out like FUN_00448cf0.
---@param id integer?
function S:enter(id)
    id = id or 0
    local c = parse()
    self.t0 = love.timer.getTime()
    self.blocks = {}
    local _, f = fonts.get(FONT_LO)
    local lineH = (f and f:getHeight() or 14) + 2
    self.lineH = lineH
    local total = 0
    for _, b in ipairs(c.blocks[id] or {}) do
        local nb = { text = b.text, pad = b.pad, dest = b.dest, center = b.center,
                     lines = widgets.wrap(FONT_LO, b.text, TEXT_W - 6) }
        if #nb.lines > MAX_LINES then for k = #nb.lines, MAX_LINES + 1, -1 do nb.lines[k] = nil end end
        nb.x, nb.w, nb.h = TEXT_X, TEXT_W, 6 + #nb.lines * lineH
        total = total + nb.h
        self.blocks[#self.blocks + 1] = nb
    end
    local space = 0
    if #self.blocks >= 2 then space = math.min(MAX_SPACE, math.floor((TEXT_H - total) / (#self.blocks - 1))) end
    local y = TEXT_Y
    for _, b in ipairs(self.blocks) do
        b.y = y
        y = y + b.h + space
        if b.pad and b.dest then
            -- the corner of the block closest to the point it explains
            local best, bd = nil, math.huge
            for _, corner in ipairs({ { b.x, b.y }, { b.x + b.w - 1, b.y }, { b.x, b.y + b.h - 1 }, { b.x + b.w - 1, b.y + b.h - 1 } }) do
                local d = (corner[1] - b.dest[1]) ^ 2 + (corner[2] - b.dest[2]) ^ 2
                if d < bd then best, bd = corner, d end
            end
            b.from = best
        end
    end
    self.continue = c.continue
    self.highlight = nil
end

function S:draw()
    local g = love.graphics
    UI.begin()
    g.setColor(0, 0, 0, 0.6)      -- IM_SCREENHELP, the shade of PNL_SCREENHELP
    g.rectangle("fill", 0, 0, 800, 600)
    g.setColor(1, 1, 1)
    local img = boxImage()
    if img then g.draw(img, BOX_X, BOX_Y) else
        g.setColor(0.1, 0.05, 0.03, 0.95)
        g.rectangle("fill", BOX_X, BOX_Y, BOX_W, BOX_H)
        g.setColor(1, 1, 1)
    end
    for i, b in ipairs(self.blocks) do
        local font = (i == self.highlight) and FONT_HI or FONT_LO
        local y = b.y + 3
        for _, l in ipairs(b.lines) do
            if b.center then fonts.print(font, l, TEXT_X, y, "center", TEXT_W)
            else fonts.print(font, l, b.x + 3, y) end
            y = y + self.lineH
        end
    end
    local b = self.blocks[self.highlight or 0]
    if b then
        g.setLineWidth(1)
        g.setColor(0, 0, 0)
        g.rectangle("line", b.x - 1 + 0.5, b.y + 1 + 0.5, b.w, b.h)
        if b.from then g.line(b.from[1] - 1, b.from[2] + 1, b.dest[1] - 1, b.dest[2] + 1) end
        g.setColor(0, 1, 0)
        g.rectangle("line", b.x + 0.5, b.y + 0.5, b.w, b.h)
        if b.from then g.line(b.from[1], b.from[2], b.dest[1], b.dest[2]) end
        g.setColor(1, 1, 1)
    end
    fonts.print(FONT_LO, self.continue, CONTINUE_X - 150, CONTINUE_Y, "center", 300)
    UI.finish()
end

function S:mousemoved(x, y)
    local vx, vy = UI.toVirtual(x, y)
    self.highlight = nil
    for i, b in ipairs(self.blocks) do
        if b.pad and vx >= b.x and vx < b.x + b.w and vy >= b.y and vy < b.y + b.h then
            self.highlight = i
            break
        end
    end
end

function S:close()
    if love.timer.getTime() - self.t0 >= SAFE_TIME then screens.pop() end
end

function S:mousereleased() self:close() end

function S:keypressed(key)
    if key == "escape" or key == "space" or key == "return" or key == "kpenter" then self:close() end
end

function S:dev(sub)
    self.t0 = -10
end

return S
