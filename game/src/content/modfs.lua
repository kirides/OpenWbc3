-- Read-only access to a mod's folder (docs/data-driven/06-mod-runtime.md 6.1). A root is either a folder below LÖVE's save directory
-- ("mods/<name>", read through love.filesystem) or any real folder (--mod <dir>, `[mods] path=` of openwbc3.ini; read through core/fs).
-- All paths given to the methods are relative to the root, with "/" and no "..".
local fs = require("src.core.fs")

local M = {}

-- A mod's folder.
---@class ModDir
---@field root string
---@field kind "save"|"real"
local Dir = {}
Dir.__index = Dir

-- `root` is a path; `kind` is "save" (relative to the save directory) or "real".
---@param root string
---@param kind ("save"|"real")?
---@return ModDir
function M.open(root, kind)
    return setmetatable({ root = root, kind = kind or "real" }, Dir)
end

---@param rel string
---@return string?
local function clean(rel)
    if rel:find("..", 1, true) or rel:sub(1, 1) == "/" or rel:find(":", 1, true) then return nil end
    return rel
end

---@param rel string
---@return string
function Dir:path(rel) return self.root .. "/" .. rel end

-- The text of a file, or nil.
-- (`rel` must stay inside the root: nil for "..", absolute paths and drive letters.)
---@return string? text
---@return any ...
function Dir:read(rel)
    rel = clean(rel)
    if not rel then return nil end
    if self.kind == "save" then
        local path = self:path(rel)
        if love.filesystem.getInfo(path, "file") then return love.filesystem.read(path) end
        return nil
    end
    return fs.read(self:path(rel))
end

---@param rel string
---@return boolean
function Dir:exists(rel) return self:read(rel) ~= nil end

-- Names of the *.lua files in a subfolder, sorted (never the file system's order: every machine must see the same one).
---@return string[]
function Dir:lua(rel)
    rel = clean(rel)
    local out = {}
    if not rel then return out end
    if self.kind == "save" then
        local path = self:path(rel)
        if love.filesystem.getInfo(path, "directory") then
            for _, name in ipairs(love.filesystem.getDirectoryItems(path)) do
                if name:lower():match("%.lua$") and love.filesystem.getInfo(path .. "/" .. name, "file") then out[#out + 1] = name end
            end
        end
    else
        for _, name in ipairs(fs.list(self:path(rel), "%.lua$") or {}) do out[#out + 1] = name end
    end
    table.sort(out, function(a, b) return a:lower() < b:lower() end)
    return out
end

-- Names of the subfolders of the root (to find mods in the mods folder).
---@param root string
---@param kind "save"|"real"
---@return string[]
function M.folders(root, kind)
    local out = {}
    if kind == "save" then
        if love.filesystem.getInfo(root, "directory") then
            for _, name in ipairs(love.filesystem.getDirectoryItems(root)) do
                if love.filesystem.getInfo(root .. "/" .. name, "directory") then out[#out + 1] = name end
            end
        end
    else
        for _, name in ipairs(fs.list(root) or {}) do
            if fs.exists(root .. "/" .. name .. "/mod.lua") then out[#out + 1] = name end
        end
    end
    table.sort(out, function(a, b) return a:lower() < b:lower() end)
    return out
end

return M
