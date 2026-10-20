-- Text helpers: the original data is Windows-1252; LÖVE wants UTF-8.
local M = {}

local CP1252 = {
    [0x80] = 0x20AC, [0x82] = 0x201A, [0x83] = 0x0192, [0x84] = 0x201E, [0x85] = 0x2026, [0x86] = 0x2020,
    [0x87] = 0x2021, [0x88] = 0x02C6, [0x89] = 0x2030, [0x8A] = 0x0160, [0x8B] = 0x2039, [0x8C] = 0x0152,
    [0x8E] = 0x017D, [0x91] = 0x2018, [0x92] = 0x2019, [0x93] = 0x201C, [0x94] = 0x201D, [0x95] = 0x2022,
    [0x96] = 0x2013, [0x97] = 0x2014, [0x98] = 0x02DC, [0x99] = 0x2122, [0x9A] = 0x0161, [0x9B] = 0x203A,
    [0x9C] = 0x0153, [0x9E] = 0x017E, [0x9F] = 0x0178,
}

local function utf8char(cp)
    if cp < 0x80 then return string.char(cp) end
    if cp < 0x800 then return string.char(0xC0 + math.floor(cp / 64), 0x80 + cp % 64) end
    return string.char(0xE0 + math.floor(cp / 4096), 0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
end

local cache = {}
---@param s string Windows-1252 text
---@return string utf8
function M.fromCP1252(s)
    if not s:find("[\128-\255]") then return s end
    local r = cache[s]
    if r then return r end
    r = s:gsub("[\128-\255]", function(c)
        local b = c:byte()
        return utf8char(CP1252[b] or b)
    end)
    cache[s] = r
    return r
end

return M
