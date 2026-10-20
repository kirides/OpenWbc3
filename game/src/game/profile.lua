-- Player heroes. Every hero is a record in the LÖVE save directory (heroes/<id>.lua):
--   { id, name, race, class, portrait, created, hero = <Hero:save()> }
-- The selected hero is stored in openwbc3.ini ([game] hero=<id>). Heroes from before there
-- was a selection (heroes/race00.lua ...) are imported on first use.
local serialize = require("src.core.serialize")
local config = require("src.core.config")
local log = require("src.core.log")
local classes = require("src.game.classes")

local M = {}

-- A player hero's record (heroes/<id>.lua), or the temporary hero of a Tournament battle.
---@class HeroProfile
---@field id string
---@field name string
---@field race integer
---@field class string
---@field portrait integer
---@field voice any?
---@field avatar any?
---@field password string?
---@field mode integer           0 normal, 1 Ironman
---@field created number         creation order (ms)
---@field magic number?          the Ironman magic number (32 bits)
---@field hero table             Hero:save()
---@field temporary boolean?     the Tournament hero: never written
---@field battles integer?       "Games Played"
---@field raceGames table<integer, integer>? games played per race (campaign difficulty)
---@field raceWins table<integer, integer>?
---@field retinue table<integer, RetinueEntry>? slot 1..8 (retinue.lua)
---@field graveyard table<integer, RetinueGrave>? 1..10 (retinue.lua)

local DIR = "heroes"
local IRONMAN_FILE = "ironman.lua"     -- deleted Ironman heroes (the original keeps them in the registry)
local IRONMAN_SLOTS = 2                -- LIMHK0_* and LIMHK1_*: the last two

local function path(id) return ("%s/%s.lua"):format(DIR, id) end

---@param file string
---@return HeroProfile?
local function readRecord(file)
    local text = love.filesystem.read(file)
    local t = text and serialize.decode(text)
    if not t then log.warn("hero file %s is unreadable", file) end
    -- heroes saved before the class was kept in the hero state
    if t and t.hero and not t.hero.class then t.hero.class = t.class end
    if t and t.hero and not t.hero.race then t.hero.race = t.race end
    return t
end

local write, newMagic

-- A listed record: Ironman heroes that were deleted before are refused (and their file is removed), old heroes get a
-- magic number.
---@param file string
---@param rec HeroProfile?
---@return HeroProfile?
local function usable(file, rec)
    if not rec or not rec.id then return nil end
    if M.isDeletedIronman(rec) then
        love.filesystem.remove(file)
        log.warn("hero %s is a deleted Ironman hero, removed", tostring(rec.name))
        return nil
    end
    if not rec.magic then
        rec.magic = newMagic()
        write(rec)
    end
    return rec
end

---@param rec HeroProfile
---@return boolean
function write(rec)
    if rec.temporary then return true end       -- a Tournament hero is never kept (FUN_0054bbd0 skips the save FUN_0044fef0)
    love.filesystem.createDirectory(DIR)
    local ok, err = love.filesystem.write(path(rec.id), serialize.encode(rec))
    if not ok then log.warn("hero not saved: %s", tostring(err)) end
    return ok
end

-- Ironman record (the 1.04 binary's registry writer FUN_00452b40 and test FUN_00452db0, the LIMHK0_* / LIMHK1_* values,
-- used by the hero list loader FUN_005549f0 and the hero deletion FUN_00555550). Every hero gets four random bytes
-- (FUN_0054c000 rolls them, 1 .. 255 each, at +0x181 .. +0x184 of the hero record; here `rec.magic`, 32 bits).
-- When an Ironman hero dies its name checksums (sum and xor of the characters) and magic number are written to the first
-- of two slots, the former first slot moves to the second; an Ironman hero file whose magic number is in a slot and
-- whose sum or xor matches is refused and removed from the list, so a backup copy of a dead Ironman hero cannot be
-- restored. The original keeps the slots in the registry; openwbc3 keeps them in ironman.lua of the user data directory.
-- Heroes from before the magic number get one when they are first listed.
local function nameSums(name)
    local a, x = 0, 0
    for i = 1, #name do
        local c = name:byte(i)
        a = a + c
        x = bit.bxor(x, c)
    end
    return a, x
end

function newMagic()
    local n = 0
    for i = 0, 3 do n = n + love.math.random(1, 255) * 256 ^ i end      -- four bytes of 1d255 (FUN_0054c000)
    return n
end

local function ironmanSlots()
    local text = love.filesystem.read(IRONMAN_FILE)
    local t = text and serialize.decode(text)
    return type(t) == "table" and t or {}
end

-- true when the Ironman hero `rec` has been deleted before
---@param rec HeroProfile?
---@return boolean
function M.isDeletedIronman(rec)
    if not rec or rec.mode ~= 1 or not rec.magic then return false end
    local a, x = nameSums(rec.name or "")
    local slots = ironmanSlots()
    for i = 1, IRONMAN_SLOTS do
        local s = slots[i]
        if s and s.n == rec.magic and (s.a == a or s.x == x) then return true end
    end
    return false
end

local function recordIronman(rec)
    if not rec.magic or M.isDeletedIronman(rec) then return end
    local a, x = nameSums(rec.name or "")
    local slots = ironmanSlots()
    table.insert(slots, 1, { a = a, x = x, n = rec.magic })
    while #slots > IRONMAN_SLOTS do table.remove(slots) end
    love.filesystem.write(IRONMAN_FILE, serialize.encode(slots))
end

-- Password check of the hero selection (the password panel's handler at 0x00555d20 compares the entered text with the
-- hero's password ignoring case, FUN_005dc0b0; every path that chooses, loads or deletes a hero asks it first). A hero without a password
-- passes. Call this wherever a screen lets the player pick a hero record other than through screens/heroselect.lua.
---@param rec HeroProfile?
---@return boolean
function M.hasPassword(rec) return rec ~= nil and rec.password ~= nil and rec.password ~= "" end

---@param rec HeroProfile?
---@param text string?
---@return boolean
function M.passwordMatches(rec, text)
    if not M.hasPassword(rec) then return true end
    ---@cast rec -nil
    return (text or ""):lower() == rec.password:lower()
end

local imported = false
local function importOld()
    if imported then return end
    imported = true
    love.filesystem.createDirectory(DIR)
    for _, f in ipairs(love.filesystem.getDirectoryItems(DIR)) do
        local race = f:match("^race(%d%d)%.lua$")
        if race then
            local data = readRecord(DIR .. "/" .. f)
            if data then
                local r = tonumber(race)
                M.create({ name = (classes.RACE_NAMES[r] or "Hero") .. " Hero", race = r, class = "Warrior", portrait = r,
                           hero = data })
            end
            love.filesystem.remove(DIR .. "/" .. f)
        end
    end
end

---@return HeroProfile[]
function M.list()
    importOld()
    local out = {}
    for _, f in ipairs(love.filesystem.getDirectoryItems(DIR)) do
        if f:match("^h%d+%.lua$") then
            local rec = usable(DIR .. "/" .. f, readRecord(DIR .. "/" .. f))
            if rec then out[#out + 1] = rec end
        end
    end
    table.sort(out, function(a, b)
        if a.created ~= b.created then return a.created < b.created end
        return a.id < b.id
    end)
    return out
end

---@param id string?
---@return HeroProfile?
function M.get(id)
    if not id or not love.filesystem.getInfo(path(id)) then return nil end
    return usable(path(id), readRecord(path(id)))
end

local counter = 0
-- spec: name, race, class, portrait [, hero, voice, avatar, password, mode]
---@param spec table name, race, class, portrait [, hero, voice, avatar, password, mode]
---@return HeroProfile
function M.create(spec)
    counter = counter + 1
    local rec = {
        id = ("h%d%03d"):format(os.time(), counter),
        name = spec.name, race = spec.race, class = spec.class, portrait = spec.portrait or 0,
        voice = spec.voice, avatar = spec.avatar, password = spec.password, mode = spec.mode or 0,
        created = os.time() * 1000 + counter, magic = newMagic(),
        hero = spec.hero or classes.newHero(spec.class, spec.race),
    }
    write(rec)
    return rec
end

---@param id string
function M.delete(id)
    love.filesystem.remove(path(id))
    love.filesystem.remove(("campaign/%s.lua"):format(id))
    if config.get("game", "hero", "") == id then
        config.set("game", "hero", "")
        config.save()
    end
end

-- An Ironman hero died (FUN_00522260 in battle, FUN_00455d60 on the defeat screen): record it, then delete the hero.
---@param rec HeroProfile
function M.deleteIronman(rec)
    recordIronman(rec)
    M.delete(rec.id)
end

-- The temporary hero of a Tournament mode battle (screens/heroselect.lua builds it, the battle screen installs it for
-- its length): while it is set it is the current hero whatever its race, every write to it goes nowhere and nothing of
-- it reaches the heroes directory. rec = { temporary = true, name, race, class, portrait, voice, avatar, mode, hero }.
local temporary
---@param rec HeroProfile?
function M.setTemporary(rec) temporary = rec end
---@return HeroProfile?
function M.temporary() return temporary end

---@return HeroProfile?
function M.current()
    if temporary then return temporary end
    local id = config.get("game", "hero", "")
    local rec = id ~= "" and M.get(id) or nil
    if rec then return rec end
    local all = M.list()
    return all[1]
end

---@param id string
function M.setCurrent(id)
    config.set("game", "hero", id)
    config.save()
end

---@param rec HeroProfile
function M.update(rec)
    write(rec)
end

-- Battle interface: the selected hero is the player's hero when its race matches the side. race == nil asks for the hero
-- whatever its race: in a network game the player picks the race of his seat freely (World:profileRace).
---@param race integer?
---@return table? hero the saved hero state (a copy)
function M.load(race)
    local rec = M.current()
    if rec and (race == nil or rec.race == race or rec.temporary) and rec.hero then
        local h = {}
        for k, v in pairs(rec.hero) do h[k] = v end
        h.mana = nil                      -- every battle starts with a tenth of the maximum mana
        return h
    end
    return nil
end

-- The selected hero's record when it is of `race` (what a battle of that side uses), else nil.
---@param race integer?
---@return HeroProfile?
function M.recordFor(race)
    local rec = M.current()
    if rec and (race == nil or rec.race == race or rec.temporary) and rec.hero then return rec end
end

-- Counts a finished battle for the current hero ("Games Played" of the results screen); returns the new count.
---@return integer
function M.addBattle()
    local rec = M.current()
    if not rec or rec.temporary then return rec and rec.battles or 0 end
    rec.battles = (rec.battles or 0) + 1
    write(rec)
    return rec.battles
end

-- The per-race counters the campaign's difficulty reads (games played and victories per race in the hero record; the 1.04 binary:
-- `FUN_004e2790` adds a game for the race of the player's side when a battle is set up, the victory handler at 0x00454987
-- adds a win for it when the battle is won). rec.raceGames[race] / rec.raceWins[race]; a hero from before has none (0).
local function bump(field, race)
    local rec = M.current()
    if not rec or rec.temporary or race == nil then return end
    rec[field] = rec[field] or {}
    rec[field][race] = (rec[field][race] or 0) + 1
    write(rec)
end

---@param race integer?
function M.addRaceGame(race) bump("raceGames", race) end
---@param race integer?
function M.addRaceWin(race) bump("raceWins", race) end

---@param race integer?
---@param hero Hero
---@return boolean
function M.save(race, hero)
    local rec = M.current()
    if rec and (race == nil or rec.race == race) and not rec.temporary then
        rec.hero = hero:save()
        rec.hero.latch = nil             -- the level-up latch is battle state (the original does not keep it)
        write(rec)
    end
    return true
end

return M
