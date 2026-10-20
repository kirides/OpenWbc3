-- Credits (the original's credits screen, opener FUN_004069e0, loader FUN_00406b10): the lines of
-- <language>/Credits.xml shown on PNL_WBC3CREDITS in two columns of 16 lines (x 270 and 535, first line at y 150, 20 px
-- apart), appearing one line per 8 timer ticks (~0.27 s at the original's 30 Hz timer); a heading that would land on
-- the last line of a column moves to the next one. After both columns are full the page stays for a while and the next
-- page starts; at the end it starts again.
local screens = require("src.core.screens")
local UI = require("src.ui.interface")
local fonts = require("src.ui.fonts")
local xml = require("src.core.xml")
local fs = require("src.core.fs")
local config = require("src.core.config")
local text = require("src.core.text")
local music = require("src.audio.music")

---@class CreditsScreen: Screen
---@field endCampaign boolean?       opened at the end of the campaign: closing also leaves the campaign map
---@field pages { cols: { kind: string, text: string }[][] }[]
---@field page integer               the page shown
---@field t0 number                  love.timer seconds when the page started
---@field shown integer              lines of the page shown so far
---@field panel Panel
---@field headingFont integer        font of the headings
---@field lineFont integer           font of the other lines
local S = { overlay = false }

local COLUMN_X = { 270, 535 }
local TOP_Y, STEP, PAGE_LINES = 150, 20, 16
local LINE_TIME, PAGE_PAUSE = 8 / 30, 24 / 30
local HEADING_FONT, LINE_FONT = "STR_PARCHMED_L35", "STR_PARCHSMALL_L150"

local function load()
    local data = fs.read(config.gamedir .. "/" .. config.language .. "/Credits.xml")
        or fs.read(config.gamedir .. "/English/Credits.xml")
    local lines = {}
    if not data then return lines end
    local root = xml.parse(text.fromCP1252(data))
    local function walk(n)
        if n.tag == "Line" then
            local kind = n.attrs.type or "normal"
            lines[#lines + 1] = { kind = kind, text = kind == "blank" and "" or (n.text or ""):gsub("^%s+", ""):gsub("%s+$", "") }
        end
        for _, c in ipairs(n.children) do walk(c) end
    end
    walk(root)
    return lines
end

-- Splits the lines into pages: { { left = {...}, right = {...} }, ... }
local function paginate(lines)
    local pages, i = {}, 1
    while i <= #lines do
        local page = { cols = { {}, {} } }
        for c = 1, 2 do
            local col = page.cols[c]
            while i <= #lines and #col < PAGE_LINES do
                local l = lines[i]
                if #col == 0 and l.kind == "blank" then i = i + 1            -- no blank line at the top of a column
                elseif #col == PAGE_LINES - 1 and l.kind == "heading" then break   -- heading moves on
                else col[#col + 1] = l i = i + 1 end
            end
        end
        pages[#pages + 1] = page
    end
    return pages
end

-- enter(endCampaign): true when the credits come from the end of the campaign (not traced in the 1.04 binary yet: its
-- opener FUN_004069e0 takes no flag): closing them then also leaves the campaign map for the main menu, as the original
-- goes back to its start-up screen. The campaign of openwbc3 has no end condition (conquering / resigning; that end
-- screen was not found in the 1.04 binary) that would open them this way yet.
---@param endCampaign boolean?
function S:enter(endCampaign)
    self.endCampaign = endCampaign
    self.pages = paginate(load())
    self.page, self.t0, self.shown = 1, love.timer.getTime(), 0
    local p = UI.panel("PNL_WBC3CREDITS", { x = 0, y = 0, onButton = function() self:close() end })
    ---@cast p -nil
    self.panel = p
    for _, it in ipairs(self.panel.items) do
        if it.name == "PAD_FULLSCREEN800x600" or it.name == "IM_WBC3CREDITS_TEXT" then it.ob = setmetatable({ source = -1 }, { __index = it.ob }) end
    end
    self.panel:setString("BUTT_OKAY_STARTUP", require("src.game.strings").get("Game.txt", "0300") or "Okay")
    self.headingFont =UI.ui.objByName[HEADING_FONT].font
    self.lineFont = UI.ui.objByName[LINE_FONT].font
    music.play("intro")
end

function S:close()
    screens.pop()
    if self.endCampaign then screens.pop() end
end

function S:update(dt)
    local page = self.pages[self.page]
    if not page then return end
    local total = #page.cols[1] + #page.cols[2]
    local elapsed = love.timer.getTime() - self.t0
    self.shown = math.min(total, math.floor(elapsed / LINE_TIME) + 1)
    if self.shown >= total and elapsed > (total + 1) * LINE_TIME + PAGE_PAUSE then
        self.page = self.page % #self.pages + 1
        self.t0, self.shown = love.timer.getTime(), 0
    end
end

function S:draw()
    UI.begin()
    self.panel:draw()
    local page = self.pages[self.page]
    if page then
        local n = 0
        for c = 1, 2 do
            local prev
            for row, l in ipairs(page.cols[c]) do
                n = n + 1
                if n > self.shown then break end
                local y = TOP_Y + (row - 1) * STEP
                if l.kind == "heading" then
                    fonts.print(self.headingFont, l.text, COLUMN_X[c] - 100, y + ((prev and prev.kind == "heading") and 5 or 0),
                                "center", 200)
                elseif l.text ~= "" then
                    fonts.print(self.lineFont, l.text, COLUMN_X[c] - 100, y, "center", 200)
                end
                prev = l
            end
        end
    end
    UI.finish()
end

function S:mousemoved(x, y) self.panel:mousemoved(UI.toVirtual(x, y)) end
function S:mousepressed(x, y, b) local vx, vy = UI.toVirtual(x, y) self.panel:mousepressed(vx, vy, b) end
function S:mousereleased(x, y, b) local vx, vy = UI.toVirtual(x, y) self.panel:mousereleased(vx, vy, b) end
function S:keypressed(key) if key == "escape" or key == "return" or key == "space" then self:close() end end

return S
