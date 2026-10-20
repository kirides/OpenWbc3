-- Content kind `tag` (stage 2, docs/data-driven/02-entities.md "Tags"): named traits of units and buildings, replacing the
-- literal code sets scattered through the engine ("is this a dragon?" is `unit.tagSet.dragon`, not DRAGON[code]).
-- Record: { id = "dragon", doc = "...", from = { field = value ... }, appliesTo = "unit" | "building" | nil }
--   from       tags implied by typed fields: a record gets the tag when every listed field equals the value
--              (`from = { alignment = "evil" }`, `{ raceClass = "U" }`, `{ planar = true }`)
-- Units and buildings list the other tags in their `tags` array. `finalise` derives `tagSet` (id -> true) from both;
-- the engine reads `rec.tagSet.<id>` (or gamedata.hasTag(code, id)). A tag that no record defines is an error for
-- mods and the base layer (a typo cannot silently never match).
---@class TagRecord
---@field id string
---@field doc string?
---@field from table<string, any>?      typed field -> value that implies the tag
---@field appliesTo "unit"|"building"|nil

local M = {
    name = "tag",
    doc = "traits of units and buildings",
}

-- The tagSet of a unit or building record: its own `tags` plus the tags its typed fields imply.
---@param rec UnitRecord|BuildingRecord
---@param kind ContentKind<table>
---@param tagKind ContentKind<TagRecord>
---@return table<string, true>
function M.tagSet(rec, kind, tagKind)
    local set = {}
    for _, id in ipairs(rec.tags or {}) do set[id] = true end
    for _, tag in ipairs(tagKind:all()) do
        local from = tag.from
        if from and (tag.appliesTo == nil or tag.appliesTo == kind.name) then
            local ok = true
            for field, value in pairs(from) do
                if rec[field] ~= value then ok = false break end
            end
            if ok then set[tag.id] = true end
        end
    end
    return set
end

return M
