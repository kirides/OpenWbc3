-- The random map settings of the side selection screen: PNL_SS_RANDOMMAP, opened at (30, 22) over the minimap while the
-- "Random Map" entry of the list is picked (opened by FUN_004e0590 with the panel handler 0x004e1390, button texts
-- set by FUN_004e3130). Five buttons, each opening a drop-down: map size (texts 180), terrain (216 + 250), "utilities"
-- (lairs, shops and temples, texts 345; the panel's button is named BUTT_RM_ISLANDS after the unused islands setting),
-- animals (182) and resources (183); the last entry of every list is "Random" (text 83.0), resolved when the game
-- starts (randommap.resolve). Values are the list indices (game/randommap.lua). The last choice is remembered in the ini
-- ([randommap]; the original keeps it in the registry, read by FUN_00450970, written by FUN_00450760).
local UI = require("src.ui.interface")
local dropdown = require("src.ui.dropdown")
local fonts = require("src.ui.fonts")
local config = require("src.core.config")
local randommap = require("src.game.randommap")

---@alias RandomMapValues table<string, integer>  size, terrain, temples, critters, resources (list indices)

---@class RandomPanelOwner    what the panel asks the screen that owns it
---@field canEdit fun(self: RandomPanelOwner|Screen): boolean
---@field locked fun(self: RandomPanelOwner|Screen): boolean

---@class RandomPanel
---@field owner RandomPanelOwner|Screen
---@field values RandomMapValues
---@field kept RandomMapValues?  the values before "I am the greatest" forced them
---@field panel Panel
---@field items table<string, PanelItem>  button name -> item
local M = {}
M.__index = M

M.X, M.Y = 30, 22

local BUTTONS = { "BUTT_RM_SIZE", "BUTT_RM_TERRAIN", "BUTT_RM_ISLANDS", "BUTT_RM_CRITTERS", "BUTT_RM_RESOURCES" }
local FIELD = { BUTT_RM_SIZE = "size", BUTT_RM_TERRAIN = "terrain", BUTT_RM_ISLANDS = "temples",
                BUTT_RM_CRITTERS = "critters", BUTT_RM_RESOURCES = "resources" }
local KEYS = { "size", "terrain", "temples", "critters", "resources" }

local function random() return UI.text(83, 0) or "Random" end

-- The drop-down's entries of a setting, the "Random" one last.
---@param field string
---@return string[]
local function entries(field)
    local list = {}
    local function add(id, n) for i = 0, n - 1 do list[#list + 1] = UI.text(id, i) or "?" end end
    if field == "size" then add(180, 4)
    elseif field == "terrain" then add(216, 8) add(250, 2)
    elseif field == "critters" then add(182, 5)
    elseif field == "resources" then add(183, 3)
    else
        list[1] = UI.text(345, 0) or "None"
        list[2] = UI.text(345, 1) or "1"
        for i = 2, 4 do list[#list + 1] = (UI.text(345, 2) or "%d"):format(i) end
    end
    list[#list + 1] = random()
    return list
end
M.entries = entries

-- What the button shows for a value (FUN_004e3130); the "no utilities" button says the short text 345.3.
---@param field string
---@param value integer
---@return string
function M.label(field, value)
    if value == randommap.RANDOM[field] then return random() end
    if field == "temples" then
        if value == 0 then return UI.text(345, 3) or "None" end
        if value == 1 then return UI.text(345, 1) or "1" end
        return (UI.text(345, 2) or "%d"):format(value)
    end
    return entries(field)[value + 1] or "?"
end

-- The stored settings (the defaults of FUN_00450970 without any).
---@return RandomMapValues
function M.load()
    local v = randommap.defaults()
    for _, k in ipairs(KEYS) do
        local n = tonumber(config.get("randommap", k, v[k]))
        if n and n >= 0 and n <= randommap.RANDOM[k] then v[k] = math.floor(n) end
    end
    return v
end

---@param values RandomMapValues
function M.store(values)
    for _, k in ipairs(KEYS) do config.set("randommap", k, values[k]) end
end

-- owner: the screen (asks canEdit() and locked()).
---@param owner RandomPanelOwner|Screen
---@return RandomPanel
function M.new(owner)
    local self = setmetatable({ owner = owner, values = M.load() }, M) --[[@as RandomPanel]]
    -- PNL_SS_RANDOMMAP is part of every War4Int.xci
    self.panel = UI.panel("PNL_SS_RANDOMMAP",
        { x = M.X, y = M.Y, onButton = function(name, it) self:button(name, it) end }) --[[@as Panel]]
    self.items = {}
    for _, n in ipairs(BUTTONS) do
        local it = self.panel:find(n) --[[@as PanelItem]]
        self.items[n] = it
        self.panel.align[it] = "left"
    end
    return self
end

---@return boolean
function M:editable()
    return self.owner:canEdit() and not self.owner:locked()
end

---@param name string
---@param it PanelItem
function M:button(name, it)
    if not self:editable() then return end
    local field = FIELD[name]
    if not field then return end
    local p = self.panel
    dropdown.open(entries(field), p.x + it.e.x, p.y + it.e.y + it.ob.h, function(index) self.values[field] = index - 1 end)
end

-- "I am the greatest" forces the settings and locks the buttons; leaving it restores them from a saved copy
-- (not traced in the 1.04 binary yet).
---@param on boolean
function M:force(on)
    if on then
        self.kept = self.kept or {}
        for k, v in pairs(self.values) do self.kept[k] = v end
        for k, v in pairs(randommap.GREATEST) do self.values[k] = v end
    elseif self.kept then
        for k, v in pairs(self.kept) do self.values[k] = v end
        self.kept = nil
    end
end

function M:sync()
    local p = self.panel
    local edit = self:editable()
    for _, n in ipairs(BUTTONS) do
        local it = self.items[n]
        local s = M.label(FIELD[n], self.values[FIELD[n]])
        -- a longer text than the 128 px button (German) is cut instead of running over the list (own choice)
        local font = it.ob.fonts and it.ob.fonts[1]
        while font and #s > 1 and fonts.width(font, s) > it.ob.w - 10 do s = s:gsub("[%z\1-\127\194-\244][\128-\191]*$", "") end
        p.itemStrings[it] = s
        p:setItemDisabled(it, not edit)
    end
end

-- PNL_RM_GENWORLD, the "Generating random map" screen: the generator entry FUN_00582180 opens it (not for the editor)
-- before the map is made and the random map battle setup FUN_00417280 closes it before the army setup / the battle; its
-- two texts are 289.0 (large) and 289.1 (medium), centred, over the full-screen picture with the generating animation
-- (checked: `--panel PNL_RM_GENWORLD`).
-- The original only redraws it from the generator's housekeeping ticks; here the map takes well under a second, so the one
-- frame is drawn and presented before the generator starts (the animation stays on its first picture). Does nothing without
-- a window (headless runs).
function M.showGenerating()
    if not (love and love.graphics and love.graphics.present and love.graphics.isActive and love.graphics.isActive()) then return end
    pcall(function()
        local p = UI.panel("PNL_RM_GENWORLD", { x = 0, y = 0 })
        -- a missing panel errors inside the pcall
        ---@cast p -nil
        for i, name in ipairs({ "STR_LARGE750", "STR_MEDIUMDLG_300" }) do
            local it = p:find(name)
            if it then
                p.itemStrings[it] = UI.text(289, i - 1) or ""
                p.align[it] = "center"
            end
        end
        love.graphics.origin()
        love.graphics.clear(0, 0, 0)
        UI.begin()
        p:draw()
        UI.finish()
        require("src.ui.gamma").apply()
        love.graphics.present()
    end)
end

-- Makes the map for the start of a game: `scn` is the stub (randommap.stub) with the sides set up, `o` the setup's options.
-- Returns the description every peer rebuilds the same map from (randommap.build), see randommap.lua.
---@param scn table
---@param o table
---@return table
function M:build(scn, o)
    local d = { seed = M.newSeed(), quests = o.quests, victory = require("src.game.victory").NAMES[o.victory], sides = {} }
    for k, v in pairs(self.values) do d[k] = v end
    for i = 0, 5 do
        local sd = scn.sides[i]
        d.sides[i] = { used = sd.used, race = sd.race }
    end
    M.showGenerating()
    randommap.generate(scn, d)
    return d
end

-- The seed of a new game (the original uses the current time; only the host's choice is sent to the other players).
---@return integer
function M.newSeed()
    return (os.time() + math.floor(os.clock() * 1000)) % 65536
end

function M:draw()
    self:sync()
    self.panel:draw()
end

function M:mousemoved(vx, vy) self.panel:mousemoved(vx, vy) end
function M:mousepressed(vx, vy, button) return self.panel:mousepressed(vx, vy, button) end
function M:mousereleased(vx, vy, button) return self.panel:mousereleased(vx, vy, button) end

return M
