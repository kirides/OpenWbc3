-- The tutorial: the main menu's Tutorial button loads Tutorial/Tutorial.SCN directly (the original's
-- tutorial start FUN_004494e0; its scenario selection screen is never reached and its background bitmap is not shipped).
-- The player is a level 1 Dwarf warrior called Sirian whatever hero was chosen, every other side is passive, there
-- is no scenario information popup, and the scenario's events (texts from Tutorial.cfg, command button events)
-- teach the controls; see World:spawnStartingForces, Events:button and the tutorial dialog in ui/hud.lua.
local screens = require("src.core.screens")
local boot = require("src.game.boot")

local M = {}

-- Battle options for a tutorial scenario; marks the sides other than the player's passive.
---@param scn table the scenario (formats/scn.lua)
---@param path string?
---@return table opts the battle options
function M.prepare(scn, path)
    for i = 1, 5 do
        local sd = scn.sides[i]
        if sd then
            sd.passive = true
            sd.aiLevel = 0
        end
    end
    return { tutorial = true, scnPath = path, noInfo = true, quests = false, profile = false, startPoints = 0,
             scripts = {}, title = scn.header and scn.header.name }
end

---@return boolean
function M.start()
    local scn, rel = boot.loadScenario("Tutorial")
    if not scn then return false end
    screens.push(require("src.screens.battle"), scn, M.prepare(scn, rel))
    return true
end

return M
