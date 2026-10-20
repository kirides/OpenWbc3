-- Treasure chests of a scenario (ITMH records, parsed by src/formats/scn.lua and edited by src/screens/editoritems.lua): turns
-- a record into what lies on the map.
--
-- A chest of the original holds up to four items, each a random item (index -2) or a numbered one of the item table, or
-- a single resource entry (item type 14 / 15 / 16 / 17 = gold / stone / metal / crystal: 500 of it for the side of the
-- hero that opens the chest, the chest search `FUN_0053a1a0` of the 1.04 binary). A hero next to an item chest opens the
-- chest dialog (screens/chest.lua) while the battle goes on: it shows the hero's worn items and pack beside the chest, and
-- items go either way (as observed in the original; the dialog's routines are not traced in the binary yet). A computer
-- hero takes what fits. A random item is the tier-2 roll the
-- scenario chests always used (the original's random item `FUN_0043e340` ranges over all items; not reproduced).
local items = require("src.game.items")

local M = {}
M.RESOURCE_BY_CODE = { [14] = "gold", [15] = "stone", [16] = "metal", [17] = "crystal" }
M.AMOUNT = 500

local CW, CH = 32, 24

-- Puts the chest `rec` (an ITMH record) into `world`.
---@param world World
---@param rec table an ITMH record (formats/scn.lua)
function M.place(world, rec)
    local gx, gy = math.floor(rec.x / CW), math.floor(rec.y / CH)
    local c = rec.chest
    if not c then
        world:dropItem(gx, gy, items.random(2), rec.dir)
        return
    end
    if c.resource then
        local kind = M.RESOURCE_BY_CODE[c.items[1] and c.items[1].data]
        if kind then world:dropResource(gx, gy, kind, rec.dir) end
        return
    end
    local list = {}
    for k = 1, math.min(c.count, 4) do
        local m = c.items[k]
        local item = m and m.index >= 0 and items.get(m.index) or nil
        list[#list + 1] = item or items.random(2)
    end
    if #list > 0 then world:dropChest(gx, gy, list, rec.dir) end
end

return M
