-- Music player for the loose MP3 soundtrack (a music set: Music/*.ini with a [SOUNDTRACK] section).
-- "intro" plays the theme, "battle" cycles the ambient tracks, "victory" / "defeat" play the set's themes of the same
-- name once (the results screen starts one, see below).
--
-- Music sets (the options screen's last Sound drop-down, the set list of the 1.04 binary's FUN_00413c00 / FUN_00413ff0):
-- every `*.ini` in the Music folder (at most 20) that has a [SOUNDTRACK] Title is listed by that title,
-- the newest list entry first (the original prepends each file to a linked list); the chosen file is kept in the
-- options. The music start-up FUN_00510570 falls back to Battlecry3.ini when the chosen file is missing. The keys the set
-- reader FUN_00510710 reads: Tracks (default 5, at most 20), AmbientN (default \Ambient0.mp3), Intro, Victory, Defeat
-- (each defaults to \\WBC3_Theme.mp3). The victory screen's
-- builder (FUN_00454560, run when a battle ends and the results screen is shown) starts the set's Victory theme when the
-- local side won and the Defeat theme otherwise (FUN_005101d0 with 2 / 3; the call is skipped at volume 0), replacing
-- whatever plays. FUN_00510330 gives the sample no loop count, so the theme plays once; the main loop's idle step
-- (FUN_00510520, every 5 s of the system timer) then starts a random ambient track when nothing plays and the music was
-- not stopped on purpose. Switching the set with Okay restarts the menu theme: the options save FUN_00414160 calls the set
-- reader FUN_00510710(1) when the chosen file changed.
local ini = require("src.core.ini")
local fs = require("src.core.fs")
local config = require("src.core.config")
local log = require("src.core.log")

---@alias MusicMode "intro"|"battle"|"victory"|"defeat"

---@class MusicModule
---@field volume number          0..1
---@field intro string?          track paths of the chosen set (set by init)
---@field victory string?
---@field defeat string?
---@field ambient string[]       (set by init, which runs before any play)
---@field current love.Source?
---@field mode MusicMode?
---@field index integer?         last ambient track played
---@field nextCheck number?      time of the next idle check
local M = { volume = 0.756 }

local DEFAULT_SET = "Battlecry3.ini"
local MAX_SETS = 20

local function trackFile(rel)
    rel = rel:gsub("^[\\/]", "")
    return config.gamedir .. "/Music/" .. rel
end

-- The music sets: { { file = "Battlecry3.ini", title = "Soundtrack: Battlecry III" } ... } in the original's list order.
---@return { file: string, title: string }[]
function M.sets()
    local out = {}
    if not config.gamedir then return out end
    local names = fs.list(config.gamedir .. "/Music", "%.[Ii][Nn][Ii]$")
    table.sort(names, function(a, b) return a:lower() < b:lower() end)
    for i = 1, math.min(#names, MAX_SETS) do
        local data = ini.load(config.gamedir .. "/Music/" .. names[i])
        local title = data and data.soundtrack and data.soundtrack.title
        if title and title ~= "" then table.insert(out, 1, { file = names[i], title = title }) end
    end
    return out
end

-- The file name of the chosen set, Battlecry3.ini when it does not exist.
---@return string
function M.setFile()
    local want = tostring(config.get("audio", "musicset", DEFAULT_SET))
    if want:find("[\\/]") or not fs.read(config.gamedir .. "/Music/" .. want) then return DEFAULT_SET end
    return want
end

function M.init()
    local data = ini.load(config.gamedir .. "/Music/" .. M.setFile()) or {}
    local st = data.soundtrack or {}
    M.intro = trackFile(st.intro or "\\WBC3_Theme.mp3")
    M.victory = trackFile(st.victory or "\\WBC3_Theme.mp3")
    M.defeat = trackFile(st.defeat or "\\WBC3_Theme.mp3")
    M.ambient = {}
    local n = math.min(tonumber(st.tracks) or 5, 20)
    for i = 0, n - 1 do
        M.ambient[#M.ambient + 1] = trackFile(st["ambient" .. i] or "\\Ambient0.mp3")
    end
    M.volume = require("src.core.gameopts").volumePercent("music") / 100
end

---@param path string
---@return love.Source?
local function source(path)
    local data = fs.read(path)
    if not data then return nil end
    -- The GOG install pads these MP3s with leading zero bytes before the MPEG
    -- sync header; LÖVE's decoder can't find the header through the padding.
    local i = 1
    while i <= #data and data:byte(i) == 0 do i = i + 1 end
    data = data:sub(i)
    local ok, src = pcall(function()
        local fd = love.filesystem.newFileData(data, path:match("[^/\\]+$"))
        return love.audio.newSource(fd, "stream")
    end)
    if not ok then
        log.warn("music %s: %s", path, tostring(src))
        return nil
    end
    return src
end

function M.stop()
    if M.current then M.current:stop() end
    M.current, M.mode = nil, nil
end

---@param mode MusicMode
function M.play(mode)
    if M.mode == mode and M.current and M.current:isPlaying() then return end
    M.stop()
    M.mode = mode
    local path
    if mode == "intro" then
        path = M.intro
    elseif mode == "victory" or mode == "defeat" then
        path = M[mode] --[[@as string?]]
    else
        M.index = ((M.index or math.random(0, 6)) % math.max(1, #M.ambient)) + 1
        path = M.ambient[M.index]
    end
    if not path then return end
    M.current = source(path)
    if M.current then
        M.current:setVolume(M.volume)
        M.current:setLooping(mode == "intro")
        M.current:play()
    end
end

-- Call every frame: when a track has ended, the next ambient one starts at the next of the 5-second checks of the
-- original's idle step (FUN_00510520: due when never run or past, the next check 5 s after each run).
function M.update()
    local mode = M.mode
    if (mode == "battle" or mode == "victory" or mode == "defeat") and M.current and not M.current:isPlaying() then
        local now = love.timer.getTime()
        if not M.nextCheck or now >= M.nextCheck then
            M.nextCheck = now + 5
            M.mode = nil
            M.play("battle")
        end
    end
end

return M
