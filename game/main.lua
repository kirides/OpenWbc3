-- openwbc3 - an open re-implementation of the Warlords Battlecry III engine.
-- Copyright (c) 2026 openwbc3 contributors. MIT License, see LICENSE.

local log = require("src.core.log")
local config = require("src.core.config")
local screens = require("src.core.screens")

---@param args string[]
---@param name string
---@return boolean
local function hasArg(args, name)
    for _, a in ipairs(args) do if a == name then return true end end
    return false
end

-- Developer aid: `--shot <file.png> --after <seconds>` saves a screenshot and quits.
---@type { path: string, after: number, t: number, taken: boolean? }?
local shot
---@param args string[]
local function setupShot(args)
    for i = 1, #args do
        if args[i] == "--shot" then shot = { path = args[i + 1], after = 3 } end
    end
    if shot then
        for i = 1, #args do
            if args[i] == "--after" then shot.after = tonumber(args[i + 1]) or 3 end
        end
        shot.t = 0
    end
end

-- Keep the mouse inside the window while it has focus (edge scrolling); the grab
-- is released on focus loss so Alt-Tab always works. `[game] grab=0` disables it.
---@param focused boolean
local function updateGrab(focused)
    if love.mouse and love.mouse.setGrabbed then
        love.mouse.setGrabbed(focused and config.get("game", "grab", true))
    end
end

function love.load(args)
    if hasArg(args, "--convert") then
        local code = require("src.tools.convert").run(args)
        love.event.quit(code)
        return
    end
    if hasArg(args, "--nettest") then
        love.event.quit(require("src.tools.nettest").run())
        return
    end
    if require("src.tools.contentcli").wanted(args) and not hasArg(args, "--selftest") then
        love.event.quit(require("src.tools.contentcli").run(args))
        return
    end
    if hasArg(args, "--selftest") then
        local code = require("src.tools.selftest").run(args)
        love.event.quit(code)
        return
    end

    log.verbose = hasArg(args, "--verbose")
    setupShot(args)
    love.graphics.setDefaultFilter("nearest", "nearest")
    love.keyboard.setKeyRepeat(true)
    -- LÖVE 12 starts with text input off (love.keyboard.hasTextInput is false), so love.textinput is
    -- never called and the typed fields (hero name, hero password) stay empty; the original always
    -- had text events, so enable them here.
    love.keyboard.setTextInput(true)

    if not config.load(args) then
        screens.switch(require("src.screens.nodata"))
        return
    end
    if config.get("graphics", "fullscreen", false) then love.window.setFullscreen(true) end
    love.window.setVSync(config.get("graphics", "vsync", true) and 1 or 0)
    local rw, rh = config.get("graphics", "width", 0), config.get("graphics", "height", 0)
    if rw >= 800 and rh >= 600 and not love.window.getFullscreen() then
        love.window.updateMode(rw, rh, { resizable = true, minwidth = 800, minheight = 600 })   -- options: Resolution
    end
    require("src.game.boot").start(args)
    updateGrab(love.window.hasFocus())
end

-- developer hook of --show: `--at <seconds> "<lua>"` runs the code with S = the top screen
---@param dt number
local function runScripts(dt)
    local boot = package.loaded["src.game.boot"]
    local list = boot and boot.scripts
    if not list or #list == 0 then return end
    boot.clock = (boot.clock or 0) + dt
    for _, s in ipairs(list) do
        if not s.done and boot.clock >= s.t then
            s.done = true
            local f, err = loadstring(s.code, "--at")
            if f then
                setfenv(f, setmetatable({ S = screens.top() }, { __index = _G }))
                local ok, e = pcall(f)
                if not ok then print("[error] --at: " .. tostring(e)) end
            else
                print("[error] --at: " .. tostring(err))
            end
        end
    end
end

function love.update(dt)
    runScripts(dt)
    screens.dispatch("update", dt)
    if shot then
        shot.t = shot.t + dt
        if shot.t >= shot.after and not shot.taken then
            shot.taken = true
            print(("[info] fps %d, memory %.1f MB"):format(love.timer.getFPS(), collectgarbage("count") / 1024))
            love.graphics.captureScreenshot(function(img)
                local f = io.open(shot.path, "wb")
                if f then
                    f:write(img:encode("png"):getString())
                    f:close()
                end
                love.event.quit()
            end)
        end
    end
end

function love.draw()
    screens.draw()
    require("src.ui.gamma").apply()
end

function love.focus(focused)
    updateGrab(focused)
    screens.dispatch("focus", focused)
end

function love.keypressed(key, ...)
    -- Alt+Tab / Win key can't be intercepted, but let Ctrl+Alt+G toggle the grab by hand
    if key == "g" and love.keyboard.isDown("lctrl", "rctrl") and love.keyboard.isDown("lalt", "ralt") then
        love.mouse.setGrabbed(not love.mouse.isGrabbed())
        return
    end
    local top = screens.top()
    if key == "f1" and top and type(top.helpId) == "number" and top ~= require("src.screens.screenhelp") then
        require("src.screens.screenhelp").open(top.helpId, true)       -- F1: the screen's help again
        return
    end
    screens.dispatch("keypressed", key, ...)
end

for _, cb in ipairs({ "keyreleased", "textinput", "mousepressed", "mousereleased",
                      "mousemoved", "wheelmoved", "resize" }) do
    love[cb] = function(...) screens.dispatch(cb, ...) end
end
