-- Content kind `lair` (stage 4, docs/data-driven/04-heroes-abilities-rules.md 4.5): the creature nests of the neutral side. Key: the code of the
-- building that is the lair (its Building.cfg has the "lair" flag; the record is what that building breeds).
--   min, max   the breeding interval in milliseconds (the first group comes after max plus dice, the next ones after min plus dice up to max)
--   boss       { unit = code, level = n }: what the lair leaves behind when it is destroyed
--   spawns     the groups it can breed, one is picked at random: { troops = n, troop = code, level = n,
--              leaders = n (default 0), leader = code, leaderLevel = n (default 1) }
-- Every unit the spawns name is added to the lair's production list (content/base/lairs.lua), which is what a side that owns the lair builds.
-- The numbers are the original's (src/game/sites.lua explains the breeding rules); a mod adds a lair by adding the record.
---@class LairSpawn
---@field troops integer
---@field troop string
---@field level integer
---@field leaders integer?
---@field leader string?
---@field leaderLevel integer?

---@class LairRecord
---@field id string                     the lair building's code
---@field min integer                   ms
---@field max integer                   ms
---@field boss { unit: string, level: integer }
---@field spawns LairSpawn[]

return {
    name = "lair",
    doc = "lairs: what a neutral nest breeds and leaves",
    refs = {
        { field = "boss.unit", target = "unit", mode = "id" },
        { field = "spawns.*.troop", target = "unit", mode = "id" },
        { field = "spawns.*.leader", target = "unit", mode = "id" },
    },
    ---@param rec LairRecord
    ---@param kind ContentKind<LairRecord>
    validate = function(rec, kind)
        if not kind._R.building[rec.id] then return "there is no building of that code" end
        if type(rec.min) ~= "number" or type(rec.max) ~= "number" or rec.max < rec.min then return "min and max must be numbers, max >= min" end
        if type(rec.spawns) ~= "table" or #rec.spawns == 0 then return "a lair needs at least one spawn group" end
    end,
}
