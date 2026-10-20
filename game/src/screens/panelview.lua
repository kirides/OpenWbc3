-- Developer aid: shows XCI panels on a plain background to inspect their layout.
-- `love game --panel PNL_A[,PNL_B...] [--screen SCR_X] [--dump] [--shot f.png]`
-- (`@123` in the list draws XCG bitmap 123)
local UI = require("src.ui.interface")

---@class PanelViewScreen: Screen
---@field shot string?               screenshot file, written on the third frame
---@field frames integer
---@field screen string?             the XCI screen drawn behind
---@field panels Panel[]
---@field bitmaps love.Image[]
local S = {}

---@param names string comma separated panel names, `@id` for a bitmap, `?` lists the panels
---@param screen string?
---@param dump boolean? print the panels' items
---@param shot string?
function S:enter(names, screen, dump, shot)
    self.shot, self.frames = shot, 0
    io.stdout:setvbuf("no")
    self.screen = screen
    self.panels = {}
    self.bitmaps = {}
    if names == "?" then
        local list = {}
        for n in pairs(UI.ui.panels) do list[#list + 1] = n end
        table.sort(list)
        print("panels: " .. table.concat(list, " "))    end
    for name in names:gmatch("[^,]+") do
        local id = name:match("^@(%d+)$")
        local p = (not id) and UI.panel(name) or nil
        if id then
            local img = UI.bitmap(tonumber(id) --[[@as integer]])
            self.bitmaps[#self.bitmaps + 1] = img
            if dump and img then print(("bitmap %s %dx%d"):format(id, img:getDimensions())) end
        end
        if p then
            self.panels[#self.panels + 1] = p
            if dump then
                print(("panel %s at %d,%d"):format(name, p.x, p.y))
                for _, it in ipairs(p.items) do
                    local ob = it.ob
                    local r = ob.srcRect
                    print(("  %-28s type %d sub %d  %3d,%3d  %3dx%3d  text %s/%s  src %s%s"):format(it.name, ob.type, ob.subtype or -1,
                        it.e.x, it.e.y, ob.w or 0, ob.h or 0, tostring(ob.text), tostring(ob.textSub), tostring(ob.source),
                        r and (" rect %d,%d,%d,%d"):format(r[1], r[2], r[3], r[4]) or ""))
                end
            end
        end
    end
end

function S:draw()
    UI.begin()
    if self.screen then UI.drawScreen(self.screen) else love.graphics.clear(0.15, 0.15, 0.2) end
    for _, p in ipairs(self.panels) do p:draw() end
    local x = 0
    for _, img in ipairs(self.bitmaps) do
        love.graphics.draw(img, x, 0)
        x = x + img:getWidth() + 4
    end
    UI.finish()
    self.frames = self.frames + 1
    if self.shot and self.frames == 3 then
        love.graphics.captureScreenshot(function(d)
            -- plain io (not love.filesystem) so absolute paths work, as in main.lua
            local f = io.open(self.shot, "wb")
            if f then
                f:write(d:encode("png"):getString())
                f:close()
            end
            love.event.quit()
        end)
    end
end

function S:keypressed(key)
    if key == "escape" then love.event.quit() end
end

return S
