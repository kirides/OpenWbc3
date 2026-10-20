-- The local "no original text in the repository" guard (docs/data-driven/07-verification-legal.md 7.2, layer 2). It needs the install:
--   pwsh tools/dev/love.ps1 -Timeout 300 -- --selftest --lua tools/dev/guard-install.lua
-- Reads the text files of the player's install (the text entries of the archives and the loose ones in the game folder), normalises every
-- line of at least 20 characters (lower case, white space collapsed, at least 8 letters) and keeps only a hash of it in memory. Then it
-- scans the files git tracks or would add (not `game/converted`, `shots`, `dump` and other ignored folders) and reports every line that matches, as
-- path:line. Nothing of the original text is written anywhere, so the guard itself cannot leak. Exit 1 when a line matches.
local vfs = require("src.vfs.vfs")
local fs = require("src.core.fs")
local hashlib = require("src.content.hash")

local TEXT_EXT = { txt = true, cfg = true, xml = true, xci = true, nam = true, ai = true, uai = true, ini = true, loc = true, lst = true,
                   scr = true, inf = true }
local SCAN_EXT = { lua = true, md = true, txt = true, ps1 = true, sh = true, bat = true, xml = true, cfg = true, json = true }

-- The form a line is compared in, or nil for a line too short to say anything.
---@param line string
---@return string?
local function normalise(line)
    line = line:lower():gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
    if #line < 20 then return nil end
    local letters = select(2, line:gsub("%a", ""))
    if letters < 8 then return nil end
    return line
end

local known, sources = {}, 0
---@param text string the contents of a text file of the install
local function learn(text)
    sources = sources + 1
    -- the files are Windows-1252 or UTF-16: look at ASCII lines only (an UTF-16 file shows up as NUL-separated letters)
    if text:sub(1, 2) == "\255\254" then text = text:gsub("%z", "") end
    for line in text:gmatch("[^\r\n]+") do
        local n = normalise(line)
        if n then known[hashlib.string(n)] = true end
    end
end

for _, path in ipairs(vfs.list()) do
    local ext = path:match("%.([^./]+)$")
    if ext and TEXT_EXT[ext:lower()] then
        local archive, entry = path:match("^(.-%.xcr)/(.+)$")
        local data = archive and vfs.read(archive, entry)
        if data then learn(data) end
    end
end
---@param dir string folder of the install ("" = its root)
local function loose(dir)
    for _, name in ipairs(fs.list(vfs.root .. (dir ~= "" and "/" .. dir or ""))) do
        local ext = name:match("%.([^./]+)$")
        if ext and TEXT_EXT[ext:lower()] then
            local data = fs.read(vfs.root .. (dir ~= "" and "/" .. dir or "") .. "/" .. name)
            if data then learn(data) end
        end
    end
end
loose("")
loose("English")
if vfs.lang and vfs.lang ~= "English" then loose(vfs.lang) end
local count = 0
for _ in pairs(known) do count = count + 1 end
print(("[info] guard-install: %d text sources, %d distinct lines"):format(sources, count))

---@param cmd string shell command
---@return string[] lines of its output
local function run(cmd)
    local p = assert(io.popen(cmd))
    local out = {}
    for line in p:lines() do out[#out + 1] = line end
    p:close()
    return out
end
local root = love.filesystem.getSource():gsub("\\", "/"):gsub("/game/?$", "")
local files = run(('git -C "%s" ls-files --cached --others --exclude-standard'):format(root))
local hits, scanned = 0, 0
for _, path in ipairs(files) do
    local ext = path:match("%.([^./]+)$")
    if ext and SCAN_EXT[ext:lower()] and not path:find("^game/converted/") and not path:find("^shots/") and not path:find("^dump/") then
        local f = io.open(root .. "/" .. path, "rb")
        local text = f and f:read("*a")
        if f then f:close() end
        if text then
            scanned = scanned + 1
            local n = 0
            for line in (text .. "\n"):gmatch("(.-)\r?\n") do
                n = n + 1
                local norm = normalise(line)
                if norm and known[hashlib.string(norm)] then
                    hits = hits + 1
                    print(("[error] guard-install: %s:%d repeats a line of the install"):format(path, n))
                end
            end
        end
    end
end
print(("[info] guard-install: %d files scanned, %d matching lines"):format(scanned, hits))
if hits > 0 then os.exit(1) end
