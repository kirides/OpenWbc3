-- Player options of the original's options screen (the 1.04 binary's options record), kept in openwbc3.ini.
-- Defaults are those of the 1.04 binary's first-run block (FUN_00453280, which fills the options record that the
-- registry then keeps): popup help All, scroll rate 3, game speed 2, music volume 3 (High), sound effects 120 (Full),
-- group move with the slowest unit, spacebar pauses, right click interface, unit speech Sometimes, female system
-- voice, tips on, environment / footstep / combat sounds on, victory / defeat build-up and hero heartbeat on,
-- shadows / ambient animations / blood / floating text / decals / mouse effects on, particles Average, lighting
-- Minimum, gamma 0 (the other options are the defaults of the options reader FUN_004521f0, not re-checked one by one).
-- The five scroll rates and the volume levels are the original's own numbers: see M.SCROLL_EDGE_EVENTS, M.SFX, M.MUSIC.
-- openwbc3's own choices (not verifiable): which options have an effect at all (docs/implemented.md "Display and
-- sound options"), the spell bar and the language switch.
local config = require("src.core.config")

local M = {}

-- Sound effects levels (Off, Low, Medium, High, Full): the options screen sets the effects volume to 0 / 30 / 60 / 90 / 120
-- (the setter at 0x0040fea0; FUN_00567b50 does the same for the in-battle dialog) on Miles' 0..127 volume scale, so the
-- fractions of full volume are n / 127. A positional sound is (125 - 5 x distance) x effects volume / 127
-- (the 25-step volume table of FUN_0050ee90), which sound.playAt / playLoopAt reproduce with this fraction as sound.volume.
M.SFX = { 0, 23.6, 47.2, 70.9, 94.5 }
-- Music levels 0..4: the Miles sample volume is `level << 5` (FUN_00510330) = 0 / 32 / 64 / 96 / 128 of 127, 128 being
-- clamped to the maximum (assumption: Miles clamps; the call is not documented to wrap).
M.MUSIC = { 0, 25.2, 50.4, 75.6, 100 }
M.VOLUMES = { effects = M.SFX, music = M.MUSIC }
-- First-run levels: sound effects Full, music High (3).
M.VOLUME_DEFAULT = { effects = M.SFX[5], music = M.MUSIC[4] }
-- Scroll rates 1..5 (Very Slow .. Very Fast; the first run starts at 3). The original moves the view by `rate` map
-- cells (32 x 24 pixels) per event: at the screen edge on every 25 ms tick of the main loop (the multimedia timer of
-- FUN_00457190, FUN_0041e020 via FUN_00458bb0) and on every 50 ms window-timer event (FUN_0041e320 case 9), with the
-- arrow keys only on the timer event; while a wall is dragged the rate is 1. That is 60 x rate cells a second at the
-- edge and 20 x rate for the keys (battle.lua scrolls continuously by these numbers).
M.SCROLL_EDGE_EVENTS, M.SCROLL_KEY_EVENTS = 60, 20
M.SCROLL_RATES = 5
-- Game speeds 0..4 (Very Slow .. Very Fast): the original stores the option and starts the game at option + 1 of its
-- five timer steps (the game clock FUN_00458dd0: x0.5, 0.75, 1, 1.5, 2).
M.SPEEDS = { 0.5, 0.75, 1, 1.5, 2 }

-- name = { section, key, default }; booleans are stored as true / false, levels as integers.
local DEFS = {
    helplevel = { "options", "helplevel", 2 },
    gamespeed = { "options", "gamespeed", 2 },
    groupmove = { "options", "groupmove", true },
    spacebar = { "options", "spacebarpauses", true },
    rightclick = { "options", "rightclickinterface", true },
    sysvoice = { "options", "systemvoice", 0 },
    tips = { "game", "tips", true },
    envsound = { "options", "environmentsound", true },
    footsteps = { "options", "footsteps", true },
    combatsounds = { "options", "combatsounds", true },
    unitspeech = { "options", "unitspeech", 1 },
    buildup = { "options", "victorydefeatbuildup", true },
    heartbeat = { "options", "heroheartbeat", true },
    shadows = { "options", "shadows", true },
    ambient = { "options", "ambientanimation", true },
    blood = { "options", "blood", true },
    gamma = { "options", "gamma", 0 },
    floattext = { "options", "floatingtext", true },
    particles = { "options", "particles", 1 },
    decals = { "options", "decals", true },
    lighting = { "options", "lighting", 1 },
    mouseeffects = { "options", "mouseeffects", true },
    spellbar = { "options", "spellbar", false },          -- openwbc3's own, off: the original has no spell bar
}

-- The stored value of an option of DEFS (number or boolean, the type of its default).
---@param name string
---@return any
function M.get(name)
    local d = DEFS[name]
    return config.get(d[1], d[2], d[3])
end

-- Bumped by every set(): the presentation caches (sprite effects, gamma) compare it to see when an option changed.
M.version = 0

---@param name string
---@param value any
function M.set(name, value)
    local d = DEFS[name]
    config.set(d[1], d[2], value)
    M.version = M.version + 1
end

-- A boolean option (anything but an explicit false is on) and a level option (0 = off).
---@param name string
---@return boolean
function M.on(name) return M.get(name) ~= false end
---@param name string
---@return number
function M.level(name) return tonumber(M.get(name)) or 0 end

-- Index of the entry of `list` closest to v (1-based).
local function nearest(list, v)
    local best, bd = 1, math.huge
    for i, x in ipairs(list) do
        if math.abs(x - v) < bd then best, bd = i, math.abs(x - v) end
    end
    return best
end

-- Scroll rate 1..5 ([options] scrollrate; the old percentage key [game] scroll is not read any more).
---@return integer
function M.scrollRate()
    return math.max(1, math.min(M.SCROLL_RATES, math.floor(tonumber(config.get("options", "scrollrate", 3)) or 3)))
end
function M.setScrollRate(r) config.set("options", "scrollrate", r) end

-- Volume levels 1..5 (Off .. Full) of the sound effects and the music ([audio] effects / music, in percent).
---@param key "effects"|"music"
---@return number
function M.volumePercent(key) return tonumber(config.get("audio", key, M.VOLUME_DEFAULT[key])) or M.VOLUME_DEFAULT[key] end
---@param key "effects"|"music"
---@return integer 1..5
function M.volumeLevel(key) return nearest(M.VOLUMES[key], M.volumePercent(key)) end
---@param key "effects"|"music"
---@param level integer 1..5
function M.setVolumeLevel(key, level) config.set("audio", key, M.VOLUMES[key][level]) end

function M.helpLevel() return tonumber(M.get("helplevel")) or 2 end
function M.spacebarPauses() return M.get("spacebar") ~= false end
function M.leftClickInterface() return M.get("rightclick") == false end
function M.groupMove() return M.get("groupmove") ~= false end
function M.unitSpeech() return tonumber(M.get("unitspeech")) or 1 end
function M.systemVoiceFemale() return (tonumber(M.get("sysvoice")) or 0) == 0 end
---@return number
function M.gameSpeed() return M.SPEEDS[(tonumber(M.get("gamespeed")) or 2) + 1] or 1 end

-- Advanced options, the [advanced] section of openwbc3.ini: the registry key of the original with
-- its value names (see src/game/advanced.lua for what was verified). With no [advanced] section at all the first-run
-- defaults apply (random weather off, 10 tournament points), with a section a missing value gets the default of
-- the reader FUN_00450d00 (random weather on, 15 points).
function M.advanced()
    local A = require("src.game.advanced")
    local section = config.ini and config.ini.advanced
    local first = section == nil
    local t = {}
    local function bool(k, firstRun, other)
        local default = other
        if first then default = firstRun end
        t[k] = config.get("advanced", A.INI[k], default)
    end
    bool("randomWeather", false, true)
    bool("resignKills", true, true)
    bool("aiResign", true, true)
    bool("tournament", false, false)
    bool("greatest", false, false)
    bool("toughTowers", false, false)
    bool("noItems", false, false)
    t.points = config.get("advanced", A.INI.points, first and 10 or 15)       -- both numbers are non-false
    return A.normalize(t)
end

function M.setAdvanced(t)
    local A = require("src.game.advanced")
    t = A.normalize(t)
    for _, k in ipairs(A.KEYS) do config.set("advanced", A.INI[k], t[k]) end
    config.save()
end

return M
