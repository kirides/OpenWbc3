-- The terrain ambience of a battle (the "environment sounds" option; the 1.04 binary's terrain ambience loop FUN_0050e420): one
-- looped stream, SoundFX/Terrain/<terrain>.wav by day and SoundFX/Terrain/Night.wav at night, at the effects volume.
--
-- Verified against the original: the file names (Plains for plains, outland, highland and jungle maps, Desert for desert
-- and wasteland, Arctic for snow; lava, caverns and wetlands have none), the switch to Night.wav whenever it is night
-- (whatever the terrain), and that nothing plays with the option off. The terrain type is the one of the random-map
-- setup; for every other map the original's static options are still zero, which is "plains" - openwbc3 does the same
-- (world.opts.terrainType may name another one). The loose Ambient.wav / Coast.wav / Prairie.wav in that folder are not
-- used by this code.
--
-- The ambience of single features (the feature display's sound check, not traced in the 1.04 binary yet; the same option):
-- a feature type whose <code>.FEA record has the ambient-sound byte set (offset 60 of the 68-byte record, read by 1.04's
-- FUN_0041b730 into 0x704618 + 68 n) plays <code>Ambient.wav of SoundFX.xcr (FUN_00511c10, sound kind 4) as a loop
-- while it is within 25 cells of the view centre and seen by the player, volume and pan by distance as for every
-- positional sound. The retail data never uses this: none of the 121 shipped feature types has the byte set (nor any
-- type of the 115 scenarios), and the six shipped files FI00..FI05Ambient.wav and FML0Ambient.wav belong to types
-- the install lacks (FML0, the lamp post, is only named in Events/Feature.lst), so nothing is heard in the original
-- or here unless an archive adds such a type. The per-type delay attribute of the feature XML (a one-shot every
-- `delay` ms instead of a loop, all 0 in the shipped files) is not read. More than 12 loops at once is openwbc3's own
-- limit (the original has none besides its channel count).
--
-- Presentation only. No simulation state.
local config = require("src.core.config")
local sound = require("src.audio.sound")
local vfs = require("src.vfs.vfs")

local ARCHIVE = "Assets/SoundFX.xcr"

---@class AmbienceModule
---@field features table<integer, love.Source>   feature id -> looped source
---@field src love.Source?    the terrain loop
---@field file string?        its name (Plains, Desert, Arctic, Night)
local M = {}

local BY_TYPE = { [0] = "Plains", "Plains", "Plains", "Desert", false, "Desert", false, "Arctic", false, "Plains" }

M.features = {}                                  -- feature id -> looped source
local MAX_FEATURE_LOOPS = 12
local typeSound = {}                             -- feature code -> wav name or false

-- The ambient wav of a feature type, or false when its record lacks the flag or the wav is missing.
---@param code string
---@return string|false
function M.featureSound(code)
    local e = typeSound[code]
    if e == nil then
        e = false
        local rec = vfs.find(code .. ".fea")
        if rec and #rec >= 61 and rec:byte(61) ~= 0 and sound.exists(ARCHIVE, code .. "Ambient.wav") then
            e = code .. "Ambient.wav"
        end
        typeSound[code] = e
    end
    return e
end

local function stopFeatures()
    for id, src in pairs(M.features) do
        src:stop()
        M.features[id] = nil
    end
end

-- `shown(feature)`: whether the player sees the feature (the battle screen's fog test).
---@param world World
---@param enabled boolean
---@param shown (fun(f: Feature): boolean)?
local function updateFeatures(world, enabled, shown)
    if not enabled or not love.audio or sound.volume <= 0 then stopFeatures() return end
    local lx, ly = sound.listenerX, sound.listenerY
    local keep, n = {}, 0
    for _, f in ipairs(world.features) do
        local wav = M.featureSound(f.code)
        if wav then
            local d = math.max(math.abs(f.gx - lx), math.abs(f.gy - ly))
            if d < 25 and n < MAX_FEATURE_LOOPS and (not shown or shown(f)) then
                n = n + 1
                keep[f.id] = true
                ---@type love.Source?
                local src = M.features[f.id]
                if not src then
                    src = sound.newSource(ARCHIVE, wav)
                    if src then
                        src:setLooping(true)
                        src:play()
                        M.features[f.id] = src
                    end
                end
                if src then
                    src:setVolume(math.min(1, math.max(0, (125 - 5 * d) / 127) * sound.volume))
                    if src:getChannelCount() == 1 then
                        src:setPosition(math.max(-1, math.min(1, (f.gx - lx) / 25)), 0, 0)
                    end
                    if not src:isPlaying() then src:play() end
                end
            end
        end
    end
    for id, src in pairs(M.features) do
        if not keep[id] then src:stop() M.features[id] = nil end
    end
end

local function stopTerrain()
    if M.src then M.src:stop() end
    M.src, M.file = nil, nil
end

function M.stop()
    stopTerrain()
    stopFeatures()
end

---@param world World
---@param enabled boolean
---@param shown (fun(f: Feature): boolean)?
function M.update(world, enabled, shown)
    updateFeatures(world, enabled, shown)
    local name
    if enabled and world.night then name = "Night"
    elseif enabled then name = BY_TYPE[(world.opts and world.opts.terrainType) or 0] end
    if not name or not config.gamedir or sound.volume <= 0 then stopTerrain() return end
    if M.file ~= name then
        stopTerrain()
        M.src = sound.playFile(config.gamedir .. "/SoundFX/Terrain/" .. name .. ".wav")
        if M.src then M.src:setLooping(true) M.file = name end
    end
    if M.src then M.src:setVolume(sound.volume) end
end

return M
