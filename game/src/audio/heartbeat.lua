-- The hero heartbeat (the "hero heartbeat" option; the 1.04 binary's FUN_0050e690): when the local hero takes
-- damage and its hit points fall into the lower ten elevenths of its maximum a heartbeat starts, the faster, louder and
-- shorter-spaced the fewer hit points are left; it beats for five seconds and then fades out.
--
-- Verified against the original: ten steps at (max / 11) * (1 .. 10) hit points, the first step whose limit is above the
-- current hit points decides (steps 1..5 use HeartBeatFast.wav, 6..10 HeartBeatSlow.wav), the beat repeats every
-- 300 + 70 * step ms at volume 125 - 10 * step (of 127), starts only when the hit points dropped by more than one
-- since the last look, fades by 5 volume points a beat after five seconds and stops when the volume is gone; the
-- remembered hit points follow the hero up when it heals. openwbc3's own: the beats are played as separate sounds
-- instead of one restarted channel, and the check runs every frame.
--
-- Presentation only. No simulation state.
local sound = require("src.audio.sound")

---@class HeartbeatStep
---@field hits integer    hit points limit of the step
---@field fast boolean    HeartBeatFast.wav (else Slow)
---@field delay number    seconds between beats
---@field volume integer  of 127

---@class HeartbeatState
---@field table table<integer, HeartbeatStep>?   [0..9], built at the first look at the hero
---@field remembered number   hit points at the last look
---@field index integer       current step, -1 = none
---@field playing boolean
---@field fading boolean
---@field volume integer?
---@field orig number?        time the beat started
---@field prev number?        time of the last beat

---@class HeartbeatModule
---@field state HeartbeatState?
local M = { state = nil }

local function reset() M.state = { table = nil, remembered = 0, index = -1, playing = false, fading = false } end

function M.stop() M.state = nil end

-- hero: the local hero's unit (or nil); now: seconds (real time).
---@param hero Unit?
---@param now number
---@param enabled boolean
function M.update(hero, now, enabled)
    if not enabled or not love.audio then M.state = nil return end
    local s = M.state
    if not s then reset() s = M.state end
    ---@cast s HeartbeatState
    if not hero or hero.hp <= 0 then s.playing, s.fading, s.index = false, false, -1 return end
    if not s.table then
        local per = math.floor((hero.maxHp or hero.hp) / 11)
        local steps = {}
        s.table = steps
        for i = 0, 9 do
            steps[i] = { hits = per * (i + 1), fast = i < 5, delay = (300 + i * 70) / 1000, volume = 125 - i * 10 }
        end
        s.remembered = hero.hp
    end
    local steps = s.table
    ---@cast steps -nil
    if s.index > -1 and steps[s.index].delay + s.prev > now then return end
    local hits = hero.hp
    local big = math.abs(hits - s.remembered) > 1
    if big or s.index == -1 then
        if hits >= s.remembered and not s.playing then s.remembered = hits return end
        for i = 0, 9 do
            if steps[i].hits > hits then
                s.remembered = hits
                s.index, s.volume = i, steps[i].volume
                sound.play("Assets/SoundFX.xcr", steps[i].fast and "HeartBeatFast.wav" or "HeartBeatSlow.wav",
                    { volume = s.volume / 127 })
                s.orig, s.prev = now, now
                s.fading, s.playing = false, true
                return
            end
        end
    else
        s.remembered = hits
        if s.playing then
            if s.fading then
                s.volume = s.volume - 5
                if s.volume <= 0 then s.playing = false return end
            end
            local t = steps[s.index]
            sound.play("Assets/SoundFX.xcr", t.fast and "HeartBeatFast.wav" or "HeartBeatSlow.wav", { volume = s.volume / 127 })
            s.prev = now
            if s.prev - s.orig > 5 then s.fading = true end
        end
    end
end

return M
