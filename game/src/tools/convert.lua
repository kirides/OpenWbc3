-- Asset converter, run as `love game --convert [options]` (see tools/convert.*).
-- Converts what LÖVE can't read natively into game/converted/:
--   * Bink videos (Video/*.bik)          -> converted/video/<name>.ogv (Theora + Vorbis)
--   * optional: sounds inside archives    -> converted/sound/<path>.ogg (Vorbis)
--     (the engine also plays the original WAVs straight from the archives;
--      converting just trades CPU at load for smaller files)
local config = require("src.core.config")
local log = require("src.core.log")

local M = {}

local isWindows = package.config:sub(1, 1) == "\\"

---@param path string
---@return string path in double quotes
local function q(path)
    return '"' .. path .. '"'
end

---@param path string
---@return string path with the separators of the platform
local function native(path)
    return isWindows and path:gsub("/", "\\") or path
end

local function mkdirs(path)
    if isWindows then
        os.execute('if not exist ' .. q(native(path)) .. ' mkdir ' .. q(native(path)))
    else
        os.execute("mkdir -p " .. q(path))
    end
end

local function exists(path)
    local f = io.open(path, "rb")
    if f then f:close() return true end
    return false
end

-- The names in a directory (not recursive), filtered by a Lua pattern over the lower-case name.
---@param path string
---@param pattern string?
---@return string[]
local function listdir(path, pattern)
    local cmd = isWindows and ('dir /b ' .. q(native(path)) .. ' 2>nul') or ('ls -1 ' .. q(path) .. ' 2>/dev/null')
    local p = io.popen(cmd)
    local out = {}
    if p then
        for line in p:lines() do
            if not pattern or line:lower():match(pattern) then out[#out + 1] = line end
        end
        p:close()
    end
    return out
end

---@param cmd string
---@return boolean ok the command exited with 0
local function run(cmd)
    -- cmd.exe strips the outer quotes of a command line that starts with one
    if isWindows then cmd = '"' .. cmd .. '"' end
    local ok = os.execute(cmd)
    return ok == true or ok == 0
end

-- The ffmpeg to use: the one given with --ffmpeg, else the first on PATH, else nil.
---@param opt string?
---@return string?
local function findFfmpeg(opt)
    if opt then return opt end
    local probe = isWindows and "where ffmpeg 2>nul" or "command -v ffmpeg 2>/dev/null"
    local p = io.popen(probe)
    local line = p and p:read("*l")
    if p then p:close() end
    return line and line ~= "" and line or nil
end

---@param args string[] the command line
---@return integer exit code: 0 when everything converted
function M.run(args)
    local opts = { video = true, audio = false, force = false }
    for i = 1, #args do
        local a = args[i]
        if a == "--ffmpeg" then opts.ffmpeg = args[i + 1]
        elseif a == "--audio" then opts.audio = true
        elseif a == "--no-video" then opts.video = false
        elseif a == "--force" then opts.force = true
        elseif a == "--out" then opts.out = args[i + 1]
        end
    end

    if not config.load(args) then return 1 end
    local ffmpeg = findFfmpeg(opts.ffmpeg)
    if not ffmpeg then
        log.error("ffmpeg not found; put it on PATH or pass --ffmpeg <path>")
        return 1
    end
    local out = opts.out or (config.sourceDir() .. "/converted")
    log.info("ffmpeg: %s", ffmpeg)
    log.info("output: %s", out)

    local failures = 0
    if opts.video then
        mkdirs(out .. "/video")
        for _, name in ipairs(listdir(config.gamedir .. "/Video", "%.bik$")) do
            local src = config.gamedir .. "/Video/" .. name
            local dst = out .. "/video/" .. name:gsub("%.[bB][iI][kK]$", ".ogv")
            if exists(dst) and not opts.force then
                -- an existing file is assumed to be good (broken output is deleted when it is made)
                log.info("skip %s (exists)", name)
            else
                log.info("video %s", name)
                local cmd = ("%s -hide_banner -loglevel error -y -i %s -c:v libtheora -q:v 8 -c:a libvorbis -q:a 4 %s")
                    :format(q(native(ffmpeg)), q(native(src)), q(native(dst)))
                if not run(cmd) then
                    log.error("failed: %s", name)
                    os.remove(dst)
                    failures = failures + 1
                elseif not M.verifyVideo(ffmpeg, dst) then
                    log.error("%s: the encoded Theora stream does not decode cleanly. Some ffmpeg builds ship a "
                        .. "broken libtheora; try another ffmpeg build (e.g. a current gyan.dev or BtbN release) "
                        .. "with --ffmpeg <path>. The broken file was removed.", name)
                    os.remove(dst)
                    failures = failures + 1
                end
            end
        end
    end

    if opts.audio then
        failures = failures + M.convertAudio(ffmpeg, out, opts)
    end

    log.info("done (%d failures)", failures)
    return failures == 0 and 0 or 1
end

-- Decodes the first seconds of a converted video and checks for decoder errors.
---@param ffmpeg string
---@param path string
---@return boolean
function M.verifyVideo(ffmpeg, path)
    local cmd = ("%s -hide_banner -loglevel error -t 3 -i %s -f null - 2>&1"):format(q(native(ffmpeg)), q(native(path)))
    if isWindows then cmd = '"' .. cmd .. '"' end
    local p = io.popen(cmd)
    if not p then return true end
    local out = p:read("*a") or ""
    p:close()
    return not out:find("unpack_block") and not out:find("[Ee]rror")
end

-- Extracts every WAV from the game's archives and encodes it to Vorbis.
---@param ffmpeg string
---@param out string output folder
---@param opts {force: boolean}
---@return integer failures
function M.convertAudio(ffmpeg, out, opts)
    local vfs = require("src.vfs.vfs")
    vfs.init(config.gamedir, config.language)
    local failures, count = 0, 0
    local tmp = out .. "/_tmp.wav"
    for _, path in ipairs(vfs.list("%.wav$")) do
        local dst = out .. "/sound/" .. path:gsub("%.[wW][aA][vV]$", ".ogg")
        if not exists(dst) or opts.force then
            local data = vfs.read(path)
            if data then
                mkdirs(dst:match("^(.*)/"))
                local f = assert(io.open(tmp, "wb"))
                f:write(data)
                f:close()
                local cmd = ("%s -hide_banner -loglevel error -y -i %s -c:a libvorbis -q:a 3 %s")
                    :format(q(native(ffmpeg)), q(native(tmp)), q(native(dst)))
                if run(cmd) then count = count + 1 else
                    log.error("failed: %s", path)
                    failures = failures + 1
                end
            end
        end
    end
    os.remove(tmp)
    log.info("audio: %d files converted", count)
    return failures
end

return M
