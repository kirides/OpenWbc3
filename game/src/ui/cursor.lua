-- Animated mouse cursors from War4Gfx.xcg (frames on Cursors.bmp), drawn by
-- the game instead of the system cursor while enabled.
local UI = require("src.ui.interface")

---@class CursorModule
---@field current string       cursor name (CU_ prefix optional)
---@field enabled boolean      drawn by the game instead of the system cursor
---@field frame integer
---@field nextTime number      ms of the next frame change (0: not started)
---@field quads table<integer, love.Quad>?
local M = { current = "ARROW", enabled = false, frame = 1, nextTime = 0 }

---@type table<string, XcgCursor>?
local byName

---@param name string
---@return XcgCursor?
local function find(name)
    if not byName then
        byName = {}
        if not UI.ui then return nil end
        for _, c in pairs(UI.ui.gfx.cursors) do
            -- record names look like "CU_ARROW"; index by the part after the prefix too
            byName[c.name] = c
            local short = c.name:match("_(.+)$")
            if short then byName[short] = byName[short] or c end
        end
    end
    return byName[name]
end

---@param on boolean
function M.enable(on)
    M.enabled = on
    love.mouse.setVisible(not on)
end

---@param name string
function M.set(name)
    if name ~= M.current then
        M.current = name
        M.frame = 1
        M.nextTime = 0
    end
end

-- The pointer cursors the original draws instead of the system cursor on every screen but the battle
-- view (the standard cursor routine FUN_00456a30; its enable flag DAT_0060c3ec is cleared for the battle by
-- the game setup screen's handler, call at 0x004e6ad0): POINTER over an active UI object, POINTERDOWN while a press
-- that began on one is held (the button-down flag DAT_00a27dad) and POINTERUP elsewhere. The original decides at the
-- mouse-down / mouse-up events, so the screens module reports them through press / release (before the
-- screen handles the click and maybe removes the button) and a click shorter than a frame still shows
-- POINTERDOWN for one drawn frame.
local held, beganOver, released = false, false, false

---@param over boolean?
function M.press(over)
    if over then held, beganOver, released = true, true, false end
end

function M.release()
    released = true
end

---@param over boolean?
function M.standard(over)
    M.enable(true)
    if held then
        M.set("POINTERDOWN")
        if released or not (love.mouse.isDown(1) or love.mouse.isDown(2)) then held, released = false, false end
        return
    end
    M.set(over and "POINTER" or "POINTERUP")
end

---@param scale? number  interface scale (the cursor is drawn at whole multiples)
function M.draw(scale)
    if not M.enabled then return end
    local c = find(M.current) or find("ARROW")
    if not c or not c.frameList[1] then
        love.mouse.setVisible(true)
        return
    end
    local img = UI.bitmap(c.bitmap)
    if not img then
        love.mouse.setVisible(true)
        return
    end
    local now = love.timer.getTime() * 1000
    local f = c.frameList[M.frame] or c.frameList[1]
    if f.ms > 0 and #c.frameList > 1 then
        if M.nextTime == 0 then M.nextTime = now + f.ms end
        if now >= M.nextTime then
            M.frame = M.frame % #c.frameList + 1
            f = c.frameList[M.frame]
            M.nextTime = now + math.max(1, f.ms)
        end
    end
    M.quads = M.quads or {}
    local key = c.id * 100 + M.frame
    local q = M.quads[key]
    if not q then
        q = love.graphics.newQuad(f.x, f.y, c.w, c.h, img:getDimensions())
        M.quads[key] = q
    end
    local s = math.max(1, math.floor((scale or 1) + 0.25))
    local mx, my = love.mouse.getPosition()
    love.graphics.setColor(1, 1, 1)
    love.graphics.draw(img, q, mx - c.hotX * s, my - c.hotY * s, 0, s, s)
end

return M
