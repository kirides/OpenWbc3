-- Registry -> readable Lua source (`--dump-content`, docs/data-driven/01-content-registry.md 1.6): sorted, stable text
-- that `load` reads back into equal tables, so modders can see what they may patch and the golden-master checks of
-- docs/data-driven/07-verification-legal.md can diff it. Derived fields and "_" keys are left out (like the hash);
-- functions become the placeholder string "<function>".
local hash = require("src.content.hash")
local M = {}

local KEYWORDS = {}
for w in ("and break do else elseif end false for function if in local nil not or repeat return then true until while")
    :gmatch("%a+") do KEYWORDS[w] = true end

local function key(k)
    if type(k) == "string" and k:match("^[%a_][%w_]*$") and not KEYWORDS[k] then return k end
    if type(k) == "string" then return ("[%q]"):format(k) end
    return "[" .. hash.number(k) .. "]"
end

local function number(v)
    if v ~= v then return "0/0" end
    if v == math.huge then return "math.huge" elseif v == -math.huge then return "-math.huge" end
    return hash.number(v)
end

local function skip(k, derived)
    return type(k) == "string" and (derived[k] or k:sub(1, 1) == "_")
end

-- Short tables of scalars stay on one line, everything else is indented.
local function simple(v)
    if hash.length(v) > 8 then return false end
    for k, x in pairs(v) do
        if type(k) ~= "number" then return false end
        if type(x) == "table" or type(x) == "function" then return false end
    end
    return true
end

local function write(v, out, indent, derived, seen)
    local t = type(v)
    if t == "number" then out[#out + 1] = number(v)
    elseif t == "string" then out[#out + 1] = ("%q"):format(v):gsub("\\n", "\n")
    elseif t == "boolean" then out[#out + 1] = tostring(v)
    elseif t == "function" then out[#out + 1] = '"<function>"'
    elseif t == "table" then
        if seen[v] then out[#out + 1] = '"<cycle>"' return end
        seen[v] = true
        local n = hash.length(v)
        local keys = {}
        for k in pairs(v) do
            if not (type(k) == "number" and k >= 1 and k <= n and k == math.floor(k)) and not (derived and skip(k, derived)) then
                keys[#keys + 1] = k
            end
        end
        table.sort(keys, hash.keyLess)
        if n == 0 and #keys == 0 then
            out[#out + 1] = "{}"
        elseif #keys == 0 and simple(v) then
            out[#out + 1] = "{ "
            for i = 1, n do
                if i > 1 then out[#out + 1] = ", " end
                write(v[i], out, indent, nil, seen)
            end
            out[#out + 1] = " }"
        else
            out[#out + 1] = "{\n"
            local inner = indent .. "    "
            for i = 1, n do
                out[#out + 1] = inner
                write(v[i], out, inner, nil, seen)
                out[#out + 1] = ",\n"
            end
            for _, k in ipairs(keys) do
                out[#out + 1] = inner .. key(k) .. " = "
                write(v[k], out, inner, nil, seen)
                out[#out + 1] = ",\n"
            end
            out[#out + 1] = indent .. "}"
        end
        seen[v] = nil
    else
        out[#out + 1] = "nil"
    end
end

M.HEADER = "-- openwbc3 content dump. Derived from your local WBC3 install and the mods you enabled: do not redistribute.\n"

-- Lua source text `return { ... }` of one kind's records in registry order.
---@param kind ContentKind<table>
---@return string
function M.kind(kind)
    local out = { M.HEADER, "-- kind: ", kind.name, " (", tostring(kind:count()), " records)\nreturn {\n" }
    local derived = kind.derivedSet
    for _, rec in ipairs(kind:all()) do
        out[#out + 1] = "    "
        write(rec, out, "    ", derived, {})
        out[#out + 1] = ",\n"
    end
    out[#out + 1] = "}\n"
    return table.concat(out)
end

-- Text of a value (tests, diffs).
---@param v any
---@return string
function M.value(v)
    local out = {}
    write(v, out, "", nil, {})
    return table.concat(out)
end

return M
