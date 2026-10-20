-- Canonical serialisation and hash of the content registry (docs/data-driven/01-content-registry.md 1.6).
--
-- The registry hash must be identical on every peer for identical content, whatever the key order or the file system
-- order was, and differ when any value changes. The stream is: kinds in registration order, records in list order,
-- table keys sorted, numbers as integers or %.17g, functions as the hash of their source text (mod chunks, whose text
-- the loader registers) or of their stripped bytecode (engine functions). Provenance lives outside the records and is
-- not part of the stream; derived fields (kind.derived) and keys starting with "_" are skipped.
--
-- The hash is four 32-bit FNV-1a lanes with different offset bases and multipliers (128 bits, hex), computed with the
-- `bit` library only. It is a consistency check between peers, not a security measure.
local bit = require("bit")
local M = {}

local byte, tobit, bxor, lshift = string.byte, bit.tobit, bit.bxor, bit.lshift

local BASES = { 0x811c9dc5, 0x2c9277b5, 0x5bd1e995, 0x1b873593 }
local MULTS = { 403, 419, 427, 443 }   -- the FNV prime is 2^24 + 403; the others are odd offsets of the same shape

-- The four FNV-1a lanes ([1] .. [4]).
---@class ContentHasher
---@field [integer] integer
local Hasher = {}
Hasher.__index = Hasher

---@return ContentHasher
function M.new()
    local h = setmetatable({}, Hasher)
    for i = 1, 4 do h[i] = tobit(BASES[i]) end
    return h
end

---@param s string
function Hasher:add(s)
    local h1, h2, h3, h4 = self[1], self[2], self[3], self[4]
    for i = 1, #s do
        local b = byte(s, i)
        h1 = bxor(h1, b)
        h1 = tobit(h1 * 403 + lshift(h1, 24))
        h2 = bxor(h2, b)
        h2 = tobit(h2 * 419 + lshift(h2, 24))
        h3 = bxor(h3, b)
        h3 = tobit(h3 * 427 + lshift(h3, 24))
        h4 = bxor(h4, b)
        h4 = tobit(h4 * 443 + lshift(h4, 24))
    end
    self[1], self[2], self[3], self[4] = h1, h2, h3, h4
end

-- The hash as 32 hex digits.
---@return string
function Hasher:finish()
    return ("%08x%08x%08x%08x"):format(self[1] % 4294967296, self[2] % 4294967296, self[3] % 4294967296,
        self[4] % 4294967296)
end

-- Hash of a plain string (hex).
---@param s string
---@return string
function M.string(s)
    local h = M.new()
    h:add(s)
    return h:finish()
end

-- Ordering of table keys of mixed type: numbers first (by value), then strings, then anything else by tostring.
---@param a any
---@param b any
---@return boolean
local function keyLess(a, b)
    local ta, tb = type(a), type(b)
    if ta ~= tb then return ta == "number" or (tb ~= "number" and ta < tb) end
    if ta == "number" or ta == "string" then return a < b end
    return tostring(a) < tostring(b)
end
M.keyLess = keyLess

-- The canonical text of a number.
---@param v number
---@return string
function M.number(v)
    if v ~= v then return "nan" end
    if v == math.huge then return "inf" elseif v == -math.huge then return "-inf" end
    if v == math.floor(v) and math.abs(v) < 2 ^ 52 then return ("%d"):format(v) end
    return ("%.17g"):format(v)
end

-- Source lines of a chunk, by chunk name (the text of mod chunks the loader registered, else the file read through LÖVE: engine and
-- base files are relative to the game folder). Cached.
local lineCache = {}
local function linesOf(source, sources)
    local cached = lineCache[source]
    if cached ~= nil then return cached or nil end
    local text = sources and sources[source]
    if not text and source:sub(1, 1) == "@" and love and love.filesystem then
        text = love.filesystem.read(source:sub(2))
    end
    ---@type string[]|false
    local lines = false
    if text then
        lines = {}
        for line in (text .. "\n"):gmatch("(.-)\r?\n") do lines[#lines + 1] = line end
    end
    lineCache[source] = lines
    return lines or nil
end

-- Forget the cached source lines (a mod's files changed).
function M.clearSources() lineCache = {} end

-- Text a function stands for in the stream: the hash of its source lines plus the plain values it captured (a factory like
-- `psych("fear")` and `psych("awe")` share their text but not their upvalues). The source is the stable identity: bytecode
-- dumps carry JIT state (flags, hot-loop marks) that differs between runs and peers.
---@param f function
---@param sources table<string, string>?
---@return string
function M.functionId(f, sources)
    local info = debug.getinfo(f, "S")
    if info.what == "C" then return "builtin:C" end
    local lines = linesOf(info.source, sources)
    local parts = {}
    if lines then
        for i = info.linedefined, info.lastlinedefined do parts[#parts + 1] = lines[i] or "" end
    else
        parts[1] = info.short_src .. ":" .. info.linedefined
    end
    local n = 1
    while true do
        local name, value = debug.getupvalue(f, n)
        if not name then break end
        local tv = type(value)
        if tv == "string" or tv == "number" or tv == "boolean" then
            parts[#parts + 1] = name .. "=" .. tostring(value)
        end
        n = n + 1
    end
    return (sources and sources[info.source] and "fn:" or "builtin:") .. M.string(table.concat(parts, "\n"))
end

-- The length of the array part: the first hole ends it (`#` of a table with holes is not defined, and must not decide the hash).
local function length(t)
    local n = 0
    while t[n + 1] ~= nil do n = n + 1 end
    return n
end
M.length = length

local function skip(k, derived)
    return type(k) == "string" and (derived[k] or k:sub(1, 1) == "_")
end

-- Writes the canonical form of `v` to `emit(string)`. `derived` is the set of keys to leave out at the top level
-- of a record (kinds list their derived fields), `sources` the function source texts.
local function serialise(v, emit, derived, sources, depth, seen)
    local t = type(v)
    if t == "number" then emit(M.number(v))
    elseif t == "string" then emit(("%q"):format(v))
    elseif t == "boolean" then emit(tostring(v))
    elseif t == "function" then emit(M.functionId(v, sources))
    elseif t == "table" then
        if seen[v] then emit("<cycle>") return end
        seen[v] = true
        emit("{")
        local n = length(v)
        for i = 1, n do
            serialise(v[i], emit, nil, sources, depth + 1, seen)
            emit(",")
        end
        local keys = {}
        for k in pairs(v) do
            if not (type(k) == "number" and k >= 1 and k <= n and k == math.floor(k)) and not (depth == 0 and skip(k, derived or {})) then
                keys[#keys + 1] = k
            end
        end
        table.sort(keys, keyLess)
        for _, k in ipairs(keys) do
            serialise(k, emit, nil, sources, depth + 1, seen)
            emit("=")
            serialise(v[k], emit, nil, sources, depth + 1, seen)
            emit(";")
        end
        emit("}")
        seen[v] = nil
    else
        emit("nil")
    end
end

-- Canonical text of one value (a record, for tests and diffs).
---@param v any
---@param derived table<string, true>?
---@param sources table<string, string>?
---@return string
function M.canonical(v, derived, sources)
    local out = {}
    serialise(v, function(s) out[#out + 1] = s end, derived, sources, 0, {})
    return table.concat(out)
end

-- Hash of a whole registry: `kinds` is the ordered list of kind handles.
---@param kinds ContentKind<table>[]
---@param sources table<string, string>?
---@param meta string?
---@return string
function M.registry(kinds, sources, meta)
    local h = M.new()
    local buf, n = {}, 0
    local function emit(s)
        n = n + 1
        buf[n] = s
        if n >= 512 then
            h:add(table.concat(buf, "", 1, n))
            n = 0
        end
    end
    for _, kind in ipairs(kinds) do
        emit("#" .. kind.name .. "\n")
        local derived = kind.derivedSet
        for _, rec in ipairs(kind:all()) do
            serialise(rec, emit, derived, sources, 0, {})
            emit("\n")
        end
    end
    if n > 0 then h:add(table.concat(buf, "", 1, n)) end
    if meta and meta ~= "" then h:add("#meta\n" .. meta) end
    return h:finish()
end

return M
