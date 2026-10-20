-- The asset layer of the content registry (docs/data-driven/05-assets.md): where a mod's own files are found, and how they replace or
-- add to the install's. A reference to an asset is a plain Lua value in a record:
--   sprite = "AHBX"                          the install's sprite set by code (the default for an original unit / building)
--   sprite = { orig = "AHBX" }               the same, explicit
--   sprite = { png = "gfx/shaman", mod = "shaman" }   a PNG sprite set in the mod's folder (src/gfx/pngset.lua); `asset.sprite` builds it
-- and `override/<name>` in a mod's folder replaces an entry of the install's archives by name (override/AHBX.ani, override/Whip.wav): the
-- simplest way to re-skin one unit or one sound. Later mods win over earlier ones, the mods win over the install.
local M = {}

---@class AssetMount
---@field id string   mod id
---@field dir { read: fun(self: any, rel: string): string? }   the mod's folder (src/content/mods.lua)

-- The mounts: { { id = "shaman", dir = <modfs dir> } ... } in load order, set by the loader after the mods are planned.
local mounts, byId, cache = {}, {}, {}      -- cache: entry name -> { data, modId } or false (the folders do not change while the game runs)

---@param list AssetMount[]?
function M.setMounts(list)
    mounts, byId, cache = list or {}, {}, {}
    for _, m in ipairs(mounts) do byId[m.id] = m end
end

---@return AssetMount[]
function M.mounts() return mounts end

-- The bytes of a file of a mod's folder, or nil.
---@param modId string
---@param rel string
---@return string?
function M.read(modId, rel)
    local m = byId[modId]
    return m and m.dir:read(rel) or nil
end

-- The replacement of an install entry (`override/<entry name>` of the latest mod that has it), or nil. Names are matched as given and in
-- lower and upper case.
---@param name string
---@return string? data
---@return string? modId
function M.override(name)
    local hit = cache[name]
    if hit == nil then
        hit = false
        for i = #mounts, 1, -1 do
            local dir = mounts[i].dir
            local data = dir:read("override/" .. name) or dir:read("override/" .. name:lower()) or dir:read("override/" .. name:upper())
            if data then hit = { data, mounts[i].id } break end
        end
        cache[name] = hit
    end
    if hit then return hit[1], hit[2] end
    return nil
end

-- True when any mod has an override folder (so the common case of no mods costs nothing).
---@return boolean
function M.active() return #mounts > 0 end

-- Builders for references, used by mod code as `asset.sprite("gfx/shaman")`: they remember which mod's folder the path is relative to.
function M.builders(modId)
    return {
        sprite = function(path) return { png = path, mod = modId } end,
        sound = function(path) return { file = path, mod = modId } end,
        icon = function(path) return { file = path, mod = modId } end,
        orig = function(code) return { orig = code } end,
    }
end

return M
