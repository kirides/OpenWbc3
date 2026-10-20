-- What the "scenario information" dialog says (shown when a battle starts and on Alt+I): the mission text
-- (<Lang>/Campaign.xcr/<scenario>.txt, one line per row), the description of a non-standard victory
-- condition (<Lang>/Victory.cfg) and the special rules (game modifiers, keep level limit) of the scenario.
local vfs = require("src.vfs.vfs")
local text = require("src.core.text")
local strings = require("src.game.strings")

local M = {}

-- What the dialog shows (M.build).
---@class ScenarioInfo
---@field heading string
---@field text string[]?         the mission text, or the victory condition's
---@field rules string[]         the special rules
---@field footer string[]
---@field rulesHeading string
---@field none string            "No Special Rules"
---@field any boolean            there is a text or a rule to show

-- victory rule of a battle -> number of its [VictoryNN_TextMM] block in Victory.cfg / XCI text 172
-- (the dialog shows text for modes 1..8 and 12, as the original's rules dialog FUN_0056cda0 does)
local SHOWN = { [1] = true, [2] = true, [3] = true, [4] = true, [5] = true, [6] = true, [7] = true, [8] = true, [12] = true }

local function xciText(id, sub)
    local ok, UI = pcall(require, "src.ui.interface")
    return ok and UI.ui and UI.text(id, sub) or nil
end

local function missionText(scnPath)
    local base = scnPath and scnPath:match("([^/\\]+)%.[sS][cC][nN]$")
    local data = base and vfs.read("Campaign.xcr", base .. ".txt")
    if not data then return nil end
    local lines = {}
    for line in (data .. "\n"):gmatch("(.-)\r?\n") do
        if #lines < 20 and (line ~= "" or #lines > 0) then lines[#lines + 1] = text.fromCP1252(line) end
    end
    while #lines > 0 and lines[#lines] == "" do lines[#lines] = nil end
    return #lines > 0 and lines or nil
end

local function victoryText(rule)
    local n = require("src.game.victory").number(rule)
    if not SHOWN[n] then return nil end
    local lines = {}
    for i = 0, 9 do
        local s = strings.get("Victory.cfg", ("Victory%02d_Text%02d"):format(n, i))
        if not s then break end
        lines[#lines + 1] = s
    end
    return #lines > 0 and lines or nil, n < 8 and xciText(172, n) or xciText(173, n - 8)
end

local function rulesOf(options)
    local out = {}
    local mods = options.mods or {}
    for i, name in ipairs({ "noDragons", "noFliers", "noLords", "toughTowers", "noTowers", "noWalls", "noHeroes" }) do
        if mods[name] then out[#out + 1] = xciText(238, i) end
    end
    local tech = options.techLevel
    if tech and tech >= 0 and tech <= 4 then
        if tech == 0 then
            out[#out + 1] = xciText(186, 0) or "No Building"
        else
            out[#out + 1] = (strings.get("Game.txt", "0558") or "Maximum Keep Level: %d"):format(tech)
        end
    end
    return out
end

-- Returns { heading, text, rules, footer } (lists of lines) for a battle, or nil when there is nothing to say.
-- `title` replaces the scenario's name (campaign battles are named by the campaign).
---@param scn table the scenario (formats/scn.lua)
---@param opts {title: string?, scnPath: string?, victory: (string|integer)?}?
---@return ScenarioInfo
function M.build(scn, opts)
    opts = opts or {}
    local info = { heading = opts.title or (scn.header and scn.header.name) or "", footer = {
        strings.get("Game.txt", "0556") or "You can display this information any time",
        strings.get("Game.txt", "0557") or "during the game by pressing ALT + i" } }
    info.text = missionText(opts.scnPath)
    if not info.text then
        local lines, name = victoryText(opts.victory)
        if lines then info.text, info.heading = lines, name or info.heading end
    end
    info.rules = rulesOf(scn.header and scn.header.options or {})
    info.heading = info.heading ~= "" and info.heading or (xciText(172, 0) or "")
    info.rulesHeading = strings.get("Game.txt", "0555") or "Special Rules"
    info.none = strings.get("Game.txt", "0559") or "No Special Rules"
    info.any = info.text ~= nil or #info.rules > 0
    return info
end

return M
