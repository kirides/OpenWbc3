-- Plays converted videos (converted/video/<name>.ogv, see tools/convert.*)
-- one after another; any key or click skips. Missing videos are skipped.
local screens = require("src.core.screens")
local log = require("src.core.log")

---@class VideoScreen: Screen
---@field list string[]              the video names (converted/video/<name>.ogv)
---@field nextScreen Screen?         switched to after the last one (else the screen pops)
---@field index integer
---@field video love.Video?          the one playing
local S = {}

---@param list string[]
---@param nextScreen Screen?
function S:enter(list, nextScreen)
    self.list = list
    self.nextScreen = nextScreen
    self.index = 0
    self:advance()
end

function S:advance()
    if self.video then
        self.video:pause()
        self.video = nil
    end
    while true do
        self.index = self.index + 1
        local name = self.list[self.index]
        if not name then
            if self.nextScreen then screens.switch(self.nextScreen) else screens.pop() end
            return
        end
        local path = "converted/video/" .. name .. ".ogv"
        if love.filesystem.getInfo(path) then
            local ok, v = pcall(love.graphics.newVideo, path, { audio = true })
            if ok and v then
                self.video = v
                v:play()
                return
            end
            log.warn("video %s: %s", name, tostring(v))
        end
    end
end

function S:update()
    if self.video and not self.video:isPlaying() then self:advance() end
end

function S:draw()
    love.graphics.clear(0, 0, 0)
    local v = self.video
    if not v then return end
    local w, h = love.graphics.getDimensions()
    local vw, vh = v:getDimensions()
    local s = math.min(w / vw, h / vh)
    love.graphics.draw(v, math.floor((w - vw * s) / 2), math.floor((h - vh * s) / 2), 0, s, s)
end

function S:keypressed() self:advance() end
function S:mousepressed() self:advance() end

return S
