-- The campaign options dialog (PNL_CAMPAIGN_OPTIONS; the 1.04 binary:
-- `FUN_005a4070` opens panel 363 at (80, 130) over the campaign map, `FUN_005a4780` / `FUN_005a4900` set the texts, the
-- option record at 0x060d37ba is { map scroll rate, difficulty, campaign menu sounds, game resolution }). Four drop-downs:
--   difficulty (TXT_CAMPAIGN_OPTIONS2 0..2: Easy, Normal, Hard; the default is Normal),
--   map scroll speed (3..5: Slow, Normal, Fast), game resolution (800 x 600 .. 1600 x 1200) and campaign menu sounds (Off / On),
-- and the buttons Cancel, Okay and "Reset Campaign" (asks "Are you sure you wish to reset your campaign?", then starts the
-- hero's campaign afresh). The picks change the option record at once (the callbacks write through the pointer); Okay
-- saves it, Cancel just closes (the in-memory change stays until the next save, as in the original); Escape closes.
-- Difficulty feeds the computer sides of every battle (campaignrun.lua), the scroll rate the map scrolling and the menu
-- sounds the Ambush / Sail / Land / Merchant / message / Tavern / Battle / retinue / xp wavs of the campaign dialogs.
-- The game resolution (0..3 = 800 / 1024 / 1280 / 1600 wide) is read by the campaign battle start (`FUN_005a1880`, which hands it to
-- `FUN_004e7230`, the battle's resolution); openwbc3 sets its window to that size when a campaign battle starts
-- (campaignrun.applyResolution: windowed, if the desktop is big enough, only once picked). The campaign map itself stays on
-- the scaled 800 x 600 canvas.
--
--   screens.push(require("src.screens.campaignoptions"), { state = <campaign state>, onReset = function() return newState end })
local screens = require("src.core.screens")
local UI = require("src.ui.interface")
local dropdown = require("src.ui.dropdown")
local run = require("src.game.campaignrun")

---@class CampaignOptionsConfig
---@field state CampaignState
---@field onReset (fun(): CampaignState?)? starts the campaign afresh, returns the new state

---@class CampaignOptionsScreen: Screen
---@field cfg CampaignOptionsConfig
---@field panel Panel
---@field drops PanelItem[]          the four drop-down buttons, in KEYS order
---@field box MsgBox?                the "reset campaign" question
local S = { overlay = true }

-- the four drop-downs in panel order (top-left, top-right, bottom-left, bottom-right) -> option key
local KEYS = { "difficulty", "scrollRate", "resolution", "menuSounds" }

local function T(id, sub, fallback) return UI.text(id, sub) or fallback end

local function resolutionText(v)
    if v < 2 then return T(171, v, v == 0 and "800 x 600" or "1024 x 768") end
    return T(254, v - 1, v == 2 and "1280 x 1024" or "1600 x 1200")
end

-- Items of drop-down i, 1-based: the texts and the option value each stands for.
local function items(i)
    local list = {}
    if i == 1 then
        for n = 0, 2 do list[#list + 1] = T(293, n, "") end
    elseif i == 2 then
        for n = 3, 5 do list[#list + 1] = T(293, n, "") end
    elseif i == 3 then
        for n = 0, 3 do list[#list + 1] = resolutionText(n) end
    else
        list = { T(292, 5, "Off"), T(292, 6, "On") }
    end
    return list
end

---@param cfg CampaignOptionsConfig?
function S:enter(cfg)
    cfg = cfg or self:sample()
    self.cfg = cfg
    local p = UI.panel("PNL_CAMPAIGN_OPTIONS", { x = 80, y = 130, onButton = function(name, it) self:button(name, it) end })
    ---@cast p -nil
    self.panel = p
    self.drops = p:all("BUTT_DROPLIST170")
    for _, it in ipairs(self.drops) do p.align[it] = "left" end
    local title = p:find("STR_LARGE400")
    ---@cast title -nil
    p.itemStrings[title] = T(314, 3, "Options")
    p.align[title] = "center"
    for i, it in ipairs(p:all("STR_SMALL260")) do p.itemStrings[it] = T(292, i, "") end
    self:refresh()
end

---@return CampaignOptionsConfig
function S:sample()
    return { state = require("src.game.campaignstate").new("sample") }
end

function S:values() return run.options(self.cfg.state) end

function S:refresh()
    local v = self:values()
    for i, key in ipairs(KEYS) do
        local text = items(i)[v[key] + 1] or ""
        self.panel.itemStrings[self.drops[i]] = text
    end
end

---@param key string                 a key of the campaign state's option record
---@param value integer
function S:set(key, value)
    self.cfg.state[key] = value
    self:refresh()
end

function S:close()
    dropdown.close()
    screens.pop()
end

function S:button(name, it)
    if name == "BUTT_DROPLIST170" then
        for i, d in ipairs(self.drops) do
            if d == it then
                local mx, my = UI.toVirtual(love.mouse.getPosition())
                dropdown.open(items(i), mx, my, function(index) self:set(KEYS[i], index - 1) end)
            end
        end
    elseif name == "BUTT_OKAY_180" then
        self.cfg.state:save()
        self:close()
    elseif name == "BUTT_CANCEL_180" then
        self:close()
    elseif name == "BUTT_RESETCAMPAIGN" then
        self.box = require("src.ui.msgbox").new({
            title = T(292, 0, "Reset Campaign"), line1 = T(314, 6, "Are you sure you wish to reset your campaign?"),
            buttons = { T(285, 3, "No"), T(285, 2, "Yes") },
            onResult = function(yes)
                self.box = nil
                if yes and self.cfg.onReset then
                    self.cfg.state = self.cfg.onReset() or self.cfg.state
                    self:refresh()
                end
            end })
    end
end

function S:update() require("src.audio.music").update() end

function S:draw()
    UI.begin()
    self.panel:draw()
    dropdown.draw()
    if self.box then self.box:draw() end
    UI.finish()
end

function S:mousemoved(x, y)
    local vx, vy = UI.toVirtual(x, y)
    if self.box then return self.box:mousemoved(vx, vy) end
    self.panel:mousemoved(vx, vy)
end

function S:mousepressed(x, y, button)
    local vx, vy = UI.toVirtual(x, y)
    if self.box then return self.box:mousepressed(vx, vy, button) end
    if dropdown.pressed(vx, vy) then return end
    self.panel:mousepressed(vx, vy, button)
end

function S:mousereleased(x, y, button)
    local vx, vy = UI.toVirtual(x, y)
    if self.box then return self.box:mousereleased(vx, vy, button) end
    if dropdown.isOpen() then return end
    self.panel:mousereleased(vx, vy, button)
end

function S:keypressed(key)
    if self.box then return self.box:keypressed(key) end
    if dropdown.isOpen() then dropdown.close() return end
    if key == "escape" then self:close() end
end

function S:leave() dropdown.close() end

-- developer aid: --show campaignoptions[:reset]
function S:dev(sub)
    self:enter(self:sample())
    if sub == "reset" then self:button("BUTT_RESETCAMPAIGN") end
    if sub == "drop" then dropdown.open(items(1), 180, 250, function() end) end
end

return S
