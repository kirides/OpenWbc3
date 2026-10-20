-- Minimal INI reader/writer. Section and key names are case-insensitive
-- (stored lower-cased); values are kept as strings.
local M = {}

---@alias IniData table<string, table<string, string>>   lower-cased section -> lower-cased key -> value

---@param text string
---@return IniData data sections ("" = keys before the first section)
---@return string[] order section names in file order
function M.parse(text)
    local data, order = {}, {}
    local section = data[""] or {}
    data[""] = section
    for line in (text .. "\n"):gmatch("(.-)\r?\n") do
        line = line:gsub("^%s+", ""):gsub("%s+$", "")
        if line ~= "" and not line:match("^[;#]") and not line:match("^//") then
            local name = line:match("^%[(.-)%]$")
            if name then
                name = name:lower()
                section = data[name] or {}
                if not data[name] then order[#order + 1] = name end
                data[name] = section
            else
                local k, v = line:match("^(.-)%s*=%s*(.*)$")
                if k then section[k:lower()] = v end
            end
        end
    end
    return data, order
end

---@param path string
---@return IniData?
function M.load(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local text = f:read("*a")
    f:close()
    return (M.parse(text))
end

-- Typed getters: the value is converted to the type of `default` (number, boolean; otherwise the string).
---@generic T
---@param data IniData?
---@param section string
---@param key string
---@param default T
---@return T
function M.get(data, section, key, default)
    local s = data and data[section:lower()]
    local v = s and s[key:lower()]
    if v == nil then return default end
    if type(default) == "number" then return tonumber(v) or default end
    if type(default) == "boolean" then
        v = v:lower()
        return v == "1" or v == "true" or v == "yes" or v == "on"
    end
    return v
end

---@param sections IniData
---@return string
function M.serialize(sections)
    local out = {}
    for name, kv in pairs(sections) do
        out[#out + 1] = "[" .. name .. "]"
        local keys = {}
        for k in pairs(kv) do keys[#keys + 1] = k end
        table.sort(keys)
        for _, k in ipairs(keys) do out[#out + 1] = k .. "=" .. tostring(kv[k]) end
        out[#out + 1] = ""
    end
    return table.concat(out, "\n")
end

return M
