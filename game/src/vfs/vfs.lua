-- Virtual filesystem over the original game installation.
--
-- Archives are registered under their path relative to the game directory
-- (e.g. "Assets/SoundFX.xcr") and, when "localized", also under their bare
-- file name ("SoundFX.xcr"). Lookups name an archive and an entry, as the
-- original engine does; `find` additionally searches all archives in mount
-- order for convenience.
local xcr = require("src.vfs.xcr")
local fs = require("src.core.fs")
local log = require("src.core.log")

---@class Vfs
---@field root string?                      the game folder (set by init)
---@field lang string                       language folder
---@field archives XcrArchive[]
---@field byKey table<string, XcrArchive>
local M = {
    root = nil,
    lang = "English",
    archives = {},     -- in mount order
    byKey = {},        -- lower-cased key -> archive
}

---@param rel string archive path relative to the game folder
---@param localized boolean? also register it under its bare file name
---@return XcrArchive?
local function mount(rel, localized)
    local key = rel:lower()
    if M.byKey[key] then return M.byKey[key] end
    local path = fs.resolve(M.root .. "/" .. rel) or (M.root .. "/" .. rel)
    local a, err = xcr.open(path)
    if not a then
        log.debug("vfs: %s", err)
        return nil
    end
    a.key = rel
    M.archives[#M.archives + 1] = a
    M.byKey[key] = a
    if localized then
        local base = rel:match("([^/]+)$"):lower()
        if not M.byKey[base] then M.byKey[base] = a end
    end
    return a
end
M.mount = mount

local function mountDir(dir, localized)
    for _, name in ipairs(fs.list(M.root .. "/" .. dir, "%.xcr$")) do
        mount(dir .. "/" .. name, localized)
    end
end

-- Mounts a language-folder archive, falling back to English/ when the requested
-- language's copy is missing (the original always ships English; a hand-added
-- language folder may lack some archives).
local function mountLang(rel, localized)
    if mount(M.lang .. "/" .. rel, localized) then return true end
    if M.lang ~= "English" then return mount("English/" .. rel, localized) end
    return false
end

---@param root string
---@param lang string?
function M.init(root, lang)
    M.root = root
    M.lang = lang or "English"
    local L = M.lang
    -- same order as the original engine
    mountDir("Assets/Terrain", true)
    mountDir("Assets/Features", true)
    mountDir("Assets/Sides", true)
    mount("PatchData.xcr", true)
    mountDir("Assets/Effects", true)
    mountLang("GameSpeech.xcr", true)
    mount("Assets/SoundFX.xcr", false)
    mount("Quest.xcr", false)
    -- not shipped by every install (this GOG one has none), so probe before logging a failure
    if fs.exists(M.root .. "/" .. L .. "/CampaignSpeech.xcr") or fs.exists(M.root .. "/English/CampaignSpeech.xcr") then
        mountLang("CampaignSpeech.xcr", true)
    end
    mount("Assets/Graphics.xcr", true)
    mountLang("GText.xcr", true)
    mount("Assets/Heroes/Portraits.xcr", true)
    -- loaded on demand by the original; cheap to mount up front
    -- DialogData.xcr sits at the install root, not in the language folder.
    if not mount(L .. "/DialogData.xcr", true) then mount("DialogData.xcr", true) end
    mountLang("Items.xcr", true)
    mountLang("Mercenaries.xcr", true)
    mountLang("Campaign.xcr", true)
    mount("RandomData.xcr", true)
    mount("Assets/Data/System.xcr", true)
    mount("Data/Data.xcr", true)
    mount("Assets/Patch.xcr", true)
    local n = 0
    for _, a in ipairs(M.archives) do n = n + #a.entries end
    log.info("vfs: %d archives, %d entries", #M.archives, n)
end

-- A mod's `override/<entry>` files replace entries of the install by name (src/assets/init.lua). `overlay` is the pseudo archive that
-- lookups of such an entry report as their source: asking it for another entry gives the override of that one, else the install's.
---@class VfsOverlay: XcrArchive
local overlay = { key = "override", entries = {}, byName = {} }
---@param entry string
---@return string?
function overlay:read(entry)
    local assets = require("src.assets")
    return assets.override(entry) or M.find(entry)
end

---@param name string
---@return XcrArchive?
function M.archive(name)
    name = name:gsub("\\", "/"):lower()
    return M.byKey[name] or M.byKey[name:match("([^/]+)$")]
end

-- Reads `entry` from archive `arch`; with only one argument, `entry` may be
-- "Archive.xcr/entry" or a bare entry name (searched in all archives).
---@param arch string
---@param entry string?
---@return string?
function M.read(arch, entry)
    if not entry then
        local a, e = arch:match("^(.*%.[xX][cC][rR])/(.+)$")
        if a then arch, entry = a, e else return M.find(arch) end
    end
    local assets = require("src.assets")
    if assets.active() then
        local data = assets.override(entry)
        if data then return data end
    end
    local a = M.archive(arch)
    return a and a:read(entry)
end

-- An entry from any archive (mount order) or a mod override; the second value is where it came from.
---@param entry string
---@return string? data
---@return XcrArchive? source
function M.find(entry)
    local assets = require("src.assets")
    if assets.active() then
        local data = assets.override(entry)
        if data then return data, overlay end
    end
    local key = entry:lower()
    for _, a in ipairs(M.archives) do
        local e = a.byName[key]
        if e then return a:read(e), a end
    end
    return nil
end

---@param entry string
---@return boolean
---@return XcrArchive? source
function M.exists(entry)
    local assets = require("src.assets")
    if assets.active() and assets.override(entry) then return true, overlay end
    local key = entry:lower()
    for _, a in ipairs(M.archives) do
        if a.byName[key] then return true, a end
    end
    return false
end

-- Lists "Archive/entry" paths whose entry name matches `pattern` (lower-cased).
---@param pattern string?
---@param arch string?
---@return string[]
function M.list(pattern, arch)
    local out = {}
    local list = arch and { M.archive(arch) } or M.archives
    for _, a in ipairs(list) do
        for _, e in ipairs(a.entries) do
            if not pattern or e.name:lower():match(pattern) then
                out[#out + 1] = a.key .. "/" .. e.name
            end
        end
    end
    return out
end

-- Loose file relative to the game directory.
---@param rel string
---@return string?
function M.readFile(rel)
    return fs.read(M.root .. "/" .. rel)
end

-- Reads a loose file from the language folder, falling back to English/ when the
-- requested language's copy is missing (the original always ships English; a hand-added
-- language folder may lack some files). `rel` is the path under the language folder.
---@param rel string
---@return string?
function M.langFile(rel)
    return fs.read(M.root .. "/" .. M.lang .. "/" .. rel)
        or (M.lang ~= "English" and fs.read(M.root .. "/English/" .. rel) or nil)
end

---@param rel string
---@return string
function M.path(rel)
    return fs.resolve(M.root .. "/" .. rel) or (M.root .. "/" .. rel)
end

return M
