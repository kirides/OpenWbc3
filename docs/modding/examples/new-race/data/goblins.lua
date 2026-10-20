-- A race is a record: the slot scenarios and saves store (16 and up for mods), the letter of the config files and the lists the rules need.
local goblins = content.clone(content.race["orc"])
goblins.id = "new_race:goblins"
goblins.slot = 16
goblins.letter = "Z"
goblins.name, goblins.plural, goblins.nameLine = "Goblin", "Goblins", nil
goblins.word = "goblin"
content.race:add(goblins)
