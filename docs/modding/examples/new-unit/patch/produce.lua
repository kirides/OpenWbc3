-- The Knights' stables hire the new unit (production lists are keyed lists: `append` needs no index).
content.building:patch("BPSB", { produces = { human = { append = { { id = "new_unit:gilded", level = "0" } } } } })
