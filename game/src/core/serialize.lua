-- Minimal Lua table serializer for save data and network messages: numbers, booleans, strings and nested tables
-- without cycles. `encode` writes a Lua chunk ("return {...}"); `decode` reads it back with a data-only parser (no
-- loadstring), so text from another machine can never run code: anything but the literals `encode` writes fails.
local M = {}

-- how deep tables may nest when decoding (encode's own data stays far below)
M.MAX_DEPTH = 64

local function dump(v, out, indent)
    local t = type(v)
    if t == "number" then
        out[#out + 1] = (v == math.floor(v) and math.abs(v) < 2 ^ 52) and ("%d"):format(v) or ("%.17g"):format(v)
    elseif t == "boolean" then
        out[#out + 1] = tostring(v)
    elseif t == "string" then
        out[#out + 1] = ("%q"):format(v)
    elseif t == "table" then
        out[#out + 1] = "{\n"
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = k end
        table.sort(keys, function(a, b)
            if type(a) == type(b) then return a < b end
            return type(a) == "number"
        end)
        for _, k in ipairs(keys) do
            out[#out + 1] = indent .. "  "
            if type(k) == "string" and k:match("^[%a_][%w_]*$") then out[#out + 1] = k .. " = "
            else out[#out + 1] = "[" .. (type(k) == "string" and ("%q"):format(k) or tostring(k)) .. "] = " end
            dump(v[k], out, indent .. "  ")
            out[#out + 1] = ",\n"
        end
        out[#out + 1] = indent .. "}"
    else
        out[#out + 1] = "nil"
    end
end

---@param v any
---@return string
function M.encode(v)
    local out = { "return " }
    dump(v, out, "")
    return table.concat(out)
end

-- The parser. Each reader takes the position of the next character and returns the value and the position after it,
-- or raises an error (caught by decode).
local byte, sub, find, char = string.byte, string.sub, string.find, string.char
local B_QUOTE, B_BACKSLASH, B_BRACE, B_BRACKET = byte('"'), byte("\\"), byte("{"), byte("[")
local ESCAPES = { n = "\n", t = "\t", r = "\r", a = "\a", b = "\b", f = "\f", v = "\v", ["\\"] = "\\", ['"'] = '"',
                  ["'"] = "'", ["\n"] = "\n", ["\r"] = "\r" }
-- %q writes these words for non-finite numbers; as a chunk they were (unset) globals, so they decode to nil
local WORDS = { ["true"] = true, ["false"] = false, ["nil"] = nil, inf = nil, nan = nil }

local function skip(s, i)
    return find(s, "[^ \t\r\n]", i) or #s + 1
end

local function readString(s, i)
    local parts, start = {}, i + 1
    local j = start
    while true do
        local k = find(s, '["\\\n]', j)
        if not k then error("unfinished string") end
        local c = byte(s, k)
        if c == B_QUOTE then
            parts[#parts + 1] = sub(s, start, k - 1)
            return table.concat(parts), k + 1
        elseif c ~= B_BACKSLASH then
            error("line break in string")
        end
        parts[#parts + 1] = sub(s, start, k - 1)
        local e = sub(s, k + 1, k + 1)
        local digits = s:match("^%d%d?%d?", k + 1)
        if digits then
            local n = tonumber(digits) --[[@as integer]]   -- one to three digits: always a number
            if n > 255 then error("bad escape") end
            parts[#parts + 1] = char(n)
            j = k + 1 + #digits
        elseif ESCAPES[e] then
            parts[#parts + 1] = ESCAPES[e]
            j = k + 2
            if e == "\r" and sub(s, j, j) == "\n" then j = j + 1 end
        else
            error("bad escape")
        end
        start = j
    end
end

local readValue

local function readTable(s, i, depth)
    if depth > M.MAX_DEPTH then error("too deep") end
    local t, n = {}, 0
    i = skip(s, i + 1)
    while sub(s, i, i) ~= "}" do
        local key, value
        local c = byte(s, i)
        local name, after = s:match("^([%a_][%w_]*)%s*=()", i)
        if name then
            key, i = name, after
        elseif c == B_BRACKET then
            key, i = readValue(s, skip(s, i + 1), depth)
            i = skip(s, i)
            if key == nil or key ~= key then error("bad key") end
            if sub(s, i, i) ~= "]" then error("']' expected") end
            i = skip(s, i + 1)
            if sub(s, i, i) ~= "=" then error("'=' expected") end
            i = i + 1
        else
            n = n + 1
            key = n
        end
        value, i = readValue(s, skip(s, i), depth)
        t[key] = value
        i = skip(s, i)
        local sep = sub(s, i, i)
        if sep == "," or sep == ";" then
            i = skip(s, i + 1)
        elseif sep ~= "}" then
            error("'}' expected")
        end
    end
    return t, i + 1
end

function readValue(s, i, depth)
    local c = byte(s, i)
    if c == B_BRACE then return readTable(s, i, depth + 1) end
    if c == B_QUOTE then return readString(s, i) end
    local num, after = s:match("^(%-?%d+%.?%d*)()", i)
    if not num then num, after = s:match("^(%-?%.%d+)()", i) end
    if num then
        local exp, after2 = s:match("^([eE][%+%-]?%d+)()", after)
        if exp then num, after = num .. exp, after2 end
        local v = tonumber(num)
        if not v then error("bad number") end
        return v, after
    end
    local word
    word, after = s:match("^(%-?[%a_][%w_]*)()", i)
    if word then
        local bare = word:gsub("^%-", "")
        if bare == "true" or bare == "false" then
            if bare ~= word then error("bad value") end
            return WORDS[word], after
        end
        if bare == "nil" or bare == "inf" or bare == "nan" then return nil, after end
    end
    error("value expected")
end

-- The value `encode` wrote, or nil (and an error message) when `s` is not such a chunk.
---@param s string
---@return any value
---@return string? err
function M.decode(s)
    if type(s) ~= "string" then return nil, "not a string" end
    local ok, v, err = pcall(function()
        local i = skip(s, 1)
        if sub(s, i, i + 5) ~= "return" then error("'return' expected") end
        local value, j = readValue(s, skip(s, i + 6), 0)
        j = skip(s, j)
        if j <= #s then error("trailing data") end
        return value
    end)
    if ok then return v end
    return nil, (tostring(v):gsub("^.-:%d+: ", ""))
end

return M
