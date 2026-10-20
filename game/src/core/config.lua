-- Runtime configuration: locates the original game installation and holds
-- user settings. Settings live in "openwbc3.ini" in the LÖVE save directory;
-- a copy next to the game folder (repo root) is also honoured.
local ini = require("src.core.ini")
local log = require("src.core.log")
local fs = require("src.core.fs")

---@class Config
---@field gamedir string?          original game installation (GOG)
---@field language string          language folder of the install ("English", "German" ...)
---@field abbrev string            two-letter suffix for asset catalogues / voice archives
---@field settings { gamedir: string? }
---@field ini IniData?             openwbc3.ini as read (and changed by set)
local M = {
    gamedir = nil,       -- original game installation (GOG)
    language = "English",
    abbrev = "en",       -- two-letter suffix for asset catalogues / voice archives
    settings = {},
}

local GOG_ID = "1207658725"

-- The ten languages the original supports: folder name -> two-letter abbreviation. The
-- abbreviation drives the `Assets/Terrain|Features|Particles/*.en|ge` globs and the
-- `Voices<En|Ge>` archives; the folder drives the localised text files and per-language
-- .xcr archives. Read off the install's folders and the original binary.
M.LANGUAGES = {
    English = "en", French = "fr", German = "ge", Spanish = "sp", Italian = "it",
    Korean = "ko", Taiwanese = "ta", Polish = "po", Russian = "ru", Japanese = "ja",
}

-- The abbreviation for a language folder. Unknown folders (a hand-added "Portuguese/")
-- still work: fall back to the first two letters, as the original's naming implies.
---@param language string
---@return string
function M.abbrevFor(language)
    return M.LANGUAGES[language] or (language:lower():sub(1, 2))
end

-- The voice archives use the capitalised form of the abbreviation (Voices<En|Ge>.xcr,
-- the naming the install's own archives use).
function M.voiceSuffix()
    local a = M.abbrev or "en"
    return a:sub(1, 1):upper() .. a:sub(2, 2)
end

-- Picks the language the install actually has, the way the original detects it: probe
-- `<Lang>/Credits.xml` for each folder and take the first that exists. The list below is
-- the original's probe order; English is always the safe default.
---@param root string
---@return string
function M.detect(root)
    for _, name in ipairs({ "English", "German", "French", "Spanish", "Italian",
                            "Korean", "Taiwanese", "Polish", "Russian", "Japanese" }) do
        if fs.exists(root .. "/" .. name .. "/Credits.xml") then return name end
    end
    return "English"
end

local function isdir(path)
    if not path or path == "" then return false end
    local f = io.open(path .. "/War4Int.xci", "rb")
    if f then f:close() return true end
    f = io.open(path .. "/Assets/Graphics.xcr", "rb")
    if f then f:close() return true end
    return false
end

local function registryPath()
    if love.system.getOS() ~= "Windows" then return nil end
    local keys = {
        "HKLM\\SOFTWARE\\WOW6432Node\\GOG.com\\Games\\" .. GOG_ID,
        "HKLM\\SOFTWARE\\GOG.com\\Games\\" .. GOG_ID,
    }
    for _, key in ipairs(keys) do
        local p = io.popen('reg query "' .. key .. '" /v path 2>nul')
        if p then
            local out = p:read("*a")
            p:close()
            local path = out:match("path%s+REG_SZ%s+([^\r\n]+)")
            if path then return path end
        end
    end
    return nil
end

local function candidates()
    local list = {}
    local function add(p) if p then list[#list + 1] = p end end
    add(os.getenv("WBC3_DIR"))
    add(M.settings.gamedir)
    add(registryPath())
    for _, drive in ipairs({ "C", "D", "E", "B" }) do
        add(drive .. ":/GOG Games/Warlords Battlecry 3")
        add(drive .. ":/Spiele/GOG Games/Warlords Battlecry 3")
        add(drive .. ":/Program Files (x86)/GOG Galaxy/Games/Warlords Battlecry 3")
    end
    local home = os.getenv("HOME")
    if home then
        add(home .. "/GOG Games/Warlords Battlecry 3")
        add(home .. "/.wine/drive_c/GOG Games/Warlords Battlecry 3")
    end
    return list
end

function M.sourceDir()
    return love.filesystem.getSource()
end

-- Reads openwbc3.ini and the command line, finds the install; false when it was not found.
---@param args string[]
---@return boolean
function M.load(args)
    -- user settings
    local text = love.filesystem.read("openwbc3.ini")
    if not text then
        local f = io.open(M.sourceDir() .. "/../openwbc3.ini", "rb")
        if f then text = f:read("*a") f:close() end
    end
    local data = text and ini.parse(text) or {}
    M.ini = data
    M.settings.gamedir = ini.get(data, "game", "dir", nil)
    M.language = ini.get(data, "game", "language", nil) --[[@as string]]   -- nil until the detection below

    for i = 1, #args do
        if args[i] == "--data" and args[i + 1] then M.settings.gamedir = args[i + 1] end
        if args[i] == "--lang" and args[i + 1] then M.language = args[i + 1] end
    end

    for _, p in ipairs(candidates()) do
        p = p:gsub("\\", "/"):gsub("/$", "")
        if isdir(p) then
            M.gamedir = p
            break
        end
    end
    -- The original picks the language from which folders exist, by probing
    -- <Lang>/Credits.xml; only an explicit --lang / [game] language= overrides that.
    if M.gamedir and not M.language then M.language = M.detect(M.gamedir) end
    M.language = M.language or "English"
    M.abbrev = M.abbrevFor(M.language)
    if M.gamedir then
        log.info("game data: %s", M.gamedir)
    else
        log.error("original game data not found; pass --data <path> or set [game] dir= in openwbc3.ini")
    end
    return M.gamedir ~= nil
end

-- A setting of openwbc3.ini, converted to the type of `default` (see ini.get).
---@generic T
---@param section string
---@param key string
---@param default T
---@return T
function M.get(section, key, default)
    return ini.get(M.ini, section, key, default)
end

-- Stores a setting (written by M.save).
---@param section string
---@param key string
---@param value any stored with tostring
function M.set(section, key, value)
    M.ini = M.ini or {}
    section = section:lower()
    M.ini[section] = M.ini[section] or {}
    M.ini[section][key:lower()] = tostring(value)
end

function M.save()
    local out = {}
    for name, kv in pairs(M.ini or {}) do
        if name ~= "" and next(kv) then out[name] = kv end
    end
    love.filesystem.write("openwbc3.ini", ini.serialize(out))
end

return M
