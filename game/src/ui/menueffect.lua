-- The main menu's hover effect (the original's effect object, constructor FUN_004052c0): when the mouse moves onto an
-- entry, a copy of its text grows wider and fades out over 1.5 seconds on top of the button.
--
-- Verified against the 1.04 binary (add FUN_00405360, update FUN_00405500, draw FUN_00405330 / FUN_00405580, called
-- from the main menu handler 0x0041d730): at most 12 effects at once (a new one is dropped when all are used; the same
-- entry may be added again, duplicates are allowed - the constructor sets that flag), the text is centred at x = 400
-- with y = 162 (Campaign), 207 (Skirmish), 252 (Multiplayer), 297 (Tutorial), 342 (Options), 387 (Editor), 472 (Quit),
-- drawn in font 26 (FO_LARGE_HILIGHT); during its life the translucency level goes from 9 to 15 (of 15) and the extra
-- space between the letters from 0 to 20 pixels, both linearly. A font translucency level L lowers every glyph's
-- coverage by L steps of 16, so a solid pixel has an opacity of about (16 - L) / 16, nothing at 15.
--
-- Presentation only. Must not touch love.graphics at require time.
local fonts = require("src.ui.fonts")

local M = {}

local MAX_EFFECTS, DURATION, MAX_PADDING, START_LEVEL, FONT = 12, 1.5, 20, 9, 26

-- button name -> text index of TXT_STARTUP, y
M.ENTRIES = {
    BUTT_MM_SINGLEPLAYER = { 0, 207 }, BUTT_MM_MULTIPLAYER = { 1, 252 }, BUTT_MM_TUTORIAL = { 2, 297 },
    BUTT_MM_OPTIONS = { 3, 342 }, BUTT_MM_EDITOR = { 4, 387 }, BUTT_MM_QUIT = { 5, 472 }, BUTT_MM_CAMPAIGN = { 6, 162 },
}

---@class MenuEffect         one growing, fading copy of an entry's text
---@field text string
---@field x number
---@field y number
---@field t0 number            start time (seconds)

---@class MenuEffects
---@field items MenuEffect[]
local List = {}
List.__index = List

---@return MenuEffects
function M.new() return setmetatable({ items = {} }, List) --[[@as MenuEffects]] end

---@param text string
---@param x number
---@param y number
---@param now number
function List:add(text, x, y, now)
    if #self.items >= MAX_EFFECTS then return end
    self.items[#self.items + 1] = { text = text, x = x, y = y, t0 = now }
end

-- Called when the mouse enters a button; `text(n)` gives TXT_STARTUP n.
---@param name string
---@param text fun(n: integer): string?
---@param now number
function List:focus(name, text, now)
    local e = M.ENTRIES[name]
    if e and text(e[1]) then self:add(text(e[1]) --[[@as string]], 400, e[2], now) end
end

function List:update(now)
    for i = #self.items, 1, -1 do
        if now - self.items[i].t0 >= DURATION then table.remove(self.items, i) end
    end
end

function List:draw(now)
    local d, face = fonts.get(FONT)
    if not d then return end
    -- a definition always comes with its face
    ---@cast face love.Font
    for _, e in ipairs(self.items) do
        local p = (now - e.t0) / DURATION
        local level = math.min(15, math.max(0, math.floor(START_LEVEL + (15 - START_LEVEL) * p)))
        local pad = math.floor(MAX_PADDING * p)
        local alpha = level >= 15 and 0 or (16 - level) / 16
        if alpha > 0 then
            local chars, width = {}, 0
            for ch in e.text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
                chars[#chars + 1] = { ch, face:getWidth(ch) + pad }
                width = width + chars[#chars][2]
            end
            local x = e.x - math.floor(width / 2)
            for _, c in ipairs(chars) do
                fonts.print(FONT, c[1], x, e.y, "left", nil, alpha)
                x = x + c[2]
            end
        end
    end
end

return M
