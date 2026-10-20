-- Content kind `itemclass` (stage 2, docs/data-driven/02-entities.md 2.5): the item classes, one row of Items.bmp each
-- (the original's equipment slot symbols). Key: the class name ("Sword" ...).
--   slot    the row of Items.bmp, which doubles as the class number
--   count   how many items of the class a hero wears (two rings, one of everything else)
--   worn    the worn slot (1..7 of hero.SLOT_LAYOUT) a computer hero's item of the class goes to (FUN_0042a0d0's switch)
---@class ItemClassRecord
---@field id string
---@field slot integer
---@field count integer
---@field worn integer

return {
    name = "itemclass",
    doc = "item classes",
    sortBy = "slot",
}
