-- Sound effects: WAVs straight from the archives (or a converted .ogg from
-- game/converted/sound when present), cached as static sources, with a small
-- pool of voices per sound so overlapping plays work.
local vfs = require("src.vfs.vfs")
local config = require("src.core.config")
local log = require("src.core.log")

-- A loaded sound: its data and the pool of sources playing it (at most four; none for M.playFile).
---@class SoundEntry
---@field data love.SoundData
---@field sources love.Source[]?

---@class SoundOpts
---@field volume number?    0..1
---@field pan number?       -1..1
---@field voice boolean?    use the voice volume instead of the effects volume
---@field cooldown number?  seconds since the same sound last started

---@class SoundModule
---@field volume number                        effects volume 0..1
---@field voiceVolume number
---@field cache table<string, SoundEntry|false>   false: tried, not found
---@field lastPlay table<string, number>
---@field trace fun(arch: string?, name: string)?   debug hook, called for every sound played
---@field listenerX number                     view centre in cells (set by the battle screen)
---@field listenerY number
local M = { volume = 0.945, voiceVolume = 1.0, cache = {}, lastPlay = {}, trace = nil }

function M.init()
    M.volume = require("src.core.gameopts").volumePercent("effects") / 100
    M.voiceVolume = config.get("audio", "voices", 100) / 100
    -- positions are only used for stereo panning; volume is computed by the caller
    if love.audio then love.audio.setDistanceModel("none") end
end

-- Finds "name" in an archive (or anywhere) and returns its cache entry or nil.
---@param arch string?
---@param name string
---@return SoundEntry?
local function load(arch, name)
    local key = (arch or "*") .. "|" .. name:lower()
    local e = M.cache[key]
    if e ~= nil then return e or nil end
    e = false
    local converted = "converted/sound/" .. (arch or "") .. "/" .. name:gsub("%.[wW][aA][vV]$", ".ogg")
    local ok, sd
    if arch and love.filesystem.getInfo(converted) then
        ok, sd = pcall(love.sound.newSoundData, converted)
    else
        local data = arch and vfs.read(arch, name) or vfs.find(name)
        if data then
            ok, sd = pcall(function()
                ---@diagnostic disable-next-line: param-type-mismatch -- LÖVE takes a FileData; the library lacks the overload
                return love.sound.newSoundData(love.filesystem.newFileData(data, name))
            end)
        end
    end
    if ok and sd then
        e = { data = sd, sources = {} }
    elseif sd then
        log.debug("sound %s: %s", name, tostring(sd))
    end
    M.cache[key] = e
    return e or nil
end

-- A source of its own (outside the voice pool) for a sound that is looped and steered by its owner, e.g. the
-- footsteps; nil when the sound doesn't exist. The caller starts, updates and stops it.
---@param arch string?
---@param name string
---@return love.Source?
function M.newSource(arch, name)
    if not love.audio then return nil end
    local e = load(arch, name)
    return e and love.audio.newSource(e.data, "static") or nil
end

-- Plays a WAV from a plain file on disk (the game's Data folder).
---@param path string
---@param opts SoundOpts?
---@return love.Source?
function M.playFile(path, opts)
    if not love.audio then return nil end
    local e = M.cache["file|" .. path]
    if e == nil then
        e = false
        local data = require("src.core.fs").read(path)
        if data then
            local ok, sd = pcall(function()
                ---@diagnostic disable-next-line: param-type-mismatch -- LÖVE takes a FileData; the library lacks the overload
                return love.sound.newSoundData(love.filesystem.newFileData(data, "event.wav"))
            end)
            if ok then e = { data = sd } end
        end
        M.cache["file|" .. path] = e
    end
    if not e then return nil end
    local src = love.audio.newSource(e.data, "static")
    src:setVolume(((opts and opts.volume) or 1) * M.volume)
    src:play()
    return src
end

---@param arch string?
---@param name string
---@return boolean
function M.exists(arch, name)
    local a = arch and vfs.archive(arch)
    if arch then return a ~= nil and a:has(name) end
    return vfs.exists(name)
end

-- Plays a sound. opts: volume (0..1), pan (-1..1), voice (bool, uses voice volume),
-- cooldown (seconds since the same sound last started).
---@param arch string? nil: any archive
---@param name string
---@param opts SoundOpts?
---@return love.Source?
function M.play(arch, name, opts)
    if not love.audio then return nil end   -- headless tools
    opts = opts or {}
    local now = love.timer.getTime()
    local key = (arch or "*") .. "|" .. name:lower()
    if opts.cooldown and M.lastPlay[key] and now - M.lastPlay[key] < opts.cooldown then return nil end
    local e = load(arch, name)
    if not e then return nil end
    if M.trace then M.trace(arch, name) end      -- debug: `--at` scripts set sound.trace = print to log every line
    local src
    for _, s in ipairs(e.sources) do
        if not s:isPlaying() then src = s break end
    end
    if not src then
        if #e.sources >= 4 then
            src = e.sources[1]
            src:stop()
        else
            src = love.audio.newSource(e.data, "static")
            e.sources[#e.sources + 1] = src
        end
    end
    local vol = (opts.volume or 1) * (opts.voice and M.voiceVolume or M.volume)
    src:setVolume(math.max(0, math.min(1, vol)))
    if src:getChannelCount() == 1 then
        local pan = opts.pan or 0
        src:setPosition(pan, 0, 0)
    end
    src:play()
    M.lastPlay[key] = now
    return src
end

-- Positional one-shot: audible within 24 cells of the view centre
-- (M.listenerX/Y, set by the battle screen); volume falls off linearly.
M.listenerX, M.listenerY = 0, 0
---@param arch string?
---@param name string
---@param gx number
---@param gy number
---@param opts SoundOpts? (changed: volume and pan are set)
---@return love.Source?
function M.playAt(arch, name, gx, gy, opts)
    local dx, dy = gx - M.listenerX, gy - M.listenerY
    local d = math.max(math.abs(dx), math.abs(dy))
    if d >= 24 then return nil end
    opts = opts or {}
    opts.volume = (opts.volume or 1) * (125 - 5 * d) / 127
    opts.pan = math.max(-1, math.min(1, dx / 25))
    return M.play(arch, name, opts)
end

-- Start a looping positional sound (a burning building's fire); returns the source, or nil when out of range.
-- The caller keeps it and calls stopLoop(source) when the fire goes out.
---@param arch string?
---@param name string
---@param gx number
---@param gy number
---@param opts SoundOpts?
---@return love.Source?
function M.playLoopAt(arch, name, gx, gy, opts)
    local dx, dy = gx - M.listenerX, gy - M.listenerY
    local d = math.max(math.abs(dx), math.abs(dy))
    if d >= 24 then return nil end
    opts = opts or {}
    opts.volume = (opts.volume or 1) * (125 - 5 * d) / 127
    opts.pan = math.max(-1, math.min(1, dx / 25))
    local src = M.play(arch, name, opts)
    if src then src:setLooping(true) end
    return src
end

---@param src love.Source?
function M.stopLoop(src)
    if src then src:stop() end
end

return M
