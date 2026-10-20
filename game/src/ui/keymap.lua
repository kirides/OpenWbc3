-- Battle keyboard shortcuts of the original (<language>/KeyMap.txt). The 1.04 binary reads the file in FUN_00426060 into
-- two tables: the first 61 lines are the shortcuts (table 0x0074c434, M.NAMES in that order), the next 48 the special
-- ability keys (table 0x0074c52c, one per case of the ability handler FUN_00426350; game/abilitykeys.lua). A line is a
-- single character (an upper-case letter means Shift + letter), "CTRL x", "ALT x", "F11", "F12", "SPACE" or "PAGEUP".
-- Anything after "//" is a comment. Missing lines keep the defaults FUN_00425bf0 sets before the file is read.
--
--   keymap.is("attack", key)     whether the pressed LÖVE key (with the current modifiers) is the shortcut
--   keymap.abilities(key)        the ability key cases (0-based) the pressed key is, in table order
local fs = require("src.core.fs")
local config = require("src.core.config")

local M = {}

M.NAMES = { "repairFast", "repairSlow",
            "sphere0", "sphere1", "sphere2", "sphere3", "sphere4", "sphere5", "sphere6", "sphere7", "sphere8", "sphere9",
            "sphere10", "sphere11", "sphere12",
            "build", "unload", "walls", "produce", "repair", "attack", "formations", "healingPotion", "addRemoveHero",
            "selectHero", "spellbook", "inventory", "quests", "centreGroup", "save", "load", "quit", "resign",
            "currentRadius", "allRadius", "speedUp", "speedDown", "gameMenu", "patrol", "convert", "move", "rally",
            "helpPopups", "pause", "attack2", "guard", "destroy", "options", "lockView", "selectAll", "selectAllType",
            "selectScreen", "selectScreenType", "defaultAttitude", "diplomacy", "speedUp2", "victory", "idleBuilder",
            "previousSite", "networkStats", "manaPotion" }

-- The original's English defaults, used when the file is missing.
local DEFAULTS = { "f", "s", "h", "s", "d", "i", "n", "p", "a", "r", "e", "x", "z", "v", "c", "b", "o", "w", "k", "e", "a",
                   "f", "h", "H", "CTRL h", "s", "i", "q", "`", "ALT s", "ALT l", "ALT q", "ALT r", "c", "r", "=", "-",
                   "ALT g", "p", "CTRL c", "v", "x", "ALT h", "F12", "A", "g", "CTRL d", "ALT o", "CTRL v", "CTRL a",
                   "CTRL z", "CTRL s", "CTRL t", "CTRL f", "ALT d", "+", "ALT v", ".", "PAGEUP", "CTRL n", "m" }

-- The 48 ability keys' defaults (FUN_00425bf0; the shipped English file differs only in Goblin Horde, "H").
M.ABILITY_COUNT = 48
local ABILITY_DEFAULTS = { "H", "L", "F", "I", "M", "P", "Z", "N", "W", "Y", "X", "U", "E", "V", "B", "K", "S", "T", "J",
                           "O", "Q", "I", "D", "B", "E", "Z", "Z", "D", "S", "B", "S", "P", "E", "P", "C", "F", "W", "P",
                           "S", "C", "S", "E", "N", "G", "F", "B", "W", "C" }

---@class KeySpec
---@field key string           LÖVE key name
---@field ctrl boolean
---@field alt boolean
---@field shift boolean

---@type table<string, KeySpec>?
local specs
---@type KeySpec[]? the ability keys, index = case + 1
local abilitySpecs

---@param line string
---@return KeySpec?
local function parse(line)
    line = line:gsub("//.*$", ""):gsub("^%s+", ""):gsub("%s+$", "")
    if line == "" then return nil end
    local mod, rest = line:match("^(%u+)%s+(.+)$")
    local spec = { ctrl = false, alt = false, shift = false }
    if mod == "CTRL" then spec.ctrl = true line = rest elseif mod == "ALT" then spec.alt = true line = rest end
    local up = line:upper()
    if up == "F12" or up == "F11" then spec.key = up:lower()
    elseif up == "SPACE" then spec.key = "space"
    elseif up == "PAGEUP" then spec.key = "pageup"
    elseif #line == 1 then
        spec.key = line:lower()
        if line:match("%u") and not spec.ctrl and not spec.alt then spec.shift = true end
    else return nil end
    return spec
end

local function load()
    specs, abilitySpecs = {}, {}
    local data = fs.read(config.gamedir .. "/" .. config.language .. "/KeyMap.txt")
        or fs.read(config.gamedir .. "/English/KeyMap.txt")
    local lines = {}
    if data then
        for l in (data .. "\n"):gmatch("(.-)\r?\n") do
            local s = parse(l)
            if s then lines[#lines + 1] = s end
        end
    end
    for i, name in ipairs(M.NAMES) do specs[name] = lines[i] or parse(DEFAULTS[i]) end
    for i = 1, M.ABILITY_COUNT do abilitySpecs[i] = lines[#M.NAMES + i] or parse(ABILITY_DEFAULTS[i]) end
end

local KEY_ALIASES = { ["kp+"] = "+", ["kp-"] = "-", ["kp."] = "." }

---@param s KeySpec?
---@param key string
---@return boolean
local function matches(s, key)
    if not s then return false end
    key = KEY_ALIASES[key] or key
    local ctrl = love.keyboard.isDown("lctrl", "rctrl")
    local alt = love.keyboard.isDown("lalt", "ralt")
    local shift = love.keyboard.isDown("lshift", "rshift")
    if s.key == "+" or s.key == "=" then
        -- "=" and "+" share a key on most layouts
        if not (key == "=" or key == "+") then return false end
        return ctrl == s.ctrl and alt == s.alt and (s.key == "=" or shift or key == "+")
    end
    if key ~= s.key then return false end
    if ctrl ~= s.ctrl or alt ~= s.alt then return false end
    -- letters: Shift decides between "h" (healing potion) and "H" (add / remove hero); other keys ignore it
    if key:match("^%a$") and s.shift ~= shift then return false end
    return true
end

-- Whether `key` (LÖVE key name) pressed with the current modifier keys is the shortcut `name`.
---@param name string   one of M.NAMES
---@param key string
---@return boolean
function M.is(name, key)
    if not specs then load() end
    ---@cast specs -nil
    return matches(specs[name], key)
end

-- The ability key cases (0-based, the cases of FUN_00426350) whose key is `key` with the current modifiers, in the
-- order of the table: FUN_00427f70 tries them in that order.
---@param key string
---@return integer[]
function M.abilities(key)
    if not abilitySpecs then load() end
    ---@cast abilitySpecs -nil
    local out = {}
    for i = 1, M.ABILITY_COUNT do
        if matches(abilitySpecs[i], key) then out[#out + 1] = i - 1 end
    end
    return out
end

return M
