-- Content kind `item` (stage 2, docs/data-driven/02-entities.md 2.5): the item catalogue, imported from <Lang>/Items.xcr/Items.xml.
-- Key: the item number of the file (a number: saves, hero profiles and scenarios store it); a mod item uses "modid:name".
--   name, desc          texts of the install's language (the importer reads them at start-up)
--   powers              { { type = "combat", data = n, chance = n, level = n, text = "..." } ... }; `type` names an `itempower` record
--   row, col            picture cell in Items.bmp; `row` is also the item class (`itemclass.slot`), `slot` = row
--   value, rarity       gold value and the weight of random drops (0 = never dropped at random)
--   tierName, tier      "minor" "lesser" "greater" "artifact" "set" and its number 1..5 (setting `item.tiers`)

---@class ItemPowerEntry
---@field type string                   an `itempower` record id
---@field data integer
---@field chance integer?
---@field level integer?
---@field text string?

---@class ItemRecord
---@field id integer|string             the item number of the file, "modid:name" for a mod item
---@field name string
---@field desc string
---@field powers ItemPowerEntry[]
---@field row integer                   the picture row of Items.bmp, also the item class
---@field col integer
---@field slot integer                  = row
---@field value integer
---@field rarity integer
---@field tierName string
---@field tier integer

return {
    name = "item",
    doc = "items",
    ---@param rec ItemRecord
    validate = function(rec)
        if type(rec.powers) ~= "table" then return "has no powers list" end
    end,
}
