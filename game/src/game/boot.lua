-- Startup: mounts the game data and opens the first screen.
local config = require("src.core.config")
local screens = require("src.core.screens")
local vfs = require("src.vfs.vfs")
local fs = require("src.core.fs")
local log = require("src.core.log")

local M = {}

---@type {t: number, code: string, done: boolean?}[]? the --at scripts of a --show screen (`done`: run already)
M.scripts = nil

---@param args string[]
---@param name string
---@return string?
local function argValue(args, name)
    for i = 1, #args do
        if args[i] == name then return args[i + 1] end
    end
    return nil
end

-- Loads a scenario by name ("Bridges") or relative path ("CampaignScenario/C_Brax.SCN").
---@param name string
---@return table? scn the scenario (formats/scn.lua)
---@return string? path where it came from
function M.loadScenario(name)
    -- "random:<seed>[:terrain=3,size=1,sides=4 ...]": a generated map (dev aid for --scenario, --sim, screenshots)
    if name:match("^random:") then return require("src.game.randommap").fromName(name), "random/" end
    local scn = require("src.formats.scn")
    local candidates = { name, "Scenario/" .. name, "Scenario/" .. name .. ".SCN", "CampaignScenario/" .. name,
                         "CampaignScenario/" .. name .. ".SCN", "Tutorial/" .. name .. ".SCN" }
    -- scenarios saved by the editor (user directory)
    local plain = name:gsub("^scenarios/", "")
    for _, n in ipairs({ plain, plain .. ".SCN" }) do
        local data = love.filesystem.getInfo("scenarios/" .. n) and love.filesystem.read("scenarios/" .. n)
        if data then
            local s, err = scn.parse(data)
            if not s then log.error("%s: %s", n, err) end
            return s, "scenarios/" .. n
        end
    end
    for _, rel in ipairs(candidates) do
        local data = fs.read(config.gamedir .. "/" .. rel)
        if data then
            local s, err = scn.parse(data)
            if not s then log.error("%s: %s", rel, err) end
            return s, rel
        end
    end
    return nil
end

---@param args string[] the command line
function M.start(args)
    vfs.init(config.gamedir, config.language)
    require("src.content.mods").configure(args)
    require("src.content.loader").setup()          -- the content registry (docs/data-driven)
    love.window.setTitle("openwbc3")
    require("src.ui.interface").init(config.gamedir, config.language)
    require("src.audio.music").init()
    require("src.audio.sound").init()
    local panel = argValue(args, "--panel")
    if panel then
        local dump = false
        for _, a in ipairs(args) do if a == "--dump" then dump = true end end
        screens.switch(require("src.screens.panelview"), panel, argValue(args, "--screen"), dump, argValue(args, "--shot"))
        return
    end
    -- developer aid: --show <screen module name> opens a screen directly
    local show = argValue(args, "--show")
    if show then
        screens.switch(require("src.screens.mainmenu"))
        -- developer hook: --at <seconds> "<lua code>" runs on the shown screen (S) once it is open
        M.scripts = {}
        for i, a in ipairs(args) do
            if a == "--at" and args[i + 2] then M.scripts[#M.scripts + 1] = { t = tonumber(args[i + 1]) or 0, code = args[i + 2] } end
        end
        local name, sub = show:match("^([%w_]+):?([%w_]*)$")
        screens.push(require("src.screens." .. name))
        local top = screens.top()
        ---@cast top -nil
        if sub ~= "" and top.dev then top:dev(sub) end
        return
    end
    -- developer aid: --random-map <seed> [--rm terrain=3,size=1,temples=2,critters=2,resources=1,sides=4] builds a random
    -- map (see src/game/randommap.lua; the values are the setup dropdowns' indices) and starts a battle on it
    local rmSeed = tonumber(argValue(args, "--random-map") or "")
    if rmSeed then
        local s, d = require("src.game.randommap").fromName("random:" .. rmSeed .. ":" .. (argValue(args, "--rm") or ""))
        screens.switch(require("src.screens.mainmenu"))
        local opts = { demo = false, scripts = {}, scnPath = "random", noInfo = true, random = d }
        for i, a in ipairs(args) do
            if a == "--demo" then opts.demo = true end
            if a == "--at" and args[i + 2] then
                opts.scripts[#opts.scripts + 1] = { t = tonumber(args[i + 1]) or 0, code = args[i + 2] }
            end
        end
        screens.push(require("src.screens.battle"), s, opts)
        return
    end
    local loadSlot = tonumber(argValue(args, "--load"))
    if loadSlot then
        screens.switch(require("src.screens.mainmenu"))
        if require("src.game.savegame").start(loadSlot) then return end
        log.error("save slot %d cannot be loaded", loadSlot)
    end
    local scenario = argValue(args, "--scenario")
    if scenario then
        local s, rel = M.loadScenario(scenario)
        if s then
            ---@cast rel -nil
            screens.switch(require("src.screens.mainmenu"))
            -- the scenario information popup would cover every screenshot: --info brings it back
            local opts = { demo = false, scripts = {}, scnPath = rel, noInfo = true }
            if rel:lower():match("^tutorial/") then opts = require("src.game.tutorial").prepare(s, rel) end
            for i, a in ipairs(args) do
                if a == "--demo" then opts.demo = true end
                if a == "--info" then opts.noInfo = false end
                -- developer hook: --at <seconds> "<lua code>" (S = battle screen, W = world)
                if a == "--at" and args[i + 2] then
                    opts.scripts[#opts.scripts + 1] = { t = tonumber(args[i + 1]) or 0, code = args[i + 2] }
                end
            end
            screens.push(require("src.screens.battle"), s, opts)
            return
        end
        log.error("scenario %s not found", scenario)
    end
    local menu = require("src.screens.mainmenu")
    menu.showTip = true      -- the tip of the day opens with the first main menu
    for _, a in ipairs(args) do
        if a == "--skip-intro" then
            screens.switch(menu)
            return
        end
    end
    screens.switch(require("src.screens.video"), { "Logo", "Intro" }, menu)
end

return M
