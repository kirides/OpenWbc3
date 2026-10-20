-- The static "no original assets in the repository" guard (docs/data-driven/07-verification-legal.md 7.2). It needs no install:
--   pwsh tools/dev/love.ps1 -- --selftest --lua tools/dev/guard.lua
-- Looks at the files git tracks (and the new ones it does not ignore) and fails (exit 1) on
--   * a file with the extension of an original asset (archives, sprites, sounds, videos, scenarios, game data files), except the
--     files named in ALLOWED_FILES;
--   * a Lua file over 256 KB, or one with a line of 60 or more numeric literals (a data dump), except ALLOWED_DATA;
--   * more 4-letter unit / building / power-up code literals ("AHBX") outside the places that may hold them (the base ruleset, the
--     importers, the tests) than CODE_LITERALS: a ratchet. The number only goes down; lower it when it does.
--   * a string literal over 120 characters in the base ruleset (game text belongs in lang files, not in data).
-- The local counterpart that compares against the player's install is tools/dev/guard-install.lua.
local FORBIDDEN = {
    "xcr", "ani", "rle", "bmp", "arm", "bui", "ter", "fea", "scn", "wav", "bik", "ai", "uai", "cfg", "xci", "xcg", "nam", "act",
    "amb", "loc", "dat", "ogv", "ogg", "mp3", "tga", "dds", "wbc", "xcb", "sav", "rgn", "map", "wad",
}
-- Reviewed by hand (images must not show the original's art either, screenshots included).
local ALLOWED_FILES = {
}
-- Numeric tables read from the game binary (decision D1 of the plan: numbers only, kept where they are used), reviewed by hand.
local ALLOWED_DATA = {
    ["game/src/game/formationdata.lua"] = true,
}
-- 4-letter code literals outside game/content/base, game/src/import/wbc3 and the test tools (state of 2026-10-14).
local CODE_LITERALS = 501

---@param cmd string shell command
---@return string[] lines of its output
local function run(cmd)
    local p = assert(io.popen(cmd))
    local out = {}
    for line in p:lines() do out[#out + 1] = line end
    p:close()
    return out
end

local failures = 0
---@param fmt string
local function fail(fmt, ...)
    failures = failures + 1
    print(("[error] guard: " .. fmt):format(...))
end

-- the repository root is the folder above the game folder
local source = love.filesystem.getSource():gsub("\\", "/")
local root = source:gsub("/game/?$", "")
local files = run(('git -C "%s" ls-files --cached --others --exclude-standard'):format(root))

local forbidden = {}
for _, ext in ipairs(FORBIDDEN) do forbidden[ext] = true end

---@param path string relative to the repository root
local function allowedForCodes(path)
    return path:find("^game/content/base/") or path:find("^game/src/import/wbc3/") or path:find("^game/src/tools/")
        or path:find("^docs/") or path:find("^tools/")
end

local codeCount, checked = 0, 0
for _, path in ipairs(files) do
    local ext = path:match("%.([^./]+)$")
    ext = ext and ext:lower()
    if ext and forbidden[ext] and not ALLOWED_FILES[path] then
        fail("%s has the extension of an original asset (.%s)", path, ext)
    elseif ext == "png" and not ALLOWED_FILES[path] and not path:find("^docs/modding/") then
        fail("%s: images need a hand review: add it to ALLOWED_FILES of tools/dev/guard.lua", path)
    end
    if ext == "lua" then
        local f = io.open(root .. "/" .. path, "rb")
        local text = f and f:read("*a")
        if f then f:close() end
        if text then
            checked = checked + 1
            if #text > 256 * 1024 and not ALLOWED_DATA[path] then fail("%s is %d KB: a Lua file over 256 KB looks like a data dump", path, math.floor(#text / 1024)) end
            local n = 0
            for line in text:gmatch("[^\n]+") do
                n = n + 1
                local numbers = 0
                for _ in line:gmatch("[%s,{]%-?%d+%.?%d*[,}]") do numbers = numbers + 1 end
                if numbers >= 60 and not ALLOWED_DATA[path] then
                    fail("%s:%d has %d numeric literals on a line: a data dump?", path, n, numbers)
                    break
                end
            end
            if not allowedForCodes(path) then
                for _ in text:gmatch('"[ABP][A-Z][A-Z0-9][A-Z0-9]"') do codeCount = codeCount + 1 end
            end
            if path:find("^game/content/base/") then
                n = 0
                for line in text:gmatch("[^\n]+") do
                    n = n + 1
                    for lit in line:gmatch('"([^"\\]*)"') do
                        if #lit > 120 and not line:find("^%s*%-%-") then fail("%s:%d: a string literal of %d characters in the base ruleset", path, n, #lit) end
                    end
                end
            end
        end
    end
end

print(("[info] guard: %d tracked files, %d Lua files, %d code literals outside the base layer (allowed %d)"):format(#files, checked, codeCount, CODE_LITERALS))
if codeCount > CODE_LITERALS then
    fail("%d 4-letter code literals outside the base layer, the importers and the tests (allowed %d): put them into content/base records",
        codeCount, CODE_LITERALS)
elseif codeCount < CODE_LITERALS then
    print(("[info] guard: the ratchet can come down: set CODE_LITERALS to %d"):format(codeCount))
end
print(("[info] guard: %d failures"):format(failures))
if failures > 0 then os.exit(1) end
