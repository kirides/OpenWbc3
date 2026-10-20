-- Content kind `resource` (stage 4, docs/data-driven/04-heroes-abilities-rules.md 4.6): the economy's resources. Key: "gold", "metal",
-- "crystal", "stone". The records are the one place that lists them (in the order the engine iterates them); the HUD layout, the
-- scenario format and the saves assume these four, so a mod cannot add a fifth yet.
--   letter   the resource column of Building.cfg (the mine types BRG.. / BRM.. / BRC.. / BRS.. end in it)
--   colour   { r, g, b } 0..255 of the minimap and the HUD
---@class ResourceRecord
---@field id string
---@field letter string
---@field colour integer[]

return {
    name = "resource",
    doc = "resources",
}
