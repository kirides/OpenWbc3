-- Story cut scene: narration (WAV) with the timed text lines of <Lang>/Campaign/<name>.xml.
-- enter(name, onDone); any key or click skips.
local screens = require("src.core.screens")
local UI = require("src.ui.interface")
local kit = require("src.ui.kit")
local fonts = require("src.ui.fonts")
local widgets = require("src.ui.widgets")
local campaign = require("src.game.campaign")
local fs = require("src.core.fs")
local music = require("src.audio.music")

---@class CutsceneScreen: Screen
---@field onDone fun()?
---@field scene table?               campaign.cutscene: { voice, delay, lines = { { text, ms } } }
---@field t number                   milliseconds since the start
---@field index integer              the line shown
---@field lineT number?              milliseconds into that line
---@field lineMs number?             its length
---@field total number               milliseconds of all lines
---@field voice love.Source?         the narration
---@field voiceAt number?            seconds
---@field voiceStarted boolean?
---@field finished boolean?
local S = {}

---@param name string
---@param onDone fun()?
function S:enter(name, onDone)
    self.onDone = onDone
    self.scene = campaign.cutscene(name)
    self.t = 0
    self.index = 1
    self.voice = nil
    if not self.scene or #self.scene.lines == 0 then
        self:finish()
        return
    end
    if self.scene.voice and love.audio then
        local data = fs.read(self.scene.voice)
        if data then
            local ok, sd = pcall(function()
                -- love.sound.newSoundData takes a FileData too; the bundled love2d library does not list it
                ---@diagnostic disable-next-line: param-type-mismatch
                return love.sound.newSoundData(love.filesystem.newFileData(data, "voice.wav"))
            end)
            if ok then
                self.voice = love.audio.newSource(sd, "static")
                self.voice:setVolume(math.min(1, require("src.audio.sound").voiceVolume + 0.1))
                self.voiceAt = self.scene.delay / 1000
            end
        end
    end
    local total = 0
    for _, l in ipairs(self.scene.lines) do total = total + l.ms end
    self.total = total
end

function S:finish()
    if self.voice then self.voice:stop() end
    if self.finished then return end
    self.finished = true
    screens.pop()
    if self.onDone then self.onDone() end
end

function S:update(dt)
    music.update()
    if self.finished or not self.scene then return end
    self.t = self.t + dt * 1000
    if self.voice and not self.voiceStarted and self.t >= self.scene.delay then
        self.voiceStarted = true
        self.voice:play()
    end
    -- find the current line
    local acc = 0
    self.index = #self.scene.lines + 1
    for i, l in ipairs(self.scene.lines) do
        acc = acc + l.ms
        if self.t < acc then self.index = i self.lineT = self.t - (acc - l.ms) self.lineMs = l.ms break end
    end
    if self.index > #self.scene.lines then self:finish() end
end

function S:draw()
    UI.begin()
    kit.backdrop(0.82)
    local l = self.scene and self.scene.lines[self.index]
    if l then
        local a = math.min(1, self.lineT / 400, (self.lineMs - self.lineT) / 400 + 0.2)
        local lines = widgets.wrap(5, l.text, 600)
        local y = 280 - #lines * 14
        for i, s in ipairs(lines) do fonts.print(5, s, 100, y + (i - 1) * 28, "center", 600, math.max(0, math.min(1, a))) end
    end
    fonts.print(2, require("src.game.l10n").own("Press any key to skip"), 0, 570, "center", 800, 0.5)
    UI.finish()
end

function S:keypressed() self:finish() end
function S:mousepressed() self:finish() end

return S
