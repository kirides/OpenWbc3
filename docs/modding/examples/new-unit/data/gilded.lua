-- `clone` copies a record so that it can be changed freely; ids of a mod are "modid:name". A scenario file stores four letters only: the
-- alias "MGLD" lets the editor and scenarios place the unit.
local knight = content.clone(content.unit["AHFX"])
knight.id = "new_unit:gilded"
knight.label = "Gilded Knight"
knight.hits = knight.hits + 25
knight.combat = knight.combat + 2
knight.cost = { gold = 400, metal = 150, crystal = 0, stone = 0 }
knight.sprite = "AHFX"                    -- the art: an install sprite set by code, or a PNG set of the mod (docs/modding/assets.md)
knight.tags = { "knight" }                 -- tags are traits the rules look for (content/base/tags.lua)
content.unit:add(knight)
content.unit:alias("MGLD", "new_unit:gilded")
