-- Patch semantics of the content registry (docs/data-driven/01-content-registry.md 1.4): deep merge of a patch
-- table into a record, list operators, the REMOVE sentinel, literal values and computed (function) updates.
--
--   scalar field          replaced
--   table (map) field     merged field by field, recursively
--   array field           replaced as a whole, unless the patch value is an operator table:
--                         { replace = {...}, remove = {...}, insertBefore = { match = m, value = v },
--                           insertAfter = { match = m, value = v }, prepend = {...}, append = {...} }
--                         (applied in that order). Elements with an `id` are addressed by it ("keyed lists").
--   content.REMOVE        deletes the field
--   function value        fn(old) -> new
--   content.value(v)      v is assigned literally (a function or table that must not be merged or called)
local M = {}

-- The sentinel a patch assigns to delete a field.
---@type table
M.REMOVE = setmetatable({}, { __tostring = function() return "content.REMOVE" end })

local LITERAL = {}
-- A patch value that is assigned as it is (a function or table that must not be merged or called).
---@param v any
---@return table
function M.value(v) return { [LITERAL] = true, v = v } end

local OPS = { replace = true, remove = true, insertBefore = true, insertAfter = true, prepend = true, append = true }
local OP_ORDER = { "replace", "remove", "insertBefore", "insertAfter", "prepend", "append" }

-- Deep copy; functions and the REMOVE sentinel are shared, shared / cyclic sub-tables stay shared in the copy.
---@generic T
---@param v T
---@param memo table?
---@return T
local function copy(v, memo)
    if type(v) ~= "table" or v == M.REMOVE then return v end
    memo = memo or {}
    local c = memo[v]
    if c then return c end
    c = {}
    memo[v] = c
    for k, x in pairs(v) do c[copy(k, memo)] = copy(x, memo) end
    local mt = getmetatable(v)
    if mt then setmetatable(c, mt) end
    return c
end
M.copy = copy

---@param t table
---@return boolean
local function isArray(t) return next(t) == nil or t[1] ~= nil end
M.isArray = isArray

local function isOperator(p)
    if p[1] ~= nil then return false end
    local any = false
    for k in pairs(p) do
        if not OPS[k] then return false end
        any = true
    end
    return any
end

-- Whether a list element is addressed by `m` (an id for records, the value itself for plain elements, or a predicate).
local function matches(el, m)
    if type(m) == "function" then return m(el) and true or false end
    if el == m then return true end
    return type(el) == "table" and el.id ~= nil and el.id == m
end

local function indexOf(list, m)
    for i, el in ipairs(list) do
        if matches(el, m) then return i end
    end
    return nil
end

-- A list of elements from an operator argument: an array, or a single keyed record.
local function elements(arg)
    if type(arg) ~= "table" then return { arg } end
    if arg[1] == nil and arg.id ~= nil then return { arg } end
    return arg
end

-- Appends a copy of `v` (an element, a keyed record or an array of them) to `list`; returns `list`.
---@param list any[]
---@param v any
---@return any[]
function M.append(list, v)
    for _, el in ipairs(elements(v)) do list[#list + 1] = copy(el) end
    return list
end

---@param list any[]
---@param v any
---@return any[]
function M.prepend(list, v)
    local els = elements(v)
    for i = #els, 1, -1 do table.insert(list, 1, copy(els[i])) end
    return list
end

-- Inserts `v` before (after = false) / after the element matching `match`.
---@param list any[]
---@param match any       an id, an element or a predicate
---@param v any
---@param after boolean?
---@return any[]
function M.insert(list, match, v, after)
    local at = indexOf(list, match)
    if not at then error(("insert: no element matches %s"):format(tostring(type(match) == "function" and "<predicate>" or match)), 0) end
    if after then at = at + 1 end
    for i, el in ipairs(elements(v)) do table.insert(list, at + i - 1, copy(el)) end
    return list
end

---@param list any[]
---@param match any
---@param v any
---@return any[]
function M.insertBefore(list, match, v) return M.insert(list, match, v, false) end
---@param list any[]
---@param match any
---@param v any
---@return any[]
function M.insertAfter(list, match, v) return M.insert(list, match, v, true) end

-- Removes every element accepted by `pred` (a predicate, or an id / value, or an array of those).
---@param list any[]
---@param pred any
---@return integer removed
function M.removeWhere(list, pred)
    local keep, removed = {}, 0
    local tests = (type(pred) == "table") and pred or { pred }
    for _, el in ipairs(list) do
        local hit = false
        for _, m in ipairs(tests) do
            if matches(el, m) then hit = true break end
        end
        if hit then removed = removed + 1 else keep[#keep + 1] = el end
    end
    for i = #list, 1, -1 do list[i] = nil end
    for i, el in ipairs(keep) do list[i] = el end
    return removed
end

local function applyOperators(list, p, path)
    for _, name in ipairs(OP_ORDER) do
        local arg = p[name]
        if arg ~= nil then
            if name == "replace" then
                for i = #list, 1, -1 do list[i] = nil end
                for i, el in ipairs(copy(arg)) do list[i] = el end
            elseif name == "remove" then
                M.removeWhere(list, arg)
            elseif name == "append" then
                M.append(list, arg)
            elseif name == "prepend" then
                M.prepend(list, arg)
            else
                if type(arg) ~= "table" or arg.match == nil then
                    error(("%s: %s needs { match = ..., value = ... }"):format(path, name), 0)
                end
                local ok, err = pcall(M.insert, list, arg.match, arg.value, name == "insertAfter")
                if not ok then error(path .. ": " .. tostring(err), 0) end
            end
        end
    end
    return list
end

-- A deep copy of a patch value that becomes the value of a field that did not exist: `content.value` wrappers inside it are unwrapped.
local function fresh(v, memo)
    if type(v) ~= "table" or v == M.REMOVE then return v end
    memo = memo or {}
    if memo[v] then return memo[v] end
    if v[LITERAL] then return copy(v.v) end
    local c = {}
    memo[v] = c
    for k, x in pairs(v) do c[k] = fresh(x, memo) end
    return c
end

-- The new value of a field holding `old` after the patch value `p`.
local function patchValue(old, p, path)
    if p == M.REMOVE then return nil end
    local tp = type(p)
    if tp == "function" then return p(old) end
    if tp ~= "table" then return p end
    if p[LITERAL] then return copy(p.v) end
    if isOperator(p) then
        if old ~= nil and (type(old) ~= "table" or not isArray(old)) then
            error(("%s: list operator on a field that is not a list"):format(path), 0)
        end
        return applyOperators(old or {}, p, path)
    end
    if type(old) == "table" and not isArray(old) and not isArray(p) then
        for k, v in pairs(p) do
            local nv = patchValue(old[k], v, path .. "." .. tostring(k))
            old[k] = nv
        end
        return old
    end
    if type(old) == "table" and not isArray(old) and next(p) == nil then return old end
    return fresh(p)
end

-- Applies the patch table `p` to the record `rec` in place.
---@param rec table
---@param p table
---@param path string?   the name of the record in messages
---@return table
function M.apply(rec, p, path)
    path = path or tostring(rec.id or "record")
    for k, v in pairs(p) do
        rec[k] = patchValue(rec[k], v, path .. "." .. tostring(k))
    end
    return rec
end

return M
