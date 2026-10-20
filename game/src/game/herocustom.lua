-- What a new hero can be customised with: portraits, voice sets and avatars available to each race, as
-- offered by the original's "Customize Your Hero" screen. The lists (and their order: the first entry is the
-- default) follow that screen in the original game; race numbers are the usual 0..15.
-- Voice sets and avatars are stored with the hero (profile record: portrait, voice, avatar, password, mode). In
-- battle the avatar is the hero's unit (world.lua), the voice set gives its speech (voices.lua), the password is
-- asked by the hero selection screen and mode 1 is Ironman (world.lua / battle.lua).
local strings = require("src.game.strings")
local config = require("src.core.config")
local content = require("src.content")

local M = {}

-- portrait numbers (Portrait<nn>.bmp) per race (the `portraits` of the race records)
M.PORTRAITS = content.race:view("portraits")

-- voice sets: id (the hero's avatar code of the race, or AXH<n> for the shared ones), the death sound that is
-- played as a preview and the side archive it lives in (Assets/Sides/<archive><En|Ge>.xcr); index = set number
M.VOICE_SETS = {
    [0] = { "AHHX", "KnightsVoices" }, { "ADHX", "DwarvesVoices" }, { "AUHX", "UndeadVoices" },
    { "AMHX", "BarbariansVoices" }, { "ABHX", "MinotaursVoices" }, { "AOHX", "OrcsVoices" },
    { "AEHX", "HighElvesVoices" }, { "AWHX", "WoodElvesVoices" }, { "AKHX", "DarkElvesVoices" },
    { "AFHX", "FeyVoices" }, { "AAHX", "DarkDwarvesVoices" }, { "AVHX", "DaemonsVoices" },
    { "AXH0", "DefaultVoices" }, { "AXH1", "DefaultVoices" }, { "AXH2", "DefaultVoices" }, { "AXH3", "DefaultVoices" },
    { "AXH4", "DefaultVoices" }, { "AXH5", "DefaultVoices" }, { "AXH6", "DefaultVoices" }, { "AXH7", "DefaultVoices" },
}

-- The sound code and archive the speech of voice set `set` is read from (the original keys the speech files on the
-- set's id in place of the unit code), or nil.
---@param set integer
---@return {code: string, archive: string}?
function M.voiceSpec(set)
    local v = M.VOICE_SETS[set]
    if not v then return nil end
    local lang = config.voiceSuffix()
    return { code = v[1], archive = ("Assets/Sides/%s%s.xcr"):format(v[2], lang) }
end

-- voice set numbers offered per race (English; other languages offer a shorter list in the original): the race records' `voices`
-- and `voicesAlt`
M.VOICES = content.race:view("voices")
M.VOICES_ALT = content.race:view("voicesAlt")

-- the voice sets a race offers in the current language (openwbc3: anything other than English gets the
-- alternative list, as the original does for its nine others)
---@param race integer
---@return integer[]
function M.voiceList(race)
    if config.language == "English" then return M.VOICES[race] end
    return M.VOICES_ALT[race] or M.VOICES[race]
end

-- avatars: the hero unit codes; index = avatar number
M.AVATAR_CODES = { [0] = "AHHX", "ADHX", "AUHX", "AMHX", "ABHX", "AOHX", "AEHX", "AWHX", "AKHX", "AFHX", "AAHX", "AVHX",
                   "ARHX", "AHH0", "AHH1", "ALHX", "APHX" }

-- avatar numbers offered per race (`avatars` of the race records)
M.AVATARS = content.race:view("avatars")

---@param race integer
---@return integer
function M.defaultPortrait(race) return M.PORTRAITS[race][1] end

---@param race integer
---@return integer
function M.defaultVoice(race) return M.voiceList(race)[1] end

---@param race integer
---@return integer
function M.defaultAvatar(race) return M.AVATARS[race][1] end

-- Voice set display name ("Daemonic Male"), from Names.cfg VOICE_NAME<nnn>.
---@param set integer
---@return string
function M.voiceName(set)
    return strings.get("Names.cfg", ("VOICE_NAME%03d"):format(set)) or ("Voice " .. set)
end

-- Next / previous entry of a list of numbers after `current` (wrapping); an unknown `current` gives the first one.
---@generic T
---@param list T[]
---@param current T
---@param dir integer
---@return T
function M.step(list, current, dir)
    for i, v in ipairs(list) do
        if v == current then return list[(i - 1 + dir) % #list + 1] end
    end
    return list[1]
end

return M
