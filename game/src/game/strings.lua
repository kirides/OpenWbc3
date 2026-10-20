-- Localised "[KEY]<tab>text" string files from the language folder
-- (Help.cfg, Game.txt, Spells.txt, ...), converted to UTF-8.
local fs = require("src.core.fs")
local config = require("src.core.config")
local text = require("src.core.text")

local M = { files = {} }

---@param name string
---@return table<string, string>
local function load(name)
    local t = M.files[name]
    if t then return t end
    t = {}
    local data = fs.read(config.gamedir .. "/" .. config.language .. "/" .. name)
        or fs.read(config.gamedir .. "/English/" .. name)
    if data then
        for line in (data .. "\n"):gmatch("(.-)\r?\n") do
            local key, value = line:match("^%[([^%]]+)%]%s*(.-)%s*$")
            if key then t[key:upper()] = text.fromCP1252(value) end
        end
    end
    M.files[name] = t
    return t
end

---@param file string
---@param key string
---@return string?
function M.get(file, key)
    return load(file)[key:upper()]
end

-- Help lines for a unit/building code: name, description, requirement, lines 1..3.
---@param code string
---@return {name: string?, desc: string?, requires: string?, hotkey: string?, lines: string[]}
function M.help(code)
    local h = load("Help.cfg")
    return {
        name = h[code .. "_NAME"],
        desc = h[code .. "_DESC"],
        requires = h[code .. "_REQU"],
        hotkey = h[code .. "_HKEY"],
        lines = { h[code .. "_LIN1"], h[code .. "_LIN2"], h[code .. "_LIN3"] },
    }
end

return M
