-- Access to the real filesystem (outside LÖVE's sandbox), used for the
-- original game installation.
local M = {}

M.isWindows = package.config:sub(1, 1) == "\\"

local function q(path) return '"' .. path .. '"' end
local function native(path) return M.isWindows and (path:gsub("/", "\\")) or path end
M.quote, M.native = q, native

---@param path string
---@return boolean
function M.exists(path)
    local f = io.open(path, "rb")
    if f then f:close() return true end
    return false
end

-- The whole file, or nil when it cannot be opened.
---@param path string
---@return string?
function M.read(path)
    local f = io.open(path, "rb")
    if not f then
        -- case-insensitive fallback for case-sensitive filesystems
        local real = M.resolve(path)
        if real then f = io.open(real, "rb") end
        if not f then return nil end
    end
    local data = f:read("*a")
    f:close()
    return data
end

-- Directory listing through the Win32 API: spawning `cmd /c dir` for every folder stalls the UI
-- for a noticeable time (process start-up plus virus scanner), so only fall back to it elsewhere.
local winList
if M.isWindows then
    local ok, ffi = pcall(require, "ffi")
    if ok then
        pcall(ffi.cdef, [[
            typedef struct { uint32_t attr; uint32_t ct[2], at[2], wt[2]; uint32_t sizeHigh, sizeLow, res0, res1;
                             char name[260]; char alt[14]; } WBC_FIND;
            void *FindFirstFileA(const char *pattern, WBC_FIND *data);
            int FindNextFileA(void *h, WBC_FIND *data);
            int FindClose(void *h);
        ]])
        winList = function(dir)
            local data = ffi.new("WBC_FIND[1]")
            local h = ffi.C.FindFirstFileA(native(dir) .. "\\*", data)
            if h == ffi.cast("void *", -1) then return nil end
            local names = {}
            repeat
                local n = ffi.string(data[0].name)
                if n ~= "." and n ~= ".." then names[#names + 1] = n end
            until ffi.C.FindNextFileA(h, data) == 0
            ffi.C.FindClose(h)
            return names
        end
    end
end

-- Lists file names in a directory. `pattern` is matched against the lower-cased name.
local cache = {}
---@param dir string
---@param pattern string? Lua pattern
---@return string[] names sorted case-insensitively (cached per folder: do not modify)
function M.list(dir, pattern)
    local names = cache[dir]
    if not names then
        names = winList and winList(dir)
        if not names then
            names = {}
            local cmd = M.isWindows and ("dir /b " .. q(native(dir)) .. " 2>nul")
                or ("ls -1 " .. q(dir) .. " 2>/dev/null")
            local p = io.popen(cmd)
            if p then
                for line in p:lines() do names[#names + 1] = line end
                p:close()
            end
        end
        table.sort(names, function(a, b) return a:lower() < b:lower() end)
        cache[dir] = names
    end
    if not pattern then return names end
    local out = {}
    for _, n in ipairs(names) do
        if n:lower():match(pattern) then out[#out + 1] = n end
    end
    return out
end

-- The original's file list (the class of FUN_004029d0 / FUN_00402ad0 in the 1.04 binary, behind the scenario, AI script
-- and unit AI lists) holds at most 1024 entries, each name in a 40-byte slot that is filled without a bound: a name of
-- 40 or more characters runs into the next entry and its path breaks. openwbc3 leaves such names out (its own choice
-- for what the original corrupts) and stops at 1024.
M.FILE_LIST_MAX, M.FILE_NAME_MAX = 1024, 39

-- `M.list` with the original file list's limits.
---@param dir string
---@param pattern string? Lua pattern
---@return string[]
function M.fileList(dir, pattern)
    local out = {}
    for _, n in ipairs(M.list(dir, pattern)) do
        if #out >= M.FILE_LIST_MAX then break end
        if #n <= M.FILE_NAME_MAX then out[#out + 1] = n end
    end
    return out
end

-- Resolves a path case-insensitively, component by component (non-Windows).
---@param path string
---@return string?
function M.resolve(path)
    if M.isWindows then return M.exists(path) and path or nil end
    local cur = path:sub(1, 1) == "/" and "" or "."
    for part in path:gmatch("[^/]+") do
        local found
        for _, n in ipairs(M.list(cur == "" and "/" or cur)) do
            if n:lower() == part:lower() then found = n break end
        end
        if not found then return nil end
        cur = cur .. "/" .. found
    end
    return cur
end

---@param path string
function M.mkdirs(path)
    if M.isWindows then
        os.execute("if not exist " .. q(native(path)) .. " mkdir " .. q(native(path)))
    else
        os.execute("mkdir -p " .. q(path))
    end
end

return M
