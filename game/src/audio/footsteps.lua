-- Footstep sounds of marching armies (the "footsteps" option; the original's move sound loops, files loaded by FUN_0050fbf0
-- and played by the per-tick sound update FUN_0050ea10, for an army with a move order that is not a critter).
--
-- Verified against the original: the per-type loops (Walk, Stomp, Trot, Flap, Soar, Splash, Wagon, Pad, Fire, Sparkles,
-- Clank, Skeleton .wav, chosen by the army type's move sound; heroes always walk), at most three loops at once
-- (the original's limit), one loop per sound type played from the nearest army of that type, only armies within 25
-- cells of the view centre that the player sees, volume and pan by distance as for every positional sound
-- (sound.playAt). The channels are looped sources of their own that follow the nearest army; a unit counts as
-- marching while it has a plain move order (a goal and neither target nor task). The marching on ford and marsh
-- cells uses two files (SplashMove / MarshMove) that this game install does not have, so the army's own sound plays
-- there too; whether an army is "marching" is decided from its order state, not the display item's animation (that
-- is openwbc3's own simplification).
--
-- Presentation only: no simulation state, no math.random.
local sound = require("src.audio.sound")
local gameopts = require("src.core.gameopts")

---@class FootstepsModule
---@field channels table<integer, { src: love.Source }>   move sound type -> its looped channel
local M = { channels = {} }

local FILES = { [0] = "Walk.wav", "Stomp.wav", "Trot.wav", "Flap.wav", "Soar.wav", "Splash.wav", "Wagon.wav", "Pad.wav",
                "Fire.wav", "Sparkles.wav", "Clank.wav", "Skeleton.wav" }
local MAX_CHANNELS = 3
local ARCHIVE = "Assets/SoundFX.xcr"

local function stopAll()
    for t, ch in pairs(M.channels) do
        ch.src:stop()
        M.channels[t] = nil
    end
end
M.stop = stopAll

-- `shown(unit)`: whether the player sees the unit; listener position (cells) is sound.listenerX / Y.
---@param world World
---@param shown fun(u: Unit): boolean
function M.update(world, shown)
    if not love.audio or not gameopts.on("footsteps") or sound.volume <= 0 then
        if next(M.channels) then stopAll() end
        return
    end
    local lx, ly = sound.listenerX, sound.listenerY
    local best = {}                                   -- sound type -> { dist, unit }
    for _, u in ipairs(world.units) do
        if u.goalX and not u.target and not u.task and (u.state == "move" or u.state == "step") and u:alive()
            and not require("src.game.unit").isCritter(u.code) then
            local d = math.max(math.abs(u.gx - lx), math.abs(u.gy - ly))
            if d < 25 and shown(u) then
                local t = u.h and 0 or (u.type and u.type.moveSound) or 0
                if not FILES[t] then t = 0 end
                local b = best[t]
                if not b or d < b.dist then best[t] = { dist = d, unit = u } end
            end
        end
    end
    local order = {}
    for t, b in pairs(best) do order[#order + 1] = { type = t, dist = b.dist, unit = b.unit } end
    table.sort(order, function(a, b) if a.dist ~= b.dist then return a.dist < b.dist end return a.type < b.type end)
    local keep = {}
    for i = 1, math.min(MAX_CHANNELS, #order) do
        local o = order[i]
        keep[o.type] = true
        local ch = M.channels[o.type]
        if not ch then
            local src = sound.newSource(ARCHIVE, FILES[o.type])
            if src then
                src:setLooping(true)
                ch = { src = src }
                M.channels[o.type] = ch
                src:play()
            end
        end
        if ch then
            local dx = o.unit.gx - lx
            local vol = math.max(0, (125 - 5 * o.dist) / 127) * sound.volume
            ch.src:setVolume(math.min(1, vol))
            if ch.src:getChannelCount() == 1 then ch.src:setPosition(math.max(-1, math.min(1, dx / 25)), 0, 0) end
            if not ch.src:isPlaying() then ch.src:play() end
        end
    end
    for t, ch in pairs(M.channels) do
        if not keep[t] then ch.src:stop(); M.channels[t] = nil end
    end
end

return M
