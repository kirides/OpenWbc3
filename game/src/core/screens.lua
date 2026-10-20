local log = require("src.core.log")

-- Screen (state) stack. A screen is a table with optional callbacks:
-- enter(...), leave(), update(dt), draw(), keypressed(...), mousepressed(...), ...

-- The screen protocol: every callback is optional. Screen modules declare `---@class <Name>Screen: Screen`.
---@class Screen
---@field enter? fun(self: Screen, ...)          pushed (dialogs get the screen below, e.g. the battle, first)
---@field leave? fun(self: Screen)               popped or switched away from
---@field resume? fun(self: Screen)              the screen above it was popped
---@field update? fun(self: Screen, dt: number)
---@field underUpdate? fun(self: Screen, dt: number) runs while overlays are on top (screens.updateUnder)
---@field draw? fun(self: Screen)
---@field focus? fun(self: Screen, focused: boolean)
---@field keypressed? fun(self: Screen, key: string, scancode: string, isrepeat: boolean)
---@field keyreleased? fun(self: Screen, key: string, scancode: string)
---@field textinput? fun(self: Screen, text: string)
---@field mousepressed? fun(self: Screen, x: number, y: number, button: integer, istouch: boolean, presses: integer)
---@field mousereleased? fun(self: Screen, x: number, y: number, button: integer, istouch: boolean, presses: integer)
---@field mousemoved? fun(self: Screen, x: number, y: number, dx: number, dy: number, istouch: boolean)
---@field wheelmoved? fun(self: Screen, x: number, y: number)
---@field resize? fun(self: Screen, w: integer, h: integer)
---@field dev? fun(self: Screen, sub: string)    `--show <screen>:<sub>`: a state worth a screenshot
---@field overlay boolean?                       the screen below stays drawn (dialogs)
---@field helpId integer?                        the original's screen help number (screenhelp.lua)
---@field noFirstHelp boolean?                   no help the first time it opens
---@field ownCursor boolean?                     draws its own cursor (battle view, editor)
---@field noStandardCursor boolean?              no press / release of the standard cursor
---@field cursorOver? fun(self: Screen): boolean whether the mouse is over an active object
---@field cursorName? fun(self: Screen): string? a cursor of its own
---@field hits table?                            kit.lua's hit boxes of a hand-made screen

---@class ScreenStack
---@field stack Screen[]
---@field stack_size integer
local M = { stack = {}, stack_size = 0 }

---@return Screen?
function M.top()
    return M.stack[M.stack_size]
end

---@param i integer? how far below the top (0 = the top)
---@return Screen?
function M.back(i)
    i = i or 0
    return M.stack[M.stack_size - i]
end

-- A screen with a `helpId` (the original's screen help number, see src/screens/screenhelp.lua) shows its help the first time
-- it opens; F1 shows it again (main.lua).
local function firstHelp(screen)
    if type(screen.helpId) == "number" and not screen.noFirstHelp and M.top() == screen then
        require("src.screens.screenhelp").open(screen.helpId)
    end
end

---@param screen Screen
function M.switch(screen, ...)
    local cur = M.top()
    if cur and cur.leave then cur:leave() end
    M.stack_size = 0
    M.push(screen, ...)
end

---@param screen Screen
function M.push(screen, ...)
    M.stack_size = M.stack_size + 1
    M.stack[M.stack_size] = screen
    if screen.enter then screen:enter(...) end
    firstHelp(screen)
end

function M.pop()
    local cur = M.top()
    if cur and cur.leave then cur:leave() end
    M.stack[M.stack_size] = nil
    M.stack_size = M.stack_size - 1
    local top = M.top()
    if top and top.resume then top:resume() end
end

-- Pops every screen but the bottom one (the main menu): where the original goes when a network game is over or the
-- player leaves it (the main menu opener FUN_0041d2c0).
function M.popToBottom()
    while M.stack_size > 1 do M.pop() end
end

local cursor, kit, UI

-- Whether the mouse is over an active object of the top screen: a screen's own `cursorOver()`, else the kit hit
-- boxes of a hand-made screen or the XCI panel drawn last (a screen may have both: panels over kit widgets).
local function cursorOver(top)
    cursor = cursor or require("src.ui.cursor")
    kit = kit or require("src.ui.kit")
    UI = UI or require("src.ui.interface")
    if type(top.cursorOver) == "function" then return top:cursorOver() and true or false end
    return (top.hits and kit.over(top)) or UI.panelOver and true or false
end

-- Forward a LÖVE callback to the top screen.
---@param name string
function M.dispatch(name, ...)
    local cur = M.top()
    if cur and not cur.noStandardCursor then
        if name == "mousepressed" then
            local over = cursorOver(cur)
            cursor.press(over)
        elseif name == "mousereleased" and cursor then
            cursor.release()
        end
    end

    -- log.info("dispatch %s to %s", name, cur.name or cur.helpId or "none")

    -- screens keep state in plain fields too (self.focus ...), so only call functions
    local f = cur and cur[name]
    if name == "update" then M.updateUnder(...) end
    if type(f) == "function" then return f(cur, ...) end
end

-- Screens below an overlay (and the first opaque one) may keep running through `underUpdate(dt)`: the battle keeps its
-- network session alive while a menu is open.
function M.updateUnder(dt)
    for i = M.stack_size - 1, 1, -1 do
        local s = M.stack[i]
        if type(s.underUpdate) == "function" then s:underUpdate(dt) end
        if not s.overlay then break end
    end
end

-- Draw every screen from the bottom up to the first opaque one, then the cursor the original draws
-- itself instead of the system cursor on every screen but the battle view (the menu cursor routine FUN_00456a30; its
-- flag at 0x60c3ec is cleared through FUN_00456a20(0) at 0x4e6ad0 when the setup starts the battle). The pointer hand
-- is over an active UI object: the kit hit boxes of a hand-made screen or the XCI panel drawn last.
-- Screens with their own cursor rules (the battle view, the editor) say so with `ownCursor`; a screen may refine "over an
-- active object" with `cursorOver()`.
function M.draw()
    local first = 1
    for i = #M.stack, 1, -1 do
        if not M.stack[i].overlay then first = i break end
    end
    for i = first, #M.stack do
        local s = M.stack[i]
        if s.draw then s:draw() end
    end
    local top = M.stack[M.stack_size]
    if top and not top.ownCursor then
        local over = cursorOver(top)      -- first: it loads the modules
        local name = type(top.cursorName) == "function" and top:cursorName() or nil     -- a screen with its own cursor rule
        if name then
            cursor.enable(true)
            cursor.set(name)
        else
            cursor.standard(over)
        end
        cursor.draw(UI.transform())
    end
end

M.cursorOver = cursorOver

return M
