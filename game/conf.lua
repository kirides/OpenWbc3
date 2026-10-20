-- openwbc3 - LÖVE configuration

-- The love2d library only types love.conf as `fun(t: table)`, so the fields set here are declared locally.
---@class LoveWindowConfig
---@field title string
---@field width integer
---@field height integer
---@field resizable boolean
---@field minwidth integer
---@field minheight integer
---@field vsync integer

---@class LoveModulesConfig
---@field joystick boolean
---@field physics boolean
---@field touch boolean
---@field window boolean
---@field graphics boolean
---@field audio boolean

---@class LoveConfig
---@field identity string
---@field version string
---@field console boolean
---@field highdpi boolean
---@field window LoveWindowConfig|false   false: no window (headless runs)
---@field modules LoveModulesConfig

---@param t LoveConfig
function love.conf(t)
    t.identity = "openwbc3"
    t.version = "12.0"
    t.console = false
    t.highdpi = false

    t.window.title = "openwbc3"
    t.window.width = 1280
    t.window.height = 800
    t.window.resizable = true
    t.window.minwidth = 800
    t.window.minheight = 600
    t.window.vsync = 1

    t.modules.joystick = false
    t.modules.physics = false
    t.modules.touch = false

    -- The asset converter runs headless.
    for _, a in ipairs(arg or {}) do
        if a == "--convert" or a == "--selftest" then
            t.window = false
            t.modules.window = false
            t.modules.graphics = false
            t.modules.audio = false
            t.console = true
        end
    end
end
