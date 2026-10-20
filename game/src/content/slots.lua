-- Persisted slot allocation for mod records (docs/data-driven/02-entities.md 2.1, 06-mod-runtime.md 6.5). Races, spheres, skills, classes and
-- victory conditions carry a number scenarios, saves and hero profiles store. A mod record that gives `slot = "auto"` gets the next free
-- number from this table, and keeps it: the table (`<mods root>/slots.lua`, `return { race = { ["mymod:goblin"] = 16 } }`) is written whenever
-- a new id was seen, and a number is never given to another id, even when the mod that had it is gone, so old saves and scenarios keep
-- their meaning.
local mods = require("src.content.mods")

local M = {}

-- The first number of a mod per kind (the original content takes the ones below).
M.FIRST = { race = 16, sphere = 13, skill = 107, class = 28, victory = 13, damagetype = 7 }

local table_, root, dirty

local function load()
    if table_ and root == mods.root then return end
    root, dirty, table_ = mods.root, false, {}
    local path = root .. "/slots.lua"
    local text = love.filesystem.getInfo(path) and love.filesystem.read(path)
    if text then
        local chunk = loadstring(text, "@" .. path)
        if chunk then
            setfenv(chunk, {})
            local ok, t = pcall(chunk)
            if ok and type(t) == "table" then table_ = t end
        end
    end
end

-- The slot of `id` in `kind`: its earlier one, or the next free number.
---@param kind ContentKind<table>
---@param id ContentId
---@return integer
function M.allocate(kind, id)
    load()
    local mine = table_[kind.name] or {}
    table_[kind.name] = mine
    if mine[id] then return mine[id] end
    local used = {}
    for _, n in pairs(mine) do used[n] = true end
    for _, rec in ipairs(kind:all()) do
        if type(rec.slot) == "number" then used[rec.slot] = true end
    end
    local n = M.FIRST[kind.name] or 0
    while used[n] do n = n + 1 end
    mine[id] = n
    dirty = true
    return n
end

-- Writes the table when something new was allocated.
function M.save()
    if not dirty then return end
    love.filesystem.createDirectory(root)
    local lines = { "-- Slots given to mod records (a number is never reused): do not edit", "return {" }
    local kinds = {}
    for name in pairs(table_) do kinds[#kinds + 1] = name end
    table.sort(kinds)
    for _, name in ipairs(kinds) do
        lines[#lines + 1] = ("    %s = {"):format(name)
        local ids = {}
        for id in pairs(table_[name]) do ids[#ids + 1] = id end
        table.sort(ids)
        for _, id in ipairs(ids) do lines[#lines + 1] = ("        [%q] = %d,"):format(id, table_[name][id]) end
        lines[#lines + 1] = "    },"
    end
    lines[#lines + 1] = "}"
    love.filesystem.write(root .. "/slots.lua", table.concat(lines, "\n") .. "\n")
    dirty = false
end

-- Forgets what was read (the next allocation reads the file again).
function M.reset() table_ = nil end

return M
