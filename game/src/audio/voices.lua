-- Unit speech: <CODE>Select<n>.wav, <CODE>Order<n>.wav, <CODE>Ready.wav, <CODE>Deathblow.wav, <CODE>Build.wav,
-- <CODE>CantBuild.wav, <CODE>Conversion.wav (and the hero's Spell<n> / Mana) in Assets/Sides/<Pack>Voices<En|Ge>.xcr,
-- where <Pack> is the side archive the unit's sprites come from. When a line may play (option "Unit Speech",
-- the shared select / order counter, the variant choice) is in speech.lua.
local sound = require("src.audio.sound")
local config = require("src.core.config")
local anims = require("src.gfx.anims")
local speech = require("src.audio.speech")

local M = {}

-- The speech files of one code and kind: [n] = Select<n>.wav ..., or `plain` (<code><kind>.wav), and the archive.
---@class VoiceList
---@field [integer] string
---@field plain string?
---@field arch string?

---@type table<string, VoiceList>
local variants = {}
---@type Speaker?
local speaker

---@param code string
---@return string?
local function voiceArchive(code)
    local set = anims.get(code)
    if not set or not set.archive then return nil end
    local base = set.archive.key:gsub("%.[xX][cC][rR]$", "")
    local lang = config.voiceSuffix()
    return base .. "Voices" .. lang .. ".xcr"
end

-- The existing variants of <code><kind><n>.wav (n = 1..9), or the plain <code><kind>.wav (list[1]).
---@param code string
---@param kind string
---@param archive string?
---@return VoiceList
local function list(code, kind, archive)
    local key = (archive or "") .. code .. kind
    local l = variants[key]
    if not l then
        l = {}
        local arch = archive or voiceArchive(code)
        if arch then
            for n = 1, 9 do
                local name = ("%s%s%d.wav"):format(code, kind, n)
                if sound.exists(arch, name) then l[n] = name end
            end
            local plain = code .. kind .. ".wav"
            if not next(l) and sound.exists(arch, plain) then l.plain = plain end
        end
        l.arch = arch
        variants[key] = l
    end
    return l
end

-- Resolves who -> unit code and the archive of a hero's voice set (unit.voiceSet, from herocustom.voiceSpec: the
-- original's per-hero voice set replaces the unit code in the file names).
---@param who string|Unit
---@return string? code
---@return string? archive
---@return Unit? unit
local function resolve(who)
    if type(who) == "table" then
        if who.voiceSet then return who.voiceSet.code, who.voiceSet.archive, who end
        return who.code, nil, who
    end
    ---@cast who string
    return who, nil, nil
end

local function now() return love.timer.getTime() end

-- Time of the first line in this battle (the counters start at their initial values then).
function M.reset()
    speaker = speech.speaker(now())
end

local function level() return require("src.core.gameopts").unitSpeech() end

-- The number of speech files the original assumes: the type's record, four for a hero or a special character.
local function fileCount(unit)
    if not unit then return 1 end
    if unit.hero then return 4 end
    local t = unit.type
    return t and t.speech and t.speech > 0 and t.speech or 1
end

-- kind: "Select", "Order", "Ready", "Conversion", "Build", "CantBuild", "Spell", "Mana". `who` is a unit code or a
-- unit. Returns true when a line started.
---@param who string|Unit
---@param kind string
---@return boolean
function M.say(who, kind)
    local code, archive, unit = resolve(who)
    if not code then return false end
    speaker = speaker or speech.speaker(now())
    local lvl = level()
    if not speech.allowed(lvl, kind, speech.dice(5)) then return false end
    local t = now()
    local l = list(code, kind, archive)
    if not l.arch then return false end
    local name
    if kind == "Select" or kind == "Order" then
        if not speaker:take(kind, t) then return false end
        local files = fileCount(unit)
        local memory = kind == "Select" and "lastSelectVoice" or "lastOrderVoice"
        local n, last = speech.pickVariant(kind, files, speech.dice(100), unit and unit[memory])
        if unit then unit[memory] = last end
        -- a unit whose archive has fewer files than the record says falls back to the closest one that exists
        while n > 1 and not l[n] do n = n - 1 end
        name = l[n] or l.plain
        if not name then
            for i = 1, 9 do if l[i] then name = l[i] break end end
        end
    elseif kind == "Ready" then
        if not speaker:takeReady(t) then return false end
        name = l.plain
    else
        name = l.plain
        if not name then
            -- the hero's Spell<n>: 1 in 10 for the third, 4 in 10 the second (FUN_0050f2c0)
            local roll = speech.dice(100)
            local n = roll > 90 and 3 or (roll > 50 and 2 or 1)
            while n > 1 and not l[n] do n = n - 1 end
            name = l[n]
        end
    end
    if not name then return false end
    return sound.play(l.arch, name, { voice = true }) ~= nil
end

-- A melee deathblow: the attacker's line, positional, at most once per 0.4 s (the counter select / order share).
---@param unit Unit
---@return boolean
function M.deathblow(unit)
    local code, archive = resolve(unit)
    if not code then return false end
    speaker = speaker or speech.speaker(now())
    if not speech.allowed(level(), "Deathblow", 5) then return false end
    local l = list(code, "Deathblow", archive)
    if not l.arch or not l.plain then return false end
    if not speaker:take("Deathblow", now()) then return false end
    return sound.playAt(l.arch, l.plain, unit.gx, unit.gy, { voice = true }) ~= nil
end

return M
