# The kinds of content

Every kind is a table `content.<kind>` with the API of `registry.md` (`add`, `patch`, `remove`, `alias`, `all`, `ids`, `bySlot` ...).
`--dump-content` writes the real records of the running game: that is the authoritative field list. The header comment of each file of
`game/src/content/kinds/` describes the fields in full; this page says what each kind is for and how a mod uses it.

| kind | key | what it holds |
|---|---|---|
| `setting` | name (`eco.mineProduce`) | the numbers of the rules: economy, step times, vision, XP table, hero limits ... Patch `value` (tables merge field by field). |
| `resource` | `gold` `metal` `crystal` `stone` | the four resources and their colours. A mod cannot add a fifth (the HUD, scenario format and saves assume four). |
| `race` | name (`human`), mod ids `modid:name` | a race: role units, build list, hero modifiers, retinue, customisation lists. `slot` is the number saves store; `slot = "auto"` for a mod race. |
| `tag` | name (`dragon`) | a named trait of units and buildings (replaces the engine's code sets). Rules look at `unit.tagSet.<tag>`. |
| `unit` | 4-letter code or `modid:name` | army and hero types: stats of the `.ARM` block, typed Army.cfg columns, `tags`, `behaviour`, `sprite`. `content.unit:alias("MGLD", id)` gives a mod unit the four letters a scenario file stores. |
| `building` | 4-letter code or `modid:name` | building types, their `produces` lists per race, `requires`, `tags`. |
| `powerup` | 4-letter code | permanent upgrades: cost, time, bonuses for army types. Their rule code is still in `game/src/game/powerups.lua`. |
| `item`, `itemclass`, `itempower` | number / name | the item catalogue (imported from `Items.xml`), the equipment classes, and what each power type of an item does. |
| `damagetype`, `missile` | name / picture code | the seven damage types with their numbers and classes; the missile pictures and their flags. |
| `status` | name (`poison`) | the timed effects on units, with their rules and hooks (`effects.md`). |
| `sphere`, `spell` | name / `sphere.index` | the spell spheres and the spells (`effects.md`: recipes and the `fx` library). |
| `skill`, `class` | name | the hero skills (value = `mul * level + base`) and the hero classes (attribute modifiers, life, mana, five skills each). |
| `ability` | name | the special buttons of troops and buildings (`spell`, `morph`, `building` abilities). |
| `attitude` | name | unit stances as rule sets of conditions and actions; the install's `CustomUnitAI/*.uai` files are imported as records after the nine built-in ones. |
| `victory` | name (`standard`) | the victory conditions the skirmish and editor screens offer, with their timers and win / lose tests. |
| `lair` | the lair building's code | what a neutral nest breeds (groups, levels, interval) and the boss it leaves; the building's production list follows from the groups. |
| `aiprofile` | level name (`knave` ... `barbarian`), `slot` = level | the numbers that differ between the computer player's levels. |

## Adding to a kind

```lua
-- data/ files (define phase): add whole records
content.attitude:add{ id = "mymod:brave", order = 50, title = "Brave", desc = "Fights everything.", icon = 3, size = 10,
                      rules = { { priority = 100, name = "", overrides = false,
                                  conds = { { code = 0, unit = 0, area = false, result = true, extra = { 0, 0, 0 } } },
                                  action = { code = 5, unit = 0, area = false, extra = { 0, 0, 0 } } } } }
-- patch/ files: change what exists
content.aiprofile:patch("emperor", { incomeCap = 50, rates = { army = 250 } })
content.lair:patch("BLBM", { max = 120000 })
```

Errors in a record (an unknown reference, a rule with a code the engine does not know) are reported when the registry is finalised and drop the
mod that made them; `--check-mod <folder>` shows them without starting the game.

## What is still code

These are not records yet; a mod changes them by `override/` of a file or not at all:

* the rules of **power-ups** (what `Knight's Quest`, `Sacred Grove` ... *do*, `game/src/game/powerups.lua`), the army abilities that need code
  (drunkenness, fanaticism, sacrifice, the wisp merge) and the unit specials (`unitspecials.lua`);
* **formations** (eight, tied to the eight buttons of the interface), the quest kinds of shrines, the shop rules;
* **terrain**, features, sounds, music, portraits, icons and texts are looked up by the engine's own names (`assets.md`).
