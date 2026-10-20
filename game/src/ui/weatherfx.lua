-- The weather as the player sees and hears it (FUN_0049b6d0 / FUN_0049b1d0 / FUN_0049b070): the night tint with its
-- four-step transition, the rain with the drop count the simulation keeps (world.rainDrops: one drop more or less per
-- overlay frame, 18 a second, because the raining flag depends on it, see weather.lua), the lightning flashes with
-- their thunder and the rain loop. Presentation only: nothing here touches the simulation, and the "random" numbers
-- come from a hash of the frame count (no math.random: network games seed that per tick).
-- Numbers from the 1.04 binary: lightning FUN_0049b1d0 (a step every 3rd frame; the next flash after
-- 1d(150 - drops/4) + 12 steps, a flash lasts 10 steps with a 1 in 800 chance per drop of being bright), rain
-- FUN_0049b6d0 (a new rain starts with 30 drops, +1 per frame up to the target), the rain volume drops / 16 of 127.
-- The drop shape (a streak of 1..40 px, slanted 1:2, 11..20 px per frame, three brightnesses 45 / 35 / 20 %): drop
-- setup FUN_0049b920 and drawing FUN_0049a790; streaks are redrawn every 4th frame at a hashed place.
local bit = require("bit")
local config = require("src.core.config")
local sound = require("src.audio.sound")
local weather = require("src.game.weather")

---@class WeatherFx
---@field drops number         rain drops shown (world.rainDrops while it rains)
---@field acc number           frames (18 a second) not yet stepped
---@field frame integer
---@field step integer
---@field flashing boolean     a lightning flash runs
---@field lit boolean          the bright palette is on
---@field t2 integer           lightning steps counted
---@field interval integer?    steps to the next flash
---@field rolls integer?       dice rolled (seeds the hash)
---@field rainSrc love.Source? the rain loop
---@field thunder love.Source? the last thunder
local M = {}
M.__index = M

local FPS = 18

---@return WeatherFx
function M.new()
    return setmetatable({ drops = 0, acc = 0, frame = 0, step = 0, flashing = false, lit = false, t2 = 0, interval = nil,
                          rainSrc = nil, thunder = nil }, M) --[[@as WeatherFx]]
end

local function hash(a, b)
    local h = (a * 40503 + b * 9973 + 12345) % 4294967296
    h = bit.bxor(h, bit.rshift(h, 15))
    h = (h * 2246 + 7) % 4294967296
    h = bit.bxor(h, bit.rshift(h, 13))
    return h % 1000003
end

-- a dice of the visual side like the game's FUN_00458e70 (1, sides, add): 1..sides plus add
---@param sides integer
---@param add? integer
---@return integer
function M:dice(sides, add)
    self.rolls = (self.rolls or 0) + 1
    return hash(self.rolls, 77) % sides + 1 + (add or 0)
end

local function soundFile(rel)
    local dir = config.gamedir
    return dir and (dir .. "/SoundFX/Weather/" .. rel) or nil
end

-- The rain class of the current drops (FUN_0049bee0): 0 low, 1 medium, 2 high
local function rainType(drops)
    if drops < 80 then return 0 elseif drops < 150 then return 1 end
    return 2
end

function M:playThunder()
    local kind = rainType(self.drops)
    local letter = "L"
    if kind == 1 then
        letter = self:dice(3) == 1 and "L" or "M"
    elseif kind == 2 then
        local n = self:dice(6)
        letter = n == 1 and "L" or (n <= 3 and "M" or "H")
    end
    local path = soundFile(("Lightning%s%d.wav"):format(letter, self:dice(2)))
    if self.thunder then self.thunder:stop() end
    self.thunder = path and sound.playFile(path) or nil
end

-- One lightning step (FUN_0049b1d0, every 3rd frame, 6 a second).
---@param world World
function M:lightningStep(world)
    if not (world.raining and world.lightning) then self.flashing, self.lit = false, false return end
    self.interval = self.interval or self:dice(150 - math.floor(self.drops / 4), 12)
    if self.flashing then
        self.t2 = self.t2 + 1
        if self.t2 == 10 then
            self.t2, self.flashing, self.lit = 0, false, false
            self.interval = self:dice(150 - math.floor(self.drops / 4), 12)
        else
            self.lit = self:dice(800) < self.drops
        end
    else
        self.t2 = self.t2 + 1
        if self.t2 == self.interval then
            self.flashing, self.t2 = true, 0
            self:playThunder()
        end
    end
end

---@param world World
---@param dt number  seconds
function M:update(world, dt)
    self.acc = self.acc + dt * FPS
    local frames = math.floor(self.acc)
    self.acc = self.acc - frames
    for _ = 1, math.min(frames, 8) do
        self.frame = self.frame + 1
        self.drops = world.raining and (world.rainDrops or 0) or 0      -- the simulation steps the drops (weather.lua)
        if self.frame % 3 == 0 then self:lightningStep(world) end
    end
    -- the rain loop, volume drops / 16 of 127 (FUN_0049c0f0)
    if self.drops > 0 then
        if not self.rainSrc then
            local path = config.gamedir and (config.gamedir .. "/SoundFX/WEATHER/Rain.wav")
            self.rainSrc = path and sound.playFile(path) or nil
            if self.rainSrc then self.rainSrc:setLooping(true) end
        end
        if self.rainSrc then
            self.rainSrc:setVolume(math.min(127, math.floor(self.drops / 16)) / 127 * sound.volume)
        end
    elseif self.rainSrc then
        self.rainSrc:stop()
        self.rainSrc = nil
    end
end

function M:stop()
    if self.rainSrc then self.rainSrc:stop() self.rainSrc = nil end
    if self.thunder then self.thunder:stop() self.thunder = nil end
end

-- Draws the tint, the lightning and the rain over the map view of W x H pixels; `scale` is the interface scale.
---@param world World
---@param W number
---@param H number
---@param scale number
function M:draw(world, W, H, scale)
    local g = love.graphics
    local night = weather.nightLevel(world)
    if night > 0 then
        g.setColor(0.02, 0.04, 0.2, 0.38 * night)
        g.rectangle("fill", 0, 0, W, H)
    end
    if self.lit then
        g.setColor(1, 1, 1, 0.5)                              -- palette type 2: the bright lightning palette
        g.rectangle("fill", 0, 0, W, H)
    end
    local n = math.floor(self.drops)
    if n > 0 then
        local f = self.frame
        g.setLineWidth(math.max(1, scale))
        local ALPHA = { 0.5, 0.25, 0.125 }                    -- shift 1 / 2 / 3: how far a pixel moves towards white
        for i = 0, n - 1 do
            local off = hash(i, 5) % 4
            local cyc = math.floor((f + off) / 4)
            local k = (f + off) % 4
            local h = hash(i, cyc)
            local seg = (h % 40 + 1) * scale * 0.6
            local sx = hash(h, 1) % (W + 20) - 10
            local sy = hash(h, 2) % (H + 20) - 10
            local pos = (k * 15 + 4) * scale
            local r = h % 20 + 1
            g.setColor(1, 1, 1, ALPHA[r < 10 and 3 or (r < 17 and 2 or 1)])
            local x, y = sx + pos / 2, sy + pos
            g.line(x, y, x + seg / 2, y + seg)
        end
        g.setLineWidth(1)
    end
    g.setColor(1, 1, 1)
end

return M
